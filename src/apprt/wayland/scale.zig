const std = @import("std");

pub const numerator_unit = 120;

/// Fractional scaling needs a viewport to map the scaled buffer onto the
/// logical surface; without one the integer path is the only correct choice.
pub const Mode = enum {
    fractional,
    integer,

    pub fn select(has_fractional_manager: bool, has_viewporter: bool) Mode {
        return if (has_fractional_manager and has_viewporter) .fractional else .integer;
    }
};

/// The compositor's preferred buffer scale wins over the entered outputs'
/// scales; with neither, the surface is unscaled.
pub fn integerScale(preferred: ?i32, entered_output_scales: []const i32) u32 {
    if (preferred) |p| return @intCast(@max(1, p));
    var best: i32 = 1;
    for (entered_output_scales) |s| best = @max(best, s);
    return @intCast(best);
}

pub fn numerator(mode: Mode, fractional: ?u32, integer: u32) u32 {
    return switch (mode) {
        .fractional => fractional orelse numerator_unit,
        .integer => integer * numerator_unit,
    };
}

pub fn bufferExtent(logical: u32, scale_num: u32) u32 {
    const scaled = @as(f64, @floatFromInt(logical)) * @as(f64, @floatFromInt(scale_num)) / numerator_unit;
    return @max(1, @as(u32, @intFromFloat(@round(scaled))));
}

pub fn isMultipleOf(extent: u32, integer: u32) bool {
    return extent % integer == 0;
}

test "fractional scaling requires both the manager and a viewporter" {
    try std.testing.expectEqual(Mode.fractional, Mode.select(true, true));
    try std.testing.expectEqual(Mode.integer, Mode.select(true, false));
    try std.testing.expectEqual(Mode.integer, Mode.select(false, true));
    try std.testing.expectEqual(Mode.integer, Mode.select(false, false));
}

test "integer scale prefers the compositor hint, then the largest entered output" {
    try std.testing.expectEqual(@as(u32, 3), integerScale(3, &.{ 1, 2 }));
    try std.testing.expectEqual(@as(u32, 2), integerScale(null, &.{ 1, 2 }));
    try std.testing.expectEqual(@as(u32, 1), integerScale(null, &.{}));
    try std.testing.expectEqual(@as(u32, 1), integerScale(0, &.{2}));
}

test "buffer size follows the numerator on both paths" {
    const frac = numerator(.fractional, 150, 2);
    try std.testing.expectEqual(@as(u32, 150), frac);
    try std.testing.expectEqual(@as(u32, 125), bufferExtent(100, frac));
    try std.testing.expectEqual(@as(u32, 50), bufferExtent(40, frac));
    try std.testing.expectEqual(@as(u32, 120), numerator(.fractional, null, 2));

    const int = numerator(.integer, 150, 2);
    try std.testing.expectEqual(@as(u32, 240), int);
    try std.testing.expectEqual(@as(u32, 200), bufferExtent(100, int));
}

test "integer scaled buffers are multiples of the scale" {
    const n = numerator(.integer, null, 3);
    for ([_]u32{ 1, 7, 801, 1079 }) |logical| {
        try std.testing.expect(isMultipleOf(bufferExtent(logical, n), 3));
    }
    try std.testing.expect(!isMultipleOf(801, 2));
}
