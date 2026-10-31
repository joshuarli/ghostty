//! Software frame and render pass. Draw-list steps are rasterized immediately.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Pipeline = @import("Pipeline.zig").Pipeline;
const Target = @import("Target.zig").Target;
const Texture = @import("Texture.zig").Texture;
const Sampler = @import("Sampler.zig").Sampler;
const Handle = @import("Buffer.zig").Handle;
const Damage = @import("Damage.zig").Damage;
const raster = @import("raster.zig");

pub const Options = struct {};

pub const Attachment = struct {
    target: union(enum) {
        texture: Texture,
        target: Target,
    },
    clear_color: ?[4]f32 = null,
};

pub const Step = struct {
    pipeline: Pipeline,
    uniforms: ?Handle = null,
    buffers: []const ?Handle = &.{},
    textures: []const ?Texture = &.{},
    samplers: []const ?Sampler = &.{},
    draw: Draw,

    pub const Draw = struct {
        type: Primitive,
        vertex_count: usize,
        instance_count: usize = 1,
    };

    pub const Primitive = enum { triangle, triangle_strip };
};

pub const Finalize = struct {
    api: *anyopaque,
    renderer: *anyopaque,
    complete_fn: *const fn (
        api: *anyopaque,
        renderer: *anyopaque,
        target: *Target,
        sync: bool,
    ) void,
};

pub const Frame = struct {
    target: *Target,
    damage: Damage,
    alloc: Allocator,
    render_passes: usize = 0,
    finalize: ?Finalize = null,

    pub fn init(alloc: Allocator, target: *Target, damage: Damage) Frame {
        return .{
            .target = target,
            .damage = damage,
            .alloc = alloc,
        };
    }

    pub fn setFinalize(self: *Frame, finalize: Finalize) void {
        self.finalize = finalize;
    }

    pub fn deinit(self: *Frame) void {
        _ = self;
    }

    pub fn complete(self: *Frame, sync: bool) void {
        const finalize = self.finalize orelse return;
        finalize.complete_fn(finalize.api, finalize.renderer, self.target, sync);
    }

    pub fn renderPass(self: *Frame, attachments: []const Attachment) RenderPass {
        self.render_passes += 1;
        return .{
            .frame = self,
            .attachments = attachments,
        };
    }
};

pub const RenderPass = struct {
    frame: *Frame,
    attachments: []const Attachment,
    step_number: usize = 0,
    uniforms: ?Handle = null,

    pub fn step(self: *RenderPass, s: Step) void {
        if (s.draw.instance_count == 0 or s.draw.vertex_count == 0) return;
        defer self.step_number += 1;
        if (s.uniforms) |uniforms| self.uniforms = uniforms;
        if (self.attachments.len == 0) return;
        var target = switch (self.attachments[0].target) {
            .target => |t| t,
            .texture => return,
        };
        if (target.width == 0 or target.height == 0) return;

        if (self.step_number == 0) {
            if (self.attachments[0].clear_color) |color| {
                raster.clear(&target, self.frame.damage, color);
            }
        }

        switch (s.pipeline.kind) {
            .bg_color => {
                const uniforms = uniformsFrom(s.uniforms) orelse return;
                raster.drawBgColor(&target, self.frame.damage, uniforms);
            },
            .cell_bg => {
                const uniforms = uniformsFrom(s.uniforms) orelse return;
                const bg = bufferAt(s.buffers, 1) orelse return;
                raster.drawCellBg(&target, self.frame.damage, uniforms, bg);
            },
            .cell_text => {
                const uniforms = uniformsFrom(s.uniforms) orelse return;
                const cells = bufferAt(s.buffers, 0) orelse return;
                const bg = bufferAt(s.buffers, 1) orelse return;
                const grayscale = textureAt(s.textures, 0) orelse return;
                const color = textureAt(s.textures, 1) orelse return;
                raster.drawCellText(
                    &target,
                    self.frame.damage,
                    uniforms,
                    cells,
                    bg,
                    grayscale,
                    color,
                );
            },
            .image => {
                const uniforms = uniformsFrom(self.uniforms) orelse return;
                const instances = bufferAt(s.buffers, 0) orelse return;
                const texture = textureAt(s.textures, 0) orelse return;
                raster.drawImages(
                    &target,
                    self.frame.damage,
                    uniforms,
                    instances.items(@import("../shaders/types.zig").Image),
                    texture,
                );
            },
            .bg_image => {
                const uniforms = uniformsFrom(s.uniforms) orelse return;
                const instances = bufferAt(s.buffers, 0) orelse return;
                const info = instances.items(@import("../shaders/types.zig").BgImage);
                if (info.len == 0) return;
                const texture = textureAt(s.textures, 0) orelse return;
                raster.drawBgImage(&target, self.frame.damage, uniforms, info[0], texture);
            },
        }
    }

    pub fn complete(self: *RenderPass) void {
        _ = self;
    }

    fn uniformsFrom(handle: ?Handle) ?*const @import("../shaders/types.zig").Uniforms {
        const h = handle orelse return null;
        const items = h.items(@import("../shaders/types.zig").Uniforms);
        if (items.len == 0) return null;
        return &items[0];
    }

    fn bufferAt(buffers: []const ?Handle, index: usize) ?Handle {
        if (index >= buffers.len) return null;
        return buffers[index];
    }

    fn textureAt(textures: []const ?Texture, index: usize) ?*const Texture {
        if (index >= textures.len) return null;
        if (textures[index] == null) return null;
        return &textures[index].?;
    }
};

test "empty render pass completes without touching pixels" {
    var target = try Target.init(std.testing.allocator, 1, 1);
    defer target.deinit();
    var frame = Frame.init(std.testing.allocator, &target, .full);
    var pass = frame.renderPass(&.{.{ .target = &target }});
    pass.complete();
    try std.testing.expectEqual(@as(u32, 0), target.pixels[0]);
}
