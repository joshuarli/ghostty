const std = @import("std");
const apprt = @import("../../apprt.zig");
const CoreSurface = @import("../../Surface.zig");
const ApprtApp = @import("App.zig");
const renderer = @import("../../renderer.zig");
const global = @import("../../global.zig");

const log = std.log.scoped(.wayland);

pub const Surface = @This();

app: *ApprtApp,
core_surface: CoreSurface,
title: ?[:0]const u8,
size: apprt.SurfaceSize,
content_scale: apprt.ContentScale,
cursor_pos: apprt.CursorPos,

pub fn init(self: *Surface, app: *ApprtApp) !void {
    self.* = .{
        .app = app,
        .core_surface = undefined,
        .title = null,
        .size = .{ .width = 800, .height = 600 },
        .content_scale = .{ .x = 1, .y = 1 },
        .cursor_pos = .{ .x = -1, .y = -1 },
    };
    try app.core_app.addSurface(self);
    errdefer app.core_app.deleteSurface(self);

    var config = try apprt.surface.newConfig(
        app.core_app,
        &app.config,
        .window,
    );
    defer config.deinit();

    try self.core_surface.init(
        app.core_app.alloc,
        &config,
        app.core_app,
        app,
        self,
    );
}

pub fn deinit(self: *Surface) void {
    if (self.title) |v| self.app.core_app.alloc.free(v);
    self.title = null;
    self.app.core_app.deleteSurface(self);
    self.core_surface.deinit();
}

pub fn core(self: *Surface) *CoreSurface {
    return &self.core_surface;
}

pub fn rtApp(self: *Surface) *ApprtApp {
    return self.app;
}

pub fn close(self: *Surface, process_active: bool) void {
    _ = process_active;
    self.app.closeSurface(self);
}

pub fn cgroup(self: *Surface) ?[]const u8 {
    _ = self;
    return null;
}

pub fn getTitle(self: *Surface) ?[:0]const u8 {
    return self.title;
}

pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
    return self.content_scale;
}

pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
    return self.size;
}

pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
    return self.cursor_pos;
}

pub fn supportsClipboard(
    self: *const Surface,
    clipboard_type: apprt.Clipboard,
) bool {
    _ = self;
    return switch (clipboard_type) {
        .standard => true,
        .selection, .primary => false,
    };
}

pub fn clipboardRequest(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    state: apprt.ClipboardRequest,
) !apprt.ClipboardReadResult {
    _ = self;
    _ = clipboard_type;
    _ = state;
    return .unsupported;
}

pub fn setClipboard(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    contents: []const apprt.ClipboardContent,
    confirm: bool,
) !void {
    _ = self;
    _ = clipboard_type;
    _ = contents;
    _ = confirm;
}

pub fn defaultTermioEnv(self: *Surface) !std.process.Environ.Map {
    _ = self;
    return try global.environMap();
}

pub fn redrawInspector(self: *Surface) void {
    _ = self;
}

pub fn renderDeviceOptions(self: *Surface) !renderer.Device.Options {
    _ = self;
    return .{};
}

pub fn setTitle(self: *Surface, title: [:0]const u8) void {
    const alloc = self.app.core_app.alloc;
    if (self.title) |v| alloc.free(v);
    self.title = alloc.dupeSentinel(u8, title, 0) catch null;
}

pub fn updateSize(self: *Surface, width: u32, height: u32) void {
    if (self.size.width == width and self.size.height == height) return;
    self.size = .{ .width = width, .height = height };
    self.core_surface.sizeCallback(self.size) catch |err| {
        log.err("size callback failed err={}", .{err});
    };
}
