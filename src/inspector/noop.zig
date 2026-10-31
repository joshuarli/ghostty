//! Inspector surface for builds that exclude the ImGui desktop tool.

const std = @import("std");
const Allocator = std.mem.Allocator;
const input = @import("../input.zig");
const terminal = @import("../terminal/main.zig");
const Overlay = @import("../renderer/Overlay.zig");

pub const KeyEvent = struct {
    event: input.KeyEvent,
    binding: []const input.Binding.Action = &.{},
    pty: []const u8 = "",

    pub fn deinit(self: *const KeyEvent, alloc: Allocator) void {
        alloc.free(self.binding);
        if (self.event.utf8.len > 0) alloc.free(self.event.utf8);
        if (self.pty.len > 0) alloc.free(self.pty);
    }
};

pub const Mouse = struct {
    last_xpos: f64 = 0,
    last_ypos: f64 = 0,
    last_point: ?terminal.Pin = null,
};

pub const Info = struct {
    pub fn overlayFeatures(
        self: *Info,
        alloc: Allocator,
    ) ![]const Overlay.Feature {
        _ = self;
        _ = alloc;
        return &.{};
    }
};

pub const Inspector = struct {
    mouse: Mouse = .{},
    info: Info = .{},

    pub fn init(alloc: Allocator) !Inspector {
        _ = alloc;
        return .{};
    }

    pub fn deinit(self: *Inspector, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }

    pub fn rendererInfo(self: *Inspector) *Info {
        return &self.info;
    }

    pub fn recordKeyEvent(
        self: *Inspector,
        alloc: Allocator,
        ev: KeyEvent,
    ) Allocator.Error!void {
        _ = self;
        var copy = ev;
        copy.deinit(alloc);
    }

    pub fn recordPtyRead(
        self: *Inspector,
        alloc: Allocator,
        term: *terminal.Terminal,
        data: []const u8,
    ) !void {
        _ = self;
        _ = alloc;
        _ = term;
        _ = data;
    }
};
