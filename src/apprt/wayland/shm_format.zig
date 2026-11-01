const std = @import("std");

pub const Advertised = struct {
    abgr8888: bool = false,
    argb8888: bool = false,
};

/// Both are 4 bytes per pixel with premultiplied alpha. ABGR8888 matches the
/// RGBA byte order of the renderers' output; ARGB8888 is the format every
/// compositor must advertise and stores B, G, R, A in little-endian memory.
pub const Format = enum {
    abgr8888,
    argb8888,

    pub fn select(advertised: Advertised) ?Format {
        if (advertised.abgr8888) return .abgr8888;
        if (advertised.argb8888) return .argb8888;
        return null;
    }

    pub fn convertRow(self: Format, dst: []u8, src: []const u8) void {
        std.debug.assert(dst.len == src.len and dst.len % 4 == 0);
        switch (self) {
            .abgr8888 => @memcpy(dst, src),
            .argb8888 => {
                var i: usize = 0;
                while (i < src.len) : (i += 4) {
                    dst[i] = src[i + 2];
                    dst[i + 1] = src[i + 1];
                    dst[i + 2] = src[i];
                    dst[i + 3] = src[i + 3];
                }
            },
        }
    }
};

test "abgr8888 is preferred when advertised" {
    try std.testing.expectEqual(Format.abgr8888, Format.select(.{ .abgr8888 = true, .argb8888 = true }).?);
    try std.testing.expectEqual(Format.abgr8888, Format.select(.{ .abgr8888 = true }).?);
}

test "argb8888 is used when abgr8888 is not advertised" {
    try std.testing.expectEqual(Format.argb8888, Format.select(.{ .argb8888 = true }).?);
}

test "no usable format is reported instead of guessed" {
    try std.testing.expect(Format.select(.{}) == null);
}

test "abgr8888 rows are copied unchanged" {
    const src = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var dst: [8]u8 = undefined;
    Format.abgr8888.convertRow(&dst, &src);
    try std.testing.expectEqualSlices(u8, &src, &dst);
}

test "argb8888 rows swap red and blue and keep green and alpha" {
    const src = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var dst: [8]u8 = undefined;
    Format.argb8888.convertRow(&dst, &src);
    try std.testing.expectEqualSlices(u8, &.{ 3, 2, 1, 4, 7, 6, 5, 8 }, &dst);
}
