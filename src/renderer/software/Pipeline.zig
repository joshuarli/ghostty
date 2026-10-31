//! A software pipeline is a concrete raster operation, not a shader program.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum {
    bg_color,
    cell_bg,
    cell_text,
    image,
    bg_image,
};

pub const StepFunction = enum {
    constant,
    per_vertex,
    per_instance,
};

pub const Options = struct {
    kind: Kind,
    step_fn: StepFunction = .per_vertex,
    blending_enabled: bool = true,
};

pub const Pipeline = struct {
    kind: Kind,
    blending_enabled: bool,

    pub fn init(alloc: Allocator, opts: Options) !Pipeline {
        _ = alloc;
        return .{
            .kind = opts.kind,
            .blending_enabled = opts.blending_enabled,
        };
    }

    pub fn deinit(self: *const Pipeline) void {
        _ = self;
    }
};

test "pipeline retains its raster operation" {
    const pipeline = try Pipeline.init(std.testing.allocator, .{ .kind = .cell_text });
    try std.testing.expectEqual(Kind.cell_text, pipeline.kind);
    try std.testing.expect(pipeline.blending_enabled);
}
