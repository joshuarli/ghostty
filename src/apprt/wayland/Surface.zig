const std = @import("std");
const apprt = @import("../../apprt.zig");
const CoreSurface = @import("../../Surface.zig");
const ApprtApp = @import("App.zig");
const renderer = @import("../../renderer.zig");
const global = @import("../../global.zig");
const input = @import("../../input.zig");
const Window = @import("window.zig").Window;

const log = std.log.scoped(.wayland);

pub const Surface = @This();

app: *ApprtApp,
core_surface: CoreSurface,
window: ?*Window,
title: ?[:0]const u8,
size: apprt.SurfaceSize,
content_scale: apprt.ContentScale,
cursor_pos: apprt.CursorPos,
pending_frame: ?renderer.Renderer.ExportedFrame,

pub fn init(self: *Surface, app: *ApprtApp) !void {
    self.* = .{
        .app = app,
        .core_surface = undefined,
        .window = null,
        .title = null,
        .size = .{ .width = 800, .height = 600 },
        .content_scale = .{ .x = 1, .y = 1 },
        .cursor_pos = .{ .x = -1, .y = -1 },
        .pending_frame = null,
    };
    try app.core_app.addSurface(self);
    errdefer app.core_app.deleteSurface(self);

    if (app.conn) |conn| {
        const win = try Window.create(
            app.core_app.alloc,
            conn,
            "com.mitchellh.ghostty",
            "Ghostty",
        );
        self.window = win;
        self.size = .{ .width = win.pixelWidth(), .height = win.pixelHeight() };
    }
    errdefer if (self.window) |win| {
        win.destroy();
        self.window = null;
    };

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
    self.core_surface.reportPresentationHealth(.unhealthy);
    if (self.window) |win| {
        self.updateSize(win.pixelWidth(), win.pixelHeight());
    }
}

pub fn deinit(self: *Surface) void {
    if (self.app.conn) |conn| {
        if (conn.clipboardState()) |clipboard| clipboard.cancel(self);
    }
    if (self.pending_frame) |frame| frame.deinit();
    self.pending_frame = null;
    if (self.title) |v| self.app.core_app.alloc.free(v);
    self.title = null;
    if (self.window) |win| {
        win.destroy();
        self.window = null;
    }
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
    if (clipboard_type != .standard) return false;
    const conn = self.app.conn orelse return false;
    return conn.clipboardState() != null;
}

pub fn clipboardRequest(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    state: apprt.ClipboardRequest,
) !apprt.ClipboardReadResult {
    if (clipboard_type != .standard) return .unsupported;

    const conn = self.app.conn orelse return .unsupported;
    const clipboard = conn.clipboardState() orelse return .unsupported;

    switch (state) {
        .paste, .osc_52_read => {
            return clipboard.read(state, self, clipboardReadComplete);
        },
        .list => {
            const mimes = clipboard.list() orelse return .unavailable;
            const alloc = self.app.core_app.alloc;
            const available = try alloc.alloc([]const u8, mimes.len);
            defer alloc.free(available);
            for (mimes, available) |mime, *out| out.* = mime;

            self.core_surface.completeClipboardRequest(state, .{
                .available = available,
                .confirmed = true,
            }) catch |err| {
                log.warn("complete paste event failed err={}", .{err});
                return .unavailable;
            };
            return .started;
        },
        .kitty_read, .kitty_write, .osc_52_write => return .unsupported,
    }
}

pub fn setClipboard(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    contents: []const apprt.ClipboardContent,
    confirm: bool,
) !void {
    if (clipboard_type != .standard) return;
    _ = confirm;

    const conn = self.app.conn orelse return error.NoWaylandConnection;
    const clipboard = conn.clipboardState() orelse return error.ClipboardUnavailable;
    try clipboard.set(contents, conn.serial());
}

fn clipboardReadComplete(
    ud: ?*anyopaque,
    req: apprt.ClipboardRequest,
    data: [:0]const u8,
) void {
    const self: *Surface = @ptrCast(@alignCast(ud orelse return));
    self.core_surface.completeClipboardRequest(req, .{
        .contents = &.{.{ .mime = "text/plain", .data = data }},
        .confirmed = true,
    }) catch |err| {
        log.warn("complete clipboard read failed err={}", .{err});
    };
}

pub fn handleKey(self: *Surface, event: input.KeyEvent) bool {
    const effect = self.core_surface.keyCallback(event) catch |err| {
        log.warn("key callback failed err={}", .{err});
        return false;
    };
    return switch (effect) {
        .closed => true,
        .ignored => false,
        .consumed => true,
    };
}

pub fn handleMouseButton(
    self: *Surface,
    action: input.MouseButtonState,
    button: input.MouseButton,
    mods: input.Mods,
) bool {
    return self.core_surface.mouseButtonCallback(action, button, mods) catch |err| {
        log.warn("mouse button failed err={}", .{err});
        return false;
    };
}

pub fn handleScroll(self: *Surface, xoff: f64, yoff: f64, mods: input.ScrollMods) void {
    self.core_surface.scrollCallback(xoff, yoff, mods) catch |err| {
        log.warn("scroll failed err={}", .{err});
    };
}

pub fn handleCursor(self: *Surface, x: f64, y: f64, mods: input.Mods) void {
    const scale = self.content_scale;
    const pos: apprt.CursorPos = .{
        .x = @floatCast(x * scale.x),
        .y = @floatCast(y * scale.y),
    };
    self.cursor_pos = pos;
    self.core_surface.cursorPosCallback(pos, mods) catch |err| {
        log.warn("cursor failed err={}", .{err});
    };
}

pub fn handleFocus(self: *Surface, focused: bool) void {
    self.core_surface.focusCallback(focused) catch |err| {
        log.warn("focus failed err={}", .{err});
    };
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

pub fn present(self: *Surface) void {
    const win = self.window orelse return;
    if (win.closed) {
        self.app.running = false;
        return;
    }
    if (win.pixelWidth() != self.size.width or win.pixelHeight() != self.size.height) {
        self.updateSize(win.pixelWidth(), win.pixelHeight());
    }
    if (win.viewport) |vp| {
        vp.setDestination(@intCast(win.width), @intCast(win.height));
    }
    const s: f64 = win.scale();
    if (@abs(s - self.content_scale.x) > 0.001) {
        self.content_scale = .{ .x = @floatCast(s), .y = @floatCast(s) };
        self.core_surface.contentScaleCallback(self.content_scale) catch |err| {
            log.warn("content scale failed err={}", .{err});
        };
    }

    if (self.pending_frame) |frame| {
        self.presentFrame(frame) catch |err| switch (err) {
            error.FramePending, error.BufferBusy => return,
            else => {
                log.warn("shm present failed err={}", .{err});
                frame.deinit();
                self.pending_frame = null;
                return;
            },
        };
        frame.deinit();
        self.pending_frame = null;
    }

    const frame = self.core_surface.renderer.takeFrame() orelse return;
    self.presentFrame(frame) catch |err| switch (err) {
        error.FramePending, error.BufferBusy => {
            self.pending_frame = frame;
            return;
        },
        else => {
            log.warn("shm present failed err={}", .{err});
            frame.deinit();
            return;
        },
    };
    frame.deinit();
}

fn presentFrame(self: *Surface, frame: renderer.Renderer.ExportedFrame) !void {
    const win = self.window orelse return error.NoWindow;
    switch (frame) {
        .memory => |mem| {
            if (comptime @hasField(@TypeOf(mem), "damage")) {
                try win.presentMemory(
                    mem.pixels,
                    mem.width,
                    mem.height,
                    mem.damage,
                    mem.revision,
                );
            } else {
                try win.presentMemory(mem.pixels, mem.width, mem.height, .bottom_up, null, 0);
            }
        },
        .dmabuf => {
            self.core_surface.reportPresentationHealth(.unhealthy);
            return error.UnsupportedFrame;
        },
    }
}
