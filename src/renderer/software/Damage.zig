//! Pixel damage in top-left physical buffer coordinates.

const std = @import("std");

pub const Rect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,

    pub fn right(self: Rect) u32 {
        return self.x +| self.width;
    }

    pub fn bottom(self: Rect) u32 {
        return self.y +| self.height;
    }

    pub fn intersects(self: Rect, x: u32, y: u32, width: u32, height: u32) bool {
        return x < self.right() and self.x < x +| width and
            y < self.bottom() and self.y < y +| height;
    }

    pub fn clipped(self: Rect, width: u32, height: u32) ?Rect {
        const x0 = @min(self.x, width);
        const y0 = @min(self.y, height);
        const x1 = @min(self.right(), width);
        const y1 = @min(self.bottom(), height);
        if (x1 <= x0 or y1 <= y0) return null;
        return .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 };
    }
};

pub const Damage = union(enum) {
    full,
    rects: []const Rect,

    pub fn intersects(self: Damage, x: u32, y: u32, width: u32, height: u32) bool {
        return switch (self) {
            .full => width > 0 and height > 0,
            .rects => |rects| for (rects) |rect| {
                if (rect.intersects(x, y, width, height)) break true;
            } else false,
        };
    }

    pub fn isEmpty(self: Damage) bool {
        return switch (self) {
            .full => false,
            .rects => |rects| rects.len == 0,
        };
    }
};

test "damage rect intersection is half-open and clipped" {
    const rect: Rect = .{ .x = 10, .y = 20, .width = 5, .height = 4 };
    try std.testing.expect(rect.intersects(9, 20, 2, 1));
    try std.testing.expect(!rect.intersects(15, 20, 1, 1));
    try std.testing.expectEqual(
        Rect{ .x = 10, .y = 20, .width = 5, .height = 4 },
        rect.clipped(100, 100).?,
    );
    try std.testing.expectEqual(null, rect.clipped(0, 0));
}
