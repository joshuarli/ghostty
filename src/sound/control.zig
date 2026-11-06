//! Small POSIX transport boundary; mute policy lives in mute.zig.
const std = @import("std");
const builtin = @import("builtin");
pub const mute = @import("mute.zig");

pub const supported = builtin.os.tag == .macos or builtin.os.tag == .linux;
pub const Server = opaque {};

extern "c" fn ghostty_mute_server_start(
    context: *anyopaque,
    callback: *const fn (*anyopaque, u8) callconv(.c) c_int,
    diagnostic: [*]u8,
    diagnostic_len: usize,
) ?*Server;
extern "c" fn ghostty_mute_server_stop(server: *Server) void;
extern "c" fn ghostty_mute_request(
    pid: c_int,
    command: u8,
    muted: *c_int,
    diagnostic: [*]u8,
    diagnostic_len: usize,
) c_int;
extern "c" fn ghostty_mute_pid() c_int;

fn apply(context: *anyopaque, command: u8) callconv(.c) c_int {
    const state: *mute.State = @ptrCast(@alignCast(context));
    // The transport validates the wire command before invoking the callback.
    return @intFromBool(state.apply(@enumFromInt(command)));
}

/// The state must remain at this address until stop() and all sound outputs
/// borrowing it have completed. Failure disables only CLI control, not sound.
pub fn start(state: *mute.State) ?*Server {
    if (comptime !supported) return null;
    var diagnostic: [256]u8 = @splat(0);
    return ghostty_mute_server_start(state, apply, &diagnostic, diagnostic.len) orelse {
        std.log.scoped(.sound).warn("runtime mute control unavailable: {s}", .{
            std.mem.sliceTo(&diagnostic, 0),
        });
        return null;
    };
}

/// Joins the control thread before the callback context can be destroyed.
pub fn stop(server: ?*Server) void {
    if (comptime !supported) return;
    if (server) |s| ghostty_mute_server_stop(s);
}

pub fn pid() u31 {
    if (comptime !supported) return 0;
    return @intCast(ghostty_mute_pid());
}

pub fn request(target_pid: u31, command: mute.Command, diagnostic: []u8) !bool {
    if (comptime !supported) return error.UnsupportedPlatform;
    var muted: c_int = 0;
    if (ghostty_mute_request(
        @intCast(target_pid),
        @intFromEnum(command),
        &muted,
        diagnostic.ptr,
        diagnostic.len,
    ) != 0) return error.IPCFailed;
    return muted != 0;
}

test "sound: mute IPC invokes the real atomic state callback" {
    if (comptime !supported) return error.SkipZigTest;
    var state: mute.State = .{};
    const server = start(&state) orelse return error.MuteControlUnavailable;
    defer stop(server);
    var diagnostic: [256]u8 = @splat(0);
    try std.testing.expect(!try request(pid(), .status, &diagnostic));
    try std.testing.expect(try request(pid(), .on, &diagnostic));
    try std.testing.expect(state.snapshot().muted);
    try std.testing.expect(try request(pid(), .on, &diagnostic));
    try std.testing.expectEqual(@as(u64, 1), state.snapshot().generation);
    try std.testing.expect(!try request(pid(), .toggle, &diagnostic));
    try std.testing.expect(!state.snapshot().muted);
    try std.testing.expectEqual(@as(u64, 2), state.snapshot().generation);
}
