const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const xkbcommon = @import("xkbcommon");
const input = @import("../../input.zig");
const keycodes = @import("../../input/keycodes.zig");
const global = @import("../../global.zig");
const KeyRepeat = @import("key_repeat.zig").KeyRepeat;

const log = std.log.scoped(.wayland);

pub const SeatEvents = struct {
    key_fn: ?*const fn (ud: ?*anyopaque, event: input.KeyEvent) bool = null,
    key_ud: ?*anyopaque = null,
    mouse_button_fn: ?*const fn (ud: ?*anyopaque, action: input.MouseButtonState, button: input.MouseButton, mods: input.Mods) bool = null,
    mouse_button_ud: ?*anyopaque = null,
    scroll_fn: ?*const fn (ud: ?*anyopaque, xoff: f64, yoff: f64, mods: input.ScrollMods) void = null,
    scroll_ud: ?*anyopaque = null,
    cursor_fn: ?*const fn (ud: ?*anyopaque, x: f64, y: f64, mods: input.Mods) void = null,
    cursor_ud: ?*anyopaque = null,
    focus_fn: ?*const fn (ud: ?*anyopaque, focused: bool) void = null,
    focus_ud: ?*anyopaque = null,
};

pub const Seat = struct {
    alloc: Allocator,
    seat: *wl.Seat,
    keyboard: ?*wl.Keyboard = null,
    pointer: ?*wl.Pointer = null,
    events: SeatEvents,
    mods: input.Mods = .{},
    last_serial: u32 = 0,
    key_repeat: KeyRepeat = .{},

    xkb_ctx: ?*xkbcommon.xkb_context = null,
    xkb_keymap: ?*xkbcommon.xkb_keymap = null,
    xkb_state: ?*xkbcommon.xkb_state = null,
    xkb_mods: ModIndices = .{},

    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    axis_h: f64 = 0,
    axis_v: f64 = 0,

    const ModIndices = struct {
        shift: xkbcommon.xkb_mod_index_t = 0,
        ctrl: xkbcommon.xkb_mod_index_t = 0,
        alt: xkbcommon.xkb_mod_index_t = 0,
        super: xkbcommon.xkb_mod_index_t = 0,
        caps: xkbcommon.xkb_mod_index_t = 0,
        num: xkbcommon.xkb_mod_index_t = 0,
    };

    pub fn init(alloc: Allocator, seat: *wl.Seat, events: SeatEvents) !*Seat {
        const self = try alloc.create(Seat);
        self.* = .{
            .alloc = alloc,
            .seat = seat,
            .events = events,
        };
        self.xkb_ctx = xkbcommon.xkb_context_new(xkbcommon.XKB_CONTEXT_NO_FLAGS);
        if (self.xkb_ctx == null) {
            alloc.destroy(self);
            return error.XkbContextFailed;
        }
        seat.setListener(*Seat, onSeatEvent, self);
        return self;
    }

    pub fn deinit(self: *Seat) void {
        if (self.keyboard) |k| k.release();
        if (self.pointer) |p| p.release();
        if (self.xkb_state) |s| xkbcommon.xkb_state_unref(s);
        if (self.xkb_keymap) |k| xkbcommon.xkb_keymap_unref(k);
        if (self.xkb_ctx) |c| xkbcommon.xkb_context_unref(c);
        self.alloc.destroy(self);
    }

    pub fn repeatTimeoutMs(self: *const Seat) ?i32 {
        return self.key_repeat.timeoutMs(nowMs());
    }

    pub fn tickRepeat(self: *Seat) void {
        const keycode = self.key_repeat.due(nowMs()) orelse return;
        self.emitKey(keycode, .repeat);
    }

    fn emitKey(self: *Seat, keycode: u32, action: input.Action) void {
        const state = self.xkb_state orelse return;
        const keysym = xkbcommon.xkb_state_key_get_one_sym(state, keycode);
        var utf8_buf: [8]u8 = undefined;
        const utf8_len = xkbcommon.xkb_state_key_get_utf8(state, keycode, &utf8_buf, utf8_buf.len);
        const utf8: []const u8 = if (utf8_len > 0) utf8_buf[0..@intCast(utf8_len)] else "";

        const physical: input.Key = for (keycodes.entries) |entry| {
            if (entry.native == keycode) break entry.key;
        } else .unidentified;

        const ev = input.KeyEvent{
            .action = action,
            .key = physical,
            .mods = self.mods,
            .consumed_mods = .{},
            .composing = false,
            .utf8 = utf8,
            .unshifted_codepoint = unshiftedCodepoint(keysym),
        };
        if (self.events.key_fn) |f| _ = f(self.events.key_ud, ev);
    }

    fn updateMods(self: *Seat) void {
        var mods: input.Mods = .{};
        if (self.xkb_state) |st| {
            if (xkbcommon.xkb_state_mod_name_is_active(
                st,
                xkbcommon.XKB_MOD_NAME_SHIFT,
                xkbcommon.XKB_STATE_MODS_EFFECTIVE,
            ) == 1) mods.shift = true;
            if (xkbcommon.xkb_state_mod_name_is_active(
                st,
                xkbcommon.XKB_MOD_NAME_CTRL,
                xkbcommon.XKB_STATE_MODS_EFFECTIVE,
            ) == 1) mods.ctrl = true;
            if (xkbcommon.xkb_state_mod_name_is_active(
                st,
                xkbcommon.XKB_MOD_NAME_ALT,
                xkbcommon.XKB_STATE_MODS_EFFECTIVE,
            ) == 1) mods.alt = true;
            if (xkbcommon.xkb_state_mod_name_is_active(
                st,
                xkbcommon.XKB_MOD_NAME_LOGO,
                xkbcommon.XKB_STATE_MODS_EFFECTIVE,
            ) == 1) mods.super = true;
            if (xkbcommon.xkb_state_mod_name_is_active(
                st,
                "Caps_Lock",
                xkbcommon.XKB_STATE_MODS_EFFECTIVE,
            ) == 1) mods.caps_lock = true;
            if (xkbcommon.xkb_state_mod_name_is_active(
                st,
                "Num_Lock",
                xkbcommon.XKB_STATE_MODS_EFFECTIVE,
            ) == 1) mods.num_lock = true;
        }
        self.mods = mods;
    }
};

fn onSeatEvent(seat: *wl.Seat, event: wl.Seat.Event, self: *Seat) void {
    switch (event) {
        .capabilities => |c| {
            if (c.capabilities.keyboard) {
                if (self.keyboard == null) {
                    const kb = seat.getKeyboard() catch |err| {
                        log.warn("getKeyboard failed err={}", .{err});
                        return;
                    };
                    kb.setListener(*Seat, onKeyboardEvent, self);
                    self.keyboard = kb;
                }
            } else if (self.keyboard) |k| {
                k.release();
                self.keyboard = null;
            }
            if (c.capabilities.pointer) {
                if (self.pointer == null) {
                    const p = seat.getPointer() catch |err| {
                        log.warn("getPointer failed err={}", .{err});
                        return;
                    };
                    p.setListener(*Seat, onPointerEvent, self);
                    self.pointer = p;
                }
            } else if (self.pointer) |p| {
                p.release();
                self.pointer = null;
            }
        },
        .name => {},
    }
}

fn onKeyboardEvent(
    kb: *wl.Keyboard,
    event: wl.Keyboard.Event,
    self: *Seat,
) void {
    _ = kb;
    switch (event) {
        .keymap => |km| {
            defer _ = std.c.close(km.fd);
            self.key_repeat.cancel();
            if (km.format != .xkb_v1) return;
            const map_str = posix.mmap(
                null,
                km.size,
                .{ .READ = true },
                .{ .TYPE = .PRIVATE },
                km.fd,
                0,
            ) catch |err| {
                log.warn("keymap mmap failed err={}", .{err});
                return;
            };
            defer posix.munmap(@alignCast(map_str));
            if (self.xkb_state) |s| xkbcommon.xkb_state_unref(s);
            self.xkb_state = null;
            if (self.xkb_keymap) |k| xkbcommon.xkb_keymap_unref(k);
            self.xkb_keymap = xkbcommon.xkb_keymap_new_from_string(
                self.xkb_ctx,
                map_str.ptr,
                xkbcommon.XKB_KEYMAP_FORMAT_TEXT_V1,
                xkbcommon.XKB_KEYMAP_COMPILE_NO_FLAGS,
            );
            if (self.xkb_keymap) |keymap| {
                self.xkb_state = xkbcommon.xkb_state_new(keymap);
            } else {
                log.err("compositor keymap failed to compile; keyboard input is disabled", .{});
            }
            self.updateMods();
        },
        .enter => |e| {
            self.last_serial = e.serial;
            if (self.events.focus_fn) |f| f(self.events.focus_ud, true);
        },
        .leave => |e| {
            self.last_serial = e.serial;
            self.key_repeat.cancel();
            if (self.events.focus_fn) |f| f(self.events.focus_ud, false);
        },
        .key => |k| {
            self.last_serial = k.serial;
            const state = self.xkb_state orelse return;
            const keycode = k.key + 8;
            const action: input.Action = if (k.state == .pressed) .press else .release;

            _ = xkbcommon.xkb_state_update_key(state, keycode, @intCast(@intFromEnum(k.state)));
            self.updateMods();
            self.emitKey(keycode, action);

            switch (action) {
                .press => if (self.xkb_keymap) |keymap| {
                    if (xkbcommon.xkb_keymap_key_repeats(keymap, keycode) != 0) {
                        self.key_repeat.press(keycode, nowMs());
                    }
                },
                else => self.key_repeat.release(keycode),
            }
        },
        .modifiers => |m| {
            self.last_serial = m.serial;
            if (self.xkb_state) |st| {
                _ = xkbcommon.xkb_state_update_mask(
                    st,
                    m.mods_depressed,
                    m.mods_latched,
                    m.mods_locked,
                    m.group,
                    0,
                    0,
                );
                self.updateMods();
            }
        },
        .repeat_info => |r| self.key_repeat.configure(r.rate, r.delay),
    }
}

fn nowMs() i64 {
    return std.Io.Timestamp.now(global.io(), .awake).toMilliseconds();
}

fn unshiftedCodepoint(keysym: u32) u21 {
    if (keysym >= 0x20 and keysym <= 0x7e) {
        var c = keysym;
        if (c >= 'A' and c <= 'Z') c += 32;
        return @intCast(c);
    }
    if (keysym >= 0x1000000) return 0;
    if (keysym <= 0x10ffff) return @intCast(keysym);
    return 0;
}

fn onPointerEvent(
    ptr: *wl.Pointer,
    event: wl.Pointer.Event,
    self: *Seat,
) void {
    _ = ptr;
    switch (event) {
        .enter => |e| {
            self.last_serial = e.serial;
            self.pointer_x = e.surface_x.toDouble();
            self.pointer_y = e.surface_y.toDouble();
            if (self.events.cursor_fn) |f| f(self.events.cursor_ud, self.pointer_x, self.pointer_y, self.mods);
        },
        .leave => {},
        .motion => |m| {
            self.pointer_x = m.surface_x.toDouble();
            self.pointer_y = m.surface_y.toDouble();
            if (self.events.cursor_fn) |f| f(self.events.cursor_ud, self.pointer_x, self.pointer_y, self.mods);
        },
        .button => |b| {
            self.last_serial = b.serial;
            const btn: input.MouseButton = switch (b.button) {
                272 => .left,
                273 => .right,
                274 => .middle,
                275 => .eight,
                276 => .nine,
                else => return,
            };
            const action: input.MouseButtonState = if (b.state == .pressed) .press else .release;
            if (self.events.mouse_button_fn) |f| _ = f(self.events.mouse_button_ud, action, btn, self.mods);
        },
        .axis => |a| {
            const v = a.value.toDouble() / 15.0;
            if (a.axis == .vertical_scroll) {
                self.axis_v += v;
                if (@abs(self.axis_v) >= 1.0) {
                    const steps = @trunc(self.axis_v);
                    self.axis_v -= steps;
                    if (self.events.scroll_fn) |f| f(self.events.scroll_ud, 0, -steps, .{});
                }
            } else {
                self.axis_h += v;
                if (@abs(self.axis_h) >= 1.0) {
                    const steps = @trunc(self.axis_h);
                    self.axis_h -= steps;
                    if (self.events.scroll_fn) |f| f(self.events.scroll_ud, -steps, 0, .{});
                }
            }
        },
        .frame, .axis_source, .axis_stop, .axis_discrete, .axis_value120, .axis_relative_direction => {},
    }
}

test "unshifted codepoint folds ASCII upper to lower" {
    const testing = std.testing;
    try testing.expectEqual(@as(u21, 'a'), unshiftedCodepoint('A'));
    try testing.expectEqual(@as(u21, 'z'), unshiftedCodepoint('z'));
    try testing.expectEqual(@as(u21, '0'), unshiftedCodepoint('0'));
}

test "linux xkb keycode maps to physical key" {
    const testing = std.testing;
    var found_a = false;
    for (keycodes.entries) |entry| {
        if (entry.key == .key_a) {
            found_a = true;
            try testing.expect(entry.native > 0);
            break;
        }
    }
    try testing.expect(found_a);
}
