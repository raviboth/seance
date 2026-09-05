//! Process I/O shared by GTK callbacks and metadata worker threads.
//! Main supplies the implementation; unit tests use the testing runtime.
const std = @import("std");
const builtin = @import("builtin");

var instance: std.Io = undefined;

pub fn init(value: std.Io) void {
    instance = value;
}

pub fn get() std.Io {
    return if (builtin.is_test) std.testing.io else instance;
}

// Read libc's current environment because GTK and the Ghostty bridge update
// it during startup, after std.process.Init's environment snapshot was made.
pub fn getenv(name: []const u8) ?[:0]const u8 {
    var buf: [256]u8 = undefined;
    const name_z = std.fmt.bufPrintZ(&buf, "{s}", .{name}) catch return null;
    return std.mem.span(std.c.getenv(name_z) orelse return null);
}

pub fn executablePath(buf: []u8) ![]const u8 {
    const len = try std.process.executablePath(get(), buf);
    return buf[0..len];
}

pub fn timestamp() i64 {
    return std.Io.Clock.real.now(get()).toSeconds();
}

pub fn milliTimestamp() i64 {
    return std.Io.Clock.real.now(get()).toMilliseconds();
}

pub fn readAll(file: std.Io.File, buf: []u8) !usize {
    var reader = file.readerStreaming(get(), &.{});
    return reader.interface.readSliceShort(buf);
}

pub fn readToEndAlloc(file: std.Io.File, alloc: std.mem.Allocator, limit: usize) ![]u8 {
    var reader = file.readerStreaming(get(), &.{});
    return reader.interface.allocRemaining(alloc, .limited(limit));
}

pub fn readLink(dir: std.Io.Dir, path: []const u8, buf: []u8) ![]const u8 {
    const len = try dir.readLink(get(), path, buf);
    return buf[0..len];
}

pub fn sleep(nanoseconds: u64) void {
    std.Io.sleep(get(), .fromNanoseconds(nanoseconds), .awake) catch {};
}

test "streaming file helpers preserve sequential reads and writes" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const file = try tmp.dir.createFile(get(), "session", .{});
        defer file.close(get());
        try file.writeStreamingAll(get(), "abc");
        try file.writeStreamingAll(get(), "def");
    }
    const file = try tmp.dir.openFile(get(), "session", .{});
    defer file.close(get());
    var buf: [3]u8 = undefined;
    try testing.expectEqual(3, try readAll(file, &buf));
    try testing.expectEqualStrings("abc", &buf);
    try testing.expectEqual(3, try readAll(file, &buf));
    try testing.expectEqualStrings("def", &buf);
    try testing.expectEqual(0, try readAll(file, &buf));
}

test "hook payload reads enforce their size limit" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(get(), .{ .sub_path = "payload", .data = "12345" });
    const file = try tmp.dir.openFile(get(), "payload", .{});
    defer file.close(get());
    try testing.expectError(error.StreamTooLong, readToEndAlloc(file, testing.allocator, 4));
}
