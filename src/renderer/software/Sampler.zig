//! Samplers are inert in the software backend; filtering lives on Texture.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Texture = @import("Texture.zig");

pub const Options = struct {
    min_filter: Texture.Filter = .nearest,
    mag_filter: Texture.Filter = .nearest,
    wrap_s: Texture.Wrap = .clamp_to_edge,
    wrap_t: Texture.Wrap = .clamp_to_edge,
};

pub const Sampler = struct {
    options: Options,

    pub fn init(opts: Options) !Sampler {
        return .{ .options = opts };
    }

    pub fn deinit(self: *const Sampler) void {
        _ = self;
    }
};

test "sampler construction is allocation free" {
    const sampler = try Sampler.init(.{});
    try std.testing.expectEqual(Texture.Filter.nearest, sampler.options.min_filter);
}
