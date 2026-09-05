//! Raw descriptors integrated with GLib's event loop. These operations stay
//! synchronous and preserve nonblocking/EINTR semantics across Zig versions.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

pub const AF = std.posix.AF;
pub const SOCK = std.posix.SOCK;
pub const SOL = std.posix.SOL;
pub const SO = std.posix.SO;
pub const POLL = std.posix.POLL;
pub const SIG = std.posix.SIG;
pub const pid_t = std.posix.pid_t;
pub const sockaddr = std.posix.sockaddr;
pub const timeval = std.posix.timeval;
pub const pollfd = std.posix.pollfd;
pub const read = std.posix.read;
pub const poll = std.posix.poll;
pub const setsockopt = std.posix.setsockopt;
pub const kill = std.posix.kill;

fn failure(err: std.posix.E) error{ WouldBlock, AccessDenied, FileNotFound, ConnectionRefused, BrokenPipe, SystemResources, Unexpected } {
    return switch (err) {
        .AGAIN => error.WouldBlock,
        .ACCES, .PERM => error.AccessDenied,
        .NOENT => error.FileNotFound,
        .CONNREFUSED => error.ConnectionRefused,
        .PIPE => error.BrokenPipe,
        .NOMEM, .NOBUFS, .MFILE, .NFILE => error.SystemResources,
        else => error.Unexpected,
    };
}

pub fn socket(domain: u32, kind: u32, protocol: u32) !c.fd_t {
    // Darwin's SOCK flags are Zig shims, not native socket(2) flags.
    const native_kind = if (builtin.os.tag.isDarwin()) kind & ~@as(u32, SOCK.NONBLOCK | SOCK.CLOEXEC) else kind;
    const rc = c.socket(domain, native_kind, protocol);
    if (rc < 0) return failure(std.posix.errno(rc));
    errdefer close(rc);
    if (builtin.os.tag.isDarwin()) {
        if (kind & SOCK.NONBLOCK != 0) try setNonblocking(rc);
        if (kind & SOCK.CLOEXEC != 0)
            _ = try fcntl(rc, c.F.SETFD, (try fcntl(rc, c.F.GETFD, 0)) | c.FD_CLOEXEC);
    }
    return rc;
}

fn fcntl(fd: c.fd_t, command: c_int, arg: c_int) !c_int {
    while (true) {
        const rc = c.fcntl(fd, command, arg);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return rc,
            .INTR => continue,
            else => |err| return failure(err),
        }
    }
}

fn setNonblocking(fd: c.fd_t) !void {
    const nonblock: c_int = @bitCast(c.O{ .NONBLOCK = true });
    _ = try fcntl(fd, c.F.SETFL, (try fcntl(fd, c.F.GETFL, 0)) | nonblock);
}

pub fn close(fd: c.fd_t) void {
    // Never retry close on EINTR: the descriptor may already have been reused.
    _ = c.close(fd);
}

pub fn bind(fd: c.fd_t, addr: *const sockaddr, len: c.socklen_t) !void {
    const rc = c.bind(fd, addr, len);
    if (rc < 0) return failure(std.posix.errno(rc));
}

pub fn connect(fd: c.fd_t, addr: *const sockaddr, len: c.socklen_t) !void {
    while (true) {
        const rc = c.connect(fd, addr, len);
        switch (std.posix.errno(rc)) {
            .SUCCESS, .ISCONN => return,
            .INTR => continue,
            else => |err| return failure(err),
        }
    }
}

pub fn fchmod(fd: c.fd_t, mode: c.mode_t) !void {
    const rc = c.fchmod(fd, mode);
    if (rc < 0) return failure(std.posix.errno(rc));
}

pub fn listen(fd: c.fd_t, backlog: u31) !void {
    const rc = c.listen(fd, backlog);
    if (rc < 0) return failure(std.posix.errno(rc));
}

pub fn accept(fd: c.fd_t, addr: ?*sockaddr, len: ?*c.socklen_t, flags: u32) !c.fd_t {
    std.debug.assert(flags == 0);
    while (true) {
        const rc = c.accept(fd, addr, len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return rc,
            .INTR => continue,
            else => |err| return failure(err),
        }
    }
}

pub fn write(fd: c.fd_t, bytes: []const u8) !usize {
    while (true) {
        const rc = c.write(fd, bytes.ptr, bytes.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => |err| return failure(err),
        }
    }
}

pub fn unlink(path: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&buf, "{s}", .{path});
    const rc = c.unlink(path_z);
    if (rc < 0) return failure(std.posix.errno(rc));
}

pub fn accessZ(path: [*:0]const u8, mode: c_uint) !void {
    const rc = c.access(path, mode);
    if (rc < 0) return failure(std.posix.errno(rc));
}

pub fn waitpid(pid: pid_t, flags: u32) void {
    while (true) {
        const rc = c.waitpid(pid, null, @intCast(flags));
        if (std.posix.errno(rc) != .INTR) return;
    }
}

test "GLib socket descriptors preserve nonblocking reads and peer EOF" {
    const testing = std.testing;
    var pair: [2]c.fd_t = undefined;
    try testing.expectEqual(0, c.socketpair(AF.UNIX, SOCK.STREAM, 0, &pair));
    defer close(pair[0]);
    var buf: [8]u8 = undefined;
    {
        defer close(pair[1]);
        try setNonblocking(pair[0]);
        try testing.expectError(error.WouldBlock, read(pair[0], &buf));
        try testing.expectEqual(4, try write(pair[1], "ping"));
        const n = try read(pair[0], &buf);
        try testing.expectEqualStrings("ping", buf[0..n]);
    }
    try testing.expectEqual(0, try read(pair[0], &buf));
}

test "socket creation preserves nonblocking and close-on-exec flags" {
    const fd = try socket(AF.UNIX, SOCK.STREAM | SOCK.NONBLOCK | SOCK.CLOEXEC, 0);
    defer close(fd);
    const flags: c.O = @bitCast(try fcntl(fd, c.F.GETFL, 0));
    try std.testing.expect(flags.NONBLOCK);
    try std.testing.expect((try fcntl(fd, c.F.GETFD, 0)) & c.FD_CLOEXEC != 0);
}
