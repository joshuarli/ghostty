const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const CoreApp = @import("../../App.zig");
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const input = @import("../../input.zig");
const Surface = @import("Surface.zig");

const log = std.log.scoped(.wayland);

pub const App = @This();

core_app: *CoreApp,
config: Config,
running: bool,
surface: ?*Surface,

pub fn init(self: *App, core_app: *CoreApp, opts: struct {}) !void {
    _ = opts;
    var config = try Config.load(core_app.alloc);
    errdefer config.deinit();
    self.* = .{
        .core_app = core_app,
        .config = config,
        .running = false,
        .surface = null,
    };
}

pub fn terminate(self: *App) void {
    if (self.surface) |s| {
        s.deinit();
        self.core_app.alloc.destroy(s);
        self.surface = null;
    }
    self.config.deinit();
}

pub fn wakeup(self: *App) void {
    _ = self;
}

pub fn keyboardLayout(self: *const App) input.KeyboardLayout {
    _ = self;
    return .unknown;
}

pub fn wait(self: *const App) !void {
    _ = self;
}

pub fn run(self: *App) !void {
    self.running = true;
    try self.newWindow();
    while (self.running) {
        try self.core_app.tick(self);
        if (self.surface == null) break;
        std.Thread.yield() catch {};
    }
}

fn newWindow(self: *App) !void {
    const alloc = self.core_app.alloc;
    const rt_surface = try alloc.create(Surface);
    errdefer alloc.destroy(rt_surface);
    try rt_surface.init(self);
    errdefer rt_surface.deinit();
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
        .quit => {
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
