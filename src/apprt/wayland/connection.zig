const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const linux = std.os.linux;
const libc = std.c;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const wp = wayland.client.wp;

const seat_mod = @import("seat.zig");
const Seat = seat_mod.Seat;
const SeatEvents = seat_mod.SeatEvents;
const Clipboard = @import("clipboard.zig").Clipboard;

const log = std.log.scoped(.wayland);

pub const Globals = struct {
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    wm_base: ?*xdg.WmBase = null,
    seat: ?*wl.Seat = null,
    seat_name: ?u32 = null,
    data_device_manager: ?*wl.DataDeviceManager = null,
    data_device_manager_name: ?u32 = null,
    fractional_manager: ?*wp.FractionalScaleManagerV1 = null,
    viewporter: ?*wp.Viewporter = null,

    pub fn deinit(self: *Globals) void {
        _ = self;
    }
};

/// The Wayland connection. It is initialized in place because the
/// registry listener keeps a pointer to it for the connection's lifetime,
/// and it creates the seat at bind time so the seat's initial
/// capabilities event reaches a listener.
pub const Connection = struct {
    display: *wl.Display,
    registry: *wl.Registry,
    globals: Globals,
    seat: ?*Seat,
    seat_events: SeatEvents,
    clipboard: ?Clipboard = null,
    poll_fds: std.ArrayListUnmanaged(posix.pollfd) = .empty,
    wake_fd: posix.fd_t,
    alloc: Allocator,

    pub fn connect(self: *Connection, alloc: Allocator, seat_events: SeatEvents) !void {
        const display = try wl.Display.connect(null);
        errdefer display.disconnect();
        const registry = try display.getRegistry();
        errdefer registry.destroy();
        const wake_fd = libc.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (wake_fd < 0) return error.EventFdFailed;
        errdefer _ = libc.close(wake_fd);
        self.* = .{
            .display = display,
            .registry = registry,
            .globals = .{},
            .seat = null,
            .seat_events = seat_events,
            .wake_fd = wake_fd,
            .alloc = alloc,
        };
        errdefer if (self.seat) |st| st.deinit();
        errdefer if (self.clipboard) |*clipboard| clipboard.deinit();
        registry.setListener(*Connection, onRegistryEvent, self);
        try roundtrip(self);
        try roundtrip(self);
        if (self.globals.compositor == null) return error.NoCompositor;
        if (self.globals.shm == null) return error.NoShm;
        if (self.globals.wm_base == null) return error.NoXdgWmBase;
    }

    pub fn disconnect(self: *Connection) void {
        if (self.clipboard) |*clipboard| {
            clipboard.deinit();
            self.clipboard = null;
        }
        if (self.seat) |st| st.deinit();
        self.seat = null;
        if (self.globals.wm_base) |v| v.destroy();
        if (self.globals.seat) |v| v.release();
        if (self.globals.data_device_manager) |v| v.destroy();
        if (self.globals.shm) |v| v.destroy();
        if (self.globals.compositor) |v| v.destroy();
        if (self.globals.fractional_manager) |v| v.destroy();
        if (self.globals.viewporter) |v| v.destroy();
        self.registry.destroy();
        self.display.disconnect();
        _ = libc.close(self.wake_fd);
        self.poll_fds.deinit(self.alloc);
        self.globals.deinit();
    }

    /// Wake a `wait` in progress. Safe to call from any thread.
    pub fn wake(self: *Connection) void {
        const one: u64 = 1;
        _ = libc.write(self.wake_fd, std.mem.asBytes(&one), @sizeOf(u64));
    }

    /// Dispatch queued events, then block until the compositor sends more,
    /// `wake` is called, or `timeout_ms` passes, and dispatch what arrived.
    /// Fails when the compositor connection is lost.
    pub fn wait(self: *Connection, timeout_ms: i32) !void {
        while (!self.display.prepareRead()) {
            if (self.display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
        }
        switch (self.display.flush()) {
            .SUCCESS, .AGAIN => {},
            else => {
                self.display.cancelRead();
                return error.FlushFailed;
            },
        }
        self.poll_fds.clearRetainingCapacity();
        try self.poll_fds.append(self.alloc, .{
            .fd = self.display.getFd(),
            .events = linux.POLL.IN,
            .revents = 0,
        });
        try self.poll_fds.append(self.alloc, .{
            .fd = self.wake_fd,
            .events = linux.POLL.IN,
            .revents = 0,
        });
        if (self.clipboard) |*clipboard| {
            try clipboard.appendPollFds(self.alloc, &self.poll_fds);
        }
        _ = posix.poll(self.poll_fds.items, timeout_ms) catch |err| {
            self.display.cancelRead();
            return err;
        };
        if (self.poll_fds.items[0].revents & linux.POLL.IN != 0) {
            if (self.display.readEvents() != .SUCCESS) return error.ReadFailed;
        } else {
            self.display.cancelRead();
            if (self.poll_fds.items[0].revents & (linux.POLL.HUP | linux.POLL.ERR) != 0) return error.ConnectionLost;
        }
        if (self.poll_fds.items[1].revents & linux.POLL.IN != 0) {
            var count: u64 = 0;
            _ = libc.read(self.wake_fd, std.mem.asBytes(&count), @sizeOf(u64));
        }
        if (self.display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
        if (self.clipboard) |*clipboard| clipboard.service();
    }

    pub fn flush(self: *Connection) void {
        _ = self.display.flush();
    }

    pub fn clipboardState(self: *Connection) ?*Clipboard {
        if (self.clipboard) |*clipboard| return clipboard;
        return null;
    }

    pub fn serial(self: *const Connection) u32 {
        return if (self.seat) |seat| seat.last_serial else 0;
    }

    fn initClipboard(self: *Connection) !void {
        if (self.clipboard != null) return;
        const manager = self.globals.data_device_manager orelse return;
        const seat = self.seat orelse return;

        self.clipboard = .{
            .alloc = self.alloc,
            .manager = manager,
            .seat = seat,
        };
        if (self.clipboard) |*clipboard| {
            clipboard.init() catch |err| {
                self.clipboard = null;
                return err;
            };
        }
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
        .global_remove => |g| {
            if (conn.globals.seat_name == @as(?u32, g.name)) {
                if (conn.clipboard) |*clipboard| {
                    clipboard.deinit();
                    conn.clipboard = null;
                }
                if (conn.seat) |st| {
                    st.deinit();
                    conn.seat = null;
                }
                if (conn.globals.seat) |v| {
                    v.release();
                    conn.globals.seat = null;
                }
                conn.globals.seat_name = null;
            }
            if (conn.globals.data_device_manager_name == @as(?u32, g.name)) {
                if (conn.clipboard) |*clipboard| {
                    clipboard.deinit();
                    conn.clipboard = null;
                }
                if (conn.globals.data_device_manager) |v| {
                    v.destroy();
                    conn.globals.data_device_manager = null;
                }
                conn.globals.data_device_manager_name = null;
            }
        },
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
        const wl_seat: *wl.Seat = try registry.bind(name, wl.Seat, @min(version, 9));
        conn.globals.seat = wl_seat;
        conn.globals.seat_name = name;
        conn.seat = try Seat.init(conn.alloc, wl_seat, conn.seat_events);
        try conn.initClipboard();
    } else if (std.mem.eql(u8, span, "wl_data_device_manager")) {
        if (conn.globals.data_device_manager != null) return;
        conn.globals.data_device_manager = try registry.bind(
            name,
            wl.DataDeviceManager,
            @min(version, 3),
        );
        conn.globals.data_device_manager_name = name;
        try conn.initClipboard();
    } else if (std.mem.eql(u8, span, "wp_fractional_scale_manager_v1")) {
        if (conn.globals.fractional_manager != null) return;
        conn.globals.fractional_manager = try registry.bind(
            name,
            wp.FractionalScaleManagerV1,
            @min(version, 1),
        );
    } else if (std.mem.eql(u8, span, "wp_viewporter")) {
        if (conn.globals.viewporter != null) return;
        conn.globals.viewporter = try registry.bind(
            name,
            wp.Viewporter,
            @min(version, 1),
        );
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
