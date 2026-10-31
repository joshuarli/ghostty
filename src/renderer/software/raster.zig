//! Software raster operations for the terminal draw list.
//!
//! Pixel storage is sRGB encoded and premultiplied, matching what a
//! compositor receives from `wl_shm`. Linear blending decodes into 16-bit
//! linear channels, blends there, and re-encodes. Text coverage is corrected
//! for `linear-corrected` by the same luminance mapping as the GPU shaders.
//!
//! The glyph blend tables are adapted from Monstar (MIT, Tim Culverhouse),
//! commit 203e1013b184b47e6c0482671882bb791aba21f3,
//! `src/pixel_raster.zig`. See LICENSES/Monstar-MIT.txt.

const std = @import("std");
const types = @import("../shaders/types.zig");
const TargetModule = @import("Target.zig");
const Target = TargetModule.Target;
const Texture = @import("Texture.zig").Texture;
const Damage = @import("Damage.zig").Damage;
const Rect = @import("Damage.zig").Rect;
const Handle = @import("Buffer.zig").Handle;

const Uniforms = types.Uniforms;
const CellText = types.CellText;
const CellBg = types.CellBg;
const Image = types.Image;
const BgImage = types.BgImage;

pub const Pixel = TargetModule.Pixel;
pub const rgba = TargetModule.rgba;
const red = TargetModule.red;
const green = TargetModule.green;
const blue = TargetModule.blue;
const alpha = TargetModule.alpha;

pub fn toLinear(value: f32) f32 {
    return if (value <= 0.04045) value / 12.92 else std.math.pow(f32, (value + 0.055) / 1.055, 2.4);
}

pub fn fromLinear(value: f32) f32 {
    return if (value <= 0.0031308) value * 12.92 else std.math.pow(f32, value, 1.0 / 2.4) * 1.055 - 0.055;
}

const linear8: [256]u16 = blk: {
    @setEvalBranchQuota(100_000);
    var table: [256]u16 = undefined;
    for (&table, 0..) |*entry, i| {
        const c: f32 = @as(f32, @floatFromInt(i)) / 255.0;
        entry.* = @intFromFloat(toLinear(c) * 65535.0 + 0.5);
    }
    break :blk table;
};

const encode16: [65536]u8 = blk: {
    @setEvalBranchQuota(200_000);
    var table: [65536]u8 = undefined;
    var start: usize = 0;
    for (0..256) |value| {
        const end: usize = if (value == 255) table.len else @intFromFloat(@ceil(
            toLinear((@as(f32, @floatFromInt(value)) + 0.5) / 255.0) * 65535,
        ));
        @memset(table[start..end], @intCast(value));
        start = end;
    }
    break :blk table;
};

/// Linear light, scaled to 0...65535, of an sRGB value in 0...255 that may
/// fall between two byte levels.
fn linearFromEncoded(value: f32) f32 {
    const clamped = std.math.clamp(value, 0, 255);
    const low: usize = @intFromFloat(clamped);
    const high = @min(low + 1, 255);
    const t = clamped - @as(f32, @floatFromInt(low));
    return @as(f32, @floatFromInt(linear8[low])) * (1 - t) + @as(f32, @floatFromInt(linear8[high])) * t;
}

fn luminance(r: u16, g: u16, b: u16) u32 {
    return (@as(u32, r) * 2126 + @as(u32, g) * 7152 + @as(u32, b) * 722) / 10000;
}

fn encodeLinear(r: u32, g: u32, b: u32) [3]u8 {
    return .{
        encode16[@min(r, 65535)],
        encode16[@min(g, 65535)],
        encode16[@min(b, 65535)],
    };
}

fn linearRgb(c: [3]u8) [3]u16 {
    return .{ linear8[c[0]], linear8[c[1]], linear8[c[2]] };
}

fn blendEncoded(dst: Pixel, src: Pixel) Pixel {
    const sa = alpha(src);
    if (sa == 0) return dst;
    if (sa == 255) return src;
    const da = alpha(dst);
    const out_a = sa + @divTrunc(@as(u32, da) * (255 - sa), 255);
    const inv = 255 - sa;
    return rgba(
        @intCast(@min(255, @as(u32, red(src)) + @divTrunc(@as(u32, red(dst)) * inv, 255))),
        @intCast(@min(255, @as(u32, green(src)) + @divTrunc(@as(u32, green(dst)) * inv, 255))),
        @intCast(@min(255, @as(u32, blue(src)) + @divTrunc(@as(u32, blue(dst)) * inv, 255))),
        @intCast(@min(255, out_a)),
    );
}

fn blendLinear(dst: Pixel, src_linear: [3]u32, src_alpha: u8) Pixel {
    if (src_alpha == 0) return dst;
    const inv: u32 = 255 - src_alpha;
    const dr: u32 = @as(u32, linear8[red(dst)]) * inv / 255;
    const dg: u32 = @as(u32, linear8[green(dst)]) * inv / 255;
    const db: u32 = @as(u32, linear8[blue(dst)]) * inv / 255;
    const out = encodeLinear(src_linear[0] + dr, src_linear[1] + dg, src_linear[2] + db);
    const da = alpha(dst);
    const out_a = src_alpha + @divTrunc(@as(u32, da) * inv, 255);
    return rgba(out[0], out[1], out[2], @intCast(@min(255, out_a)));
}

fn blendColor(dst: Pixel, color: [4]u8, linear: bool, opacity: u8) Pixel {
    if (opacity == 0 or color[3] == 0) return dst;
    const a: u32 = (@as(u32, color[3]) * opacity + 127) / 255;
    if (linear) {
        const rgb = linearRgb(.{ color[0], color[1], color[2] });
        return blendLinear(dst, .{
            @as(u32, rgb[0]) * a / 255,
            @as(u32, rgb[1]) * a / 255,
            @as(u32, rgb[2]) * a / 255,
        }, @intCast(a));
    }
    return blendEncoded(dst, rgba(
        @intCast(@as(u32, color[0]) * a / 255),
        @intCast(@as(u32, color[1]) * a / 255),
        @intCast(@as(u32, color[2]) * a / 255),
        @intCast(a),
    ));
}

fn backgroundColor(u: *const Uniforms, linear: bool) [4]u8 {
    const c = u.bg_color;
    if (!linear) return c;
    const rgb = encodeLinear(
        @as(u32, linear8[c[0]]) * c[3] / 255,
        @as(u32, linear8[c[1]]) * c[3] / 255,
        @as(u32, linear8[c[2]]) * c[3] / 255,
    );
    return .{ rgb[0], rgb[1], rgb[2], c[3] };
}

fn damageRow(damage: Damage, y: u32, width: u32) bool {
    return damage.intersects(0, y, width, 1);
}

fn fillSpan(target: *Target, y: u32, x0: u32, x1: u32, color: [4]u8, linear: bool) void {
    if (y >= target.height) return;
    const start = @min(x0, target.width);
    const end = @min(x1, target.width);
    if (end <= start) return;
    for (target.pixels[@as(usize, y) * target.width + start ..][0 .. end - start]) |*pixel| {
        pixel.* = blendColor(pixel.*, color, linear, 255);
    }
}

pub fn clear(target: *Target, damage: Damage, color: [4]f32) void {
    const c = rgba(
        @intFromFloat(@round(std.math.clamp(color[0], 0, 1) * 255)),
        @intFromFloat(@round(std.math.clamp(color[1], 0, 1) * 255)),
        @intFromFloat(@round(std.math.clamp(color[2], 0, 1) * 255)),
        @intFromFloat(@round(std.math.clamp(color[3], 0, 1) * 255)),
    );
    switch (damage) {
        .full => @memset(target.pixels, c),
        .rects => |rects| for (rects) |rect| {
            const clipped = rect.clipped(target.width, target.height) orelse continue;
            var y = clipped.y;
            const y_end = clipped.bottom();
            while (y < y_end) : (y += 1) {
                @memset(target.pixels[@as(usize, y) * target.width + clipped.x ..][0..clipped.width], c);
            }
        },
    }
}

fn premultipliedBackground(u: *const Uniforms) Pixel {
    const c = u.bg_color;
    const a: u32 = c[3];
    if (u.bools.use_linear_blending) {
        const rgb = encodeLinear(
            @as(u32, linear8[c[0]]) * a / 255,
            @as(u32, linear8[c[1]]) * a / 255,
            @as(u32, linear8[c[2]]) * a / 255,
        );
        return rgba(rgb[0], rgb[1], rgb[2], c[3]);
    }
    return rgba(
        @intCast(@as(u32, c[0]) * a / 255),
        @intCast(@as(u32, c[1]) * a / 255),
        @intCast(@as(u32, c[2]) * a / 255),
        c[3],
    );
}

pub fn drawBgColor(target: *Target, damage: Damage, u: *const Uniforms) void {
    const src = premultipliedBackground(u);
    var y: u32 = 0;
    while (y < target.height) : (y += 1) {
        if (!damageRow(damage, y, target.width)) continue;
        @memset(target.pixels[@as(usize, y) * target.width ..][0..target.width], src);
    }
}

fn cellRect(
    u: *const Uniforms,
    col: u32,
    row: u32,
) struct { x0: u32, y0: u32, x1: u32, y1: u32 } {
    const cw = u.cell_size[0];
    const ch = u.cell_size[1];
    const left = u.grid_padding[3];
    const top = u.grid_padding[0];
    return .{
        .x0 = @intFromFloat(@max(0, @floor(left + @as(f32, @floatFromInt(col)) * cw))),
        .y0 = @intFromFloat(@max(0, @floor(top + @as(f32, @floatFromInt(row)) * ch))),
        .x1 = @intFromFloat(@ceil(left + @as(f32, @floatFromInt(col + 1)) * cw)),
        .y1 = @intFromFloat(@ceil(top + @as(f32, @floatFromInt(row + 1)) * ch)),
    };
}

fn fillCell(
    target: *Target,
    damage: Damage,
    u: *const Uniforms,
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,
    color: [4]u8,
) void {
    if (color[3] == 0) return;
    if (!damage.intersects(x0, y0, x1 -| x0, y1 -| y0)) return;
    const linear = u.bools.use_linear_blending;
    var y = y0;
    const y_end = @min(y1, target.height);
    while (y < y_end) : (y += 1) {
        if (!damageRow(damage, y, target.width)) continue;
        fillSpan(target, y, x0, x1, color, linear);
    }
}

pub fn drawCellBg(
    target: *Target,
    damage: Damage,
    u: *const Uniforms,
    bg_handle: Handle,
) void {
    const cols: u32 = u.grid_size[0];
    const rows: u32 = u.grid_size[1];
    if (cols == 0 or rows == 0) return;
    const cells = bg_handle.items(CellBg);
    if (cells.len < @as(usize, cols) * rows) return;

    var row: u32 = 0;
    while (row < rows) : (row += 1) {
        var col: u32 = 0;
        while (col < cols) : (col += 1) {
            const rect = cellRect(u, col, row);
            fillCell(target, damage, u, rect.x0, rect.y0, rect.x1, rect.y1, cells[@as(usize, row) * cols + col]);
        }
    }

    const grid_left: u32 = @intFromFloat(@max(0, @floor(u.grid_padding[3])));
    const grid_top: u32 = @intFromFloat(@max(0, @floor(u.grid_padding[0])));
    const grid_right: u32 = @intFromFloat(@ceil(u.grid_padding[3] + @as(f32, @floatFromInt(cols)) * u.cell_size[0]));
    const grid_bottom: u32 = @intFromFloat(@ceil(u.grid_padding[0] + @as(f32, @floatFromInt(rows)) * u.cell_size[1]));

    if (u.padding_extend.left) {
        row = 0;
        while (row < rows) : (row += 1) {
            const rect = cellRect(u, 0, row);
            fillCell(target, damage, u, 0, rect.y0, grid_left, rect.y1, cells[@as(usize, row) * cols]);
        }
    }
    if (u.padding_extend.right) {
        row = 0;
        while (row < rows) : (row += 1) {
            const rect = cellRect(u, 0, row);
            fillCell(target, damage, u, grid_right, rect.y0, target.width, rect.y1, cells[@as(usize, row) * cols + cols - 1]);
        }
    }
    if (u.padding_extend.up) {
        fillCellY(target, damage, u, 0, grid_top, cells[0..cols], cols);
    }
    if (u.padding_extend.down) {
        fillCellY(target, damage, u, grid_bottom, target.height, cells[@as(usize, rows - 1) * cols ..][0..cols], cols);
    }
}

fn fillCellY(
    target: *Target,
    damage: Damage,
    u: *const Uniforms,
    y0: u32,
    y1: u32,
    cells: []const CellBg,
    cols: u32,
) void {
    var col: u32 = 0;
    while (col < cols) : (col += 1) {
        const rect = cellRect(u, col, 0);
        fillCell(target, damage, u, rect.x0, y0, rect.x1, y1, cells[col]);
    }
}

const TextSource = struct {
    srgb: [3]u8,
    linear: [3]u16,
    alpha: u8,
    correction: ?[256]u8 = null,
};

fn cursorAt(u: *const Uniforms, x: u32, y: u32) bool {
    const wide = u.bools.cursor_wide;
    return y == u.cursor_pos[1] and
        (x == u.cursor_pos[0] or (wide and x == u.cursor_pos[0] + 1));
}

fn premultiplyLinear(rgb: [3]u16, alpha_value: u8) [3]u16 {
    return .{
        @intCast(@as(u32, rgb[0]) * alpha_value / 255),
        @intCast(@as(u32, rgb[1]) * alpha_value / 255),
        @intCast(@as(u32, rgb[2]) * alpha_value / 255),
    };
}

/// The cell background composited over the surface background, as
/// premultiplied linear light. The text shaders judge contrast and weight
/// against this value.
fn premultipliedLinearBackground(u: *const Uniforms, bg_handle: Handle, x: u32, y: u32) [3]u16 {
    const global = premultiplyLinear(
        linearRgb(.{ u.bg_color[0], u.bg_color[1], u.bg_color[2] }),
        u.bg_color[3],
    );
    const cells = bg_handle.items(CellBg);
    const index = @as(usize, y) * u.grid_size[0] + x;
    if (index >= cells.len) return global;
    const cell = cells[index];
    const above = premultiplyLinear(linearRgb(.{ cell[0], cell[1], cell[2] }), cell[3]);
    const inv: u32 = 255 - cell[3];
    return .{
        @intCast(@min(65535, @as(u32, above[0]) + @as(u32, global[0]) * inv / 255)),
        @intCast(@min(65535, @as(u32, above[1]) + @as(u32, global[1]) * inv / 255)),
        @intCast(@min(65535, @as(u32, above[2]) + @as(u32, global[2]) * inv / 255)),
    };
}

fn resolveTextSource(
    u: *const Uniforms,
    cell: CellText,
    bg_handle: Handle,
) TextSource {
    const linear = u.bools.use_linear_blending;
    var color = cell.color;
    var lin = linearRgb(.{ color[0], color[1], color[2] });
    const bg_lin = premultipliedLinearBackground(u, bg_handle, cell.grid_pos[0], cell.grid_pos[1]);
    const bg_l = luminance(bg_lin[0], bg_lin[1], bg_lin[2]);

    if (u.min_contrast > 1.0 and !cell.bools.no_min_contrast) {
        const fg = premultiplyLinear(lin, color[3]);
        const fg_l = luminance(fg[0], fg[1], fg[2]);
        const ratio = @as(f32, @floatFromInt(@max(fg_l, bg_l) + 3277)) /
            @as(f32, @floatFromInt(@min(fg_l, bg_l) + 3277));
        if (ratio < u.min_contrast) {
            const white_ratio = @as(f32, @floatFromInt(65535 + 3277)) /
                @as(f32, @floatFromInt(bg_l + 3277));
            const black_ratio = @as(f32, @floatFromInt(3277)) /
                @as(f32, @floatFromInt(bg_l + 3277));
            if (white_ratio > black_ratio) {
                color = .{ 255, 255, 255, 255 };
                lin = .{ 65535, 65535, 65535 };
            } else {
                color = .{ 0, 0, 0, 255 };
                lin = .{ 0, 0, 0 };
            }
        }
    }

    if (cursorAt(u, cell.grid_pos[0], cell.grid_pos[1]) and !cell.bools.is_cursor_glyph) {
        color = u.cursor_color;
        lin = linearRgb(.{ color[0], color[1], color[2] });
    }

    var result: TextSource = .{
        .srgb = .{ color[0], color[1], color[2] },
        .linear = lin,
        .alpha = color[3],
    };

    if (u.bools.use_linear_correction and linear) {
        const fg = premultiplyLinear(lin, color[3]);
        const fg_l = luminance(fg[0], fg[1], fg[2]);
        if (@abs(@as(i64, fg_l) - @as(i64, bg_l)) > 66) {
            var table: [256]u8 = undefined;
            const fg_enc = fromLinear(@as(f32, @floatFromInt(fg_l)) / 65535.0) * 255.0;
            const bg_enc = fromLinear(@as(f32, @floatFromInt(bg_l)) / 65535.0) * 255.0;
            const diff: f32 = @floatFromInt(@as(i64, fg_l) - @as(i64, bg_l));
            for (&table, 0..) |*entry, cov| {
                const weight = @as(f32, @floatFromInt(cov)) / 255.0;
                const blend_l = linearFromEncoded(fg_enc * weight + bg_enc * (1 - weight));
                const corrected = (blend_l - @as(f32, @floatFromInt(bg_l))) / diff;
                entry.* = @intFromFloat(@round(std.math.clamp(corrected, 0, 1) * 255.0));
            }
            result.correction = table;
        }
    }
    return result;
}

fn blendTextPixel(
    dst: Pixel,
    src: TextSource,
    coverage: u8,
    linear: bool,
) Pixel {
    if (coverage == 0) return dst;
    var a32: u32 = (@as(u32, src.alpha) * coverage + 127) / 255;
    if (src.correction) |table| a32 = (@as(u32, table[coverage]) * src.alpha + 127) / 255;
    if (a32 == 0) return dst;
    if (linear) {
        return blendLinear(dst, .{
            @as(u32, src.linear[0]) * a32 / 255,
            @as(u32, src.linear[1]) * a32 / 255,
            @as(u32, src.linear[2]) * a32 / 255,
        }, @intCast(a32));
    }
    return blendEncoded(dst, rgba(
        @intCast(@as(u32, src.srgb[0]) * a32 / 255),
        @intCast(@as(u32, src.srgb[1]) * a32 / 255),
        @intCast(@as(u32, src.srgb[2]) * a32 / 255),
        @intCast(a32),
    ));
}

fn colorGlyphPixel(
    dst: Pixel,
    sample: [4]u8,
    linear: bool,
) Pixel {
    if (sample[3] == 0) return dst;
    if (linear) {
        const rgb = linearRgb(.{ sample[0], sample[1], sample[2] });
        return blendLinear(dst, .{ rgb[0], rgb[1], rgb[2] }, sample[3]);
    }
    const a: u32 = sample[3];
    return blendEncoded(dst, rgba(
        @intCast(@as(u32, sample[0]) * a / 255),
        @intCast(@as(u32, sample[1]) * a / 255),
        @intCast(@as(u32, sample[2]) * a / 255),
        sample[3],
    ));
}

pub fn drawCellText(
    target: *Target,
    damage: Damage,
    u: *const Uniforms,
    cells_handle: Handle,
    bg_handle: Handle,
    grayscale: *const Texture,
    color: *const Texture,
) void {
    const cols: u32 = u.grid_size[0];
    const rows: u32 = u.grid_size[1];
    const instances = cells_handle.items(CellText);
    if (cols == 0 or rows == 0) return;
    const cw = u.cell_size[0];
    const ch = u.cell_size[1];
    const left = u.grid_padding[3];
    const top = u.grid_padding[0];
    const linear = u.bools.use_linear_blending;

    for (instances) |cell| {
        if (cell.glyph_size[0] == 0 or cell.glyph_size[1] == 0) continue;
        const cell_x = @as(f32, @floatFromInt(cell.grid_pos[0]));
        const cell_y = @as(f32, @floatFromInt(cell.grid_pos[1]));
        var ox: f32 = @floatFromInt(@as(i16, cell.bearings[0]));
        var oy: f32 = ch - @as(f32, @floatFromInt(@as(i16, cell.bearings[1])));
        const x: f32 = left + cell_x * cw + ox;
        const y: f32 = top + cell_y * ch + oy;
        _ = &ox;
        _ = &oy;
        const w: f32 = @floatFromInt(cell.glyph_size[0]);
        const h: f32 = @floatFromInt(cell.glyph_size[1]);
        const x0: u32 = @intFromFloat(@max(0, @floor(x)));
        const y0: u32 = @intFromFloat(@max(0, @floor(y)));
        const x1: u32 = @intFromFloat(@min(@as(f32, @floatFromInt(target.width)), @ceil(x + w)));
        const y1: u32 = @intFromFloat(@min(@as(f32, @floatFromInt(target.height)), @ceil(y + h)));
        if (x1 <= x0 or y1 <= y0) continue;
        if (!damage.intersects(x0, y0, x1 - x0, y1 - y0)) continue;

        const source = if (cell.atlas == .grayscale)
            resolveTextSource(u, cell, bg_handle)
        else
            null;

        var py = y0;
        while (py < y1) : (py += 1) {
            if (!damageRow(damage, py, target.width)) continue;
            const v = (@as(f32, @floatFromInt(py)) + 0.5 - y) / h;
            const sy: i64 = @intFromFloat(@floor(@as(f32, @floatFromInt(cell.glyph_pos[1])) + v * h));
            var px = x0;
            while (px < x1) : (px += 1) {
                const u_norm = (@as(f32, @floatFromInt(px)) + 0.5 - x) / w;
                const sx: i64 = @intFromFloat(@floor(@as(f32, @floatFromInt(cell.glyph_pos[0])) + u_norm * w));
                const dst = &target.pixels[@as(usize, py) * target.width + px];
                switch (cell.atlas) {
                    .grayscale => {
                        const sample = grayscale.sample(sx, sy);
                        dst.* = blendTextPixel(dst.*, source.?, sample[0], linear);
                    },
                    .color => {
                        const sample = color.sample(sx, sy);
                        dst.* = colorGlyphPixel(dst.*, sample, linear);
                    },
                }
            }
        }
    }
}

const LinearSample = struct {
    rgb: [3]f32,
    alpha: f32,
};

/// Image textures are sRGB on the GPU, so filtering happens in linear light.
fn sampleBilinearLinear(tex: *const Texture, x: f32, y: f32) LinearSample {
    if (tex.width == 0 or tex.height == 0) return .{ .rgb = .{ 0, 0, 0 }, .alpha = 0 };
    const x0: i64 = @intFromFloat(@floor(x));
    const y0: i64 = @intFromFloat(@floor(y));
    const fx = x - @floor(x);
    const fy = y - @floor(y);
    const taps = [4][4]u8{
        tex.sample(x0, y0),
        tex.sample(x0 + 1, y0),
        tex.sample(x0, y0 + 1),
        tex.sample(x0 + 1, y0 + 1),
    };
    const weights = [4]f32{ (1 - fx) * (1 - fy), fx * (1 - fy), (1 - fx) * fy, fx * fy };
    var out: LinearSample = .{ .rgb = .{ 0, 0, 0 }, .alpha = 0 };
    for (taps, weights) |tap, weight| {
        for (&out.rgb, 0..) |*channel, i| {
            channel.* += @as(f32, @floatFromInt(linear8[tap[i]])) / 65535.0 * weight;
        }
        out.alpha += @as(f32, @floatFromInt(tap[3])) / 255.0 * weight;
    }
    return out;
}

fn linearToByte(value: f32) u8 {
    const scaled = std.math.clamp(value, 0, 1) * 65535.0 + 0.5;
    return encode16[@intFromFloat(scaled)];
}

fn blendImageSample(dst: Pixel, sample: LinearSample, linear: bool) Pixel {
    const a: u8 = @intFromFloat(@round(std.math.clamp(sample.alpha, 0, 1) * 255));
    if (a == 0) return dst;
    if (linear) {
        return blendLinear(dst, .{
            @intFromFloat(@round(std.math.clamp(sample.rgb[0], 0, 1) * sample.alpha * 65535)),
            @intFromFloat(@round(std.math.clamp(sample.rgb[1], 0, 1) * sample.alpha * 65535)),
            @intFromFloat(@round(std.math.clamp(sample.rgb[2], 0, 1) * sample.alpha * 65535)),
        }, a);
    }
    return blendEncoded(dst, rgba(
        @intFromFloat(@round(@as(f32, @floatFromInt(linearToByte(sample.rgb[0]))) * sample.alpha)),
        @intFromFloat(@round(@as(f32, @floatFromInt(linearToByte(sample.rgb[1]))) * sample.alpha)),
        @intFromFloat(@round(@as(f32, @floatFromInt(linearToByte(sample.rgb[2]))) * sample.alpha)),
        a,
    ));
}

pub fn drawImages(
    target: *Target,
    damage: Damage,
    u: *const Uniforms,
    instances: []const Image,
    tex: *const Texture,
) void {
    if (tex.width == 0 or tex.height == 0) return;
    const cw = u.cell_size[0];
    const ch = u.cell_size[1];
    const left = u.grid_padding[3];
    const top = u.grid_padding[0];
    const linear = u.bools.use_linear_blending;

    for (instances) |img| {
        if (img.dest_size[0] <= 0 or img.dest_size[1] <= 0) continue;
        const x: f32 = left + img.grid_pos[0] * cw + img.cell_offset[0];
        const y: f32 = top + img.grid_pos[1] * ch + img.cell_offset[1];
        const w = img.dest_size[0];
        const h = img.dest_size[1];
        const x0: u32 = @intFromFloat(@max(0, @floor(x)));
        const y0: u32 = @intFromFloat(@max(0, @floor(y)));
        const x1: u32 = @intFromFloat(@min(@as(f32, @floatFromInt(target.width)), @ceil(x + w)));
        const y1: u32 = @intFromFloat(@min(@as(f32, @floatFromInt(target.height)), @ceil(y + h)));
        if (x1 <= x0 or y1 <= y0) continue;
        if (!damage.intersects(x0, y0, x1 - x0, y1 - y0)) continue;

        var py = y0;
        while (py < y1) : (py += 1) {
            if (!damageRow(damage, py, target.width)) continue;
            const v = (@as(f32, @floatFromInt(py)) + 0.5 - y) / h;
            const sy = img.source_rect[1] + v * img.source_rect[3] - 0.5;
            var px = x0;
            while (px < x1) : (px += 1) {
                const u_norm = (@as(f32, @floatFromInt(px)) + 0.5 - x) / w;
                const sx = img.source_rect[0] + u_norm * img.source_rect[2] - 0.5;
                const sample = sampleBilinearLinear(tex, sx, sy);
                const dst = &target.pixels[@as(usize, py) * target.width + px];
                dst.* = blendImageSample(dst.*, sample, linear);
            }
        }
    }
}

pub fn drawBgImage(
    target: *Target,
    damage: Damage,
    u: *const Uniforms,
    info: BgImage,
    tex: *const Texture,
) void {
    if (tex.width == 0 or tex.height == 0) return;
    const tex_w: f32 = @floatFromInt(tex.width);
    const tex_h: f32 = @floatFromInt(tex.height);
    const screen_w = u.screen_size[0];
    const screen_h = u.screen_size[1];
    var dest_w = tex_w;
    var dest_h = tex_h;
    switch (info.info.fit) {
        .contain => {
            const scale = @min(screen_w / tex_w, screen_h / tex_h);
            dest_w = tex_w * scale;
            dest_h = tex_h * scale;
        },
        .cover => {
            const scale = @max(screen_w / tex_w, screen_h / tex_h);
            dest_w = tex_w * scale;
            dest_h = tex_h * scale;
        },
        .stretch => {
            dest_w = screen_w;
            dest_h = screen_h;
        },
        .none => {},
    }

    const start_x: f32 = 0;
    const start_y: f32 = 0;
    const mid_x = (screen_w - dest_w) / 2;
    const mid_y = (screen_h - dest_h) / 2;
    const end_x = screen_w - dest_w;
    const end_y = screen_h - dest_h;
    const offset = switch (info.info.position) {
        .tl => [2]f32{ start_x, start_y },
        .tc => [2]f32{ mid_x, start_y },
        .tr => [2]f32{ end_x, start_y },
        .ml => [2]f32{ start_x, mid_y },
        .mc => [2]f32{ mid_x, mid_y },
        .mr => [2]f32{ end_x, mid_y },
        .bl => [2]f32{ start_x, end_y },
        .bc => [2]f32{ mid_x, end_y },
        .br => [2]f32{ end_x, end_y },
    };
    const scale_x = tex_w / dest_w;
    const scale_y = tex_h / dest_h;
    const bg = backgroundColor(u, u.bools.use_linear_blending);
    const bg_a = @as(f32, @floatFromInt(bg[3])) / 255.0;
    const opacity = @min(info.opacity, if (bg_a > 0) 1.0 / bg_a else 1.0);
    const linear = u.bools.use_linear_blending;

    var y: u32 = 0;
    while (y < target.height) : (y += 1) {
        if (!damageRow(damage, y, target.width)) continue;
        var x: u32 = 0;
        while (x < target.width) : (x += 1) {
            var tx = (@as(f32, @floatFromInt(x)) + 0.5 - offset[0]) * scale_x;
            var ty = (@as(f32, @floatFromInt(y)) + 0.5 - offset[1]) * scale_y;
            if (info.info.repeat) {
                tx = @mod(@mod(tx, tex_w) + tex_w, tex_w);
                ty = @mod(@mod(ty, tex_h) + tex_h, tex_h);
            }
            var sample: LinearSample = .{ .rgb = .{ 0, 0, 0 }, .alpha = 0 };
            if (tx >= 0 and tx < tex_w and ty >= 0 and ty < tex_h) {
                sample = sampleBilinearLinear(tex, tx - 0.5, ty - 0.5);
            }
            var rgb: [3]f32 = sample.rgb;
            var a = sample.alpha;
            if (!linear) {
                rgb = .{
                    @as(f32, @floatFromInt(linearToByte(rgb[0]))) / 255.0,
                    @as(f32, @floatFromInt(linearToByte(rgb[1]))) / 255.0,
                    @as(f32, @floatFromInt(linearToByte(rgb[2]))) / 255.0,
                };
            }
            rgb[0] *= a;
            rgb[1] *= a;
            rgb[2] *= a;
            rgb[0] *= opacity;
            rgb[1] *= opacity;
            rgb[2] *= opacity;
            a *= opacity;
            const bg_lin = if (linear) [3]f32{
                toLinear(@as(f32, @floatFromInt(bg[0])) / 255.0),
                toLinear(@as(f32, @floatFromInt(bg[1])) / 255.0),
                toLinear(@as(f32, @floatFromInt(bg[2])) / 255.0),
            } else [3]f32{
                @as(f32, @floatFromInt(bg[0])) / 255.0,
                @as(f32, @floatFromInt(bg[1])) / 255.0,
                @as(f32, @floatFromInt(bg[2])) / 255.0,
            };
            rgb[0] += bg_lin[0] * (1 - a);
            rgb[1] += bg_lin[1] * (1 - a);
            rgb[2] += bg_lin[2] * (1 - a);
            a = 1 - (1 - a) * (1 - bg_a);
            rgb[0] *= bg_a;
            rgb[1] *= bg_a;
            rgb[2] *= bg_a;
            const dst = &target.pixels[@as(usize, y) * target.width + x];
            if (linear) {
                dst.* = blendLinear(dst.*, .{
                    @intFromFloat(rgb[0] * 65535),
                    @intFromFloat(rgb[1] * 65535),
                    @intFromFloat(rgb[2] * 65535),
                }, @intFromFloat(a * 255));
            } else {
                dst.* = blendEncoded(dst.*, rgba(
                    @intFromFloat(rgb[0] * 255),
                    @intFromFloat(rgb[1] * 255),
                    @intFromFloat(rgb[2] * 255),
                    @intFromFloat(a * 255),
                ));
            }
        }
    }
}

test "opaque background fill matches the requested color" {
    const alloc = std.testing.allocator;
    var target = try Target.init(alloc, 3, 2);
    defer target.deinit();
    const u: Uniforms = .{
        .projection_matrix = undefined,
        .screen_size = .{ 3, 2 },
        .cell_size = .{ 1, 1 },
        .grid_size = .{ 3, 2 },
        .grid_padding = .{ 0, 0, 0, 0 },
        .padding_extend = .{},
        .min_contrast = 1,
        .cursor_pos = .{ 0xffff, 0xffff },
        .cursor_color = .{ 0, 0, 0, 0 },
        .bg_color = .{ 10, 20, 30, 255 },
        .bools = .{ .cursor_wide = false, .use_display_p3 = false, .use_linear_blending = false },
    };
    clear(&target, .full, .{ 0, 0, 0, 0 });
    drawBgColor(&target, .full, &u);
    for (target.pixels) |pixel| try std.testing.expectEqual(rgba(10, 20, 30, 255), pixel);
}

test "glyph placement uses bearings and the grayscale atlas" {
    const alloc = std.testing.allocator;
    var target = try Target.init(alloc, 4, 4);
    defer target.deinit();
    clear(&target, .full, .{ 0, 0, 0, 0 });
    const u: Uniforms = .{
        .projection_matrix = undefined,
        .screen_size = .{ 4, 4 },
        .cell_size = .{ 4, 4 },
        .grid_size = .{ 1, 1 },
        .grid_padding = .{ 0, 0, 0, 0 },
        .padding_extend = .{},
        .min_contrast = 1,
        .cursor_pos = .{ 0xffff, 0xffff },
        .cursor_color = .{ 0, 0, 0, 0 },
        .bg_color = .{ 0, 0, 0, 255 },
        .bools = .{ .cursor_wide = false, .use_display_p3 = false, .use_linear_blending = false },
    };
    var atlas = try Texture.init(.{ .alloc = alloc, .format = .grayscale, .target = .rectangle }, 2, 2, &.{
        255, 0,
        0, 128,
    });
    defer atlas.deinit();
    var color_atlas = try Texture.init(.{ .alloc = alloc, .format = .bgra, .target = .rectangle }, 1, 1, &.{ 0, 0, 0, 0 });
    defer color_atlas.deinit();
    const bg = [_]CellBg{.{ 0, 0, 0, 255 }};
    const cells = [_]CellText{.{
        .glyph_pos = .{ 0, 0 },
        .glyph_size = .{ 2, 2 },
        .bearings = .{ 1, 3 },
        .grid_pos = .{ 0, 0 },
        .color = .{ 255, 0, 0, 255 },
        .atlas = .grayscale,
    }};
    drawBgColor(&target, .full, &u);
    drawCellText(
        &target,
        .full,
        &u,
        .{ .ptr = @constCast(@ptrCast(&cells)), .len = cells.len },
        .{ .ptr = @constCast(@ptrCast(&bg)), .len = bg.len },
        &atlas,
        &color_atlas,
    );
    try std.testing.expectEqual(rgba(255, 0, 0, 255), target.pixels[1 * 4 + 1]);
    try std.testing.expectEqual(rgba(0, 0, 0, 255), target.pixels[1 * 4 + 2]);
    try std.testing.expectEqual(rgba(0, 0, 0, 255), target.pixels[2 * 4 + 1]);
    const half = target.pixels[2 * 4 + 2];
    try std.testing.expect(red(half) > 0 and red(half) < 255);
}

fn testUniforms() Uniforms {
    return .{
        .projection_matrix = undefined,
        .screen_size = .{ 8, 8 },
        .cell_size = .{ 4, 4 },
        .grid_size = .{ 2, 2 },
        .grid_padding = .{ 0, 0, 0, 0 },
        .padding_extend = .{},
        .min_contrast = 1,
        .cursor_pos = .{ 0xffff, 0xffff },
        .cursor_color = .{ 0, 0, 0, 0 },
        .bg_color = .{ 2, 3, 4, 255 },
        .bools = .{ .cursor_wide = false, .use_display_p3 = false, .use_linear_blending = true },
    };
}

fn testDrawScene(
    target: *Target,
    damage: Damage,
    cells: []const CellText,
    bg: []const CellBg,
    atlas: *const Texture,
    color: *const Texture,
) void {
    const u = testUniforms();
    drawBgColor(target, damage, &u);
    drawCellBg(
        target,
        damage,
        &u,
        .{ .ptr = @constCast(@ptrCast(bg.ptr)), .len = bg.len },
    );
    drawCellText(
        target,
        damage,
        &u,
        .{ .ptr = @constCast(@ptrCast(cells.ptr)), .len = cells.len },
        .{ .ptr = @constCast(@ptrCast(bg.ptr)), .len = bg.len },
        atlas,
        color,
    );
}

test "incremental row damage matches a full repaint" {
    const alloc = std.testing.allocator;
    var full = try Target.init(alloc, 8, 8);
    defer full.deinit();
    var incremental = try Target.init(alloc, 8, 8);
    defer incremental.deinit();

    var atlas = try Texture.init(.{ .alloc = alloc, .format = .grayscale, .target = .rectangle }, 4, 2, &.{
        255, 0, 255, 0,
        0, 255, 0, 255,
    });
    defer atlas.deinit();
    var color_atlas = try Texture.init(.{ .alloc = alloc, .format = .bgra, .target = .rectangle }, 1, 1, &.{ 0, 0, 0, 0 });
    defer color_atlas.deinit();

    const bg = [_]CellBg{
        .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 },
        .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 },
    };
    const cells = [_]CellText{
        .{
            .glyph_pos = .{ 0, 0 },
            .glyph_size = .{ 2, 2 },
            .bearings = .{ 1, 3 },
            .grid_pos = .{ 0, 0 },
            .color = .{ 230, 240, 231, 255 },
            .atlas = .grayscale,
        },
        .{
            .glyph_pos = .{ 2, 0 },
            .glyph_size = .{ 2, 2 },
            .bearings = .{ 1, 3 },
            .grid_pos = .{ 1, 1 },
            .color = .{ 240, 147, 134, 255 },
            .atlas = .grayscale,
        },
    };

    clear(&full, .full, .{ 0, 0, 0, 0 });
    testDrawScene(&full, .full, &cells, &bg, &atlas, &color_atlas);
    clear(&incremental, .full, .{ 0, 0, 0, 0 });
    testDrawScene(&incremental, .full, &cells, &bg, &atlas, &color_atlas);

    var changed = cells;
    changed[1].color = .{ 196, 232, 145, 255 };
    changed[1].glyph_pos = .{ 0, 1 };
    const row_damage = [_]Rect{.{ .x = 0, .y = 4, .width = 8, .height = 4 }};
    testDrawScene(&full, .full, &changed, &bg, &atlas, &color_atlas);
    testDrawScene(&incremental, .{ .rects = &row_damage }, &changed, &bg, &atlas, &color_atlas);

    try std.testing.expectEqualSlices(u32, full.pixels, incremental.pixels);
}

test "translucent cell background composites in linear light" {
    const alloc = std.testing.allocator;
    var target = try Target.init(alloc, 1, 1);
    defer target.deinit();
    var u = testUniforms();
    u.screen_size = .{ 1, 1 };
    u.grid_size = .{ 1, 1 };
    u.cell_size = .{ 1, 1 };
    clear(&target, .full, .{ 0, 0, 0, 0 });
    drawBgColor(&target, .full, &u);
    const bg = [_]CellBg{.{ 255, 0, 0, 128 }};
    drawCellBg(&target, .full, &u, .{ .ptr = @constCast(@ptrCast(&bg)), .len = 1 });
    const pixel = target.pixels[0];
    try std.testing.expect(red(pixel) > 100);
    try std.testing.expect(green(pixel) < 96);
    try std.testing.expectEqual(@as(u8, 255), alpha(pixel));
}
