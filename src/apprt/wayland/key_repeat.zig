const std = @import("std");

/// Wayland leaves key repeat to the client: the compositor reports the
/// delay and rate with `wl_keyboard.repeat_info`, and the client synthesizes
/// repeated presses while one repeating key is held. Times are monotonic
/// milliseconds supplied by the caller.
pub const KeyRepeat = struct {
    timing: ?Timing = null,
    held: ?Held = null,

    const Timing = struct {
        delay_ms: i64,
        interval_ms: i64,
    };

    const Held = struct {
        keycode: u32,
        next_ms: i64,
    };

    /// A rate of zero disables repeat, as the protocol specifies.
    pub fn configure(self: *KeyRepeat, rate_per_second: i32, delay_ms: i32) void {
        if (rate_per_second <= 0) {
            self.timing = null;
            self.held = null;
            return;
        }
        self.timing = .{
            .delay_ms = @max(delay_ms, 0),
            .interval_ms = @max(@divTrunc(1000, rate_per_second), 1),
        };
    }

    pub fn press(self: *KeyRepeat, keycode: u32, now_ms: i64) void {
        const timing = self.timing orelse return;
        self.held = .{ .keycode = keycode, .next_ms = now_ms + timing.delay_ms };
    }

    pub fn release(self: *KeyRepeat, keycode: u32) void {
        const held = self.held orelse return;
        if (held.keycode == keycode) self.held = null;
    }

    pub fn cancel(self: *KeyRepeat) void {
        self.held = null;
    }

    /// Milliseconds until the next repeat, or null when nothing is held.
    pub fn timeoutMs(self: *const KeyRepeat, now_ms: i64) ?i32 {
        const held = self.held orelse return null;
        const remaining = @max(held.next_ms - now_ms, 0);
        return @intCast(@min(remaining, std.math.maxInt(i32)));
    }

    /// Returns the held keycode when a repeat is due and schedules the next.
    /// At most one repeat fires per call, so a stalled loop never bursts.
    pub fn due(self: *KeyRepeat, now_ms: i64) ?u32 {
        const timing = self.timing orelse return null;
        const held = &(self.held orelse return null);
        if (now_ms < held.next_ms) return null;
        held.next_ms += timing.interval_ms;
        if (held.next_ms <= now_ms) held.next_ms = now_ms + timing.interval_ms;
        return held.keycode;
    }
};

test "repeat starts after the delay and then follows the rate" {
    var repeat: KeyRepeat = .{};
    repeat.configure(25, 600);
    repeat.press(38, 1000);

    try std.testing.expectEqual(@as(?i32, 600), repeat.timeoutMs(1000));
    try std.testing.expectEqual(@as(?u32, null), repeat.due(1599));
    try std.testing.expectEqual(@as(?u32, 38), repeat.due(1600));
    try std.testing.expectEqual(@as(?i32, 40), repeat.timeoutMs(1600));
    try std.testing.expectEqual(@as(?u32, null), repeat.due(1639));
    try std.testing.expectEqual(@as(?u32, 38), repeat.due(1640));
}

test "a stalled loop fires one repeat rather than a burst" {
    var repeat: KeyRepeat = .{};
    repeat.configure(25, 600);
    repeat.press(38, 0);

    try std.testing.expectEqual(@as(?u32, 38), repeat.due(5000));
    try std.testing.expectEqual(@as(?u32, null), repeat.due(5000));
    try std.testing.expectEqual(@as(?i32, 40), repeat.timeoutMs(5000));
}

test "releasing a different key keeps the held key repeating" {
    var repeat: KeyRepeat = .{};
    repeat.configure(25, 600);
    repeat.press(38, 0);
    repeat.release(50);
    try std.testing.expectEqual(@as(?u32, 38), repeat.due(600));
    repeat.release(38);
    try std.testing.expectEqual(@as(?i32, null), repeat.timeoutMs(600));
    try std.testing.expectEqual(@as(?u32, null), repeat.due(10_000));
}

test "a later press takes over repeat" {
    var repeat: KeyRepeat = .{};
    repeat.configure(25, 600);
    repeat.press(38, 0);
    repeat.press(39, 100);
    try std.testing.expectEqual(@as(?u32, null), repeat.due(600));
    try std.testing.expectEqual(@as(?u32, 39), repeat.due(700));
}

test "zero rate disables repeat and drops the held key" {
    var repeat: KeyRepeat = .{};
    repeat.configure(25, 600);
    repeat.press(38, 0);
    repeat.configure(0, 600);
    try std.testing.expectEqual(@as(?i32, null), repeat.timeoutMs(0));
    repeat.press(38, 0);
    try std.testing.expectEqual(@as(?u32, null), repeat.due(10_000));
}

test "repeat is off until the compositor reports timing" {
    var repeat: KeyRepeat = .{};
    repeat.press(38, 0);
    try std.testing.expectEqual(@as(?u32, null), repeat.due(10_000));
}
