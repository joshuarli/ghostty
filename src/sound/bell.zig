//! Bell sounds. A bell clip is mono 16-bit PCM padded with the guard samples
//! the mixer's interpolation reads past either end of a clip.

const std = @import("std");
const Allocator = std.mem.Allocator;
const pack = @import("pack.zig");

pub const Clip = struct {
    /// Guard samples included.
    samples: []i16,
    rate: u32,

    pub fn deinit(self: Clip, alloc: Allocator) void {
        alloc.free(self.samples);
    }
};

const tone_rate: u32 = 48_000;
const tone_hz: f64 = 880;
const tone_seconds: f64 = 0.22;
const tone_attack_seconds: f64 = 0.003;
const tone_decay_seconds: f64 = 0.06;
const tone_peak: f64 = 0.6;

/// A short struck-bell tone: a sine with a fast attack and exponential decay.
pub fn tone(alloc: Allocator) Allocator.Error!Clip {
    const frames: usize = @intFromFloat(tone_seconds * tone_rate);
    const out = try guarded(alloc, frames);
    const audio = out[pack.guard_before..][0..frames];
    for (audio, 0..) |*sample, i| {
        const t = @as(f64, @floatFromInt(i)) / tone_rate;
        const attack = @min(1.0, t / tone_attack_seconds);
        const decay = @exp(-t / tone_decay_seconds);
        const value = @sin(2 * std.math.pi * tone_hz * t) * attack * decay * tone_peak;
        sample.* = @intFromFloat(@round(value * 32767));
    }
    return .{ .samples = out, .rate = tone_rate };
}

pub const WavError = error{
    NotWav,
    Unsupported,
    Truncated,
    Empty,
} || Allocator.Error;

/// Reads PCM (8, 16, 24, or 32 bit) or 32-bit float WAV data, mixing all
/// channels down to mono.
pub fn wav(alloc: Allocator, bytes: []const u8) WavError!Clip {
    if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..4], "RIFF") or !std.mem.eql(u8, bytes[8..12], "WAVE")) {
        return error.NotWav;
    }
    var format: ?Format = null;
    var data: ?[]const u8 = null;
    var offset: usize = 12;
    while (offset + 8 <= bytes.len) {
        const id = bytes[offset..][0..4];
        const size: usize = std.mem.readInt(u32, bytes[offset + 4 ..][0..4], .little);
        const body_start = offset + 8;
        const body_end = @min(body_start + size, bytes.len);
        const body = bytes[body_start..body_end];
        if (std.mem.eql(u8, id, "fmt ")) {
            format = try parseFormat(body);
        } else if (std.mem.eql(u8, id, "data")) {
            data = body;
            break;
        }
        offset = body_start + size + (size & 1);
    }
    const fmt = format orelse return error.NotWav;
    const body = data orelse return error.Truncated;
    const frame_bytes = @as(usize, fmt.channels) * fmt.bytes;
    const frames = body.len / frame_bytes;
    if (frames == 0) return error.Empty;

    const out = try guarded(alloc, frames);
    const audio = out[pack.guard_before..][0..frames];
    for (audio, 0..) |*sample, frame| {
        var sum: f32 = 0;
        for (0..fmt.channels) |channel| {
            sum += fmt.read(body[frame * frame_bytes + channel * fmt.bytes ..]);
        }
        const mixed = sum / @as(f32, @floatFromInt(fmt.channels));
        sample.* = @intFromFloat(@round(std.math.clamp(mixed, -1, 1) * 32767));
    }
    return .{ .samples = out, .rate = fmt.rate };
}

const Format = struct {
    channels: u16,
    rate: u32,
    bytes: usize,
    float: bool,

    fn read(self: Format, b: []const u8) f32 {
        if (self.float) return @bitCast(std.mem.readInt(u32, b[0..4], .little));
        return switch (self.bytes) {
            1 => (@as(f32, @floatFromInt(b[0])) - 128) / 128,
            2 => @as(f32, @floatFromInt(std.mem.readInt(i16, b[0..2], .little))) / 32768,
            3 => @as(f32, @floatFromInt(std.mem.readInt(i24, b[0..3], .little))) / 8388608,
            else => @as(f32, @floatFromInt(std.mem.readInt(i32, b[0..4], .little))) / 2147483648,
        };
    }
};

fn parseFormat(body: []const u8) WavError!Format {
    if (body.len < 16) return error.Truncated;
    const tag = std.mem.readInt(u16, body[0..2], .little);
    const channels = std.mem.readInt(u16, body[2..4], .little);
    const rate = std.mem.readInt(u32, body[4..8], .little);
    const bits = std.mem.readInt(u16, body[14..16], .little);
    if (channels == 0 or rate == 0) return error.Unsupported;
    const float = switch (tag) {
        1 => false,
        3 => true,
        else => return error.Unsupported,
    };
    const supported = if (float) bits == 32 else bits == 8 or bits == 16 or bits == 24 or bits == 32;
    if (!supported) return error.Unsupported;
    return .{ .channels = channels, .rate = rate, .bytes = bits / 8, .float = float };
}

fn guarded(alloc: Allocator, frames: usize) Allocator.Error![]i16 {
    const out = try alloc.alloc(i16, pack.guard_before + frames + pack.guard_after);
    @memset(out, 0);
    return out;
}

fn testWav(alloc: Allocator, channels: u16, bits: u16, tag: u16, payload: []const u8) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(alloc);
    const block = channels * bits / 8;
    try list.appendSlice(alloc, "RIFF");
    try list.appendSlice(alloc, &std.mem.toBytes(@as(u32, @intCast(36 + payload.len))));
    try list.appendSlice(alloc, "WAVEfmt ");
    try list.appendSlice(alloc, &std.mem.toBytes(@as(u32, 16)));
    try list.appendSlice(alloc, &std.mem.toBytes(tag));
    try list.appendSlice(alloc, &std.mem.toBytes(channels));
    try list.appendSlice(alloc, &std.mem.toBytes(@as(u32, 22_050)));
    try list.appendSlice(alloc, &std.mem.toBytes(@as(u32, 22_050) * block));
    try list.appendSlice(alloc, &std.mem.toBytes(block));
    try list.appendSlice(alloc, &std.mem.toBytes(bits));
    try list.appendSlice(alloc, "data");
    try list.appendSlice(alloc, &std.mem.toBytes(@as(u32, @intCast(payload.len))));
    try list.appendSlice(alloc, payload);
    return list.toOwnedSlice(alloc);
}

test "the built-in tone is guarded, audible, and decays" {
    const clip = try tone(std.testing.allocator);
    defer clip.deinit(std.testing.allocator);
    try std.testing.expectEqual(tone_rate, clip.rate);
    try std.testing.expectEqual(@as(i16, 0), clip.samples[0]);
    try std.testing.expectEqual(@as(i16, 0), clip.samples[clip.samples.len - 1]);

    var early: u32 = 0;
    var late: u32 = 0;
    const audio = clip.samples[pack.guard_before .. clip.samples.len - pack.guard_after];
    for (audio[0..2400]) |s| early = @max(early, @abs(@as(i32, s)));
    for (audio[audio.len - 2400 ..]) |s| late = @max(late, @abs(@as(i32, s)));
    try std.testing.expect(early > 10_000);
    try std.testing.expect(late < early / 10);
}

test "wav reads 16-bit stereo as mono at its own rate" {
    const alloc = std.testing.allocator;
    const payload = std.mem.toBytes([4]i16{ 10_000, 20_000, -8_000, -4_000 });
    const bytes = try testWav(alloc, 2, 16, 1, &payload);
    defer alloc.free(bytes);
    const clip = try wav(alloc, bytes);
    defer clip.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 22_050), clip.rate);
    try std.testing.expectEqual(pack.guard_before + 2 + pack.guard_after, clip.samples.len);
    try std.testing.expectEqual(@as(i16, 15_000), clip.samples[pack.guard_before]);
    try std.testing.expectEqual(@as(i16, -6_000), clip.samples[pack.guard_before + 1]);
}

test "wav reads 8-bit and 32-bit float data" {
    const alloc = std.testing.allocator;
    const bytes8 = try testWav(alloc, 1, 8, 1, &.{ 255, 128, 0 });
    defer alloc.free(bytes8);
    const clip8 = try wav(alloc, bytes8);
    defer clip8.deinit(alloc);
    try std.testing.expect(clip8.samples[pack.guard_before] > 32_000);
    try std.testing.expectEqual(@as(i16, 0), clip8.samples[pack.guard_before + 1]);
    try std.testing.expect(clip8.samples[pack.guard_before + 2] < -32_000);

    const payload = std.mem.toBytes([2]f32{ 0.5, -2.0 });
    const bytesf = try testWav(alloc, 1, 32, 3, &payload);
    defer alloc.free(bytesf);
    const clipf = try wav(alloc, bytesf);
    defer clipf.deinit(alloc);
    try std.testing.expectEqual(@as(i16, 16_384), clipf.samples[pack.guard_before]);
    try std.testing.expectEqual(@as(i16, -32_767), clipf.samples[pack.guard_before + 1]);
}

test "wav rejects what it cannot play" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.NotWav, wav(alloc, "not a wav file at all"));
    const compressed = try testWav(alloc, 1, 16, 2, &.{ 0, 0 });
    defer alloc.free(compressed);
    try std.testing.expectError(error.Unsupported, wav(alloc, compressed));
    const empty = try testWav(alloc, 1, 16, 1, &.{});
    defer alloc.free(empty);
    try std.testing.expectError(error.Empty, wav(alloc, empty));
}
