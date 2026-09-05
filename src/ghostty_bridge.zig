const std = @import("std");
const io = @import("io.zig");
const builtin = @import("builtin");
const c = @import("c.zig").c;
const config_mod = @import("config.zig");
const pane_mod = @import("pane.zig");
const Pane = pane_mod.Pane;

// Global ghostty state
var ghostty_app: c.ghostty_app_t = null;
var ghostty_config: c.ghostty_config_t = null;
var needs_tick: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
const resize_cursor_override_key = "seance-resize-override";

// Captured clipboard text from the most recent writeClipboardCb call.
// Used by session.zig to read scrollback file paths without going through
// GDK clipboard (which fails on Wayland during shutdown).
// Only accessed from the GTK main thread — no synchronization needed.
pub var captured_clipboard: [4096]u8 = [_]u8{0} ** 4096;
pub var captured_clipboard_len: usize = 0;

// Path to ghostty's original resources dir (before wrapping).
var ghostty_orig_resources: [std.fs.max_path_bytes]u8 = undefined;
var ghostty_orig_resources_len: usize = 0;
// Path to our runtime wrapper resources dir.
var wrapper_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
var wrapper_dir_len: usize = 0;
// Path to seance's own bundled themes directory.
// Usually <prefix>/share/ghostty/themes, but distro packages that bundle
// resources under share/seance/ghostty use that location instead.
var seance_themes_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
var seance_themes_dir_len: usize = 0;

/// Return seance's bundled themes directory, if found.
pub fn getSeanceThemesDir() ?[]const u8 {
    if (seance_themes_dir_len == 0) return null;
    return seance_themes_dir_buf[0..seance_themes_dir_len];
}

/// Return ghostty's original resources directory (before wrapping), if found.
pub fn getGhosttyOrigResourcesDir() ?[]const u8 {
    if (ghostty_orig_resources_len == 0) return null;
    return ghostty_orig_resources[0..ghostty_orig_resources_len];
}

/// Locate seance's own bundled themes dir relative to the executable.
/// Tries the seance-private location first (used by distro packages that
/// move share/ghostty under share/seance/ghostty to avoid conflicts).
fn findSeanceThemesDir() void {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = io.executablePath(&exe_buf) catch return;
    const exe_dir = std.fs.path.dirname(exe_path) orelse return;
    const prefix = std.fs.path.dirname(exe_dir) orelse return;
    const suffixes = [_][]const u8{ "share/seance/ghostty/themes", "share/ghostty/themes" };
    for (suffixes) |suffix| {
        const path = std.fmt.bufPrint(&seance_themes_dir_buf, "{s}/{s}", .{ prefix, suffix }) catch return;
        if (std.Io.Dir.accessAbsolute(io.get(), path, .{})) {
            seance_themes_dir_len = path.len;
            return;
        } else |_| {}
    }
}

/// Set GHOSTTY_RESOURCES_DIR to a wrapper directory that mirrors ghostty's
/// resources but replaces the shell integration scripts with wrappers that
/// chain-load the originals and then source seance's integration.
fn ensureResourcesDir() void {
    // Locate seance's own bundled themes independently of ghostty
    findSeanceThemesDir();

    // Step 1: locate ghostty's real resources
    if (io.getenv("GHOSTTY_RESOURCES_DIR")) |existing| {
        const len = existing.len;
        if (len >= ghostty_orig_resources.len) return;
        @memcpy(ghostty_orig_resources[0..len], existing[0..len]);
        ghostty_orig_resources[len] = 0;
        ghostty_orig_resources_len = len;
    } else if (!findGhosttyResourcesDir()) {
        std.log.warn("ghostty_bridge: no ghostty resources dir found, shell integration will be disabled", .{});
        return;
    }

    // Step 2: create a wrapper dir that injects seance shell integration
    if (createWrapperResourcesDir()) {
        _ = c.setenv("GHOSTTY_RESOURCES_DIR", @ptrCast(&wrapper_dir_buf), 1);
        std.log.debug("ghostty_bridge: using wrapper resources dir: {s}", .{wrapper_dir_buf[0..wrapper_dir_len]});
    } else {
        _ = c.setenv("GHOSTTY_RESOURCES_DIR", @ptrCast(&ghostty_orig_resources), 1);
        std.log.debug("ghostty_bridge: using ghostty resources dir: {s}", .{ghostty_orig_resources[0..ghostty_orig_resources_len]});
    }
}

/// Locate ghostty's resources dir and store in ghostty_orig_resources.
///
/// Distro packages (e.g. Arch) move share/ghostty under share/seance/ghostty
/// to avoid file conflicts with the system ghostty package, so the
/// seance-private location is checked first on every candidate prefix.
fn findGhosttyResourcesDir() bool {
    const suffixes = [_][]const u8{ "share/seance/ghostty", "share/ghostty" };

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (io.executablePath(&exe_buf)) |exe_path| {
        if (std.fs.path.dirname(exe_path)) |exe_dir| {
            if (std.fs.path.dirname(exe_dir)) |prefix| {
                for (suffixes) |suffix| {
                    if (tryGhosttyResourcesAt(prefix, suffix)) return true;
                }
            }
        }
    } else |_| {}

    const system_prefixes = [_][]const u8{ "/usr", "/usr/local" };
    for (system_prefixes) |prefix| {
        for (suffixes) |suffix| {
            if (tryGhosttyResourcesAt(prefix, suffix)) return true;
        }
    }
    return false;
}

/// If "<prefix>/<suffix>/shell-integration" exists, store "<prefix>/<suffix>"
/// in ghostty_orig_resources and return true.
fn tryGhosttyResourcesAt(prefix: []const u8, suffix: []const u8) bool {
    const res_path = std.fmt.bufPrintZ(&ghostty_orig_resources, "{s}/{s}", .{ prefix, suffix }) catch return false;
    const res_slice = std.mem.sliceTo(res_path, 0);
    var check_buf: [std.fs.max_path_bytes]u8 = undefined;
    const check_path = std.fmt.bufPrint(&check_buf, "{s}/shell-integration", .{res_slice}) catch return false;
    std.Io.Dir.accessAbsolute(io.get(), check_path, .{}) catch return false;
    ghostty_orig_resources_len = res_slice.len;
    return true;
}

/// Build a runtime wrapper directory that mirrors ghostty's resources via
/// symlinks, except for bash/zsh shell integration which we replace with
/// thin wrappers that chain-load the originals then source seance integration.
fn createWrapperResourcesDir() bool {
    const real = ghostty_orig_resources[0..ghostty_orig_resources_len];
    if (real.len == 0) return false;

    const runtime_dir = io.getenv("XDG_RUNTIME_DIR") orelse return false;
    const pid = std.c.getpid();

    // Create a parent dir that holds both the resources subdir and a terminfo
    // symlink as siblings.  Ghostty's Exec.zig computes
    //   TERMINFO = dirname(GHOSTTY_RESOURCES_DIR) + "/terminfo"
    // so this layout ensures child processes can resolve xterm-ghostty.
    var parent_buf: [std.fs.max_path_bytes]u8 = undefined;
    const parent_path = std.fmt.bufPrintZ(&parent_buf, "{s}/seance-resources-{d}", .{ runtime_dir, pid }) catch return false;

    // Clean any stale wrapper dir from a previous crashed instance with the same PID
    std.Io.Dir.cwd().deleteTree(io.get(), parent_path) catch {};
    std.Io.Dir.createDirAbsolute(io.get(), parent_path, .default_dir) catch return false;

    // Resources subdir — this is what GHOSTTY_RESOURCES_DIR will point to
    const wrapper_path = std.fmt.bufPrintZ(&wrapper_dir_buf, "{s}/ghostty", .{parent_path}) catch return false;
    wrapper_dir_len = wrapper_path.len;
    std.Io.Dir.createDirAbsolute(io.get(), wrapper_path, .default_dir) catch return false;

    // Symlink the terminfo database as a sibling of the resources subdir
    if (std.fs.path.dirname(real)) |real_parent| {
        var ti_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.fmt.bufPrint(&ti_buf, "{s}/terminfo", .{real_parent})) |ti_target| {
            var pd = std.Io.Dir.openDirAbsolute(io.get(), parent_path, .{}) catch return false;
            defer pd.close(io.get());
            pd.symLink(io.get(), ti_target, "terminfo", .{ .is_directory = true }) catch |e| {
                std.log.warn("ghostty_bridge: failed to symlink terminfo: {}", .{e});
            };
        } else |_| {}
    }

    var wd = std.Io.Dir.openDirAbsolute(io.get(), wrapper_path, .{}) catch return false;
    defer wd.close(io.get());

    // Symlink all top-level entries except shell-integration and themes
    // (those are handled separately below)
    {
        var rd = std.Io.Dir.openDirAbsolute(io.get(), real, .{ .iterate = true }) catch return false;
        defer rd.close(io.get());
        var it = rd.iterate();
        while (it.next(io.get()) catch null) |entry| {
            if (std.mem.eql(u8, entry.name, "shell-integration")) continue;
            if (std.mem.eql(u8, entry.name, "themes")) continue;
            var tbuf: [std.fs.max_path_bytes]u8 = undefined;
            const target = std.fmt.bufPrint(&tbuf, "{s}/{s}", .{ real, entry.name }) catch continue;
            wd.symLink(io.get(), target, entry.name, .{ .is_directory = (entry.kind == .directory) }) catch |e| {
                std.log.warn("ghostty_bridge: failed to symlink {s}: {}", .{ entry.name, e });
            };
        }
    }

    // Create shell-integration dirs for bash and zsh
    wd.createDirPath(io.get(), "shell-integration/bash") catch return false;
    wd.createDirPath(io.get(), "shell-integration/zsh") catch return false;

    // Symlink all other shell-integration subdirs (elvish, fish, nushell, etc.)
    {
        var si_buf: [std.fs.max_path_bytes]u8 = undefined;
        const si_path = std.fmt.bufPrint(&si_buf, "{s}/shell-integration", .{real}) catch return false;
        var sid = std.Io.Dir.openDirAbsolute(io.get(), si_path, .{ .iterate = true }) catch return false;
        defer sid.close(io.get());
        var wsi = wd.openDir(io.get(), "shell-integration", .{}) catch return false;
        defer wsi.close(io.get());
        var it = sid.iterate();
        while (it.next(io.get()) catch null) |entry| {
            if (std.mem.eql(u8, entry.name, "bash") or std.mem.eql(u8, entry.name, "zsh")) continue;
            var tbuf: [std.fs.max_path_bytes]u8 = undefined;
            const target = std.fmt.bufPrint(&tbuf, "{s}/{s}", .{ si_path, entry.name }) catch continue;
            wsi.symLink(io.get(), target, entry.name, .{ .is_directory = (entry.kind == .directory) }) catch |e| {
                std.log.warn("ghostty_bridge: failed to symlink shell-integration/{s}: {}", .{ entry.name, e });
            };
        }
    }

    // Write wrapper shell integration scripts
    writeShellWrapper(wd, "shell-integration/bash/ghostty.bash", real, "/shell-integration/bash/ghostty.bash", "/bash-integration.sh") catch return false;
    writeShellWrapper(wd, "shell-integration/zsh/ghostty-integration", real, "/shell-integration/zsh/ghostty-integration", "/zsh-integration.sh") catch return false;

    // Create merged themes directory: seance bundled themes take precedence,
    // then ghostty's original themes fill in any gaps.
    createMergedThemesDir(wd, real);

    return true;
}

/// Build a themes/ directory in the wrapper containing symlinks to individual
/// theme files from both seance's bundled set and ghostty's original resources.
/// Seance themes are added first so they take precedence (duplicate names from
/// ghostty are silently skipped).
fn createMergedThemesDir(wd: std.Io.Dir, ghostty_resources: []const u8) void {
    wd.createDir(io.get(), "themes", .default_dir) catch return;
    var themes_dir = wd.openDir(io.get(), "themes", .{}) catch return;
    defer themes_dir.close(io.get());

    // Seance's bundled themes first (highest precedence)
    if (seance_themes_dir_len > 0) {
        symlinkThemesFrom(themes_dir, seance_themes_dir_buf[0..seance_themes_dir_len]);
    }

    // Then ghostty's original themes (skip names that already exist)
    var ghostty_themes_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ghostty_themes = std.fmt.bufPrint(&ghostty_themes_buf, "{s}/themes", .{ghostty_resources}) catch return;
    symlinkThemesFrom(themes_dir, ghostty_themes);
}

/// Symlink all theme files from source_path into themes_dir.
/// Existing entries are silently skipped (allows higher-priority sources
/// to take precedence).
fn symlinkThemesFrom(themes_dir: std.Io.Dir, source_path: []const u8) void {
    var source = std.Io.Dir.openDirAbsolute(io.get(), source_path, .{ .iterate = true }) catch return;
    defer source.close(io.get());
    var it = source.iterate();
    while (it.next(io.get()) catch null) |entry| {
        if (entry.kind == .directory) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        var target_buf: [std.fs.max_path_bytes]u8 = undefined;
        const target = std.fmt.bufPrint(&target_buf, "{s}/{s}", .{ source_path, entry.name }) catch continue;
        themes_dir.symLink(io.get(), target, entry.name, .{}) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => std.log.debug("ghostty_bridge: failed to symlink theme {s}: {}", .{ entry.name, e }),
        };
    }
}

fn writeShellWrapper(wd: std.Io.Dir, path: []const u8, real: []const u8, orig_suffix: []const u8, seance_suffix: []const u8) !void {
    var f = try wd.createFile(io.get(), path, .{});
    defer f.close(io.get());
    var buf: [2048]u8 = undefined;
    const content = std.fmt.bufPrint(&buf, "builtin source \"{s}{s}\"\n[[ -n \"$SEANCE_SHELL_INTEGRATION_DIR\" && -r \"$SEANCE_SHELL_INTEGRATION_DIR{s}\" ]] && builtin source \"$SEANCE_SHELL_INTEGRATION_DIR{s}\"\n", .{ real, orig_suffix, seance_suffix, seance_suffix }) catch return error.NoSpaceLeft;
    try f.writeStreamingAll(io.get(), content);
}

/// Remove the runtime wrapper resources directory.
pub fn cleanupResourcesWrapper() void {
    if (wrapper_dir_len == 0) return;
    const path = wrapper_dir_buf[0..wrapper_dir_len];
    // wrapper_dir_buf is .../seance-resources-{pid}/ghostty — delete the
    // parent to clean up both the resources subdir and the terminfo symlink.
    if (std.fs.path.dirname(path)) |parent| {
        std.Io.Dir.cwd().deleteTree(io.get(), parent) catch {};
    }
    wrapper_dir_len = 0;
}

/// Initialize the ghostty library and create the app instance.
/// Must be called after GTK is initialized but before creating surfaces.
pub fn init() bool {
    // Ensure ghostty can find its resources (shell integration, terminfo, etc.)
    ensureResourcesDir();

    // Initialize ghostty library (sets up allocators, logging)
    if (c.ghostty_init(0, null) != c.GHOSTTY_SUCCESS) {
        std.log.err("ghostty_bridge: ghostty_init failed", .{});
        return false;
    }

    // Create and configure ghostty config
    ghostty_config = c.ghostty_config_new() orelse {
        std.log.err("ghostty_bridge: ghostty_config_new failed", .{});
        return false;
    };

    // Apply seance defaults (e.g. window padding) before user configs,
    // so user's ghostty config can override them.
    applySeanceDefaults(@ptrCast(ghostty_config));

    // Load default ghostty config files (~/.config/ghostty/config etc.)
    c.ghostty_config_load_default_files(@ptrCast(ghostty_config));

    // Apply seance-specific overrides via a temp config file
    applySeanceConfig(@ptrCast(ghostty_config));

    // Finalize config (validates and applies defaults)
    c.ghostty_config_finalize(@ptrCast(ghostty_config));

    // Query resolved colors from ghostty (must be after finalization)
    const theme_mod = @import("theme.zig");
    theme_mod.queryGhosttyColors(@ptrCast(ghostty_config));

    // Set up runtime callbacks
    const rt_config = c.ghostty_runtime_config_s{
        .userdata = null,
        .supports_selection_clipboard = true,
        .wakeup_cb = wakeupCb,
        .action_cb = actionCb,
        .read_clipboard_cb = readClipboardCb,
        .confirm_read_clipboard_cb = confirmReadClipboardCb,
        .write_clipboard_cb = writeClipboardCb,
        .close_surface_cb = closeSurfaceCb,
    };

    // Create ghostty app
    ghostty_app = c.ghostty_app_new(&rt_config, @ptrCast(ghostty_config)) orelse {
        std.log.err("ghostty_bridge: ghostty_app_new failed", .{});
        c.ghostty_config_free(@ptrCast(ghostty_config));
        ghostty_config = null;
        return false;
    };

    std.log.debug("ghostty_bridge: initialized successfully", .{});
    return true;
}

/// Shut down ghostty and free resources.
pub fn deinit() void {
    if (ghostty_app) |app_ptr| {
        c.ghostty_app_free(app_ptr);
        ghostty_app = null;
    }
    if (ghostty_config) |cfg_ptr| {
        c.ghostty_config_free(cfg_ptr);
        ghostty_config = null;
    }
}

/// Get the ghostty app handle (for creating surfaces).
pub fn getApp() c.ghostty_app_t {
    return ghostty_app;
}

/// Manually trigger a tick (called from main loop).
pub fn tick() void {
    if (ghostty_app) |app_ptr| {
        c.ghostty_app_tick(app_ptr);
    }
}

// ── Runtime callbacks ─────────────────────────────────────────────

/// Called by ghostty when it needs the main loop to wake up and call tick().
/// This is called from IO/renderer threads, so we use an atomic swap to
/// coalesce rapid wakeups into a single idle callback.
fn wakeupCb(userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
    if (!needs_tick.swap(true, .seq_cst)) {
        _ = c.g_idle_add_full(c.G_PRIORITY_DEFAULT, tickIdleCb, null, null);
    }
    // Break the main loop out of its poll() so the idle fires immediately.
    c.g_main_context_wakeup(null);
}

/// GLib idle callback that performs the ghostty tick.
fn tickIdleCb(_: c.gpointer) callconv(.c) c.gboolean {
    needs_tick.store(false, .seq_cst);
    tick();
    return c.G_SOURCE_REMOVE;
}

/// Called by ghostty when an action needs to be performed by the host.
/// Returns true if the action was handled.
fn actionCb(
    app: c.ghostty_app_t,
    target: c.ghostty_target_s,
    action: c.ghostty_action_s,
) callconv(.c) bool {
    _ = app;
    return handleAction(target, action);
}

/// Get the Pane pointer from a surface target via userdata.
fn paneFromTarget(target: c.ghostty_target_s) ?*Pane {
    if (target.tag != c.GHOSTTY_TARGET_SURFACE) return null;
    const surface = target.target.surface orelse return null;
    const ud = c.ghostty_surface_userdata(surface);
    if (ud == null) return null;
    return @ptrCast(@alignCast(ud));
}

/// Handle ghostty actions by routing to seance systems.
fn handleAction(target: c.ghostty_target_s, action: c.ghostty_action_s) bool {
    switch (action.tag) {
        c.GHOSTTY_ACTION_SET_TITLE => {
            if (paneFromTarget(target)) |pane| {
                const title_data = action.action.set_title;
                if (title_data.title) |t| {
                    const title = std.mem.sliceTo(t, 0);
                    pane_mod.handleSetTitle(pane, title);
                }
            }
            return true;
        },
        c.GHOSTTY_ACTION_PWD => {
            if (paneFromTarget(target)) |pane| {
                const pwd_data = action.action.pwd;
                if (pwd_data.pwd) |p| {
                    const pwd = std.mem.sliceTo(p, 0);
                    if (pane.updateCwd(pwd)) {
                        // Refresh sidebar so CWD is shown on the workspace tab
                        const Window = @import("window.zig");
                        if (Window.window_manager) |wm| {
                            if (wm.findByWorkspaceId(pane.workspace_id)) |state| {
                                state.sidebar.refresh();
                                state.sidebar.setActive(state.active_workspace);
                            }
                        }
                    }
                }
            }
            return true;
        },
        c.GHOSTTY_ACTION_RING_BELL => {
            if (paneFromTarget(target)) |pane| {
                pane_mod.handleBell(pane);
            }
            return true;
        },
        c.GHOSTTY_ACTION_DESKTOP_NOTIFICATION => {
            if (paneFromTarget(target)) |pane| {
                const notif = action.action.desktop_notification;
                const title: ?[]const u8 = if (notif.title) |t| std.mem.sliceTo(t, 0) else null;
                const body: ?[]const u8 = if (notif.body) |b| std.mem.sliceTo(b, 0) else null;
                pane_mod.handleDesktopNotification(pane, title, body);
            }
            return true;
        },
        c.GHOSTTY_ACTION_SHOW_CHILD_EXITED => {
            if (paneFromTarget(target)) |pane| {
                pane_mod.handleChildExited(pane);
            }
            return true;
        },
        c.GHOSTTY_ACTION_MOUSE_SHAPE => {
            if (paneFromTarget(target)) |pane| {
                // Update cursor shape on the GLArea widget
                const shape = action.action.mouse_shape;
                const cursor_name: [*:0]const u8 = switch (shape) {
                    c.GHOSTTY_MOUSE_SHAPE_DEFAULT => "default",
                    c.GHOSTTY_MOUSE_SHAPE_TEXT => "text",
                    c.GHOSTTY_MOUSE_SHAPE_POINTER => "pointer",
                    c.GHOSTTY_MOUSE_SHAPE_CROSSHAIR => "crosshair",
                    c.GHOSTTY_MOUSE_SHAPE_MOVE => "move",
                    c.GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED => "not-allowed",
                    c.GHOSTTY_MOUSE_SHAPE_GRAB => "grab",
                    c.GHOSTTY_MOUSE_SHAPE_GRABBING => "grabbing",
                    c.GHOSTTY_MOUSE_SHAPE_COL_RESIZE => "col-resize",
                    c.GHOSTTY_MOUSE_SHAPE_ROW_RESIZE => "row-resize",
                    c.GHOSTTY_MOUSE_SHAPE_N_RESIZE => "n-resize",
                    c.GHOSTTY_MOUSE_SHAPE_E_RESIZE => "e-resize",
                    c.GHOSTTY_MOUSE_SHAPE_S_RESIZE => "s-resize",
                    c.GHOSTTY_MOUSE_SHAPE_W_RESIZE => "w-resize",
                    c.GHOSTTY_MOUSE_SHAPE_EW_RESIZE => "ew-resize",
                    c.GHOSTTY_MOUSE_SHAPE_NS_RESIZE => "ns-resize",
                    c.GHOSTTY_MOUSE_SHAPE_WAIT => "wait",
                    c.GHOSTTY_MOUSE_SHAPE_PROGRESS => "progress",
                    c.GHOSTTY_MOUSE_SHAPE_HELP => "help",
                    c.GHOSTTY_MOUSE_SHAPE_ALL_SCROLL => "all-scroll",
                    else => "default",
                };
                if (pane.gl_area) |gl| {
                    const gl_widget: *c.GtkWidget = @ptrCast(gl);
                    if (c.g_object_get_data(@as(*c.GObject, @ptrCast(gl_widget)), resize_cursor_override_key) == null) {
                        c.gtk_widget_set_cursor_from_name(gl_widget, cursor_name);
                    }
                }
            }
            return true;
        },
        c.GHOSTTY_ACTION_MOUSE_VISIBILITY => {
            return true;
        },
        c.GHOSTTY_ACTION_RENDER => {
            if (paneFromTarget(target)) |pane| {
                pane.queueRedraw();
            }
            return true;
        },
        c.GHOSTTY_ACTION_CELL_SIZE => {
            return true;
        },
        c.GHOSTTY_ACTION_SIZE_LIMIT => {
            return true;
        },
        c.GHOSTTY_ACTION_INITIAL_SIZE => {
            return true;
        },
        c.GHOSTTY_ACTION_SCROLLBAR => {
            if (paneFromTarget(target)) |pane| {
                const sb = action.action.scrollbar;
                pane.updateScrollbar(sb.total, sb.offset, sb.len);
            }
            return true;
        },
        c.GHOSTTY_ACTION_NEW_TAB => {
            return true;
        },
        c.GHOSTTY_ACTION_NEW_SPLIT => {
            return true;
        },
        c.GHOSTTY_ACTION_CLOSE_TAB => {
            return true;
        },
        c.GHOSTTY_ACTION_QUIT => {
            return true;
        },
        c.GHOSTTY_ACTION_COLOR_CHANGE => {
            return true;
        },
        c.GHOSTTY_ACTION_CONFIG_CHANGE => {
            return true;
        },
        c.GHOSTTY_ACTION_RENDERER_HEALTH => {
            return true;
        },
        c.GHOSTTY_ACTION_KEY_SEQUENCE => {
            return true;
        },
        c.GHOSTTY_ACTION_KEY_TABLE => {
            return true;
        },
        c.GHOSTTY_ACTION_OPEN_URL => {
            const url_data = action.action.open_url;
            if (url_data.url) |url_ptr| {
                if (url_data.len > 0 and url_data.len < 4096) {
                    var buf: [4096]u8 = undefined;
                    @memcpy(buf[0..url_data.len], url_ptr[0..url_data.len]);
                    buf[url_data.len] = 0;
                    _ = c.g_app_info_launch_default_for_uri(
                        @as([*c]const u8, @ptrCast(&buf)),
                        null,
                        null,
                    );
                }
            }
            return true;
        },
        c.GHOSTTY_ACTION_PRESENT_TERMINAL => {
            return true;
        },
        c.GHOSTTY_ACTION_START_SEARCH => {
            if (paneFromTarget(target)) |pane| {
                if (!pane.search_overlay.is_visible) {
                    pane.search_overlay.show();
                }
            }
            return true;
        },
        c.GHOSTTY_ACTION_END_SEARCH => {
            if (paneFromTarget(target)) |pane| {
                if (pane.search_overlay.is_visible) {
                    pane.search_overlay.hide();
                }
            }
            return true;
        },
        c.GHOSTTY_ACTION_SEARCH_TOTAL => {
            if (paneFromTarget(target)) |pane| {
                const total = action.action.search_total.total;
                pane.search_overlay.search_total = total;
                pane.search_overlay.updateMatchLabel();
            }
            return true;
        },
        c.GHOSTTY_ACTION_SEARCH_SELECTED => {
            if (paneFromTarget(target)) |pane| {
                const selected = action.action.search_selected.selected;
                pane.search_overlay.search_selected = selected;
                pane.search_overlay.updateMatchLabel();
            }
            return true;
        },
        else => {
            return false;
        },
    }
}

/// Context passed through the GDK async clipboard read callback.
const ClipboardReadCtx = struct {
    pane_id: u64,
    state: ?*anyopaque,
    list_available: bool,

    fn surface(self: *const ClipboardReadCtx) c.ghostty_surface_t {
        // The pane may have closed while GDK was reading the clipboard.
        const wm = @import("window.zig").window_manager orelse return null;
        const window = wm.findByPaneId(self.pane_id) orelse return null;
        for (window.workspaces.items) |ws| {
            if (ws.findPaneById(self.pane_id)) |pane| return pane.surface;
        }
        return null;
    }
};

fn clipboardCompletion(clipboard: *c.GdkClipboard, list_available: bool) c.ghostty_clipboard_complete_s {
    var result: c.ghostty_clipboard_complete_s = std.mem.zeroes(c.ghostty_clipboard_complete_s);
    result.confirmed = true; // Preserve Séance's existing clipboard policy.
    if (list_available) {
        const formats = c.gdk_clipboard_get_formats(clipboard);
        result.available = c.gdk_content_formats_get_mime_types(formats, &result.available_len);
    }
    return result;
}

/// Séance serves text from the standard and selection clipboards. The new
/// embedding API negotiates MIME types and uses explicit content lengths.
fn readClipboardCb(
    userdata: ?*anyopaque,
    clipboard_type: c.ghostty_clipboard_e,
    state: ?*anyopaque,
    mimes: [*c]const [*c]const u8,
    mimes_len: usize,
    list_available: bool,
) callconv(.c) c.ghostty_clipboard_read_result_e {
    const pane: *Pane = if (userdata) |ud| @ptrCast(@alignCast(ud)) else return c.GHOSTTY_CLIPBOARD_READ_UNAVAILABLE;
    const surface = pane.surface orelse return c.GHOSTTY_CLIPBOARD_READ_UNAVAILABLE;
    const display = c.gdk_display_get_default() orelse return c.GHOSTTY_CLIPBOARD_READ_UNAVAILABLE;
    const clipboard = (if (clipboard_type == c.GHOSTTY_CLIPBOARD_SELECTION)
        c.gdk_display_get_primary_clipboard(display)
    else
        c.gdk_display_get_clipboard(display)) orelse return c.GHOSTTY_CLIPBOARD_READ_UNAVAILABLE;

    var wants_text = false;
    for (mimes[0..mimes_len]) |mime| {
        if (std.mem.eql(u8, std.mem.span(mime), "text/plain")) wants_text = true;
    }
    if (!wants_text) {
        if (mimes_len != 0 or !list_available) return c.GHOSTTY_CLIPBOARD_READ_UNSUPPORTED;
        const complete = clipboardCompletion(clipboard, true);
        c.ghostty_surface_complete_clipboard_request(surface, &complete, state);
        return c.GHOSTTY_CLIPBOARD_READ_STARTED;
    }

    const ctx: *ClipboardReadCtx = @ptrCast(@alignCast(c.g_malloc(@sizeOf(ClipboardReadCtx)) orelse return c.GHOSTTY_CLIPBOARD_READ_UNAVAILABLE));
    ctx.* = .{ .pane_id = pane.id, .state = state, .list_available = list_available };
    c.gdk_clipboard_read_text_async(clipboard, null, onClipboardTextReady, @ptrCast(ctx));
    return c.GHOSTTY_CLIPBOARD_READ_STARTED;
}

fn onClipboardTextReady(
    source_object: ?*c.GObject,
    res: ?*c.GAsyncResult,
    user_data: c.gpointer,
) callconv(.c) void {
    const ctx: *ClipboardReadCtx = @ptrCast(@alignCast(user_data));
    defer c.g_free(@ptrCast(ctx));
    const clipboard: *c.GdkClipboard = @ptrCast(source_object orelse return);
    const text = c.gdk_clipboard_read_text_finish(clipboard, res, null);
    defer if (text != null) c.g_free(text);
    const surface = ctx.surface() orelse return;
    if (text == null) {
        c.ghostty_surface_deny_clipboard_request(surface, ctx.state);
        return;
    }
    const content: c.ghostty_clipboard_content_s = .{
        .mime = "text/plain",
        .data = text,
        .len = std.mem.len(text),
    };
    var complete = clipboardCompletion(clipboard, ctx.list_available);
    complete.contents = &content;
    complete.contents_len = 1;
    c.ghostty_surface_complete_clipboard_request(surface, &complete, ctx.state);
}

/// Preserve the existing policy for programmatic clipboard access.
fn confirmReadClipboardCb(
    userdata: ?*anyopaque,
    request_data: [*c]const c.ghostty_clipboard_confirm_s,
    state: ?*anyopaque,
    request: c.ghostty_clipboard_request_e,
) callconv(.c) void {
    _ = request;
    const pane: *Pane = if (userdata) |ud| @ptrCast(@alignCast(ud)) else return;
    const surface = pane.surface orelse return;
    if (request_data == null) {
        c.ghostty_surface_deny_clipboard_request(surface, state);
        return;
    }
    const complete: c.ghostty_clipboard_complete_s = .{
        .contents = request_data.*.contents,
        .contents_len = request_data.*.contents_len,
        .available = request_data.*.available,
        .available_len = request_data.*.available_len,
        .confirmed = true,
        .remember = false,
    };
    c.ghostty_surface_complete_clipboard_request(surface, &complete, state);
}

fn writeClipboardCb(
    userdata: ?*anyopaque,
    clipboard_type: c.ghostty_clipboard_e,
    contents: [*c]const c.ghostty_clipboard_content_s,
    count: usize,
    confirm: bool,
) callconv(.c) void {
    _ = userdata;
    _ = confirm;
    for (contents[0..count]) |content| {
        if (content.data == null or content.mime == null) continue;
        if (!std.mem.startsWith(u8, std.mem.span(content.mime), "text/plain")) continue;
        const bytes = content.data[0..content.len];
        // Capture export paths even during shutdown when GDK is unavailable.
        if (bytes.len < captured_clipboard.len) {
            @memcpy(captured_clipboard[0..bytes.len], bytes);
            captured_clipboard[bytes.len] = 0;
            captured_clipboard_len = bytes.len;
        }
        const display = c.gdk_display_get_default() orelse return;
        const clipboard = (if (clipboard_type == c.GHOSTTY_CLIPBOARD_SELECTION)
            c.gdk_display_get_primary_clipboard(display)
        else
            c.gdk_display_get_clipboard(display)) orelse return;
        // Ghostty's content is no longer required to be NUL terminated.
        const text = c.g_strndup(content.data, content.len) orelse return;
        defer c.g_free(text);
        c.gdk_clipboard_set_text(clipboard, text);
        return;
    }
}

/// Called by ghostty when a surface should be closed.
fn closeSurfaceCb(userdata: ?*anyopaque, process_alive: bool) callconv(.c) void {
    _ = process_alive;
    if (userdata) |ud| {
        const pane: *Pane = @ptrCast(@alignCast(ud));
        pane_mod.handleChildExited(pane);
    }
}

// ── Config translation ────────────────────────────────────────────

/// Public wrapper for applying seance defaults (called before loading user configs).
pub fn applySeanceDefaultsPublic(config: *anyopaque) void {
    applySeanceDefaults(config);
}

/// Public wrapper for applying seance config to a ghostty config object.
pub fn applySeanceConfigPublic(config: *anyopaque) void {
    applySeanceConfig(config);
}

/// Apply seance defaults that should sit below user configs in priority.
/// Called before ghostty_config_load_default_files so that the user's
/// ghostty config (and later, seance config) can override these values.
fn applySeanceDefaults(config: *anyopaque) void {
    const defaults = "window-padding-x = 8\nwindow-padding-y = 8\nfont-size = 11\n";

    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const runtime_dir = config_mod.runtimeDir();
    const tmp_path = std.fmt.bufPrintZ(&tmp_path_buf, "{s}/seance-ghostty-defaults.tmp", .{runtime_dir}) catch return;
    const file = std.Io.Dir.createFileAbsolute(io.get(), tmp_path, .{}) catch return;
    defer {
        file.close(io.get());
        std.Io.Dir.deleteFileAbsolute(io.get(), tmp_path) catch {};
    }
    file.writeStreamingAll(io.get(), defaults) catch return;
    c.ghostty_config_load_file(@ptrCast(config), tmp_path);
}

/// When no explicit theme is configured, choose between "Adwaita" and
/// "Adwaita Dark" based on the system's dark/light preference.
/// Non-Linux always defaults to dark.
pub fn resolveDefaultThemeName() []const u8 {
    if (builtin.os.tag != .linux) return "Adwaita Dark";
    const style_manager = c.adw_style_manager_get_default();
    if (c.adw_style_manager_get_dark(style_manager) != 0)
        return "Adwaita Dark"
    else
        return "Adwaita";
}

/// Apply seance config overrides to ghostty config via a temp config file.
/// Ghostty's C API doesn't have config_set, so we write a temp file.
/// Only writes non-color settings; color resolution is handled by ghostty's
/// own theme system, queried after finalization.
fn applySeanceConfig(config: *anyopaque) void {
    const cfg = config_mod.get();

    // Build config string
    var buf: [4096]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    const writer = &fbs;

    // Font
    //
    // Ghostty's `font-family` is a RepeatableString that *appends* rather
    // than replaces.  If the user has `font-family = FiraCode Nerd Font`
    // in ~/.config/ghostty/config, that gets loaded by
    // `ghostty_config_load_default_files` first, and then appending our
    // seance setting would just add a *fallback* font instead of replacing
    // the primary.  Write an empty value first to clear the list (the
    // RepeatableString.parseCLI contract: empty value resets the list),
    // then write our font on the next line so it becomes the only entry.
    if (cfg.font_family_len > 0) {
        writer.writeAll("font-family = \n") catch {};
        writer.print("font-family = {s}\n", .{cfg.font_family[0..cfg.font_family_len]}) catch {};
    }
    if (cfg.font_size) |fs| {
        writer.print("font-size = {d}\n", .{@as(u32, @intFromFloat(fs))}) catch {};
    }

    // Theme override — if seance config sets a theme, override ghostty's.
    // When no theme is configured, follow system dark/light preference.
    if (cfg.theme_len > 0) {
        writer.print("theme = {s}\n", .{cfg.theme[0..cfg.theme_len]}) catch {};
    } else {
        writer.print("theme = {s}\n", .{resolveDefaultThemeName()}) catch {};
    }

    // Background opacity
    if (cfg.background_opacity < 1.0) {
        writer.print("background-opacity = {d}\n", .{cfg.background_opacity}) catch {};
    }

    // Scrollback
    writer.print("scrollback-limit = {d}\n", .{cfg.scrollback_lines}) catch {};

    // Cursor
    const cursor_style: []const u8 = switch (cfg.cursor_shape) {
        .block => "block",
        .ibeam => "bar",
        .underline => "underline",
    };
    writer.print("cursor-style = {s}\n", .{cursor_style}) catch {};
    writer.print("cursor-style-blink = {s}\n", .{if (cfg.cursor_blink) "true" else "false"}) catch {};

    // Disable ghostty's shell-integration cursor feature. That feature injects
    // a hardcoded DECSCUSR (\e[5 q / \e[6 q) into PS1 on every prompt render,
    // which overrides our cursor-style setting and prevents live config updates
    // from taking effect at the prompt. Seance owns the cursor shape via its
    // own config, so turn the shell-integration override off unconditionally.
    writer.writeAll("shell-integration-features = no-cursor\n") catch {};

    // Window padding (only if explicitly set in seance config)
    if (cfg.window_padding_x) |px| {
        writer.print("window-padding-x = {d}\n", .{px}) catch {};
    }
    if (cfg.window_padding_y) |py| {
        writer.print("window-padding-y = {d}\n", .{py}) catch {};
    }

    const written = fbs.buffered();
    if (written.len == 0) return;

    // Write to temp file and load
    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const runtime_dir = config_mod.runtimeDir();
    const tmp_path = std.fmt.bufPrintZ(&tmp_path_buf, "{s}/seance-ghostty-config.tmp", .{runtime_dir}) catch return;
    const file = std.Io.Dir.createFileAbsolute(io.get(), tmp_path, .{}) catch return;
    defer {
        file.close(io.get());
        std.Io.Dir.deleteFileAbsolute(io.get(), tmp_path) catch {};
    }
    file.writeStreamingAll(io.get(), written) catch return;

    // ghostty_config_load_file expects a [*:0]const u8
    c.ghostty_config_load_file(
        @ptrCast(config),
        tmp_path,
    );
}
