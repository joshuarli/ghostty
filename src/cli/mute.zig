const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
const Action = @import("ghostty.zig").Action;
const control = @import("../sound/control.zig");
const Command = control.mute.Command;

pub const Options = struct {
    /// Target a specific Ghostty process rather than the inherited instance.
    pid: ?u31 = null,
    _command: Command = .toggle,

    pub fn help(_: Options) !void {
        return Action.help_error;
    }
};

/// Control keyboard sounds in an already-running Ghostty instance.
///
/// Usage: `ghostty mute [toggle|on|off|status] [--pid=PID]`
/// The conventional `ghostty +mute` spelling is also accepted.
///
/// With no state argument, toggle muting. `on` mutes keyboard sounds; `off`
/// removes the mute override; `status` does not change anything. Successful
/// commands print `on` or `off` (the resulting MUTE state) and exit zero.
///
/// This is application-wide, keyboard-only, and temporary. It does not change
/// configuration, system volume, or terminal bells. It survives configuration
/// reloads and resets on restart. Unmuting still respects `keyboard-sound=off`
/// and the configured keyboard volume.
///
/// From a Ghostty shell, GHOSTTY_MUTE_PID selects the originating application.
/// Otherwise exactly one responsive instance must exist. `--pid=PID` overrides
/// the environment. Ambiguity and stale inherited targets are errors, never a
/// reason to mute another instance. No new Ghostty application is launched.
///
/// Supported on the native macOS and Wayland runtimes. Rebuild and restart the
/// application once to install the listener. GTK has no keyboard-sound output
/// or listener. The CLI uses only local, owner-private Unix sockets.
///
/// Exit status: 0 = acknowledged, 1 = IPC/platform failure, 2 = invalid usage.
/// A failed request is never retried automatically: a lost acknowledgement can
/// mean a toggle was applied. Use `status` or an explicit `on`/`off` to recover.
pub fn run(alloc: Allocator) !u8 {
    var iter = try global.args().iterateAllocator(alloc);
    defer iter.deinit();
    _ = iter.next(); // executable; parseArgs consumes mute/+mute itself

    var buffer: [512]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(global.io(), &buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    const opts = parseArgs(&iter) catch |err| switch (err) {
        error.ActionHelpRequested => return err,
        else => {
            try stderr.writeAll("Usage: ghostty mute [toggle|on|off|status] [--pid=PID]\n");
            return 2;
        },
    };
    if (comptime !control.supported) {
        try stderr.writeAll("Runtime keyboard mute is supported only on macOS and native Wayland.\n");
        return 1;
    }
    var diagnostic: [256]u8 = @splat(0);
    const muted = control.request(opts.pid orelse 0, opts._command, &diagnostic) catch {
        try stderr.print("ghostty mute: {s}\n", .{std.mem.sliceTo(&diagnostic, 0)});
        return 1;
    };
    var out_buffer: [16]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(global.io(), &out_buffer);
    try stdout_writer.interface.writeAll(if (muted) "on\n" else "off\n");
    try stdout_writer.interface.flush();
    return 0;
}

fn parseArgs(iter: anytype) !Options {
    const name = iter.next() orelse return error.InvalidArgument;
    if (!std.mem.eql(u8, name, "mute") and !std.mem.eql(u8, name, "+mute"))
        return error.InvalidArgument;
    var result: Options = .{};
    var command_seen = false;
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"))
            return Action.help_error;
        if (std.mem.startsWith(u8, arg, "--pid=")) {
            if (result.pid != null) return error.InvalidArgument;
            const value = arg[6..];
            if (value.len == 0) return error.InvalidArgument;
            for (value) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidArgument;
            const pid = std.fmt.parseInt(u31, value, 10) catch return error.InvalidArgument;
            if (pid == 0) return error.InvalidArgument;
            result.pid = pid;
            continue;
        }
        if (command_seen) return error.InvalidArgument;
        result._command = std.meta.stringToEnum(Command, arg) orelse return error.InvalidArgument;
        command_seen = true;
    }
    return result;
}

test "mute CLI parses toggle and explicit states" {
    const cases = .{
        .{ "mute", Command.toggle, @as(?u31, null) },
        .{ "+mute", Command.toggle, @as(?u31, null) },
        .{ "mute on", Command.on, @as(?u31, null) },
        .{ "mute off --pid=123", Command.off, @as(?u31, 123) },
        .{ "+mute --pid=42 status", Command.status, @as(?u31, 42) },
        .{ "mute toggle", Command.toggle, @as(?u31, null) },
    };
    inline for (cases) |case| {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(std.testing.allocator, case[0]);
        defer iter.deinit();
        const parsed = try parseArgs(&iter);
        try std.testing.expectEqual(case[1], parsed._command);
        try std.testing.expectEqual(case[2], parsed.pid);
    }
}

test "mute CLI rejects malformed and contradictory arguments" {
    for ([_][]const u8{
        "mute no", "mute on off", "mute --pid=0", "mute --pid=-1",
        "mute --pid=+1", "mute --pid=", "mute --pid=2147483648",
        "mute --pid=1 --pid=2", "mute --pid=1x", "mute --unknown",
        "mute -e echo", "mute +new-tab", "other mute",
    }) |text| {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(std.testing.allocator, text);
        defer iter.deinit();
        try std.testing.expectError(error.InvalidArgument, parseArgs(&iter));
    }
}

test "mute CLI help does not send a request" {
    for ([_][]const u8{ "mute --help", "+mute -h" }) |text| {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(std.testing.allocator, text);
        defer iter.deinit();
        try std.testing.expectError(Action.help_error, parseArgs(&iter));
    }
}
