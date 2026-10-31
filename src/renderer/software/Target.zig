//! CPU render target. Pixels are top-left RGBA8, sRGB encoded, with
//! premultiplied alpha. The presentation layer converts to the wl_shm byte
//! order and origin.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Pixel = u32;

pub const State = struct {
    content_valid: bool = false,
    revision: u64 = 0,
};

pub const Target = struct {
    alloc: Allocator,
    width: u32,
    height: u32,
    pixels: []Pixel,
    state: *State,

    pub fn init(alloc: Allocator, width: u32, height: u32) !Target {
        const len = try std.math.mul(usize, width, height);
        const pixels = try alloc.alloc(Pixel, len);
        @memset(pixels, 0);
        const state = try alloc.create(State);
        state.* = .{};
        return .{
            .alloc = alloc,
            .width = width,
            .height = height,
            .pixels = pixels,
            .state = state,
        };
    }

    pub fn deinit(self: *Target) void {
        self.alloc.free(self.pixels);
        self.alloc.destroy(self.state);
        self.* = undefined;
    }

    pub fn bytes(self: *const Target) []const u8 {
        return std.mem.sliceAsBytes(self.pixels);
    }
};

pub inline fn rgba(r: u8, g: u8, b: u8, a: u8) Pixel {
    return @as(u32, r) |
        (@as(u32, g) << 8) |
        (@as(u32, b) << 16) |
        (@as(u32, a) << 24);
}

pub inline fn red(p: Pixel) u8 {
    return @truncate(p);
}

pub inline fn green(p: Pixel) u8 {
    return @truncate(p >> 8);
}

pub inline fn blue(p: Pixel) u8 {
    return @truncate(p >> 16);
}

pub inline fn alpha(p: Pixel) u8 {
    return @truncate(p >> 24);
}

test "pixel packing matches the documented RGBA byte order" {
    const p = rgba(0x12, 0x34, 0x56, 0x78);
    const bytes = std.mem.asBytes(&p);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0x56, 0x78 }, bytes);
}
