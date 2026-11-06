//! The render step shared by every audio output: drain the play ring into
//! the mixers and produce one block of stereo float samples. It allocates
//! nothing, takes no locks, and does no I/O, because outputs may call it
//! from a real-time callback.

const std = @import("std");
const engine = @import("engine.zig");
const mixer = @import("mixer.zig");
const mute = @import("mute.zig");

pub const RenderResult = struct {
    sounding: bool,
    fresh: bool,
};

/// Keys and the bell mix separately: keys follow focus and the keyboard
/// volume, while the bell sounds whenever it is enabled.
pub const RenderState = struct {
    shared: *engine.Shared,
    mixer: mixer.Mixer,
    consumer: engine.PlayRing.Consumer,
    bell_mixer: mixer.Mixer = .init(48_000),
    mute_generation: u64 = 0,

    pub fn setOutRate(self: *RenderState, rate: f64) void {
        self.mixer.setOutRate(rate);
        self.bell_mixer.setOutRate(rate);
    }

    pub fn clear(self: *RenderState) void {
        self.mixer.clear();
        self.bell_mixer.clear();
    }
};

const bell_block = 256;

pub fn renderInto(state: *RenderState, left: []f32, right: []f32) RenderResult {
    const shared = state.shared;
    const runtime_mute = shared.muteSnapshot();
    if (runtime_mute.generation != state.mute_generation) {
        // Clear only keyboard voices, including delayed chimes. The epoch
        // catches a mute/unmute cycle between callbacks; the bell is untouched.
        state.mixer.clear();
        state.mute_generation = runtime_mute.generation;
    }
    const keys_on = !runtime_mute.muted and shared.enabled.load(.monotonic) and shared.ghostty_active.load(.acquire);
    const bell_on = shared.bell_enabled.load(.monotonic);
    const drop_before = shared.drop_before.load(.acquire);
    var fresh = false;
    while (state.consumer.pop()) |play| {
        if (play.bell) {
            if (bell_on) {
                state.bell_mixer.start(&play);
                fresh = true;
            }
        } else if (keys_on and play.seq >= drop_before and
            play.mute_generation == runtime_mute.generation)
        {
            state.mixer.start(&play);
            fresh = true;
        }
    }
    const master: f32 = if (keys_on) shared.masterGain() else 0;
    const keys_sounding = state.mixer.render(left, right, master) and keys_on;
    if (!keys_on) state.mixer.clear();

    var bell_sounding = false;
    if (!bell_on) {
        state.bell_mixer.clear();
    } else if (state.bell_mixer.activeVoices() > 0) {
        bell_sounding = true;
        mixBell(state, left, right, shared.bellGain());
    }
    return .{ .sounding = keys_sounding or bell_sounding, .fresh = fresh };
}

fn mixBell(state: *RenderState, left: []f32, right: []f32, gain: f32) void {
    const n = @min(left.len, right.len);
    var scratch_l: [bell_block]f32 = undefined;
    var scratch_r: [bell_block]f32 = undefined;
    var offset: usize = 0;
    while (offset < n) {
        const m = @min(bell_block, n - offset);
        _ = state.bell_mixer.render(scratch_l[0..m], scratch_r[0..m], gain);
        for (left[offset..][0..m], right[offset..][0..m], scratch_l[0..m], scratch_r[0..m]) |*l, *r, bl, br| {
            l.* = std.math.clamp(l.* + bl, -1, 1);
            r.* = std.math.clamp(r.* + br, -1, 1);
        }
        offset += m;
    }
}

pub fn idleFrames(rate: f64, seconds: f64) u64 {
    if (!(rate > 0) or !std.math.isFinite(rate)) return std.math.maxInt(u64);
    const frames = rate * seconds;
    if (frames >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) return std.math.maxInt(u64);
    return @intFromFloat(frames);
}

fn testState(shared: *engine.Shared, ring: *engine.PlayRing.Shared) struct { state: RenderState, producer: engine.PlayRing.Producer } {
    const ends = engine.PlayRing.reset(ring);
    return .{
        .state = .{ .shared = shared, .mixer = .init(48_000), .consumer = ends.consumer },
        .producer = ends.producer,
    };
}

test "render plays one attack and drops it after focus loss" {
    var shared = engine.Shared.init(.{ .volume = 1, .focused = true });
    var ring: engine.PlayRing.Shared = .{};
    var rig = testState(&shared, &ring);
    const state = &rig.state;
    var left: [8]f32 = undefined;
    var right: [8]f32 = undefined;
    _ = renderInto(state, &left, &right);

    const samples = [_]i16{ 0, 0, 30_000, 0, 0, 0 };
    try std.testing.expect(rig.producer.push(.{
        .samples = &samples,
        .src_rate = 48_000,
        .seq = shared.next_seq.fetchAdd(1, .monotonic),
    }));
    const played = renderInto(state, &left, &right);
    try std.testing.expect(played.fresh);
    try std.testing.expect(played.sounding);
    try std.testing.expect(left[0] > 0.5);

    shared.drop_before.store(shared.next_seq.load(.monotonic), .release);
    try std.testing.expect(rig.producer.push(.{
        .samples = &samples,
        .src_rate = 48_000,
        .seq = 0,
    }));
    const dropped = renderInto(state, &left, &right);
    try std.testing.expect(!dropped.fresh);

    shared.ghostty_active.store(false, .release);
    try std.testing.expect(rig.producer.push(.{
        .samples = &samples,
        .src_rate = 48_000,
        .seq = shared.next_seq.fetchAdd(1, .monotonic),
    }));
    const inactive = renderInto(state, &left, &right);
    try std.testing.expect(!inactive.fresh);
    try std.testing.expect(!inactive.sounding);
    try std.testing.expectEqual(@as(f32, 0), left[0]);
    try std.testing.expectEqual(@as(usize, 0), state.mixer.activeVoices());
}

test "bell sounds without focus and ignores the keyboard volume" {
    var shared = engine.Shared.init(.{
        .volume = 0,
        .focused = false,
        .enabled = false,
        .bell = .{ .enabled = true, .volume = 0.5 },
    });
    var ring: engine.PlayRing.Shared = .{};
    var rig = testState(&shared, &ring);
    const state = &rig.state;
    var left: [8]f32 = undefined;
    var right: [8]f32 = undefined;
    _ = renderInto(state, &left, &right);

    const samples = [_]i16{ 0, 0, 20_000, 20_000, 20_000, 0, 0, 0 };
    try std.testing.expect(rig.producer.push(.{
        .samples = &samples,
        .src_rate = 48_000,
        .bell = true,
    }));
    const played = renderInto(state, &left, &right);
    try std.testing.expect(played.fresh);
    try std.testing.expect(played.sounding);
    try std.testing.expect(@abs(left[0]) > 0.01);
    try std.testing.expect(@abs(left[0]) < 0.5);
}

test "a disabled bell is dropped" {
    var shared = engine.Shared.init(.{ .bell = .{ .enabled = false } });
    var ring: engine.PlayRing.Shared = .{};
    var rig = testState(&shared, &ring);
    var left: [8]f32 = undefined;
    var right: [8]f32 = undefined;
    const samples = [_]i16{ 0, 0, 20_000, 0, 0, 0 };
    try std.testing.expect(rig.producer.push(.{ .samples = &samples, .src_rate = 48_000, .bell = true }));
    const result = renderInto(&rig.state, &left, &right);
    try std.testing.expect(!result.fresh);
    try std.testing.expect(!result.sounding);
}

test "sound: mute clears active and queued keys but leaves the bell playing" {
    var runtime_mute: mute.State = .{};
    var shared = engine.Shared.init(.{
        .volume = 1,
        .focused = true,
        .mute_state = &runtime_mute,
        .bell = .{ .enabled = true, .volume = 0.5 },
    });
    var ring: engine.PlayRing.Shared = .{};
    var rig = testState(&shared, &ring);
    var left: [8]f32 = undefined;
    var right: [8]f32 = undefined;
    _ = renderInto(&rig.state, &left, &right);
    const samples: [128]i16 = @splat(20_000);
    try std.testing.expect(rig.producer.push(.{ .samples = &samples, .src_rate = 48_000 }));
    try std.testing.expect(renderInto(&rig.state, &left, &right).sounding);
    try std.testing.expect(rig.state.mixer.activeVoices() > 0);

    _ = runtime_mute.apply(.on);
    try std.testing.expect(rig.producer.push(.{ .samples = &samples, .src_rate = 48_000 }));
    try std.testing.expect(rig.producer.push(.{ .samples = &samples, .src_rate = 48_000, .bell = true }));
    const muted = renderInto(&rig.state, &left, &right);
    try std.testing.expect(muted.sounding);
    try std.testing.expectEqual(@as(usize, 0), rig.state.mixer.activeVoices());
    try std.testing.expect(rig.state.bell_mixer.activeVoices() > 0);
    try std.testing.expect(@abs(left[0]) > 0.01);
    try std.testing.expect(@abs(left[0]) < 0.5);
}

test "sound: mute rapid on off cycle cannot replay queued or delayed clicks" {
    var runtime_mute: mute.State = .{};
    var shared = engine.Shared.init(.{ .volume = 1, .focused = true, .mute_state = &runtime_mute });
    var ring: engine.PlayRing.Shared = .{};
    var rig = testState(&shared, &ring);
    var left: [8]f32 = undefined;
    var right: [8]f32 = undefined;
    _ = renderInto(&rig.state, &left, &right);
    const samples: [128]i16 = @splat(20_000);
    try std.testing.expect(rig.producer.push(.{ .samples = &samples, .src_rate = 48_000 }));
    try std.testing.expect(renderInto(&rig.state, &left, &right).sounding);
    try std.testing.expect(rig.producer.push(.{
        .samples = &samples,
        .src_rate = 48_000,
        .delay_us = 70_000,
    }));
    // No renderer or input callback runs between these two transitions.
    _ = runtime_mute.apply(.on);
    _ = runtime_mute.apply(.off);
    const quiet = renderInto(&rig.state, &left, &right);
    try std.testing.expect(!quiet.fresh and !quiet.sounding);
    try std.testing.expectEqual(@as(usize, 0), rig.state.mixer.activeVoices());
    for (left) |sample| try std.testing.expectEqual(@as(f32, 0), sample);
    for (right) |sample| try std.testing.expectEqual(@as(f32, 0), sample);
    try std.testing.expect(rig.producer.push(.{
        .samples = &samples,
        .src_rate = 48_000,
        .mute_generation = runtime_mute.snapshot().generation,
    }));
    try std.testing.expect(renderInto(&rig.state, &left, &right).sounding);
}

test "idle frames saturate on bad rates" {
    try std.testing.expectEqual(@as(u64, 96_000), idleFrames(48_000, 2));
    try std.testing.expectEqual(std.math.maxInt(u64), idleFrames(0, 2));
    try std.testing.expectEqual(std.math.maxInt(u64), idleFrames(std.math.inf(f64), 2));
}
