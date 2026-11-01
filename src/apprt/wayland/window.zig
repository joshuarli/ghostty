const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const libc = std.c;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const wp = wayland.client.wp;

const connection = @import("connection.zig");
const Connection = connection.Connection;
const scale_mod = @import("scale.zig");
const shm_format = @import("shm_format.zig");

const log = std.log.scoped(.wayland);

/// Three buffers let the compositor hold one frame while another is being
/// written and a third is pending release. Storage is never resized while a
/// buffer is busy; a released buffer of the wrong generation is discarded.
const max_buffers = 3;
const max_total_shm_bytes = 512 * 1024 * 1024;
const max_damage_history = 8;
const max_damage_rects = 64;

pub const DamageRect = @import("../../renderer/software/Damage.zig").Rect;

pub const RowOrder = enum { top_down, bottom_up };

const DamageEntry = struct {
    revision: u64 = 0,
    full: bool = true,
    rects: [16]DamageRect = undefined,
    len: u8 = 0,
};

pub const Window = struct {
    conn: *Connection,
    alloc: Allocator,
    surface: *wl.Surface,
    xdg_surface: *xdg.Surface,
    toplevel: *xdg.Toplevel,
    fractional: ?*wp.FractionalScaleV1,
    viewport: ?*wp.Viewport,
    scale_num: u32,
    fractional_num: ?u32 = null,
    preferred_integer: ?i32 = null,
    entered_outputs: std.ArrayListUnmanaged(*wl.Output) = .empty,
    configured: bool,
    /// Logical surface size in surface-local coordinates.
    width: u32,
    height: u32,
    buffers: std.ArrayListUnmanaged(*BufferSlot) = .empty,
    damage_history: [max_damage_history]DamageEntry = @splat(.{}),
    damage_history_count: u8 = 0,
    damage_history_next: u8 = 0,
    damage_scratch: [max_damage_rects]DamageRect = undefined,
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
            .frame_pending = false,
            .closed = false,
        };

        xdg_surface.setListener(*Window, onXdgSurfaceEvent, self);
        toplevel.setListener(*Window, onToplevelEvent, self);

        if (conn.globals.viewporter) |vp| {
            const port: ?*wp.Viewport = vp.getViewport(surface) catch |err| blk: {
                log.warn("getViewport failed err={}", .{err});
                break :blk null;
            };
            self.viewport = port;
        }
        surface.setListener(*Window, onSurfaceEvent, self);
        if (scale_mod.Mode.select(
            conn.globals.fractional_manager != null,
            self.viewport != null,
        ) == .fractional) {
            const mgr = conn.globals.fractional_manager.?;
            const frac: ?*wp.FractionalScaleV1 = mgr.getFractionalScale(surface) catch |err| blk: {
                log.warn("fractional_scale failed err={}", .{err});
                break :blk null;
            };
            if (frac) |f| {
                f.setListener(*Window, onFractionalEvent, self);
                self.fractional = f;
            }
        }

        var i: usize = 0;
        while (i < 50 and !self.configured) : (i += 1) {
            _ = conn.display.dispatch();
        }
        if (!self.configured) {
            self.width = 800;
            self.height = 600;
        }
        self.refreshScale();
        return self;
    }

    pub fn destroy(self: *Window) void {
        for (self.buffers.items) |slot| slot.destroy(self.alloc);
        self.buffers.deinit(self.alloc);
        self.entered_outputs.deinit(self.alloc);
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

    pub fn pixelWidth(self: *const Window) u32 {
        return scale_mod.bufferExtent(self.width, self.scale_num);
    }

    pub fn pixelHeight(self: *const Window) u32 {
        return scale_mod.bufferExtent(self.height, self.scale_num);
    }

    pub fn refreshScale(self: *Window) void {
        const mode: scale_mod.Mode = if (self.fractional != null) .fractional else .integer;
        var scales: [8]i32 = undefined;
        var count: usize = 0;
        for (self.entered_outputs.items) |output| {
            const factor = connection.outputScale(self.conn, output) orelse continue;
            if (count == scales.len) break;
            scales[count] = factor;
            count += 1;
        }
        const integer = scale_mod.integerScale(self.preferred_integer, scales[0..count]);
        self.scale_num = scale_mod.numerator(mode, self.fractional_num, integer);
    }

    fn integerScale(self: *const Window) u32 {
        return self.scale_num / scale_mod.numerator_unit;
    }

    fn applyScale(self: *Window) void {
        if (self.viewport) |vp| vp.setDestination(@intCast(self.width), @intCast(self.height));
        if (self.fractional == null and self.surface.getVersion() >= wl.Surface.set_buffer_scale_since_version) {
            self.surface.setBufferScale(@intCast(self.integerScale()));
        }
    }

    pub fn presentMemory(
        self: *Window,
        pixels: []const u8,
        width: u32,
        height: u32,
        row_order: RowOrder,
        damage: ?[]const DamageRect,
        revision: u64,
    ) !void {
        if (width == 0 or height == 0) return error.ZeroSize;
        if (self.frame_pending) return error.FramePending;
        const stride = std.math.mul(usize, width, 4) catch return error.ShmBufferTooLarge;
        const expected = std.math.mul(usize, stride, height) catch return error.ShmBufferTooLarge;
        if (pixels.len < expected) return error.ShortFrame;
        if (self.fractional == null and self.viewport == null) {
            const n = self.integerScale();
            if (!scale_mod.isMultipleOf(width, n) or !scale_mod.isMultipleOf(height, n)) {
                return error.StaleFrameScale;
            }
        }

        const slot = try self.acquireSlot(width, height);
        errdefer slot.busy = false;

        const incremental = self.incrementalDamage(slot, revision, damage);
        errdefer slot.has_revision = false;
        copyFrame(slot.data[0..expected], pixels[0..expected], width, height, row_order, incremental, slot.format);

        self.applyScale();
        self.surface.attach(slot.buffer, 0, 0);
        if (incremental) |rects| {
            if (self.surface.getVersion() >= wl.Surface.damage_buffer_since_version) {
                for (rects) |rect| {
                    self.surface.damageBuffer(
                        @intCast(rect.x),
                        @intCast(rect.y),
                        @intCast(rect.width),
                        @intCast(rect.height),
                    );
                }
            } else {
                for (rects) |rect| {
                    self.surface.damage(
                        @intCast(rect.x),
                        @intCast(rect.y),
                        @intCast(rect.width),
                        @intCast(rect.height),
                    );
                }
            }
        } else if (self.surface.getVersion() >= wl.Surface.damage_buffer_since_version) {
            self.surface.damageBuffer(0, 0, @intCast(width), @intCast(height));
        } else {
            self.surface.damage(0, 0, @intCast(width), @intCast(height));
        }
        const frame = try self.surface.frame();
        frame.setListener(*Window, onFrameEvent, self);
        self.frame_pending = true;
        slot.busy = true;
        slot.revision = revision;
        slot.has_revision = true;
        self.surface.commit();
        self.recordDamage(revision, damage);
        self.conn.flush();
    }

    /// Return damage that repairs `slot` from its stored revision to the
    /// incoming one. Stale or incomplete history forces a full-buffer damage.
    fn incrementalDamage(
        self: *Window,
        slot: *const BufferSlot,
        revision: u64,
        current: ?[]const DamageRect,
    ) ?[]const DamageRect {
        if (!slot.has_revision or revision <= slot.revision) return null;
        if (revision - slot.revision == 1) return current;

        if (revision - slot.revision > max_damage_history) return null;
        var len: usize = 0;
        var rev = slot.revision + 1;
        while (rev < revision) : (rev += 1) {
            const entry = self.damageEntry(rev) orelse return null;
            if (entry.full) return null;
            if (len + entry.len > self.damage_scratch.len) return null;
            @memcpy(self.damage_scratch[len..][0..entry.len], entry.rects[0..entry.len]);
            len += entry.len;
        }
        const current_rects = current orelse return null;
        if (len + current_rects.len > self.damage_scratch.len) return null;
        @memcpy(self.damage_scratch[len..][0..current_rects.len], current_rects);
        len += current_rects.len;
        if (len == 0) return &.{};
        return self.damage_scratch[0..len];
    }

    fn damageEntry(self: *const Window, revision: u64) ?*const DamageEntry {
        var i: u8 = 0;
        while (i < self.damage_history_count) : (i += 1) {
            const index = (self.damage_history_next + max_damage_history - 1 - i) % max_damage_history;
            const entry = &self.damage_history[index];
            if (entry.revision == revision) return entry;
        }
        return null;
    }

    fn recordDamage(self: *Window, revision: u64, damage: ?[]const DamageRect) void {
        const entry = &self.damage_history[self.damage_history_next];
        entry.revision = revision;
        entry.full = false;
        entry.len = 0;
        if (damage) |rects| {
            if (rects.len > entry.rects.len) {
                entry.full = true;
            } else {
                @memcpy(entry.rects[0..rects.len], rects);
                entry.len = @intCast(rects.len);
            }
        } else {
            entry.full = true;
        }
        self.damage_history_next = (self.damage_history_next + 1) % max_damage_history;
        self.damage_history_count = @min(self.damage_history_count + 1, max_damage_history);
    }

    fn acquireSlot(self: *Window, width: u32, height: u32) !*BufferSlot {
        for (self.buffers.items) |slot| {
            if (!slot.busy and slot.width == width and slot.height == height) return slot;
        }

        if (self.buffers.items.len < max_buffers) {
            const slot = try BufferSlot.create(self, width, height);
            errdefer slot.destroy(self.alloc);
            try self.buffers.append(self.alloc, slot);
            return slot;
        }

        for (self.buffers.items, 0..) |slot, i| {
            if (slot.busy) continue;
            slot.destroy(self.alloc);
            _ = self.buffers.swapRemove(i);
            const new_slot = try BufferSlot.create(self, width, height);
            errdefer new_slot.destroy(self.alloc);
            try self.buffers.append(self.alloc, new_slot);
            return new_slot;
        }

        return error.BufferBusy;
    }
};

/// Write `src` into the shared buffer `dst`. `repair` names the only regions
/// that differ from what `dst` already holds; null means all of it. Bottom-up
/// sources are flipped and always copied whole.
fn copyFrame(
    dst: []u8,
    src: []const u8,
    width: u32,
    height: u32,
    row_order: RowOrder,
    repair: ?[]const DamageRect,
    format: shm_format.Format,
) void {
    const stride = @as(usize, width) * 4;
    switch (row_order) {
        .bottom_up => {
            var row: usize = 0;
            while (row < height) : (row += 1) {
                const dst_off = (height - 1 - row) * stride;
                format.convertRow(dst[dst_off..][0..stride], src[row * stride ..][0..stride]);
            }
        },
        .top_down => {
            const rects = repair orelse return format.convertRow(dst, src);
            for (rects) |rect| {
                const clipped = rect.clipped(width, height) orelse continue;
                const row_bytes = @as(usize, clipped.width) * 4;
                var row: usize = clipped.y;
                while (row < clipped.bottom()) : (row += 1) {
                    const off = row * stride + @as(usize, clipped.x) * 4;
                    format.convertRow(dst[off..][0..row_bytes], src[off..][0..row_bytes]);
                }
            }
        },
    }
}

const BufferSlot = struct {
    window: *Window,
    buffer: *wl.Buffer,
    pool: *wl.ShmPool,
    fd: posix.fd_t,
    data: []align(std.heap.page_size_min) u8,
    width: u32,
    height: u32,
    busy: bool,
    format: shm_format.Format,
    revision: u64 = 0,
    has_revision: bool = false,

    fn create(window: *Window, width: u32, height: u32) !*BufferSlot {
        const alloc = window.alloc;
        const stride = std.math.mul(usize, width, 4) catch return error.ShmBufferTooLarge;
        const size = std.math.mul(usize, stride, height) catch return error.ShmBufferTooLarge;
        if (stride > std.math.maxInt(i32) or size > std.math.maxInt(i32)) {
            return error.ShmBufferTooLarge;
        }
        if (size > max_total_shm_bytes / max_buffers) return error.ShmBudgetExceeded;

        const self = try alloc.create(BufferSlot);
        errdefer alloc.destroy(self);

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
        errdefer posix.munmap(data);

        const shm = window.conn.globals.shm orelse return error.NoShm;
        const format = shm_format.Format.select(window.conn.globals.shm_formats) orelse
            return error.NoShmFormat;
        const pool = try shm.createPool(fd, @intCast(size));
        errdefer pool.destroy();
        const buffer = try pool.createBuffer(
            0,
            @intCast(width),
            @intCast(height),
            @intCast(stride),
            switch (format) {
                .abgr8888 => wl.Shm.Format.abgr8888,
                .argb8888 => wl.Shm.Format.argb8888,
            },
        );

        self.* = .{
            .window = window,
            .buffer = buffer,
            .pool = pool,
            .fd = fd,
            .data = data,
            .width = width,
            .height = height,
            .busy = false,
            .format = format,
        };
        buffer.setListener(*BufferSlot, onBufferRelease, self);
        return self;
    }

    fn destroy(self: *BufferSlot, alloc: Allocator) void {
        self.buffer.destroy();
        self.pool.destroy();
        posix.munmap(self.data);
        _ = libc.close(self.fd);
        alloc.destroy(self);
    }
};

fn onBufferRelease(
    buffer: *wl.Buffer,
    event: wl.Buffer.Event,
    slot: *BufferSlot,
) void {
    _ = buffer;
    switch (event) {
        .release => slot.busy = false,
    }
}

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
            if (s.scale > 0) {
                win.fractional_num = s.scale;
                win.refreshScale();
            }
        },
    }
}

fn onSurfaceEvent(
    surface: *wl.Surface,
    event: wl.Surface.Event,
    win: *Window,
) void {
    _ = surface;
    switch (event) {
        .enter => |e| if (e.output) |output| {
            win.entered_outputs.append(win.alloc, output) catch |err| {
                log.warn("track entered output failed err={}", .{err});
                return;
            };
            win.refreshScale();
        },
        .leave => |e| if (e.output) |output| {
            for (win.entered_outputs.items, 0..) |entered, i| {
                if (entered != output) continue;
                _ = win.entered_outputs.swapRemove(i);
                break;
            }
            win.refreshScale();
        },
        .preferred_buffer_scale => |e| {
            win.preferred_integer = e.factor;
            win.refreshScale();
        },
        .preferred_buffer_transform => {},
    }
}

test "physical pixels follow the fractional scale numerator" {
    var win: Window = undefined;
    win.scale_num = 180;
    win.width = 100;
    win.height = 50;
    try std.testing.expectEqual(@as(u32, 150), win.pixelWidth());
    try std.testing.expectEqual(@as(u32, 75), win.pixelHeight());
}

test "damage history unions missed revisions and rejects stale buffers" {
    var win: Window = undefined;
    win.damage_history = @splat(.{});
    win.damage_history_count = 0;
    win.damage_history_next = 0;

    var slot: BufferSlot = undefined;
    slot.has_revision = true;
    slot.revision = 1;

    const first = [_]DamageRect{.{ .x = 0, .y = 1, .width = 4, .height = 1 }};
    const second = [_]DamageRect{.{ .x = 0, .y = 2, .width = 4, .height = 1 }};
    const current = [_]DamageRect{.{ .x = 0, .y = 3, .width = 4, .height = 1 }};
    win.recordDamage(2, &first);
    win.recordDamage(3, &second);

    const merged = win.incrementalDamage(&slot, 4, &current) orelse return error.MissingDamage;
    try std.testing.expectEqual(@as(usize, 3), merged.len);
    try std.testing.expectEqual(@as(u32, 1), merged[0].y);
    try std.testing.expectEqual(@as(u32, 3), merged[2].y);

    slot.revision = 0;
    try std.testing.expect(win.incrementalDamage(&slot, 10, &current) == null);
}

test "top-down repair copies only the damaged rectangle" {
    var dst: [48]u8 = @splat(0);
    var src: [dst.len]u8 = undefined;
    @memset(&src, 7);
    const damage = [_]DamageRect{.{ .x = 1, .y = 1, .width = 2, .height = 1 }};
    copyFrame(&dst, &src, 4, 3, .top_down, &damage, .abgr8888);

    for (dst, 0..) |byte, i| {
        const pixel = i / 4;
        const inside = pixel == 5 or pixel == 6;
        try std.testing.expectEqual(@as(u8, if (inside) 7 else 0), byte);
    }
}

test "top-down without repair regions copies the whole frame" {
    var dst: [16]u8 = @splat(0);
    var src: [16]u8 = undefined;
    for (&src, 0..) |*byte, i| byte.* = @intCast(i);
    copyFrame(&dst, &src, 2, 2, .top_down, null, .abgr8888);
    try std.testing.expectEqualSlices(u8, &src, &dst);
}

test "bottom-up source is flipped into top-down rows" {
    var dst: [16]u8 = @splat(0);
    const src = [_]u8{ 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4 };
    copyFrame(&dst, &src, 2, 2, .bottom_up, null, .abgr8888);
    try std.testing.expectEqualSlices(u8, &.{ 3, 3, 3, 3, 4, 4, 4, 4, 1, 1, 1, 1, 2, 2, 2, 2 }, &dst);
}

test "argb8888 conversion applies to flipped and repaired rows" {
    const src = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var flipped: [8]u8 = undefined;
    copyFrame(&flipped, &src, 1, 2, .bottom_up, null, .argb8888);
    try std.testing.expectEqualSlices(u8, &.{ 7, 6, 5, 8, 3, 2, 1, 4 }, &flipped);

    var repaired: [8]u8 = @splat(0);
    const damage = [_]DamageRect{.{ .x = 0, .y = 1, .width = 1, .height = 1 }};
    copyFrame(&repaired, &src, 1, 2, .top_down, &damage, .argb8888);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 7, 6, 5, 8 }, &repaired);
}
