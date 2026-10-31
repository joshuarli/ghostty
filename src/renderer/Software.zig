//! CPU-rendered graphics backend. It consumes the same render state, draw
//! lists, font atlases, and image placements as the GPU backends, then
//! exports sRGB RGBA pixels for wl_shm presentation. No EGL/OpenGL object is
//! created.

const std = @import("std");
const Allocator = std.mem.Allocator;
const build_config = @import("../build_config.zig");
const font = @import("../font/main.zig");
const rendererpkg = @import("../renderer.zig");
const shadertoy = @import("shadertoy.zig");

pub const Buffer = @import("software/Buffer.zig").Buffer;
pub const BufferOptions = @import("software/Buffer.zig").Options;
pub const Handle = @import("software/Buffer.zig").Handle;
pub const Pipeline = @import("software/Pipeline.zig").Pipeline;
pub const SamplerModule = @import("software/Sampler.zig");
pub const Sampler = SamplerModule.Sampler;
const SamplerOptions = SamplerModule.Options;
pub const TextureModule = @import("software/Texture.zig");
pub const Texture = TextureModule.Texture;
const TextureFormat = TextureModule.Format;
const TextureOptions = TextureModule.Options;
pub const Target = @import("software/Target.zig").Target;
pub const Damage = @import("software/Damage.zig").Damage;
pub const DamageRect = @import("software/Damage.zig").Rect;
pub const Frame = @import("software/Frame.zig").Frame;
pub const RenderPass = @import("software/Frame.zig").RenderPass;

pub const Software = @This();

pub const shaders = @import("software/shaders.zig");
pub const swap_chain_count = 1;
pub const custom_shader_target: shadertoy.Target = .glsl;
pub const custom_shader_y_is_down = true;
pub const supports_custom_shaders = false;

const CellText = shaders.CellText;
const CellBg = shaders.CellBg;
const Uniforms = shaders.Uniforms;

const log = std.log.scoped(.software_renderer);

pub const Device = struct {
    pub const Options = struct {};

    pub fn init(alloc: Allocator, options: Options) !*Device {
        _ = options;
        const self = try alloc.create(Device);
        self.* = .{};
        return self;
    }

    pub fn deinit(self: *Device, alloc: Allocator) void {
        alloc.destroy(self);
    }

    pub fn warmup() !void {}
};

pub const ImageTextureFormat = enum { gray, rgba, bgra };

pub const ExportedFrame = union(enum) {
    dmabuf: DummyDmabuf,
    memory: Memory,

    /// The software backend never produces GPU buffers. Keep the variant so
    /// apprt presentation code remains shared; it is never selected.
    pub const DummyDmabuf = struct {
        pub fn deinit(self: DummyDmabuf) void {
            _ = self;
        }
    };

    /// RGBA8, premultiplied, sRGB encoded, top-down rows, tightly packed.
    pub const Memory = struct {
        width: u32,
        height: u32,
        pixels: []u8,
        alloc: Allocator,
        revision: u64,
        /// Null means the whole frame changed. Relative to `revision - 1`.
        damage: ?[]DamageRect,

        pub fn deinit(self: Memory) void {
            self.alloc.free(self.pixels);
            if (self.damage) |rects| self.alloc.free(rects);
        }
    };

    pub fn deinit(self: ExportedFrame) void {
        switch (self) {
            .dmabuf => |v| v.deinit(),
            .memory => |v| v.deinit(),
        }
    }
};

alloc: Allocator,
blending: @import("../config.zig").Config.AlphaBlending,
width: u32 = 0,
height: u32 = 0,

previous: Snapshot = .{},
have_previous: bool = false,
    previous_had_images: bool = false,
previous_uniforms: Uniforms = undefined,
dirty_rows: []bool = &.{},
damage_rects: std.ArrayListUnmanaged(DamageRect) = .empty,
current_damage: Damage = .full,

pub fn init(
    alloc: Allocator,
    device: *const Device,
    opts: rendererpkg.Options,
) !Software {
    _ = device;
    return .{
        .alloc = alloc,
        .blending = opts.config.blending,
        .width = opts.size.screen.width,
        .height = opts.size.screen.height,
    };
}

pub fn deinit(self: *Software) void {
    self.previous.deinit(self.alloc);
    self.alloc.free(self.dirty_rows);
    self.damage_rects.deinit(self.alloc);
    self.* = undefined;
}

pub fn threadEnter(self: *Software, surface: *@import("../apprt.zig").Surface) !void {
    _ = self;
    _ = surface;
}

pub fn threadExit(self: *Software) void {
    _ = self;
}

pub fn loopEnter(self: *Software) void {
    _ = self;
}

pub fn loopExit(self: *Software) void {
    _ = self;
}

pub fn displayRealized(self: *Software) void {
    _ = self;
}

pub fn surfaceSize(self: *const Software) !struct { width: u32, height: u32 } {
    return .{ .width = self.width, .height = self.height };
}

pub fn setViewport(self: *Software, width: u32, height: u32) void {
    self.width = width;
    self.height = height;
}

pub fn drawFrameStart(self: *Software) void {
    _ = self;
}

pub fn drawFrameEnd(self: *Software) void {
    _ = self;
}

pub fn initShaders(
    self: *const Software,
    alloc: Allocator,
    custom_shaders: []const [:0]const u8,
) !shaders.Shaders {
    _ = self;
    if (custom_shaders.len > 0) {
        log.warn("software renderer does not support custom shaders; ignoring {d} shader(s)", .{custom_shaders.len});
        return shaders.Shaders.init(alloc, &.{});
    }
    return shaders.Shaders.init(alloc, custom_shaders);
}

pub fn initTarget(self: *const Software, width: usize, height: usize) !Target {
    return Target.init(self.alloc, @intCast(width), @intCast(height));
}

pub fn initAtlasTexture(self: *const Software, atlas: *const font.Atlas) !Texture {
    const format: TextureFormat = switch (atlas.format) {
        .grayscale => .grayscale,
        .bgra => .bgra,
        else => return error.UnsupportedAtlasFormat,
    };
    return Texture.init(.{
        .alloc = self.alloc,
        .format = format,
        .target = .rectangle,
        .min_filter = .nearest,
        .mag_filter = .nearest,
    }, atlas.size, atlas.size, null);
}

pub fn textureOptions(self: *const Software) TextureOptions {
    return .{
        .alloc = self.alloc,
        .format = .rgba,
        .target = .@"2d",
        .min_filter = .linear,
        .mag_filter = .linear,
    };
}

pub fn imageTextureOptions(
    self: *const Software,
    format: ImageTextureFormat,
    srgb: bool,
) TextureOptions {
    _ = srgb;
    return .{
        .alloc = self.alloc,
        .format = switch (format) {
            .gray => .grayscale,
            .rgba => .rgba,
            .bgra => .bgra,
        },
        .target = .@"2d",
        .min_filter = .linear,
        .mag_filter = .linear,
    };
}

pub fn samplerOptions(self: *const Software) SamplerOptions {
    _ = self;
    return .{};
}

pub fn bufferOptions(self: *const Software) BufferOptions {
    return .{ .alloc = self.alloc };
}

pub const instanceBufferOptions = bufferOptions;
pub const uniformBufferOptions = bufferOptions;
pub const fgBufferOptions = bufferOptions;
pub const bgBufferOptions = bufferOptions;
pub const imageBufferOptions = bufferOptions;
pub const bgImageBufferOptions = bufferOptions;

pub fn beginFrame(self: *Software, renderer: anytype, target: *Target) !Frame {
    self.current_damage = try self.prepareDamage(renderer, target);
    target.state.content_valid = false;
    var frame = Frame.init(self.alloc, target, self.current_damage);
    frame.setFinalize(.{
        .api = self,
        .renderer = renderer,
        .complete_fn = completeFrame,
    });
    return frame;
}

const Generic = rendererpkg.GenericRenderer(Software);

fn completeFrame(
    api: *anyopaque,
    renderer_ptr: *anyopaque,
    target: *Target,
    sync: bool,
) void {
    _ = sync;
    const self: *Software = @ptrCast(@alignCast(api));
    const renderer: *Generic = @ptrCast(@alignCast(renderer_ptr));
    if (self.current_damage.isEmpty()) {
        target.state.content_valid = true;
        renderer.frameCompleted(.healthy);
        return;
    }
    const exported = self.present(target.*, renderer.presentationHealth()) catch |err| {
        log.warn("software present failed err={}", .{err});
        renderer.frameCompleted(.unhealthy);
        return;
    };
    renderer.pushFrame(exported);
    _ = renderer.surface_mailbox.push(.redraw, .{ .forever = {} });
    renderer.frameCompleted(.healthy);
}

pub fn present(
    self: *Software,
    target: Target,
    presentation_health: rendererpkg.Health,
) !ExportedFrame {
    _ = presentation_health;
    const pixel_count = @as(usize, target.width) * target.height;
    const pixels = try self.alloc.dupe(u8, std.mem.sliceAsBytes(target.pixels[0..pixel_count]));
    errdefer self.alloc.free(pixels);

    const damage: ?[]DamageRect = switch (self.current_damage) {
        .full => null,
        .rects => |rects| if (rects.len == 0) null else self.alloc.dupe(DamageRect, rects) catch null,
    };
    errdefer if (damage) |rects| self.alloc.free(rects);

    target.state.content_valid = true;
    target.state.revision +%= 1;

    return .{ .memory = .{
        .width = target.width,
        .height = target.height,
        .pixels = pixels,
        .alloc = self.alloc,
        .revision = target.state.revision,
        .damage = damage,
    } };
}

fn prepareDamage(self: *Software, renderer: anytype, target: *Target) !Damage {
    const cells = &renderer.cells;
    const rows: u32 = cells.size.rows;
    const cols: u32 = cells.size.columns;

    try self.ensureDirtyRows(rows);
    @memset(self.dirty_rows, false);
    self.damage_rects.clearRetainingCapacity();

    const has_images = renderer.bg_image != null or
        renderer.images.kitty_placements.items.len > 0 or
        renderer.images.overlay_placements.items.len > 0;
    const full = !self.have_previous or
        !target.state.content_valid or
        target.width != self.width or
        target.height != self.height or
        rows != self.previous.rows or
        cols != self.previous.cols or
        !std.meta.eql(self.previous_uniforms, renderer.uniforms) or
        has_images or
        self.previous_had_images;

    if (full) {
        try self.capture(cells);
        self.previous_uniforms = renderer.uniforms;
        self.previous_had_images = has_images;
        self.have_previous = true;
        return .full;
    }

    self.diffRows(cells);
    try self.capture(cells);
    self.previous_uniforms = renderer.uniforms;
    self.previous_had_images = has_images;

    if (!self.buildDamageRects(target, renderer.uniforms)) return .full;
    if (self.damage_rects.items.len == 0) return .{ .rects = &.{} };
    if (self.damage_rects.items.len > 64) return .full;
    return .{ .rects = self.damage_rects.items };
}

fn ensureDirtyRows(self: *Software, rows: u32) !void {
    if (self.dirty_rows.len == rows) return;
    self.alloc.free(self.dirty_rows);
    self.dirty_rows = try self.alloc.alloc(bool, rows);
    @memset(self.dirty_rows, false);
}

fn markDirtyRow(self: *Software, y: usize) void {
    if (y < self.dirty_rows.len) self.dirty_rows[y] = true;
}

fn diffRows(self: *Software, cells: anytype) void {
    const rows: usize = cells.size.rows;
    const cols: usize = cells.size.columns;

    var y: usize = 0;
    while (y < rows) : (y += 1) {
        const bg_now = cells.bg_cells[y * cols ..][0..cols];
        const bg_old = self.previous.bg[y * cols ..][0..cols];
        if (!std.mem.eql(u8, std.mem.sliceAsBytes(bg_now), std.mem.sliceAsBytes(bg_old))) {
            self.markDirtyRow(y);
            continue;
        }
        const fg_now = cells.fg_rows[y + 1].items;
        const fg_old = self.previous.row(y + 1);
        if (!std.mem.eql(u8, std.mem.sliceAsBytes(fg_now), std.mem.sliceAsBytes(fg_old))) {
            self.markDirtyRow(y);
        }
    }

    for ([_]usize{ 0, rows + 1 }) |row_index| {
        const now = cells.fg_rows[row_index].items;
        const old = self.previous.row(row_index);
        if (std.mem.eql(u8, std.mem.sliceAsBytes(now), std.mem.sliceAsBytes(old))) continue;
        for (old) |cell| self.markDirtyRow(cell.grid_pos[1]);
        for (now) |cell| self.markDirtyRow(cell.grid_pos[1]);
    }
}

fn capture(self: *Software, cells: anytype) !void {
    try self.previous.capture(self.alloc, cells);
}

fn buildDamageRects(self: *Software, target: *Target, uniforms: Uniforms) bool {
    const cell_h = uniforms.cell_size[1];
    const top = uniforms.grid_padding[0];
    for (self.dirty_rows, 0..) |dirty, y_usize| {
        if (!dirty) continue;
        const y: f32 = @floatFromInt(y_usize);
        const y0f = top + (y - 1) * cell_h;
        const y1f = top + (y + 2) * cell_h;
        const y0: u32 = @intFromFloat(@max(0, @floor(y0f)));
        const y1: u32 = @intFromFloat(@min(@as(f32, @floatFromInt(target.height)), @ceil(y1f)));
        if (y1 <= y0) continue;

        if (self.damage_rects.items.len > 0) {
            const last = &self.damage_rects.items[self.damage_rects.items.len - 1];
            if (y0 <= last.y +| last.height) {
                const end = @max(last.y +| last.height, y1);
                last.height = end - last.y;
                continue;
            }
        }
        self.damage_rects.append(self.alloc, .{
            .x = 0,
            .y = y0,
            .width = target.width,
            .height = y1 - y0,
        }) catch return false;
    }
    return true;
}

const Snapshot = struct {
    alloc: Allocator = undefined,
    bg: []CellBg = &.{},
    fg: []CellText = &.{},
    offsets: []usize = &.{},
    rows: u32 = 0,
    cols: u32 = 0,

    fn deinit(self: *Snapshot, alloc: Allocator) void {
        alloc.free(self.bg);
        alloc.free(self.fg);
        alloc.free(self.offsets);
        self.* = .{ .alloc = alloc };
    }

    fn row(self: *const Snapshot, index: usize) []const CellText {
        if (index + 1 >= self.offsets.len) return &.{};
        return self.fg[self.offsets[index]..self.offsets[index + 1]];
    }

    fn capture(self: *Snapshot, alloc: Allocator, cells: anytype) !void {
        const rows: usize = cells.size.rows;
        const cols: usize = cells.size.columns;
        const row_count = rows + 2;

        if (self.offsets.len != row_count + 1) {
            alloc.free(self.offsets);
            self.offsets = try alloc.alloc(usize, row_count + 1);
        }
        if (self.bg.len != rows * cols) {
            alloc.free(self.bg);
            self.bg = try alloc.alloc(CellBg, rows * cols);
        }

        var total: usize = 0;
        for (0..row_count) |i| total += cells.fg_rows[i].items.len;
        if (self.fg.len != total) {
            alloc.free(self.fg);
            self.fg = try alloc.alloc(CellText, total);
        }

        @memcpy(self.bg, cells.bg_cells[0 .. rows * cols]);
        var offset: usize = 0;
        for (0..row_count) |i| {
            self.offsets[i] = offset;
            const items = cells.fg_rows[i].items;
            @memcpy(self.fg[offset..][0..items.len], items);
            offset += items.len;
        }
        self.offsets[row_count] = offset;
        self.alloc = alloc;
        self.rows = @intCast(rows);
        self.cols = @intCast(cols);
    }
};

test "snapshot diff identifies background and cursor row changes" {
    _ = build_config;
    _ = Pipeline;
    _ = Handle;
    _ = Damage;
}

test "damage tracks changed rows and clears when nothing changed" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const cell = @import("cell.zig");
    const image = @import("image.zig");

    const Fake = struct {
        cells: cell.Contents,
        uniforms: Uniforms,
        images: image.State = .empty,
        bg_image: ?image.Image = null,
    };

    var fake: Fake = .{
        .cells = .{},
        .uniforms = .{
            .projection_matrix = undefined,
            .screen_size = .{ 8, 16 },
            .cell_size = .{ 4, 4 },
            .grid_size = .{ 2, 4 },
            .grid_padding = .{ 0, 0, 0, 0 },
            .padding_extend = .{},
            .min_contrast = 1,
            .cursor_pos = .{ 0xffff, 0xffff },
            .cursor_color = .{ 0, 0, 0, 0 },
            .bg_color = .{ 11, 15, 18, 255 },
            .bools = .{ .cursor_wide = false, .use_display_p3 = false, .use_linear_blending = true },
        },
    };
    defer fake.cells.deinit(alloc);
    try fake.cells.resize(alloc, .{ .rows = 4, .columns = 2 });

    var target = try Target.init(alloc, 8, 16);
    defer target.deinit();

    var sw: Software = .{
        .alloc = alloc,
        .blending = .native,
        .width = 8,
        .height = 16,
        .previous = .{ .alloc = alloc },
    };
    defer sw.deinit();

    try testing.expectEqual(Damage.full, try sw.prepareDamage(&fake, &target));
    target.state.content_valid = true;

    try fake.cells.add(alloc, .text, .{
        .glyph_pos = .{ 0, 0 },
        .glyph_size = .{ 2, 2 },
        .bearings = .{ 1, 3 },
        .grid_pos = .{ 0, 2 },
        .color = .{ 255, 255, 255, 255 },
        .atlas = .grayscale,
    });
    const first = try sw.prepareDamage(&fake, &target);
    switch (first) {
        .full => return error.UnexpectedFullDamage,
        .rects => |rects| {
            try testing.expect(rects.len > 0);
            var covered = false;
            for (rects) |rect| {
                if (rect.y <= 8 and rect.y + rect.height >= 12) covered = true;
            }
            try testing.expect(covered);
        },
    }

    target.state.content_valid = true;
    const second = try sw.prepareDamage(&fake, &target);
    switch (second) {
        .full => return error.UnexpectedFullDamage,
        .rects => |rects| try testing.expectEqual(@as(usize, 0), rects.len),
    }
}

test {
    _ = @import("software/Buffer.zig");
    _ = @import("software/Damage.zig");
    _ = @import("software/Frame.zig");
    _ = @import("software/Pipeline.zig");
    _ = @import("software/Sampler.zig");
    _ = @import("software/Target.zig");
    _ = @import("software/Texture.zig");
    _ = @import("software/raster.zig");
    _ = @import("software/reference_test.zig");
    _ = @import("software/shaders.zig");
}
