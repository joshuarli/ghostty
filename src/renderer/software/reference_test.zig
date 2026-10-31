//! Pixel-differential tests for the software rasterizer.
//!
//! The reference here is a floating-point transcription of the GPU shaders
//! (`cell_text`, `cell_bg`, `bg_color`, `image`, `common`) and of the blend
//! state they run under: premultiplied source-over, in linear light when the
//! framebuffer is sRGB. It shares no code with `raster.zig`, so a scene that
//! disagrees means the rasterizer drifted from the shaders.

const std = @import("std");
const types = @import("../shaders/types.zig");
const raster = @import("raster.zig");
const Target = @import("Target.zig").Target;
const Texture = @import("Texture.zig").Texture;
const Handle = @import("Buffer.zig").Handle;

const Uniforms = types.Uniforms;
const CellText = types.CellText;
const CellBg = types.CellBg;
const Image = types.Image;

const Rgba = [4]f64;

fn decode(v: f64) f64 {
    return if (v <= 0.04045) v / 12.92 else std.math.pow(f64, (v + 0.055) / 1.055, 2.4);
}

fn encode(v: f64) f64 {
    const c = std.math.clamp(v, 0, 1);
    return if (c <= 0.0031308) c * 12.92 else std.math.pow(f64, c, 1.0 / 2.4) * 1.055 - 0.055;
}

fn luminance(c: Rgba) f64 {
    return c[0] * 0.2126 + c[1] * 0.7152 + c[2] * 0.0722;
}

fn loadColor(c: [4]u8, linear: bool) Rgba {
    var out: Rgba = .{
        @as(f64, @floatFromInt(c[0])) / 255,
        @as(f64, @floatFromInt(c[1])) / 255,
        @as(f64, @floatFromInt(c[2])) / 255,
        @as(f64, @floatFromInt(c[3])) / 255,
    };
    if (linear) for (out[0..3]) |*v| {
        v.* = decode(v.*);
    };
    for (out[0..3]) |*v| v.* *= out[3];
    return out;
}

fn over(dst: Rgba, src: Rgba) Rgba {
    const inv = 1 - src[3];
    return .{
        src[0] + dst[0] * inv,
        src[1] + dst[1] * inv,
        src[2] + dst[2] * inv,
        src[3] + dst[3] * inv,
    };
}

const GrayAtlas = struct {
    width: usize,
    height: usize,
    data: []const u8,

    fn at(self: GrayAtlas, x: i64, y: i64) f64 {
        const cx: usize = @intCast(std.math.clamp(x, 0, @as(i64, @intCast(self.width)) - 1));
        const cy: usize = @intCast(std.math.clamp(y, 0, @as(i64, @intCast(self.height)) - 1));
        return @as(f64, @floatFromInt(self.data[cy * self.width + cx])) / 255;
    }
};

const RgbaImage = struct {
    width: usize,
    height: usize,
    data: []const u8,

    fn texel(self: RgbaImage, x: i64, y: i64) Rgba {
        const cx: usize = @intCast(std.math.clamp(x, 0, @as(i64, @intCast(self.width)) - 1));
        const cy: usize = @intCast(std.math.clamp(y, 0, @as(i64, @intCast(self.height)) - 1));
        const off = (cy * self.width + cx) * 4;
        return .{
            decode(@as(f64, @floatFromInt(self.data[off])) / 255),
            decode(@as(f64, @floatFromInt(self.data[off + 1])) / 255),
            decode(@as(f64, @floatFromInt(self.data[off + 2])) / 255),
            @as(f64, @floatFromInt(self.data[off + 3])) / 255,
        };
    }

    fn bilinear(self: RgbaImage, x: f64, y: f64) Rgba {
        const x0 = @floor(x);
        const y0 = @floor(y);
        const fx = x - x0;
        const fy = y - y0;
        const ix: i64 = @intFromFloat(x0);
        const iy: i64 = @intFromFloat(y0);
        const p00 = self.texel(ix, iy);
        const p10 = self.texel(ix + 1, iy);
        const p01 = self.texel(ix, iy + 1);
        const p11 = self.texel(ix + 1, iy + 1);
        var out: Rgba = undefined;
        for (&out, 0..) |*v, i| {
            const top = p00[i] * (1 - fx) + p10[i] * fx;
            const bottom = p01[i] * (1 - fx) + p11[i] * fx;
            v.* = top * (1 - fy) + bottom * fy;
        }
        return out;
    }
};

const Scene = struct {
    uniforms: Uniforms,
    cell_bg: []const CellBg,
    text: []const CellText,
    gray: GrayAtlas,
    color: RgbaImage,
    images: []const Image = &.{},
    image: RgbaImage = .{ .width = 1, .height = 1, .data = &.{ 0, 0, 0, 0 } },
};

fn pixelIsCovered(px: u32, py: u32, x: f64, y: f64, w: f64, h: f64) bool {
    const cx = @as(f64, @floatFromInt(px)) + 0.5;
    const cy = @as(f64, @floatFromInt(py)) + 0.5;
    return cx >= x and cx < x + w and cy >= y and cy < y + h;
}

fn cursorCell(u: Uniforms, gx: u32, gy: u32) bool {
    return gy == u.cursor_pos[1] and
        (gx == u.cursor_pos[0] or (u.bools.cursor_wide and gx == u.cursor_pos[0] + 1));
}

fn backgroundBehind(scene: Scene, gx: u32, gy: u32) Rgba {
    const u = scene.uniforms;
    const index = @as(usize, gy) * u.grid_size[0] + gx;
    const cell = loadColor(scene.cell_bg[index], true);
    const global = loadColor(u.bg_color, true);
    return .{
        cell[0] + global[0] * (1 - cell[3]),
        cell[1] + global[1] * (1 - cell[3]),
        cell[2] + global[2] * (1 - cell[3]),
        cell[3] + global[3] * (1 - cell[3]),
    };
}

fn contrastRatio(a: Rgba, b: Rgba) f64 {
    const la = luminance(a) + 0.05;
    const lb = luminance(b) + 0.05;
    return @max(la, lb) / @min(la, lb);
}

fn contrasted(min_ratio: f64, fg: Rgba, bg: Rgba) Rgba {
    if (contrastRatio(fg, bg) >= min_ratio) return fg;
    const white = contrastRatio(.{ 1, 1, 1, 1 }, bg);
    const black = contrastRatio(.{ 0, 0, 0, 1 }, bg);
    return if (white > black) .{ 1, 1, 1, 1 } else .{ 0, 0, 0, 1 };
}

fn textFragment(scene: Scene, inst: CellText, coverage: f64) Rgba {
    const u = scene.uniforms;
    const linear = u.bools.use_linear_blending;
    const bg = backgroundBehind(scene, inst.grid_pos[0], inst.grid_pos[1]);
    var color = loadColor(inst.color, true);

    if (u.min_contrast > 1 and !inst.bools.no_min_contrast) {
        color = contrasted(u.min_contrast, color, bg);
    }
    if (!inst.bools.is_cursor_glyph and cursorCell(u, inst.grid_pos[0], inst.grid_pos[1])) {
        color = loadColor(u.cursor_color, linear);
    }
    if (!linear) {
        for (color[0..3]) |*v| v.* = encode(v.* / color[3]) * color[3];
    }

    var a = coverage;
    if (u.bools.use_linear_correction) {
        const fg_l = luminance(color);
        const bg_l = luminance(bg);
        if (@abs(fg_l - bg_l) > 0.001) {
            const blend_l = decode(encode(fg_l) * a + encode(bg_l) * (1 - a));
            a = std.math.clamp((blend_l - bg_l) / (fg_l - bg_l), 0, 1);
        }
    }
    for (&color) |*v| v.* *= a;
    return color;
}

fn renderReference(alloc: std.mem.Allocator, scene: Scene, width: u32, height: u32) ![]Rgba {
    const u = scene.uniforms;
    const linear = u.bools.use_linear_blending;
    const fb = try alloc.alloc(Rgba, @as(usize, width) * height);
    errdefer alloc.free(fb);

    const bg = loadColor(u.bg_color, linear);
    @memset(fb, bg);

    const cw: f64 = u.cell_size[0];
    const ch: f64 = u.cell_size[1];
    const pad_top: f64 = u.grid_padding[0];
    const pad_left: f64 = u.grid_padding[3];
    const cols: i64 = u.grid_size[0];
    const rows: i64 = u.grid_size[1];

    var py: u32 = 0;
    while (py < height) : (py += 1) {
        var px: u32 = 0;
        while (px < width) : (px += 1) {
            var gx: i64 = @intFromFloat(@floor((@as(f64, @floatFromInt(px)) + 0.5 - pad_left) / cw));
            var gy: i64 = @intFromFloat(@floor((@as(f64, @floatFromInt(py)) + 0.5 - pad_top) / ch));
            if (gx < 0) {
                if (!u.padding_extend.left) continue;
                gx = 0;
            } else if (gx > cols - 1) {
                if (!u.padding_extend.right) continue;
                gx = cols - 1;
            }
            if (gy < 0) {
                if (!u.padding_extend.up) continue;
                gy = 0;
            } else if (gy > rows - 1) {
                if (!u.padding_extend.down) continue;
                gy = rows - 1;
            }
            const cell = scene.cell_bg[@intCast(gy * cols + gx)];
            const index = @as(usize, py) * width + px;
            fb[index] = over(fb[index], loadColor(cell, linear));
        }
    }

    for (scene.text) |inst| {
        if (inst.glyph_size[0] == 0 or inst.glyph_size[1] == 0) continue;
        const w: f64 = @floatFromInt(inst.glyph_size[0]);
        const h: f64 = @floatFromInt(inst.glyph_size[1]);
        const x = pad_left + @as(f64, @floatFromInt(inst.grid_pos[0])) * cw + @as(f64, @floatFromInt(inst.bearings[0]));
        const y = pad_top + @as(f64, @floatFromInt(inst.grid_pos[1])) * ch + ch - @as(f64, @floatFromInt(inst.bearings[1]));
        py = 0;
        while (py < height) : (py += 1) {
            var px: u32 = 0;
            while (px < width) : (px += 1) {
                if (!pixelIsCovered(px, py, x, y, w, h)) continue;
                const tx = @as(f64, @floatFromInt(inst.glyph_pos[0])) +
                    (@as(f64, @floatFromInt(px)) + 0.5 - x) / w * w;
                const ty = @as(f64, @floatFromInt(inst.glyph_pos[1])) +
                    (@as(f64, @floatFromInt(py)) + 0.5 - y) / h * h;
                const sx: i64 = @intFromFloat(@floor(tx));
                const sy: i64 = @intFromFloat(@floor(ty));
                const out: Rgba = switch (inst.atlas) {
                    .grayscale => textFragment(scene, inst, scene.gray.at(sx, sy)),
                    .color => scene.color.texel(sx, sy),
                };
                const index = @as(usize, py) * width + px;
                fb[index] = over(fb[index], out);
            }
        }
    }

    for (scene.images) |img| {
        const w: f64 = img.dest_size[0];
        const h: f64 = img.dest_size[1];
        const x = pad_left + @as(f64, img.grid_pos[0]) * cw + img.cell_offset[0];
        const y = pad_top + @as(f64, img.grid_pos[1]) * ch + img.cell_offset[1];
        py = 0;
        while (py < height) : (py += 1) {
            var px: u32 = 0;
            while (px < width) : (px += 1) {
                if (!pixelIsCovered(px, py, x, y, w, h)) continue;
                const u_norm = (@as(f64, @floatFromInt(px)) + 0.5 - x) / w;
                const v_norm = (@as(f64, @floatFromInt(py)) + 0.5 - y) / h;
                const sx = @as(f64, img.source_rect[0]) + u_norm * img.source_rect[2] - 0.5;
                const sy = @as(f64, img.source_rect[1]) + v_norm * img.source_rect[3] - 0.5;
                var sample = scene.image.bilinear(sx, sy);
                if (!linear) for (sample[0..3]) |*c| {
                    c.* = encode(c.*);
                };
                for (sample[0..3]) |*c| c.* *= sample[3];
                const index = @as(usize, py) * width + px;
                fb[index] = over(fb[index], sample);
            }
        }
    }
    return fb;
}

fn toByte(v: f64) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

fn referenceBytes(fb: Rgba, linear: bool) [4]u8 {
    return .{
        toByte(if (linear) encode(fb[0]) else fb[0]),
        toByte(if (linear) encode(fb[1]) else fb[1]),
        toByte(if (linear) encode(fb[2]) else fb[2]),
        toByte(fb[3]),
    };
}

fn handleOf(comptime T: type, items: []const T) Handle {
    return .{ .ptr = @constCast(@ptrCast(items.ptr)), .len = items.len };
}

fn renderRaster(alloc: std.mem.Allocator, scene: Scene, width: u32, height: u32) !Target {
    var target = try Target.init(alloc, width, height);
    errdefer target.deinit();
    var gray = try Texture.init(
        .{ .alloc = alloc, .format = .grayscale, .target = .rectangle },
        scene.gray.width,
        scene.gray.height,
        scene.gray.data,
    );
    defer gray.deinit();
    const color_bytes = try alloc.alloc(u8, scene.color.data.len);
    defer alloc.free(color_bytes);
    var i: usize = 0;
    while (i < color_bytes.len) : (i += 4) {
        color_bytes[i] = scene.color.data[i + 2];
        color_bytes[i + 1] = scene.color.data[i + 1];
        color_bytes[i + 2] = scene.color.data[i];
        color_bytes[i + 3] = scene.color.data[i + 3];
    }
    var color = try Texture.init(
        .{ .alloc = alloc, .format = .bgra, .target = .rectangle },
        scene.color.width,
        scene.color.height,
        color_bytes,
    );
    defer color.deinit();
    var image = try Texture.init(
        .{ .alloc = alloc, .format = .rgba, .min_filter = .linear, .mag_filter = .linear },
        scene.image.width,
        scene.image.height,
        scene.image.data,
    );
    defer image.deinit();

    raster.clear(&target, .full, .{ 0, 0, 0, 0 });
    raster.drawBgColor(&target, .full, &scene.uniforms);
    raster.drawCellBg(&target, .full, &scene.uniforms, handleOf(CellBg, scene.cell_bg));
    raster.drawCellText(
        &target,
        .full,
        &scene.uniforms,
        handleOf(CellText, scene.text),
        handleOf(CellBg, scene.cell_bg),
        &gray,
        &color,
    );
    raster.drawImages(&target, .full, &scene.uniforms, scene.images, &image);
    return target;
}

const Tolerance = struct {
    max_channel: u8,
    max_mismatched_fraction: f64 = 0.0,
};

fn expectMatchesReference(scene: Scene, width: u32, height: u32, tolerance: Tolerance) !void {
    const alloc = std.testing.allocator;
    const fb = try renderReference(alloc, scene, width, height);
    defer alloc.free(fb);
    var target = try renderRaster(alloc, scene, width, height);
    defer target.deinit();

    const linear = scene.uniforms.bools.use_linear_blending;
    var worst: u8 = 0;
    var worst_at: [2]u32 = .{ 0, 0 };
    var over_tolerance: usize = 0;
    var py: u32 = 0;
    while (py < height) : (py += 1) {
        var px: u32 = 0;
        while (px < width) : (px += 1) {
            const index = @as(usize, py) * width + px;
            const want = referenceBytes(fb[index], linear);
            const got = [4]u8{
                @truncate(target.pixels[index]),
                @truncate(target.pixels[index] >> 8),
                @truncate(target.pixels[index] >> 16),
                @truncate(target.pixels[index] >> 24),
            };
            var pixel_worst: u8 = 0;
            for (want, got) |a, b| pixel_worst = @max(pixel_worst, if (a > b) a - b else b - a);
            if (pixel_worst > tolerance.max_channel) over_tolerance += 1;
            if (pixel_worst > worst) {
                worst = pixel_worst;
                worst_at = .{ px, py };
            }
        }
    }
    const fraction = @as(f64, @floatFromInt(over_tolerance)) / @as(f64, @floatFromInt(@as(usize, width) * height));
    if (over_tolerance > 0 and fraction > tolerance.max_mismatched_fraction) {
        const index = @as(usize, worst_at[1]) * width + worst_at[0];
        const want = referenceBytes(fb[index], linear);
        std.debug.print(
            "{d} of {d} pixels differ by more than {d}; worst {d} at ({d},{d}): reference {any}, raster {any}\n",
            .{
                over_tolerance,
                @as(usize, width) * height,
                tolerance.max_channel,
                worst,
                worst_at[0],
                worst_at[1],
                want,
                [4]u8{
                    @truncate(target.pixels[index]),
                    @truncate(target.pixels[index] >> 8),
                    @truncate(target.pixels[index] >> 16),
                    @truncate(target.pixels[index] >> 24),
                },
            },
        );
        return error.RasterDiffersFromReference;
    }
}

const Mode = enum { linear_corrected, linear, native };

fn uniformsFor(mode: Mode, cols: u16, rows: u16, cell: [2]f32, padding: [4]f32) Uniforms {
    return .{
        .projection_matrix = undefined,
        .screen_size = .{
            padding[3] + padding[1] + @as(f32, @floatFromInt(cols)) * cell[0],
            padding[0] + padding[2] + @as(f32, @floatFromInt(rows)) * cell[1],
        },
        .cell_size = cell,
        .grid_size = .{ cols, rows },
        .grid_padding = padding,
        .padding_extend = .{},
        .min_contrast = 1,
        .cursor_pos = .{ 0xffff, 0xffff },
        .cursor_color = .{ 255, 255, 255, 255 },
        .bg_color = .{ 16, 24, 40, 255 },
        .bools = .{
            .cursor_wide = false,
            .use_display_p3 = false,
            .use_linear_blending = mode != .native,
            .use_linear_correction = mode == .linear_corrected,
        },
    };
}

fn patternAtlas(comptime size: usize) [size * size]u8 {
    var data: [size * size]u8 = undefined;
    for (&data, 0..) |*v, i| {
        const x = i % size;
        const y = i / size;
        v.* = @intCast((x * 37 + y * 91 + x * y * 13) % 256);
    }
    return data;
}

const empty_color = RgbaImage{ .width = 1, .height = 1, .data = &.{ 0, 0, 0, 0 } };

fn toleranceFor(mode: Mode) Tolerance {
    return .{ .max_channel = if (mode == .linear_corrected) 6 else 3 };
}

const all_modes = [_]Mode{ .linear_corrected, .linear, .native };

test "translucent text over translucent backgrounds follows the shaders" {
    const atlas = patternAtlas(32);
    const bg = [_]CellBg{
        .{ 0, 0, 0, 0 },     .{ 200, 30, 30, 90 }, .{ 30, 200, 30, 255 }, .{ 30, 30, 200, 128 },
        .{ 255, 255, 0, 40 }, .{ 0, 0, 0, 0 },      .{ 90, 90, 90, 200 },  .{ 10, 250, 250, 255 },
    };
    const text = [_]CellText{
        .{ .glyph_pos = .{ 0, 0 }, .glyph_size = .{ 7, 12 }, .bearings = .{ 1, 14 }, .grid_pos = .{ 0, 0 }, .color = .{ 230, 230, 230, 255 }, .atlas = .grayscale },
        .{ .glyph_pos = .{ 8, 0 }, .glyph_size = .{ 7, 12 }, .bearings = .{ 1, 14 }, .grid_pos = .{ 1, 0 }, .color = .{ 230, 100, 60, 200 }, .atlas = .grayscale },
        .{ .glyph_pos = .{ 16, 0 }, .glyph_size = .{ 7, 12 }, .bearings = .{ 0, 14 }, .grid_pos = .{ 2, 0 }, .color = .{ 20, 20, 20, 120 }, .atlas = .grayscale },
        .{ .glyph_pos = .{ 24, 0 }, .glyph_size = .{ 7, 12 }, .bearings = .{ 1, 13 }, .grid_pos = .{ 3, 0 }, .color = .{ 255, 255, 255, 60 }, .atlas = .grayscale },
        .{ .glyph_pos = .{ 0, 14 }, .glyph_size = .{ 7, 12 }, .bearings = .{ 1, 14 }, .grid_pos = .{ 0, 1 }, .color = .{ 100, 200, 100, 255 }, .atlas = .grayscale },
        .{ .glyph_pos = .{ 8, 14 }, .glyph_size = .{ 7, 12 }, .bearings = .{ 1, 14 }, .grid_pos = .{ 1, 1 }, .color = .{ 10, 10, 10, 255 }, .atlas = .grayscale },
        .{ .glyph_pos = .{ 16, 14 }, .glyph_size = .{ 7, 12 }, .bearings = .{ 1, 14 }, .grid_pos = .{ 2, 1 }, .color = .{ 255, 0, 255, 180 }, .atlas = .grayscale },
        .{ .glyph_pos = .{ 24, 14 }, .glyph_size = .{ 7, 12 }, .bearings = .{ 1, 14 }, .grid_pos = .{ 3, 1 }, .color = .{ 0, 0, 0, 255 }, .atlas = .grayscale },
    };
    for (all_modes) |mode| {
        var u = uniformsFor(mode, 4, 2, .{ 8, 16 }, .{ 2, 1, 1, 3 });
        u.bg_color = .{ 20, 40, 60, 128 };
        try expectMatchesReference(.{
            .uniforms = u,
            .cell_bg = &bg,
            .text = &text,
            .gray = .{ .width = 32, .height = 32, .data = &atlas },
            .color = empty_color,
        }, 36, 34, toleranceFor(mode));
    }
}

test "combining marks overlay their base glyph in draw order" {
    const atlas = patternAtlas(32);
    const bg = [_]CellBg{ .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 } };
    const text = [_]CellText{
        .{ .glyph_pos = .{ 0, 0 }, .glyph_size = .{ 7, 12 }, .bearings = .{ 1, 14 }, .grid_pos = .{ 0, 0 }, .color = .{ 240, 240, 240, 255 }, .atlas = .grayscale },
        .{ .glyph_pos = .{ 8, 20 }, .glyph_size = .{ 5, 4 }, .bearings = .{ 2, 17 }, .grid_pos = .{ 0, 0 }, .color = .{ 240, 240, 240, 255 }, .atlas = .grayscale },
        .{ .glyph_pos = .{ 16, 0 }, .glyph_size = .{ 7, 12 }, .bearings = .{ 1, 14 }, .grid_pos = .{ 1, 0 }, .color = .{ 255, 160, 0, 220 }, .atlas = .grayscale },
        .{ .glyph_pos = .{ 24, 20 }, .glyph_size = .{ 4, 4 }, .bearings = .{ -1, 15 }, .grid_pos = .{ 1, 0 }, .color = .{ 0, 160, 255, 220 }, .atlas = .grayscale },
    };
    for (all_modes) |mode| {
        const u = uniformsFor(mode, 2, 1, .{ 8, 16 }, .{ 0, 0, 0, 0 });
        try expectMatchesReference(.{
            .uniforms = u,
            .cell_bg = &bg,
            .text = &text,
            .gray = .{ .width = 32, .height = 32, .data = &atlas },
            .color = empty_color,
        }, 16, 16, toleranceFor(mode));
    }
}

test "box drawing glyphs fill their cells without seams" {
    var atlas: [16 * 16]u8 = @splat(0);
    for (0..16) |y| for (0..8) |x| {
        atlas[y * 16 + x] = 255;
    };
    for (0..16) |y| for (8..16) |x| {
        atlas[y * 16 + x] = if (x == 11 or y == 7 or y == 8) 255 else 0;
    };
    const bg: [6]CellBg = @splat(.{ 0, 0, 0, 0 });
    var text: [6]CellText = undefined;
    for (&text, 0..) |*t, i| {
        t.* = .{
            .glyph_pos = if (i % 2 == 0) .{ 0, 0 } else .{ 8, 0 },
            .glyph_size = .{ 8, 16 },
            .bearings = .{ 0, 16 },
            .grid_pos = .{ @intCast(i % 3), @intCast(i / 3) },
            .color = .{ 200, 180, 40, 255 },
            .atlas = .grayscale,
        };
    }
    for (all_modes) |mode| {
        const u = uniformsFor(mode, 3, 2, .{ 8, 16 }, .{ 0, 0, 0, 0 });
        const scene: Scene = .{
            .uniforms = u,
            .cell_bg = &bg,
            .text = &text,
            .gray = .{ .width = 16, .height = 16, .data = &atlas },
            .color = empty_color,
        };
        try expectMatchesReference(scene, 24, 32, toleranceFor(mode));

        var target = try renderRaster(std.testing.allocator, scene, 24, 32);
        defer target.deinit();
        const solid = target.pixels[0];
        for (0..16) |y| for (0..8) |x| {
            try std.testing.expectEqual(solid, target.pixels[y * 24 + x]);
            try std.testing.expectEqual(solid, target.pixels[y * 24 + 16 + x]);
        };
    }
}

test "wide glyphs span two cells and wide cursors recolor them" {
    const atlas = patternAtlas(32);
    const bg: [6]CellBg = @splat(.{ 0, 0, 0, 0 });
    const text = [_]CellText{
        .{ .glyph_pos = .{ 0, 0 }, .glyph_size = .{ 16, 14 }, .bearings = .{ 0, 14 }, .grid_pos = .{ 1, 0 }, .color = .{ 230, 230, 230, 255 }, .atlas = .grayscale },
        .{ .glyph_pos = .{ 0, 16 }, .glyph_size = .{ 16, 14 }, .bearings = .{ 0, 14 }, .grid_pos = .{ 0, 1 }, .color = .{ 120, 220, 120, 255 }, .atlas = .grayscale },
        .{ .glyph_pos = .{ 16, 16 }, .glyph_size = .{ 8, 14 }, .bearings = .{ 0, 14 }, .grid_pos = .{ 2, 1 }, .color = .{ 120, 220, 120, 255 }, .atlas = .grayscale },
    };
    for ([_]Mode{ .linear_corrected, .linear }) |mode| {
        var u = uniformsFor(mode, 3, 2, .{ 8, 16 }, .{ 0, 0, 0, 0 });
        u.cursor_pos = .{ 1, 0 };
        u.cursor_color = .{ 255, 80, 80, 255 };
        u.bools.cursor_wide = true;
        try expectMatchesReference(.{
            .uniforms = u,
            .cell_bg = &bg,
            .text = &text,
            .gray = .{ .width = 32, .height = 32, .data = &atlas },
            .color = empty_color,
        }, 24, 32, toleranceFor(mode));
    }
}

test "color glyphs blend as premultiplied linear colors" {
    const atlas = patternAtlas(8);
    const bg = [_]CellBg{ .{ 0, 0, 0, 0 }, .{ 120, 0, 0, 255 } };
    var emoji: [8 * 8 * 4]u8 = undefined;
    for (0..64) |i| {
        const a: u8 = @intCast((i * 4) % 256);
        emoji[i * 4] = a / 2;
        emoji[i * 4 + 1] = a / 3;
        emoji[i * 4 + 2] = a;
        emoji[i * 4 + 3] = a;
    }
    const text = [_]CellText{
        .{ .glyph_pos = .{ 0, 0 }, .glyph_size = .{ 8, 8 }, .bearings = .{ 0, 12 }, .grid_pos = .{ 0, 0 }, .color = .{ 255, 255, 255, 255 }, .atlas = .color },
        .{ .glyph_pos = .{ 0, 0 }, .glyph_size = .{ 8, 8 }, .bearings = .{ 0, 12 }, .grid_pos = .{ 1, 0 }, .color = .{ 255, 255, 255, 255 }, .atlas = .color },
    };
    const u = uniformsFor(.linear, 2, 1, .{ 8, 16 }, .{ 0, 0, 0, 0 });
    try expectMatchesReference(.{
        .uniforms = u,
        .cell_bg = &bg,
        .text = &text,
        .gray = .{ .width = 8, .height = 8, .data = &atlas },
        .color = .{ .width = 8, .height = 8, .data = &emoji },
    }, 16, 16, toleranceFor(.linear));
}

fn kittyImage() [6 * 5 * 4]u8 {
    var data: [6 * 5 * 4]u8 = undefined;
    for (0..30) |i| {
        const x = i % 6;
        const y = i / 6;
        data[i * 4] = @intCast(x * 50);
        data[i * 4 + 1] = @intCast(y * 60);
        data[i * 4 + 2] = if ((x + y) % 2 == 0) 255 else 20;
        data[i * 4 + 3] = @intCast(80 + x * 30);
    }
    return data;
}

test "kitty images scale, crop, and blend like the image shader" {
    const atlas = patternAtlas(8);
    const bg: [6]CellBg = @splat(.{ 0, 0, 0, 0 });
    const pixels = kittyImage();
    const images = [_]Image{
        .{ .grid_pos = .{ 0, 0 }, .cell_offset = .{ 0, 0 }, .source_rect = .{ 0, 0, 6, 5 }, .dest_size = .{ 12, 10 } },
        .{ .grid_pos = .{ 1, 0 }, .cell_offset = .{ 0, 0 }, .source_rect = .{ 1, 1, 4, 3 }, .dest_size = .{ 8, 6 } },
        .{ .grid_pos = .{ 1, 1 }, .cell_offset = .{ 0, 0 }, .source_rect = .{ 0, 0, 6, 5 }, .dest_size = .{ 6, 5 } },
    };
    for (all_modes) |mode| {
        const u = uniformsFor(mode, 3, 2, .{ 8, 16 }, .{ 0, 0, 0, 0 });
        try expectMatchesReference(.{
            .uniforms = u,
            .cell_bg = &bg,
            .text = &.{},
            .gray = .{ .width = 8, .height = 8, .data = &atlas },
            .color = empty_color,
            .images = &images,
            .image = .{ .width = 6, .height = 5, .data = &pixels },
        }, 24, 32, toleranceFor(mode));
    }
}

test "kitty images at fractional offsets cover only the pixels they contain" {
    const atlas = patternAtlas(8);
    const bg: [6]CellBg = @splat(.{ 0, 0, 0, 0 });
    const pixels = kittyImage();
    const images = [_]Image{
        .{ .grid_pos = .{ 0, 0 }, .cell_offset = .{ 1.5, 2.25 }, .source_rect = .{ 0, 0, 6, 5 }, .dest_size = .{ 9.5, 7.5 } },
    };
    for (all_modes) |mode| {
        const u = uniformsFor(mode, 3, 2, .{ 8, 16 }, .{ 0, 0, 0, 0 });
        try expectMatchesReference(.{
            .uniforms = u,
            .cell_bg = &bg,
            .text = &.{},
            .gray = .{ .width = 8, .height = 8, .data = &atlas },
            .color = empty_color,
            .images = &images,
            .image = .{ .width = 6, .height = 5, .data = &pixels },
        }, 24, 32, toleranceFor(mode));
    }
}

test "minimum contrast recolors text before the cursor overrides it" {
    const atlas = patternAtlas(32);
    const bg = [_]CellBg{
        .{ 20, 20, 20, 255 }, .{ 235, 235, 235, 255 }, .{ 120, 120, 120, 90 },
        .{ 30, 30, 120, 255 }, .{ 0, 0, 0, 0 },         .{ 250, 240, 10, 255 },
    };
    var text: [6]CellText = undefined;
    for (&text, 0..) |*t, i| {
        t.* = .{
            .glyph_pos = .{ 0, 0 },
            .glyph_size = .{ 7, 12 },
            .bearings = .{ 1, 14 },
            .grid_pos = .{ @intCast(i % 3), @intCast(i / 3) },
            .color = if (i % 2 == 0) .{ 40, 40, 40, 255 } else .{ 230, 230, 230, 255 },
            .atlas = .grayscale,
            .bools = .{ .no_min_contrast = i == 5 },
        };
    }
    for ([_]Mode{ .linear_corrected, .linear }) |mode| {
        var u = uniformsFor(mode, 3, 2, .{ 8, 16 }, .{ 0, 0, 0, 0 });
        u.min_contrast = 4.5;
        u.cursor_pos = .{ 1, 0 };
        u.cursor_color = .{ 30, 30, 30, 255 };
        u.bg_color = .{ 16, 24, 40, 200 };
        try expectMatchesReference(.{
            .uniforms = u,
            .cell_bg = &bg,
            .text = &text,
            .gray = .{ .width = 32, .height = 32, .data = &atlas },
            .color = empty_color,
        }, 24, 32, toleranceFor(mode));
    }
}
