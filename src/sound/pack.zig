//! rvpack v1 reader. The file is predecoded mono PCM; nothing here decodes
//! compressed audio. Layout matches Klack's `rvpack` crate.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

comptime {
    if (builtin.cpu.arch.endian() != .little) {
        @compileError("rvpack is a little-endian format");
    }
}

pub const magic = "RVPK";
pub const version: u16 = 1;
pub const key_slots: usize = 128;
pub const flag_has_release: u16 = 1;
pub const guard_before: usize = 2;
pub const guard_after: usize = 3;

const gap: usize = 4;
const header_len: usize = 32;
const map_len: usize = key_slots * 4;
const press_offset: usize = header_len;
const clips_offset: usize = press_offset + 2 * map_len;
const clip_entry_len: usize = 8;

pub const Error = error{
    TooShort,
    BadMagic,
    UnsupportedVersion,
    BadSampleRate,
    Misaligned,
    OutOfBounds,
    BadClipRef,
    BadClip,
    BadMeta,
    TooManyClips,
};

pub const ClipRef = struct {
    first: u16 = 0,
    count: u16 = 0,

    pub fn isNone(self: ClipRef) bool {
        return self.count == 0;
    }
};

const Clip = struct {
    start: u32,
    len: u32,
};

/// Validated view of a pack. Samples point into `bytes`.
pub const Pack = struct {
    bytes: []const u8,
    sample_rate: u32,
    flags: u16,
    maps: []const u8,
    clips: []const u8,
    pcm: []const i16,

    pub fn parse(bytes: []const u8) Error!Pack {
        if (bytes.len < clips_offset) return error.TooShort;
        if (!std.mem.eql(u8, bytes[0..4], magic)) return error.BadMagic;
        const file_version = readU16(bytes, 4);
        if (file_version != version) return error.UnsupportedVersion;
        const flags = readU16(bytes, 6);
        const sample_rate = readU32(bytes, 8);
        if (sample_rate == 0) return error.BadSampleRate;
        const clip_count: usize = readU32(bytes, 12);
        const pcm_offset: usize = readU32(bytes, 16);
        const pcm_samples: usize = readU32(bytes, 20);
        const meta_offset: usize = readU32(bytes, 24);
        const meta_len: usize = readU32(bytes, 28);

        if (clip_count > std.math.maxInt(u16)) return error.TooManyClips;
        const clips_end = clips_offset + clip_count * clip_entry_len;
        if (clips_end > bytes.len) return error.OutOfBounds;
        const meta_end = std.math.add(usize, meta_offset, meta_len) catch return error.OutOfBounds;
        if (meta_offset < clips_end or meta_end > bytes.len) return error.OutOfBounds;
        const pcm_bytes_len = std.math.mul(usize, pcm_samples, 2) catch return error.OutOfBounds;
        const pcm_end = std.math.add(usize, pcm_offset, pcm_bytes_len) catch return error.OutOfBounds;
        if (pcm_offset < meta_end or pcm_end > bytes.len) return error.OutOfBounds;
        if (!metaOk(bytes[meta_offset..meta_end])) return error.BadMeta;

        const pcm_bytes = bytes[pcm_offset..pcm_end];
        const pcm: []const i16 = if (pcm_samples == 0) &.{} else pcm: {
            if (!std.mem.isAligned(@intFromPtr(pcm_bytes.ptr), @alignOf(i16))) return error.Misaligned;
            // The host is little-endian and every bit pattern is a valid sample.
            break :pcm @as([*]const i16, @ptrCast(@alignCast(pcm_bytes.ptr)))[0..pcm_samples];
        };

        const view: Pack = .{
            .bytes = bytes,
            .sample_rate = sample_rate,
            .flags = flags,
            .maps = bytes[press_offset..clips_offset],
            .clips = bytes[clips_offset..clips_end],
            .pcm = pcm,
        };
        for (0..2 * key_slots) |slot| {
            const ref = view.mapEntry(slot);
            if (!ref.isNone() and @as(usize, ref.first) + @as(usize, ref.count) > clip_count) {
                return error.BadClipRef;
            }
        }
        for (0..clip_count) |index| {
            const entry = view.clipEntry(index);
            const start: usize = entry.start;
            const len: usize = entry.len;
            if (len == 0 or start < guard_before or start + len + guard_after > pcm_samples) {
                return error.BadClip;
            }
        }
        return view;
    }

    pub fn hasRelease(self: Pack) bool {
        return self.flags & flag_has_release != 0;
    }

    pub fn press(self: Pack, keycode: u8) ClipRef {
        if (keycode >= key_slots) return .{};
        return self.mapEntry(keycode);
    }

    pub fn release(self: Pack, keycode: u8) ClipRef {
        if (keycode >= key_slots) return .{};
        return self.mapEntry(key_slots + @as(usize, keycode));
    }

    pub fn clipCount(self: Pack) usize {
        return self.clips.len / clip_entry_len;
    }

    pub fn clip(self: Pack, index: usize) []const i16 {
        const entry = self.clipEntry(index);
        const start: usize = entry.start;
        return self.pcm[start .. start + entry.len];
    }

    pub fn clipWithGuards(self: Pack, index: usize) []const i16 {
        const entry = self.clipEntry(index);
        const start: usize = entry.start;
        const len: usize = entry.len;
        return self.pcm[start - guard_before .. start + len + guard_after];
    }

    fn mapEntry(self: Pack, slot: usize) ClipRef {
        const at = slot * 4;
        return .{
            .first = readU16(self.maps, at),
            .count = readU16(self.maps, at + 2),
        };
    }

    fn clipEntry(self: Pack, index: usize) Clip {
        const at = index * clip_entry_len;
        return .{
            .start = readU32(self.clips, at),
            .len = readU32(self.clips, at + 4),
        };
    }
};

fn readU16(bytes: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, bytes[at..][0..2], .little);
}

fn readU32(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

fn metaOk(bytes: []const u8) bool {
    var has_id = false;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return false;
        const key = line[0..eq];
        const value = line[eq + 1 ..];
        if (std.mem.eql(u8, key, "id") and value.len > 0) has_id = true;
        if (std.mem.eql(u8, key, "order")) {
            _ = std.fmt.parseInt(u16, value, 10) catch return false;
        }
    }
    return has_id;
}

pub const Meta = struct {
    id: []const u8,
    name: []const u8 = "",
    variant: []const u8 = "",
    category: []const u8 = "",
    color: []const u8 = "",
    credit: []const u8 = "",
    order: u16 = 0,
    is_default: bool = false,
};

pub const PackData = struct {
    sample_rate: u32,
    meta: Meta,
    press: [key_slots]ClipRef,
    release: [key_slots]ClipRef,
    clips: []const []const i16,
};

pub fn encode(alloc: Allocator, pack: PackData) (Error || Allocator.Error)![]u8 {
    if (pack.sample_rate == 0) return error.BadSampleRate;
    if (pack.clips.len > std.math.maxInt(u16)) return error.TooManyClips;
    for (pack.clips) |clip| if (clip.len == 0) return error.BadClip;
    for (pack.press) |ref| if (clipRefOutOfRange(pack, ref)) return error.BadClipRef;
    for (pack.release) |ref| if (clipRefOutOfRange(pack, ref)) return error.BadClipRef;
    if (pack.meta.id.len == 0) return error.BadMeta;
    const fields = [_]struct { []const u8, []const u8 }{
        .{ "id", pack.meta.id },
        .{ "name", pack.meta.name },
        .{ "variant", pack.meta.variant },
        .{ "category", pack.meta.category },
        .{ "color", pack.meta.color },
        .{ "credit", pack.meta.credit },
    };
    for (fields) |field| {
        if (std.mem.indexOfAny(u8, field[1], "\n\r") != null) return error.BadMeta;
    }

    var meta: std.ArrayList(u8) = .empty;
    defer meta.deinit(alloc);
    for (fields) |field| {
        try meta.appendSlice(alloc, field[0]);
        try meta.append(alloc, '=');
        try meta.appendSlice(alloc, field[1]);
        try meta.append(alloc, '\n');
    }
    var order_buf: [8]u8 = undefined;
    const order = std.fmt.bufPrint(&order_buf, "{d}", .{pack.meta.order}) catch unreachable;
    try meta.appendSlice(alloc, "order=");
    try meta.appendSlice(alloc, order);
    try meta.append(alloc, '\n');
    try meta.appendSlice(alloc, "default=");
    try meta.append(alloc, if (pack.meta.is_default) '1' else '0');
    try meta.append(alloc, '\n');

    var pcm_samples: usize = gap;
    for (pack.clips) |clip| pcm_samples += clip.len + gap;
    const meta_offset = clips_offset + pack.clips.len * clip_entry_len;
    const pcm_offset = std.mem.alignForward(usize, meta_offset + meta.items.len, 16);
    const total = pcm_offset + pcm_samples * 2;
    const out = try alloc.alloc(u8, total);
    @memset(out, 0);
    @memcpy(out[0..4], magic);
    std.mem.writeInt(u16, out[4..6], version, .little);
    const flags: u16 = if (hasReleaseData(pack)) flag_has_release else 0;
    std.mem.writeInt(u16, out[6..8], flags, .little);
    std.mem.writeInt(u32, out[8..12], pack.sample_rate, .little);
    std.mem.writeInt(u32, out[12..16], @intCast(pack.clips.len), .little);
    std.mem.writeInt(u32, out[16..20], @intCast(pcm_offset), .little);
    std.mem.writeInt(u32, out[20..24], @intCast(pcm_samples), .little);
    std.mem.writeInt(u32, out[24..28], @intCast(meta_offset), .little);
    std.mem.writeInt(u32, out[28..32], @intCast(meta.items.len), .little);

    var at: usize = press_offset;
    for (pack.press) |ref| at = writeClipRef(out, at, ref);
    for (pack.release) |ref| at = writeClipRef(out, at, ref);
    var cursor: u32 = gap;
    for (pack.clips) |clip| {
        std.mem.writeInt(u32, out[at..][0..4], cursor, .little);
        std.mem.writeInt(u32, out[at + 4 ..][0..4], @intCast(clip.len), .little);
        at += clip_entry_len;
        cursor += @intCast(clip.len + gap);
    }
    @memcpy(out[meta_offset..][0..meta.items.len], meta.items);
    var sample_at: usize = pcm_offset;
    for (0..gap) |_| {
        std.mem.writeInt(i16, out[sample_at..][0..2], 0, .little);
        sample_at += 2;
    }
    for (pack.clips) |clip| {
        for (clip) |sample| {
            std.mem.writeInt(i16, out[sample_at..][0..2], sample, .little);
            sample_at += 2;
        }
        for (0..gap) |_| {
            std.mem.writeInt(i16, out[sample_at..][0..2], 0, .little);
            sample_at += 2;
        }
    }
    return out;
}

fn clipRefOutOfRange(pack: PackData, ref: ClipRef) bool {
    return !ref.isNone() and @as(usize, ref.first) + @as(usize, ref.count) > pack.clips.len;
}

fn writeClipRef(out: []u8, at: usize, ref: ClipRef) usize {
    std.mem.writeInt(u16, out[at..][0..2], ref.first, .little);
    std.mem.writeInt(u16, out[at + 2 ..][0..2], ref.count, .little);
    return at + 4;
}

fn hasReleaseData(pack: PackData) bool {
    for (pack.release) |ref| if (!ref.isNone()) return true;
    return false;
}

const sample_clip_a = [_]i16{ 100, -200, 300 };
const sample_clip_b = [_]i16{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 };
const sample_clip_c = [_]i16{ -5, -5, -5, -5 };
const sample_clips = [_][]const i16{ &sample_clip_a, &sample_clip_b, &sample_clip_c };

fn samplePack() PackData {
    var press: [key_slots]ClipRef = @splat(.{});
    var release: [key_slots]ClipRef = @splat(.{});
    press[0x00] = .{ .first = 0, .count = 1 };
    press[0x31] = .{ .first = 1, .count = 2 };
    release[0x31] = .{ .first = 2, .count = 1 };
    return .{
        .sample_rate = 44_100,
        .meta = .{
            .id = "test-pack",
            .name = "Test Switch",
            .variant = "PBT",
            .category = "tactile",
            .color = "#FF8800",
            .credit = "Unit test",
            .order = 7,
            .is_default = true,
        },
        .press = press,
        .release = release,
        .clips = &sample_clips,
    };
}

fn alignedOf(alloc: Allocator, bytes: []const u8) ![]align(16) u8 {
    const buf = try alloc.alignedAlloc(u8, .@"16", bytes.len);
    @memcpy(buf, bytes);
    return buf;
}

test "sound: rvpack roundtrip preserves clips and maps" {
    const alloc = std.testing.allocator;
    const bytes = try encode(alloc, samplePack());
    defer alloc.free(bytes);
    const buf = try alignedOf(alloc, bytes);
    defer alloc.free(buf);
    const view = try Pack.parse(buf);
    try std.testing.expectEqual(@as(u32, 44_100), view.sample_rate);
    try std.testing.expect(view.hasRelease());
    try std.testing.expectEqual(ClipRef{ .first = 0, .count = 1 }, view.press(0x00));
    try std.testing.expectEqual(ClipRef{ .first = 1, .count = 2 }, view.press(0x31));
    try std.testing.expectEqual(ClipRef{ .first = 2, .count = 1 }, view.release(0x31));
    try std.testing.expect(view.press(0x01).isNone());
    try std.testing.expect(view.press(200).isNone());
    try std.testing.expect(view.release(200).isNone());
    try std.testing.expectEqual(@as(usize, 3), view.clipCount());
    try std.testing.expectEqualSlices(i16, &.{ 100, -200, 300 }, view.clip(0));
    try std.testing.expectEqualSlices(i16, &.{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 }, view.clip(1));
}

test "sound: clips are surrounded by zero guards" {
    const alloc = std.testing.allocator;
    const bytes = try encode(alloc, samplePack());
    defer alloc.free(bytes);
    const buf = try alignedOf(alloc, bytes);
    defer alloc.free(buf);
    const view = try Pack.parse(buf);
    for (0..view.clipCount()) |i| {
        const guarded = view.clipWithGuards(i);
        const audio = view.clip(i);
        try std.testing.expectEqual(guard_before + audio.len + guard_after, guarded.len);
        for (guarded[0..guard_before]) |sample| try std.testing.expectEqual(@as(i16, 0), sample);
        try std.testing.expectEqualSlices(i16, audio, guarded[guard_before .. guard_before + audio.len]);
        for (guarded[guard_before + audio.len ..]) |sample| try std.testing.expectEqual(@as(i16, 0), sample);
    }
}

test "sound: pcm offset is 16-byte aligned" {
    const alloc = std.testing.allocator;
    const bytes = try encode(alloc, samplePack());
    defer alloc.free(bytes);
    const offset = std.mem.readInt(u32, bytes[16..20], .little);
    try std.testing.expectEqual(@as(u32, 0), offset % 16);
}

test "sound: pack without release sounds clears the flag" {
    const alloc = std.testing.allocator;
    var pack = samplePack();
    pack.release = @splat(.{});
    const bytes = try encode(alloc, pack);
    defer alloc.free(bytes);
    const buf = try alignedOf(alloc, bytes);
    defer alloc.free(buf);
    try std.testing.expect(!((try Pack.parse(buf)).hasRelease()));
}

test "sound: every truncation is rejected" {
    const alloc = std.testing.allocator;
    const bytes = try encode(alloc, samplePack());
    defer alloc.free(bytes);
    var len: usize = 0;
    while (len < bytes.len) : (len += 1) {
        const buf = try alignedOf(alloc, bytes[0..len]);
        defer alloc.free(buf);
        if (Pack.parse(buf)) |_| return error.TestExpectedError else |_| {}
    }
}

test "sound: rejects bad magic and version" {
    const alloc = std.testing.allocator;
    var bytes = try encode(alloc, samplePack());
    defer alloc.free(bytes);
    bytes[0] = 'X';
    const bad_magic = try alignedOf(alloc, bytes);
    defer alloc.free(bad_magic);
    try std.testing.expectError(error.BadMagic, Pack.parse(bad_magic));

    bytes[0] = 'R';
    bytes[4] = 9;
    const bad_version = try alignedOf(alloc, bytes);
    defer alloc.free(bad_version);
    try std.testing.expectError(error.UnsupportedVersion, Pack.parse(bad_version));
}

test "sound: rejects a clip ref past the clip table" {
    const alloc = std.testing.allocator;
    const bytes = try encode(alloc, samplePack());
    defer alloc.free(bytes);
    bytes[34] = 9;
    const buf = try alignedOf(alloc, bytes);
    defer alloc.free(buf);
    try std.testing.expectError(error.BadClipRef, Pack.parse(buf));
}

test "sound: rejects a clip without guard room" {
    const alloc = std.testing.allocator;
    const bytes = try encode(alloc, samplePack());
    defer alloc.free(bytes);
    std.mem.writeInt(u32, bytes[1056..1060], 0, .little);
    const buf = try alignedOf(alloc, bytes);
    defer alloc.free(buf);
    try std.testing.expectError(error.BadClip, Pack.parse(buf));
}

test "sound: rejects misaligned pcm" {
    const alloc = std.testing.allocator;
    const bytes = try encode(alloc, samplePack());
    defer alloc.free(bytes);
    const buf = try alloc.alignedAlloc(u8, .@"16", bytes.len + 1);
    defer alloc.free(buf);
    buf[0] = 0;
    @memcpy(buf[1..], bytes);
    try std.testing.expectError(error.Misaligned, Pack.parse(buf[1..]));
}

test "sound: writer rejects invalid packs" {
    const alloc = std.testing.allocator;
    var pack = samplePack();
    pack.meta.name = "two\nlines";
    try std.testing.expectError(error.BadMeta, encode(alloc, pack));

    pack = samplePack();
    pack.press[5] = .{ .first = 2, .count = 2 };
    try std.testing.expectError(error.BadClipRef, encode(alloc, pack));

    pack = samplePack();
    const empty = [_][]const i16{ &.{ 100, -200, 300 }, &.{}, &.{ -5, -5, -5, -5 } };
    pack.clips = &empty;
    try std.testing.expectError(error.BadClip, encode(alloc, pack));

    pack = samplePack();
    pack.sample_rate = 0;
    try std.testing.expectError(error.BadSampleRate, encode(alloc, pack));
}

test "sound: metadata ignores unknown keys and rejects a missing id" {
    try std.testing.expect(metaOk("id=x\nfuture=1\norder=3\n"));
    try std.testing.expect(!metaOk("name=no id\n"));
    try std.testing.expect(!metaOk("id=x\nno equals sign\n"));
    try std.testing.expect(!metaOk("id=x\norder=nope\n"));
}

test "sound: random corruption never panics" {
    const alloc = std.testing.allocator;
    const original = try encode(alloc, samplePack());
    defer alloc.free(original);
    var state: u64 = 0x2545F4914F6CDD1D;
    var i: usize = 0;
    while (i < 5_000) : (i += 1) {
        const mutated = try alloc.dupe(u8, original);
        defer alloc.free(mutated);
        var n: usize = 0;
        while (n < 4) : (n += 1) {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            const pos = @as(usize, @intCast(state % @min(mutated.len, 1_200)));
            mutated[pos] = @truncate(state >> 40);
        }
        const buf = try alignedOf(alloc, mutated);
        defer alloc.free(buf);
        const view = Pack.parse(buf) catch continue;
        var key: u16 = 0;
        while (key <= 255) : (key += 1) {
            _ = view.press(@intCast(key));
            _ = view.release(@intCast(key));
        }
        var clip_i: usize = 0;
        while (clip_i < view.clipCount()) : (clip_i += 1) {
            _ = view.clipWithGuards(clip_i);
        }
    }
}
