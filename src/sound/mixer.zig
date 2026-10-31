//! Voice mixer for the CoreAudio render callback. Fixed voice pool, no
//! allocation: 32.32 fixed-point positions, 4-point cubic Hermite
//! interpolation, a ramped master gain, and a soft-knee limiter.

const std = @import("std");
const pack = @import("pack.zig");

pub const max_voices: usize = 32;

const one: u64 = 1 << 32;
const fraction: u64 = one - 1;
const i16_scale: f32 = 1.0 / 32_768.0;
const knee: f32 = 0.8;

pub const Play = struct {
    samples: []const i16 = &.{},
    src_rate: u32 = 0,
    pitch: f32 = 1,
    gain_l: f32 = 1,
    gain_r: f32 = 1,
    delay_us: u32 = 0,
    seq: u64 = 0,
    bell: bool = false,
};

const Voice = struct {
    samples: []const i16,
    pos: u64,
    end: u64,
    step: u64,
    gain_l: f32,
    gain_r: f32,
    delay: u32,
    serial: u64,
};

pub const Mixer = struct {
    out_rate: f64,
    voices: [max_voices]?Voice = @splat(null),
    serial: u64 = 0,
    gain: f32 = 0,

    pub fn init(out_rate: f64) Mixer {
        return .{ .out_rate = out_rate };
    }

    pub fn setOutRate(self: *Mixer, out_rate: f64) void {
        self.out_rate = if (out_rate > 0 and std.math.isFinite(out_rate)) out_rate else 48_000;
    }

    pub fn activeVoices(self: *const Mixer) usize {
        var n: usize = 0;
        for (self.voices) |voice| if (voice != null) {
            n += 1;
        };
        return n;
    }

    pub fn clear(self: *Mixer) void {
        self.voices = @splat(null);
    }

    pub fn start(self: *Mixer, play: *const Play) void {
        const guard = pack.guard_before + pack.guard_after;
        const audio_len = play.samples.len -| guard;
        if (audio_len == 0 or self.out_rate <= 0) return;
        const ratio = @as(f64, @floatFromInt(play.src_rate)) / self.out_rate * @as(f64, play.pitch);
        const raw = @round(ratio * @as(f64, @floatFromInt(one)));
        const step: u64 = if (raw >= 1 and raw <= @as(f64, @floatFromInt(std.math.maxInt(u64))))
            @intFromFloat(raw)
        else
            1;
        const delay_f = @as(f64, @floatFromInt(play.delay_us)) * self.out_rate / 1e6;
        const delay: u32 = if (!std.math.isFinite(delay_f) or delay_f <= 0)
            0
        else if (delay_f >= @as(f64, @floatFromInt(std.math.maxInt(u32))))
            std.math.maxInt(u32)
        else
            @intFromFloat(@round(delay_f));
        self.serial += 1;
        const voice: Voice = .{
            .samples = play.samples,
            .pos = @as(u64, pack.guard_before) << 32,
            .end = @as(u64, pack.guard_before + audio_len) << 32,
            .step = step,
            .gain_l = play.gain_l,
            .gain_r = play.gain_r,
            .delay = delay,
            .serial = self.serial,
        };
        self.voices[self.freeSlot()] = voice;
    }

    /// Overwrites both channels. Returns whether any voice is sounding or waiting out a delay.
    pub fn render(self: *Mixer, left: []f32, right: []f32, master: f32) bool {
        const n = @min(left.len, right.len);
        const l = left[0..n];
        const r = right[0..n];
        @memset(l, 0);
        @memset(r, 0);
        var sounding = false;
        for (&self.voices) |*slot| {
            if (slot.*) |*voice| {
                sounding = true;
                const offset: usize = @min(voice.delay, n);
                voice.delay -= @intCast(offset);
                if (offset != n and mixVoice(voice, l[offset..], r[offset..])) slot.* = null;
            }
        }
        const from = self.gain;
        self.gain = master;
        if (sounding and n > 0) {
            const step = (master - from) / @as(f32, @floatFromInt(n));
            var g = from;
            for (l, r) |*ls, *rs| {
                g += step;
                ls.* = softClip(ls.* * g);
                rs.* = softClip(rs.* * g);
            }
        }
        return sounding;
    }

    fn freeSlot(self: *const Mixer) usize {
        for (self.voices, 0..) |voice, i| if (voice == null) return i;
        var oldest: usize = 0;
        var serial: u64 = std.math.maxInt(u64);
        for (self.voices, 0..) |voice, i| {
            const s = if (voice) |v| v.serial else 0;
            if (s < serial) {
                serial = s;
                oldest = i;
            }
        }
        return oldest;
    }
};

fn mixVoice(v: *Voice, left: []f32, right: []f32) bool {
    const s = v.samples;
    const gl = v.gain_l * i16_scale;
    const gr = v.gain_r * i16_scale;
    if (v.step == one and v.pos & fraction == 0) {
        const start: usize = @intCast(v.pos >> 32);
        const end: usize = @intCast(v.end >> 32);
        const count = @min(end -| start, left.len);
        for (left[0..count], right[0..count], s[start .. start + count]) |*l, *r, x| {
            const sample: f32 = @floatFromInt(x);
            l.* += sample * gl;
            r.* += sample * gr;
        }
        v.pos = @as(u64, start + count) << 32;
    } else {
        var pos = v.pos;
        for (left, right) |*l, *r| {
            if (pos >= v.end) break;
            const i: usize = @intCast(pos >> 32);
            const t: f32 = @as(f32, @floatFromInt(pos & fraction)) * (1.0 / @as(f32, @floatFromInt(one)));
            const xm1: f32 = @floatFromInt(s[i - 1]);
            const x0: f32 = @floatFromInt(s[i]);
            const x1: f32 = @floatFromInt(s[i + 1]);
            const x2: f32 = @floatFromInt(s[i + 2]);
            const c1 = 0.5 * (x1 - xm1);
            const c2 = xm1 - 2.5 * x0 + 2.0 * x1 - 0.5 * x2;
            const c3 = 0.5 * (x2 - xm1) + 1.5 * (x0 - x1);
            const y = ((c3 * t + c2) * t + c1) * t + x0;
            l.* += y * gl;
            r.* += y * gr;
            pos += v.step;
        }
        v.pos = pos;
    }
    return v.pos >= v.end;
}

fn softClip(x: f32) f32 {
    const a = @abs(x);
    if (a <= knee) return x;
    const over = (a - knee) / (1.0 - knee);
    const y = knee + (1.0 - knee) * over / (1.0 + over);
    return if (x < 0) -y else y;
}

fn guardCopy(alloc: std.mem.Allocator, audio: []const i16) ![]i16 {
    const out = try alloc.alloc(i16, pack.guard_before + audio.len + pack.guard_after);
    @memset(out, 0);
    @memcpy(out[pack.guard_before..][0..audio.len], audio);
    return out;
}

fn playOf(samples: []const i16, src_rate: u32) Play {
    return .{ .samples = samples, .src_rate = src_rate };
}

fn settled(rate: f64) Mixer {
    var m = Mixer.init(rate);
    var l: [4]f32 = undefined;
    var r: [4]f32 = undefined;
    _ = m.render(&l, &r, 1);
    return m;
}

fn renderInto(m: *Mixer, frames: usize, alloc: std.mem.Allocator) !struct { []f32, []f32, bool } {
    const l = try alloc.alloc(f32, frames);
    errdefer alloc.free(l);
    const r = try alloc.alloc(f32, frames);
    const sounding = m.render(l, r, 1);
    return .{ l, r, sounding };
}

test "sound: unity rate copies samples exactly" {
    const alloc = std.testing.allocator;
    var audio: [100]i16 = undefined;
    for (&audio, 0..) |*sample, i| sample.* = @intCast(i * 100);
    const samples = try guardCopy(alloc, &audio);
    defer alloc.free(samples);
    var m = settled(48_000);
    var p = playOf(samples, 48_000);
    m.start(&p);
    const l, const r, const sounding = try renderInto(&m, 128, alloc);
    defer alloc.free(l);
    defer alloc.free(r);
    try std.testing.expect(sounding);
    for (audio, 0..) |sample, i| {
        const expected: f32 = @as(f32, @floatFromInt(sample)) / 32_768.0;
        try std.testing.expectEqual(expected, l[i]);
        try std.testing.expectEqual(l[i], r[i]);
    }
    for (l[100..]) |sample| try std.testing.expectEqual(@as(f32, 0), sample);
    try std.testing.expectEqual(@as(usize, 0), m.activeVoices());
}

test "sound: delay postpones the start" {
    const alloc = std.testing.allocator;
    const audio: [10]i16 = @splat(1000);
    const samples = try guardCopy(alloc, &audio);
    defer alloc.free(samples);
    var m = settled(1_000_000);
    var p = playOf(samples, 1_000_000);
    p.delay_us = 10;
    m.start(&p);
    const l, const r, _ = try renderInto(&m, 32, alloc);
    defer alloc.free(l);
    defer alloc.free(r);
    for (l[0..10]) |sample| try std.testing.expectEqual(@as(f32, 0), sample);
    for (l[10..20]) |sample| try std.testing.expectEqual(@as(f32, 1000.0 / 32_768.0), sample);
    for (l[20..]) |sample| try std.testing.expectEqual(@as(f32, 0), sample);
}

test "sound: delay longer than a block carries over" {
    const alloc = std.testing.allocator;
    const audio: [4]i16 = @splat(1000);
    const samples = try guardCopy(alloc, &audio);
    defer alloc.free(samples);
    var m = settled(1_000_000);
    var p = playOf(samples, 1_000_000);
    p.delay_us = 200;
    m.start(&p);
    const l, const r, const sounding = try renderInto(&m, 128, alloc);
    defer alloc.free(l);
    defer alloc.free(r);
    try std.testing.expect(sounding);
    for (l) |sample| try std.testing.expectEqual(@as(f32, 0), sample);
    const l2, const r2, _ = try renderInto(&m, 128, alloc);
    defer alloc.free(l2);
    defer alloc.free(r2);
    for (l2[0..72]) |sample| try std.testing.expectEqual(@as(f32, 0), sample);
    try std.testing.expectEqual(@as(f32, 1000.0 / 32_768.0), l2[72]);
}

test "sound: gains apply per channel" {
    const alloc = std.testing.allocator;
    const audio: [8]i16 = @splat(16_384);
    const samples = try guardCopy(alloc, &audio);
    defer alloc.free(samples);
    var m = settled(48_000);
    var p = playOf(samples, 48_000);
    p.gain_l = 0.5;
    p.gain_r = 0.25;
    m.start(&p);
    const l, const r, _ = try renderInto(&m, 8, alloc);
    defer alloc.free(l);
    defer alloc.free(r);
    try std.testing.expectEqual(@as(f32, 0.25), l[0]);
    try std.testing.expectEqual(@as(f32, 0.125), r[0]);
}

test "sound: half rate interpolates linear ramps exactly" {
    const alloc = std.testing.allocator;
    var audio: [64]i16 = undefined;
    for (&audio, 0..) |*sample, i| sample.* = @intCast(i * 200);
    const samples = try guardCopy(alloc, &audio);
    defer alloc.free(samples);
    var m = settled(48_000);
    var p = playOf(samples, 24_000);
    m.start(&p);
    const l, const r, _ = try renderInto(&m, 128, alloc);
    defer alloc.free(l);
    defer alloc.free(r);
    for (l[2..120], 2..) |sample, k| {
        const expected = 200.0 * @as(f32, @floatFromInt(k)) / 2.0 / 32_768.0;
        try std.testing.expect(@abs(sample - expected) < 1e-6);
    }
}

test "sound: constant signal survives pitch shift" {
    const alloc = std.testing.allocator;
    const audio: [200]i16 = @splat(1000);
    const samples = try guardCopy(alloc, &audio);
    defer alloc.free(samples);
    var m = settled(48_000);
    var p = playOf(samples, 44_100);
    p.pitch = 1.03;
    m.start(&p);
    const l, const r, _ = try renderInto(&m, 128, alloc);
    defer alloc.free(l);
    defer alloc.free(r);
    for (l[2..120]) |sample| try std.testing.expect(@abs(sample - 1000.0 / 32_768.0) < 1e-6);
}

test "sound: resampling to 96k preserves duration" {
    const alloc = std.testing.allocator;
    const audio: [441]i16 = @splat(1000);
    const samples = try guardCopy(alloc, &audio);
    defer alloc.free(samples);
    var m = settled(96_000);
    var p = playOf(samples, 44_100);
    m.start(&p);
    var produced: usize = 0;
    var blocks: usize = 0;
    while (blocks < 64) : (blocks += 1) {
        const l, const r, const sounding = try renderInto(&m, 64, alloc);
        defer alloc.free(l);
        defer alloc.free(r);
        for (l) |sample| if (sample != 0) {
            produced += 1;
        };
        if (!sounding) break;
    }
    try std.testing.expect(produced >= 958 and produced <= 962);
}

test "sound: steals the oldest voice when full" {
    const alloc = std.testing.allocator;
    const first_audio: [1000]i16 = @splat(100);
    const rest_audio: [1000]i16 = @splat(10);
    const first = try guardCopy(alloc, &first_audio);
    defer alloc.free(first);
    const rest = try guardCopy(alloc, &rest_audio);
    defer alloc.free(rest);
    var m = settled(48_000);
    var first_play = playOf(first, 48_000);
    m.start(&first_play);
    var i: usize = 0;
    while (i < max_voices) : (i += 1) {
        var rest_play = playOf(rest, 48_000);
        m.start(&rest_play);
    }
    try std.testing.expectEqual(max_voices, m.activeVoices());
    const l, const r, _ = try renderInto(&m, 16, alloc);
    defer alloc.free(l);
    defer alloc.free(r);
    const expected = @as(f32, max_voices) * 10.0 / 32_768.0;
    try std.testing.expect(@abs(l[0] - expected) < 1e-6);
}

test "sound: limiter keeps output within unity" {
    const alloc = std.testing.allocator;
    const audio: [256]i16 = @splat(std.math.maxInt(i16));
    const samples = try guardCopy(alloc, &audio);
    defer alloc.free(samples);
    var m = settled(48_000);
    var i: usize = 0;
    while (i < max_voices) : (i += 1) {
        var p = playOf(samples, 48_000);
        m.start(&p);
    }
    const l, const r, _ = try renderInto(&m, 256, alloc);
    defer alloc.free(l);
    defer alloc.free(r);
    for (l, r) |ls, rs| {
        try std.testing.expect(@abs(ls) <= 1);
        try std.testing.expect(@abs(rs) <= 1);
    }
    try std.testing.expect(l[10] > 0.95);
}

test "sound: soft clip is transparent below the knee and monotonic" {
    try std.testing.expectEqual(@as(f32, 0.5), softClip(0.5));
    try std.testing.expectEqual(@as(f32, -0.8), softClip(-0.8));
    var prev = softClip(0);
    var i: usize = 1;
    while (i <= 4000) : (i += 1) {
        const y = softClip(@as(f32, @floatFromInt(i)) / 1000.0);
        try std.testing.expect(y >= prev and y < 1);
        prev = y;
    }
}

test "sound: master gain ramps without a jump" {
    const alloc = std.testing.allocator;
    const audio: [512]i16 = @splat(16_384);
    const samples = try guardCopy(alloc, &audio);
    defer alloc.free(samples);
    var m = Mixer.init(48_000);
    var p = playOf(samples, 48_000);
    m.start(&p);
    const l = try alloc.alloc(f32, 256);
    defer alloc.free(l);
    const r = try alloc.alloc(f32, 256);
    defer alloc.free(r);
    _ = m.render(l, r, 1);
    try std.testing.expect(l[0] < 0.01);
    try std.testing.expect(@abs(l[255] - 0.5) < 1e-3);
    for (l[0 .. l.len - 1], l[1..]) |a, b| try std.testing.expect(b >= a);
}

test "sound: focus loss ramps out and a cleared mixer stays silent" {
    const alloc = std.testing.allocator;
    const audio: [512]i16 = @splat(16_384);
    const samples = try guardCopy(alloc, &audio);
    defer alloc.free(samples);
    var m = Mixer.init(48_000);
    var p = playOf(samples, 48_000);
    m.start(&p);
    const l = try alloc.alloc(f32, 256);
    defer alloc.free(l);
    const r = try alloc.alloc(f32, 256);
    defer alloc.free(r);
    _ = m.render(l, r, 1);
    try std.testing.expect(m.activeVoices() > 0);
    const l2 = try alloc.alloc(f32, 256);
    defer alloc.free(l2);
    const r2 = try alloc.alloc(f32, 256);
    defer alloc.free(r2);
    _ = m.render(l2, r2, 0);
    try std.testing.expect(l2[0] > 0.1);
    try std.testing.expect(@abs(l2[255]) < 1e-3);
    m.clear();
    try std.testing.expectEqual(@as(usize, 0), m.activeVoices());
    const l3, const r3, const sounding = try renderInto(&m, 64, alloc);
    defer alloc.free(l3);
    defer alloc.free(r3);
    try std.testing.expect(!sounding);
    for (l3) |sample| try std.testing.expectEqual(@as(f32, 0), sample);
}

test "sound: silence reports not sounding" {
    const alloc = std.testing.allocator;
    var m = settled(48_000);
    const l, const r, const sounding = try renderInto(&m, 64, alloc);
    defer alloc.free(l);
    defer alloc.free(r);
    try std.testing.expect(!sounding);
    for (l, r) |ls, rs| {
        try std.testing.expectEqual(@as(f32, 0), ls);
        try std.testing.expectEqual(@as(f32, 0), rs);
    }
}

test "sound: a huge step stays inside the guarded clip" {
    const alloc = std.testing.allocator;
    const audio = [_]i16{1000};
    const samples = try guardCopy(alloc, &audio);
    defer alloc.free(samples);
    var m = settled(48_000);
    var p = playOf(samples, 48_000);
    p.pitch = 1000;
    m.start(&p);
    const l, const r, _ = try renderInto(&m, 64, alloc);
    defer alloc.free(l);
    defer alloc.free(r);
    for (l, r) |ls, rs| {
        try std.testing.expect(std.math.isFinite(ls));
        try std.testing.expect(std.math.isFinite(rs));
    }
}
