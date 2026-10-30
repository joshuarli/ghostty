const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const libc = std.c;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const wp = wayland.client.wp;

const Connection = @import("connection.zig").Connection;

const log = std.log.scoped(.wayland);

pub const Window = struct {
    conn: *Connection,
    alloc: Allocator,
    surface: *wl.Surface,
    xdg_surface: *xdg.Surface,
    toplevel: *xdg.Toplevel,
    fractional: ?*wp.FractionalScaleV1,
    viewport: ?*wp.Viewport,
    scale_num: u32,
    configured: bool,
    width: u32,
    height: u32,
    shm_fd: posix.fd_t,
    shm_size: usize,
    shm_data: []u8,
    pool: ?*wl.ShmPool,
    buffer: ?*wl.Buffer,
    buf_width: u32,
    buf_height: u32,
    frame_pending: bool,
    closed: bool,

    pub fn create(
        alloc: Allocator,
        conn: *Connection,
        app_id: [:0]const u8,
        title: [:0]const u8,
    ) !*Window {
        const self = try alloc.create(Window);
        errdefer alloc.destroy(self);

        const compositor = conn.globals.compositor orelse return error.NoCompositor;
        const wm_base = conn.globals.wm_base orelse return error.NoXdgWmBase;

        const surface = try compositor.createSurface();
        errdefer surface.destroy();
        const xdg_surface = try wm_base.getXdgSurface(surface);
        errdefer xdg_surface.destroy();
        const toplevel = try xdg_surface.getToplevel();
        errdefer toplevel.destroy();

        toplevel.setAppId(app_id);
        toplevel.setTitle(title);
        surface.commit();

        self.* = .{
            .conn = conn,
            .alloc = alloc,
            .surface = surface,
            .xdg_surface = xdg_surface,
            .toplevel = toplevel,
            .fractional = null,
            .viewport = null,
            .scale_num = 120,
            .configured = false,
            .width = 800,
            .height = 600,
            .shm_fd = -1,
            .shm_size = 0,
            .shm_data = &.{},
            .pool = null,
            .buffer = null,
            .buf_width = 0,
            .buf_height = 0,
            .frame_pending = false,
            .closed = false,
        };

        xdg_surface.setListener(*Window, onXdgSurfaceEvent, self);
        toplevel.setListener(*Window, onToplevelEvent, self);

        if (conn.globals.fractional_manager) |mgr| {
            const frac: ?*wp.FractionalScaleV1 = mgr.getFractionalScale(surface) catch |err| blk: {
                log.warn("fractional_scale failed err={}", .{err});
                break :blk null;
            };
            if (frac) |f| {
                f.setListener(*Window, onFractionalEvent, self);
                self.fractional = f;
            }
        }
        if (conn.globals.viewporter) |vp| {
            const port: ?*wp.Viewport = vp.getViewport(surface) catch |err| blk: {
                log.warn("getViewport failed err={}", .{err});
                break :blk null;
            };
            self.viewport = port;
        }

        var i: usize = 0;
        while (i < 50 and !self.configured) : (i += 1) {
            _ = conn.display.dispatch();
        }
        if (!self.configured) {
            self.width = 800;
            self.height = 600;
        }
        return self;
    }

    pub fn destroy(self: *Window) void {
        if (self.buffer) |b| b.destroy();
        if (self.pool) |p| p.destroy();
        if (self.shm_data.len > 0) posix.munmap(@alignCast(self.shm_data));
        if (self.shm_fd >= 0) _ = libc.close(self.shm_fd);
        if (self.fractional) |f| f.destroy();
        if (self.viewport) |v| v.destroy();
        self.toplevel.destroy();
        self.xdg_surface.destroy();
        self.surface.destroy();
        self.alloc.destroy(self);
    }

    pub fn scale(self: *const Window) f64 {
        return @as(f64, @floatFromInt(self.scale_num)) / 120.0;
    }

    pub fn presentMemory(
        self: *Window,
        pixels: []const u8,
        width: u32,
        height: u32,
    ) !void {
        try self.ensureShm(width, height);
        const stride: usize = @as(usize, width) * 4;
        const src_stride = stride;
        var row: u32 = 0;
        while (row < height) : (row += 1) {
            const src_off = @as(usize, row) * src_stride;
            const dst_row = height - 1 - row;
            const dst_off = @as(usize, dst_row) * stride;
            @memcpy(
                self.shm_data[dst_off .. dst_off + stride],
                pixels[src_off .. src_off + stride],
            );
        }
        self.surface.attach(self.buffer, 0, 0);
        self.surface.damage(0, 0, @intCast(width), @intCast(height));
        if (!self.frame_pending) {
            const frame = try self.surface.frame();
            frame.setListener(*Window, onFrameEvent, self);
            self.frame_pending = true;
        }
        self.surface.commit();
        self.conn.flush();
    }

    fn ensureShm(self: *Window, width: u32, height: u32) !void {
        if (self.buffer != null and
            self.buf_width == width and self.buf_height == height) return;
        if (self.buffer) |b| b.destroy();
        self.buffer = null;
        if (self.pool) |p| p.destroy();
        self.pool = null;
        if (self.shm_data.len > 0) posix.munmap(@alignCast(self.shm_data));
        self.shm_data = &.{};
        if (self.shm_fd >= 0) _ = libc.close(self.shm_fd);

        const stride: i32 = @intCast(width * 4);
        const size: usize = @as(usize, height) * @as(usize, @intCast(stride));
        const fd = try posix.memfd_create("ghostty-wayland-shm", 0);
        errdefer _ = libc.close(fd);
        if (libc.ftruncate(fd, @intCast(size)) != 0) return error.FtruncateFailed;
        const data = try posix.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );

        const shm = self.conn.globals.shm orelse return error.NoShm;
        const pool = try shm.createPool(fd, @intCast(size));
        const buffer = try pool.createBuffer(
            0,
            @intCast(width),
            @intCast(height),
            stride,
            wl.Shm.Format.argb8888,
        );

        self.shm_fd = fd;
        self.shm_size = size;
        self.shm_data = data;
        self.pool = pool;
        self.buffer = buffer;
        self.buf_width = width;
        self.buf_height = height;
    }
};

fn onXdgSurfaceEvent(
    xdg_surface: *xdg.Surface,
    event: xdg.Surface.Event,
    win: *Window,
) void {
    switch (event) {
        .configure => |c| {
            xdg_surface.ackConfigure(c.serial);
            win.configured = true;
        },
    }
}

fn onToplevelEvent(
    toplevel: *xdg.Toplevel,
    event: xdg.Toplevel.Event,
    win: *Window,
) void {
    _ = toplevel;
    switch (event) {
        .configure => |c| {
            if (c.width > 0) win.width = @intCast(c.width);
            if (c.height > 0) win.height = @intCast(c.height);
        },
        .close => {
            win.closed = true;
        },
        .configure_bounds => {},
        .wm_capabilities => {},
    }
}

fn onFrameEvent(
    cb: *wl.Callback,
    event: wl.Callback.Event,
    win: *Window,
) void {
    _ = event;
    cb.destroy();
    win.frame_pending = false;
}

fn onFractionalEvent(
    frac: *wp.FractionalScaleV1,
    event: wp.FractionalScaleV1.Event,
    win: *Window,
) void {
    _ = frac;
    switch (event) {
        .preferred_scale => |s| {
            if (s.scale > 0) win.scale_num = s.scale;
        },
    }
}
