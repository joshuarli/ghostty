//! CPU-side replacement for a GPU buffer. A handle is a typed view over
//! storage owned by the Buffer wrapper, so render passes can consume the
//! same vertex and uniform shapes as the GPU backends.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Handle = struct {
    ptr: *anyopaque,
    len: usize,

    pub fn items(self: Handle, comptime T: type) []const T {
        if (self.len == 0) return &.{};
        return @as([*]const T, @ptrCast(@alignCast(self.ptr)))[0..self.len];
    }
};

pub const Options = struct {
    alloc: Allocator,
};

pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();

        buffer: Handle,
        storage: []T,
        alloc: Allocator,

        pub fn init(opts: Options, len: usize) !Self {
            const alloc = opts.alloc;
            const storage = try alloc.alloc(T, len);
            @memset(storage, undefined);
            return .{
                .buffer = .{
                    .ptr = storage.ptr,
                    .len = len,
                },
                .storage = storage,
                .alloc = alloc,
            };
        }

        pub fn initFill(opts: Options, data: []const T) !Self {
            const alloc = opts.alloc;
            const storage = try alloc.dupe(T, data);
            return .{
                .buffer = .{
                    .ptr = storage.ptr,
                    .len = storage.len,
                },
                .storage = storage,
                .alloc = alloc,
            };
        }

        pub fn deinit(self: *Self) void {
            self.alloc.free(self.storage);
            self.* = undefined;
        }

        pub fn sync(self: *Self, data: []const T) !void {
            if (data.len > self.storage.len) {
                const new_len = @max(data.len, self.storage.len * 2);
                const storage = try self.alloc.realloc(self.storage, new_len);
                self.storage = storage;
            }
            @memcpy(self.storage[0..data.len], data);
            self.buffer = .{
                .ptr = self.storage.ptr,
                .len = data.len,
            };
        }

        pub fn syncFromArrayLists(
            self: *Self,
            lists: []const std.ArrayListUnmanaged(T),
        ) !usize {
            var total: usize = 0;
            for (lists) |list| total += list.items.len;
            if (total > self.storage.len) {
                const new_len = @max(total, self.storage.len * 2);
                self.storage = try self.alloc.realloc(self.storage, new_len);
            }
            var i: usize = 0;
            for (lists) |list| {
                @memcpy(self.storage[i..][0..list.items.len], list.items);
                i += list.items.len;
            }
            self.buffer = .{
                .ptr = self.storage.ptr,
                .len = total,
            };
            return total;
        }
    };
}

test "buffer sync grows and exposes the written length" {
    const alloc = std.testing.allocator;
    var buf = try Buffer(u32).init(.{ .alloc = alloc }, 1);
    defer buf.deinit();

    try buf.sync(&.{ 1, 2, 3 });
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, buf.buffer.items(u32));

    try buf.sync(&.{9});
    try std.testing.expectEqualSlices(u32, &.{9}, buf.buffer.items(u32));
}
