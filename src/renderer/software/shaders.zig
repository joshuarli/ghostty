//! Pipeline collection for the software rasterizer. The vertex and uniform
//! layouts are shared with the GPU backends so draw lists stay identical.

const std = @import("std");
const Allocator = std.mem.Allocator;
const pipeline_mod = @import("Pipeline.zig");
const Pipeline = pipeline_mod.Pipeline;
const types = @import("../shaders/types.zig");

pub const Uniforms = types.Uniforms;
pub const CellText = types.CellText;
pub const CellBg = types.CellBg;
pub const Image = types.Image;
pub const BgImage = types.BgImage;

const pipeline_descs = [_]struct { []const u8, pipeline_mod.Kind }{
    .{ "bg_color", .bg_color },
    .{ "cell_bg", .cell_bg },
    .{ "cell_text", .cell_text },
    .{ "image", .image },
    .{ "bg_image", .bg_image },
};

const PipelineCollection = blk: {
    const names = names: {
        var result: [pipeline_descs.len][]const u8 = undefined;
        for (pipeline_descs, 0..) |desc, i| result[i] = desc[0];
        break :names result;
    };
    var types_arr: [pipeline_descs.len]type = @splat(Pipeline);
    var attrs: [pipeline_descs.len]std.lang.Type.Struct.FieldAttributes = @splat(.{
        .@"align" = @alignOf(Pipeline),
    });
    break :blk @Struct(.auto, null, &names, &types_arr, &attrs);
};

pub const Shaders = struct {
    pipelines: PipelineCollection,
    post_pipelines: []const Pipeline = &.{},
    defunct: bool = false,

    pub const uninit: Shaders = .{
        .pipelines = undefined,
        .post_pipelines = &.{},
        .defunct = true,
    };

    pub fn init(alloc: Allocator, post_shaders: []const [:0]const u8) !Shaders {
        if (post_shaders.len > 0) return error.CustomShaderUnsupported;

        var pipelines: PipelineCollection = undefined;
        inline for (pipeline_descs) |desc| {
            @field(pipelines, desc[0]) = try Pipeline.init(alloc, .{
                .kind = desc[1],
                .step_fn = switch (desc[1]) {
                    .cell_text, .image, .bg_image => .per_instance,
                    else => .per_vertex,
                },
                .blending_enabled = desc[1] != .bg_color,
            });
        }
        return .{ .pipelines = pipelines };
    }

    pub fn deinit(self: *Shaders, alloc: Allocator) void {
        _ = alloc;
        if (self.defunct) return;
        self.defunct = true;
        inline for (pipeline_descs) |desc| {
            @field(self.pipelines, desc[0]).deinit();
        }
    }
};

test "software shaders expose every draw-list pipeline" {
    var shaders = try Shaders.init(std.testing.allocator, &.{});
    defer shaders.deinit(std.testing.allocator);
    try std.testing.expectEqual(pipeline_mod.Kind.bg_color, shaders.pipelines.bg_color.kind);
    try std.testing.expectEqual(pipeline_mod.Kind.cell_text, shaders.pipelines.cell_text.kind);
    try std.testing.expectError(
        error.CustomShaderUnsupported,
        Shaders.init(std.testing.allocator, &.{"shader"}),
    );
}
