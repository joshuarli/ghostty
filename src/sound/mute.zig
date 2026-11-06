//! Runtime keyboard mute state, independent of configuration and audio lifetime.
//! The IPC thread writes this; input and audio threads only take snapshots.
const std = @import("std");

// Wire values are shared with control.h. Never reorder these.
pub const Command = enum(u8) {
    status = 0,
    toggle = 1,
    on = 2,
    off = 3,
};

pub const Snapshot = struct {
    muted: bool = false,
    generation: u64 = 0,
};

pub const State = struct {
    // One atomic snapshot prevents observing a new mute bit with an old epoch.
    // Every transition invalidates queued/playing keyboard samples, including
    // an on/off pair entirely between two render callbacks.
    bits: std.atomic.Value(u64) = .init(0),

    pub fn snapshot(self: *const State) Snapshot {
        const bits = self.bits.load(.acquire);
        return .{ .muted = bits & 1 != 0, .generation = bits >> 1 };
    }

    pub fn apply(self: *State, command: Command) bool {
        var old = self.bits.load(.acquire);
        while (true) {
            const previous = old & 1 != 0;
            const muted = switch (command) {
                .status => return previous,
                .toggle => !previous,
                .on => true,
                .off => false,
            };
            if (muted == previous) return muted;
            const next = ((old & ~@as(u64, 1)) +% 2) | @as(u64, @intFromBool(muted));
            if (self.bits.cmpxchgWeak(old, next, .acq_rel, .acquire)) |actual| {
                old = actual;
            } else return muted;
        }
    }
};

test "sound: mute transitions are idempotent and preserve generations" {
    const t = std.testing;
    var state: State = .{};
    try t.expect(!state.apply(.status));
    try t.expectEqual(@as(u64, 0), state.snapshot().generation);
    try t.expect(state.apply(.on));
    try t.expect(state.apply(.on));
    try t.expect(state.apply(.status));
    try t.expectEqual(@as(u64, 1), state.snapshot().generation);
    try t.expect(!state.apply(.off));
    try t.expect(!state.apply(.off));
    try t.expectEqual(@as(u64, 2), state.snapshot().generation);
    try t.expect(state.apply(.toggle));
    try t.expect(!state.apply(.toggle));
    try t.expectEqual(@as(u64, 4), state.snapshot().generation);
}

test "sound: mute generation survives a complete on off cycle" {
    var state: State = .{};
    const before = state.snapshot();
    _ = state.apply(.on);
    _ = state.apply(.off);
    const after = state.snapshot();
    try std.testing.expectEqual(before.muted, after.muted);
    try std.testing.expect(before.generation != after.generation);
}

test "sound: mute concurrent toggles do not lose transitions" {
    var state: State = .{};
    const Worker = struct {
        fn run(target: *State) void {
            for (0..1000) |_| _ = target.apply(.toggle);
        }
    };
    {
        var threads: [4]std.Thread = undefined;
        var started: usize = 0;
        defer for (threads[0..started]) |thread| thread.join();
        for (&threads) |*thread| {
            thread.* = try std.Thread.spawn(.{}, Worker.run, .{&state});
            started += 1;
        }
    }
    try std.testing.expect(!state.snapshot().muted);
    try std.testing.expectEqual(@as(u64, 4000), state.snapshot().generation);
}
