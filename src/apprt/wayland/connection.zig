const std = @import("std");
const Allocator = std.mem.Allocator;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;

const log = std.log.scoped(.wayland);

pub const Globals = struct {
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    wm_base: ?*xdg.WmBase = null,
    seat: ?*wl.Seat = null,

    pub fn deinit(self: *Globals) void {
        _ = self;
    }
};

pub const Connection = struct {
    display: *wl.Display,
    registry: *wl.Registry,
    globals: Globals,
    alloc: Allocator,

    pub fn connect(alloc: Allocator) !Connection {
        const display = try wl.Display.connect(null);
        errdefer display.disconnect();
        const registry = try display.getRegistry();
        var self = Connection{
            .display = display,
            .registry = registry,
            .globals = .{},
            .alloc = alloc,
        };
        registry.setListener(*Connection, onRegistryEvent, &self);
        try roundtrip(&self);
        try roundtrip(&self);
        if (self.globals.compositor == null) return error.NoCompositor;
        if (self.globals.shm == null) return error.NoShm;
        if (self.globals.wm_base == null) return error.NoXdgWmBase;
        return self;
    }

    pub fn disconnect(self: *Connection) void {
        if (self.globals.wm_base) |v| v.destroy();
        if (self.globals.seat) |v| v.release();
        if (self.globals.shm) |v| v.destroy();
        if (self.globals.compositor) |v| v.destroy();
        self.registry.destroy();
        self.display.disconnect();
        self.globals.deinit();
    }

    pub fn dispatchPending(self: *Connection) void {
        _ = self.display.dispatchPending();
    }

    pub fn flush(self: *Connection) void {
        _ = self.display.flush();
    }
};

fn roundtrip(conn: *Connection) !void {
    const e = conn.display.roundtrip();
    if (e != .SUCCESS) return error.RoundtripFailed;
}

fn onRegistryEvent(
    registry: *wl.Registry,
    event: wl.Registry.Event,
    conn: *Connection,
) void {
    switch (event) {
        .global => |g| {
            bindGlobal(conn, registry, g.name, g.interface, g.version) catch |err| {
                log.warn("bind {s} failed err={}", .{ g.interface, err });
            };
        },
        .global_remove => {},
    }
}

fn bindGlobal(
    conn: *Connection,
    registry: *wl.Registry,
    name: u32,
    iface: [*:0]const u8,
    version: u32,
) !void {
    const span = std.mem.span(iface);
    if (std.mem.eql(u8, span, "wl_compositor")) {
        if (conn.globals.compositor != null) return;
        conn.globals.compositor = try registry.bind(
            name,
            wl.Compositor,
            @min(version, 4),
        );
    } else if (std.mem.eql(u8, span, "wl_shm")) {
        if (conn.globals.shm != null) return;
        conn.globals.shm = try registry.bind(name, wl.Shm, @min(version, 1));
    } else if (std.mem.eql(u8, span, "xdg_wm_base")) {
        if (conn.globals.wm_base != null) return;
        const wm: *xdg.WmBase = try registry.bind(
            name,
            xdg.WmBase,
            @min(version, 6),
        );
        wm.setListener(*xdg.WmBase, onWmBaseEvent, wm);
        conn.globals.wm_base = wm;
    } else if (std.mem.eql(u8, span, "wl_seat")) {
        if (conn.globals.seat != null) return;
        conn.globals.seat = try registry.bind(name, wl.Seat, @min(version, 9));
    }
}

fn onWmBaseEvent(
    wm: *xdg.WmBase,
    event: xdg.WmBase.Event,
    data: *xdg.WmBase,
) void {
    _ = data;
    switch (event) {
        .ping => |p| wm.pong(p.serial),
    }
}
