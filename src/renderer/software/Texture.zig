//! CPU textures. Data is kept in its upload format (grayscale, BGRA, or
//! RGBA) and sampled by the software rasterizer.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Format = enum {
    grayscale,
    rgba,
    bgra,

    pub fn depth(self: Format) usize {
        return switch (self) {
            .grayscale => 1,
            .rgba, .bgra => 4,
        };
    }
};

pub const Filter = enum { nearest, linear };
pub const Wrap = enum { clamp_to_edge, repeat };
pub const Target = enum { @"2d", rectangle };

pub const Options = struct {
    alloc: Allocator,
    format: Format,
    target: Target = .@"2d",
    min_filter: Filter = .nearest,
    mag_filter: Filter = .nearest,
    wrap_s: Wrap = .clamp_to_edge,
    wrap_t: Wrap = .clamp_to_edge,
};

pub const Error = error{ OutOfMemory, Overflow };

pub const Texture = struct {
    alloc: Allocator,
    width: usize,
    height: usize,
    format: Format,
    target: Target,
    min_filter: Filter,
    mag_filter: Filter,
    wrap_s: Wrap,
    wrap_t: Wrap,
    pixels: []u8,

    pub fn init(
        opts: Options,
        width: usize,
        height: usize,
        data: ?[]const u8,
    ) Error!Texture {
        const alloc = opts.alloc;
        const len = try std.math.mul(usize, try std.math.mul(usize, width, height), opts.format.depth());
        const pixels = try alloc.alloc(u8, len);
        if (data) |src| {
            if (src.len < len) {
                alloc.free(pixels);
                return error.OutOfMemory;
            }
            @memcpy(pixels, src[0..len]);
        } else {
            @memset(pixels, 0);
        }
        return .{
            .alloc = alloc,
            .width = width,
            .height = height,
            .format = opts.format,
            .target = opts.target,
            .min_filter = opts.min_filter,
            .mag_filter = opts.mag_filter,
            .wrap_s = opts.wrap_s,
            .wrap_t = opts.wrap_t,
            .pixels = pixels,
        };
    }

    pub fn deinit(self: *const Texture) void {
        self.alloc.free(self.pixels);
    }

    pub fn replaceRegion(
        self: *const Texture,
        x: usize,
        y: usize,
        width: usize,
        height: usize,
        data: []const u8,
    ) Error!void {
        const depth = self.format.depth();
        if (x > self.width or width > self.width - x or
            y > self.height or height > self.height - y)
        {
            return error.OutOfMemory;
        }
        if (data.len < width * height * depth) return error.OutOfMemory;

        var row: usize = 0;
        while (row < height) : (row += 1) {
            const dst = ((y + row) * self.width + x) * depth;
            const src = row * width * depth;
            @memcpy(self.pixels[dst..][0 .. width * depth], data[src..][0 .. width * depth]);
        }
    }

    pub fn sample(self: *const Texture, x: i64, y: i64) [4]u8 {
        const cx = clampCoord(x, self.width, self.wrap_s);
        const cy = clampCoord(y, self.height, self.wrap_t);
        const off = (@as(usize, @intCast(cy)) * self.width + @as(usize, @intCast(cx))) * self.format.depth();
        return switch (self.format) {
            .grayscale => .{ self.pixels[off], self.pixels[off], self.pixels[off], 255 },
            .rgba => .{ self.pixels[off], self.pixels[off + 1], self.pixels[off + 2], self.pixels[off + 3] },
            .bgra => .{ self.pixels[off + 2], self.pixels[off + 1], self.pixels[off], self.pixels[off + 3] },
        };
    }

    fn clampCoord(value: i64, size: usize, wrap: Wrap) usize {
        if (size == 0) return 0;
        return switch (wrap) {
            .repeat => @intCast(@mod(value, @as(i64, @intCast(size)))),
            .clamp_to_edge => @intCast(std.math.clamp(value, 0, @as(i64, @intCast(size - 1)))),
        };
    }
};

test "texture region replacement keeps row stride" {
    const alloc = std.testing.allocator;
    const tex = try Texture.init(.{
        .alloc = alloc,
        .format = .rgba,
    }, 3, 2, null);
    defer tex.deinit();

    try tex.replaceRegion(1, 0, 2, 2, &.{
        1, 2, 3, 4, 5, 6, 7, 8,
        9, 10, 11, 12, 13, 14, 15, 16,
    });
    try std.testing.expectEqual([4]u8{ 1, 2, 3, 4 }, tex.sample(1, 0));
    try std.testing.expectEqual([4]u8{ 5, 6, 7, 8 }, tex.sample(2, 0));
    try std.testing.expectEqual([4]u8{ 9, 10, 11, 12 }, tex.sample(1, 1));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, tex.sample(0, 0));
}
