const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const CoreApp = @import("../../App.zig");
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const input = @import("../../input.zig");
const Surface = @import("Surface.zig");
const Connection = @import("connection.zig").Connection;
const text_input = @import("text_input.zig");

const log = std.log.scoped(.wayland);

pub const App = @This();

core_app: *CoreApp,
config: Config,
conn: ?*Connection,
running: bool,
surface: ?*Surface,

pub fn init(self: *App, core_app: *CoreApp, opts: struct {}) !void {
    _ = opts;
    var config = try Config.load(core_app.alloc);
    errdefer config.deinit();
    self.* = .{
        .core_app = core_app,
        .config = config,
        .conn = null,
        .running = false,
        .surface = null,
    };
}

pub fn terminate(self: *App) void {
    self.teardown();
    self.config.deinit();
}

fn teardown(self: *App) void {
    if (self.surface) |s| {
        self.surface = null;
        s.deinit();
        self.core_app.alloc.destroy(s);
    }
    if (self.conn) |c| {
        self.conn = null;
        c.disconnect();
        self.core_app.alloc.destroy(c);
    }
}

pub fn wakeup(self: *App) void {
    if (self.conn) |c| c.wake();
}

pub fn keyboardLayout(self: *const App) input.KeyboardLayout {
    _ = self;
    return .unknown;
}

pub fn wait(self: *const App) !void {
    _ = self;
}

pub fn run(self: *App) !void {
    defer self.teardown();
    try self.connect();
    self.running = true;
    try self.newWindow();
    const conn = self.conn.?;
    while (self.running) {
        try conn.wait(-1);
        try self.core_app.tick(self);
        conn.refreshInputMethod();
        if (self.surface) |s| {
            s.present();
            if (s.window) |w| {
                if (w.closed) {
                    self.running = false;
                    break;
                }
            }
        } else break;
        conn.flush();
    }
}

fn connect(self: *App) !void {
    const alloc = self.core_app.alloc;
    const conn = try alloc.create(Connection);
    errdefer alloc.destroy(conn);
    try conn.connect(alloc, .{
        .key_fn = onKey,
        .key_ud = self,
        .mouse_button_fn = onMouseButton,
        .mouse_button_ud = self,
        .scroll_fn = onScroll,
        .scroll_ud = self,
        .cursor_fn = onCursor,
        .cursor_ud = self,
        .focus_fn = onFocus,
        .focus_ud = self,
    }, .{
        .preedit_fn = onPreedit,
        .commit_fn = onCommit,
        .cursor_rect_fn = onImeCursorRect,
        .ud = self,
    });
    self.conn = conn;
}

fn newWindow(self: *App) !void {
    const alloc = self.core_app.alloc;
    const rt_surface = try alloc.create(Surface);
    errdefer alloc.destroy(rt_surface);
    try rt_surface.init(self);
    self.surface = rt_surface;
}

pub fn closeSurface(self: *App, surface: *Surface) void {
    if (self.surface == surface) self.surface = null;
    surface.deinit();
    self.core_app.alloc.destroy(surface);
    self.running = false;
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    _ = target;
    switch (action) {
        .quit, .close_all_windows => {
            self.running = false;
            return true;
        },
        .new_window => {
            if (self.surface == null) try self.newWindow();
            return true;
        },
        .close_window => {
            if (self.surface) |s| {
                self.closeSurface(s);
                return true;
            }
            return false;
        },
        .render => {
            if (self.conn) |c| c.wake();
            return true;
        },
        else => {
            log.debug("unhandled action {}", .{action});
            return false;
        },
    }
    _ = value;
}

pub fn performIpc(
    alloc: Allocator,
    target: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    value: apprt.ipc.Action.Value(action),
) !bool {
    _ = alloc;
    _ = target;
    _ = value;
    switch (action) {
        .new_window, .new_tab, .toggle_quick_terminal => return false,
    }
}

pub fn redrawInspector(_: *App, surface: *Surface) void {
    _ = surface;
}

fn onKey(ud: ?*anyopaque, event: input.KeyEvent) bool {
    const self: *App = @ptrCast(@alignCast(ud orelse return false));
    const s = self.surface orelse return false;
    if (event.action == .release) {
        _ = s.handleKey(event);
        return false;
    }
    if (self.core_app.keyEvent(self, event)) return true;
    return s.handleKey(event);
}

fn onMouseButton(
    ud: ?*anyopaque,
    action: input.MouseButtonState,
    button: input.MouseButton,
    mods: input.Mods,
) bool {
    const self: *App = @ptrCast(@alignCast(ud orelse return false));
    const s = self.surface orelse return false;
    return s.handleMouseButton(action, button, mods);
}

fn onScroll(
    ud: ?*anyopaque,
    xoff: f64,
    yoff: f64,
    mods: input.ScrollMods,
) void {
    const self: *App = @ptrCast(@alignCast(ud orelse return));
    const s = self.surface orelse return;
    s.handleScroll(xoff, yoff, mods);
}

fn onCursor(ud: ?*anyopaque, x: f64, y: f64, mods: input.Mods) void {
    const self: *App = @ptrCast(@alignCast(ud orelse return));
    const s = self.surface orelse return;
    s.handleCursor(x, y, mods);
}

fn onFocus(ud: ?*anyopaque, focused: bool) void {
    const self: *App = @ptrCast(@alignCast(ud orelse return));
    self.core_app.focusEvent(focused);
    const s = self.surface orelse return;
    s.handleFocus(focused);
}

fn onPreedit(ud: ?*anyopaque, text: ?[]const u8) void {
    const self: *App = @ptrCast(@alignCast(ud orelse return));
    const s = self.surface orelse return;
    s.handlePreedit(text);
}

fn onCommit(ud: ?*anyopaque, text: []const u8) void {
    const self: *App = @ptrCast(@alignCast(ud orelse return));
    const s = self.surface orelse return;
    s.handleCommit(text);
}

fn onImeCursorRect(ud: ?*anyopaque) ?text_input.Rect {
    const self: *App = @ptrCast(@alignCast(ud orelse return null));
    const s = self.surface orelse return null;
    return s.imeCursorRect();
}
