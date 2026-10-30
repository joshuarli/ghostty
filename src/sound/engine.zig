const std = @import("std");
const mixer = @import("mixer.zig");
const pack = @import("pack.zig");

pub const pitch_jitter_cents: f32 = 8;
pub const gain_jitter_db: f32 = 0.4;
pub const pan_width: f32 = 0.4;

const ctrl_c_pitch: f32 = 0.7937;
const ctrl_d_pitch: f32 = 0.8909;
const esc_pitch: f32 = 1.1892;
const esc_gain: f32 = 0.7079;
const arrow_gain: f32 = 0.8;
const arrow_pitch_left: f32 = 0.8909;
const arrow_pitch_down: f32 = 0.9439;
const arrow_pitch_right: f32 = 1.0595;
const copy_pitch_first: f32 = 1.2599;
const copy_pitch_second: f32 = 1.5874;
const paste_pitch_first: f32 = 1.5874;
const paste_pitch_second: f32 = 1.2599;
const copy_paste_delay_us: u32 = 70_000;

pub const flag_fn: u64 = 0x0080_0000;
pub const dev_lctl: u64 = 0x0000_0001;
pub const dev_lshift: u64 = 0x0000_0002;
pub const dev_rshift: u64 = 0x0000_0004;
pub const dev_lcmd: u64 = 0x0000_0008;
pub const dev_rcmd: u64 = 0x0000_0010;
pub const dev_lalt: u64 = 0x0000_0020;
pub const dev_ralt: u64 = 0x0000_0040;
pub const dev_rctl: u64 = 0x0000_2000;
const dev_all: u64 = dev_lctl | dev_lshift | dev_rshift | dev_lcmd | dev_rcmd | dev_lalt | dev_ralt | dev_rctl;

pub const code = struct {
    pub const a: u8 = 0x00;
    pub const d: u8 = 0x02;
    pub const c: u8 = 0x08;
    pub const v: u8 = 0x09;
    pub const @"return": u8 = 0x24;
    pub const space: u8 = 0x31;
    pub const escape: u8 = 0x35;
    pub const right_command: u8 = 0x36;
    pub const command: u8 = 0x37;
    pub const shift: u8 = 0x38;
    pub const caps_lock: u8 = 0x39;
    pub const option: u8 = 0x3A;
    pub const control: u8 = 0x3B;
    pub const right_shift: u8 = 0x3C;
    pub const right_option: u8 = 0x3D;
    pub const right_control: u8 = 0x3E;
    pub const function: u8 = 0x3F;
    pub const left_arrow: u8 = 0x7B;
    pub const right_arrow: u8 = 0x7C;
    pub const down_arrow: u8 = 0x7D;
    pub const up_arrow: u8 = 0x7E;
};

const KeyGeom = struct { code: u8, row: u8, x: f32 };

pub const keys = [_]KeyGeom{
    .{ .code = 0x35, .row = 0, .x = 0.5 },
    .{ .code = 0x7A, .row = 0, .x = 2.5 },
    .{ .code = 0x78, .row = 0, .x = 3.5 },
    .{ .code = 0x63, .row = 0, .x = 4.5 },
    .{ .code = 0x76, .row = 0, .x = 5.5 },
    .{ .code = 0x60, .row = 0, .x = 7.0 },
    .{ .code = 0x61, .row = 0, .x = 8.0 },
    .{ .code = 0x62, .row = 0, .x = 9.0 },
    .{ .code = 0x64, .row = 0, .x = 10.0 },
    .{ .code = 0x65, .row = 0, .x = 11.5 },
    .{ .code = 0x6D, .row = 0, .x = 12.5 },
    .{ .code = 0x67, .row = 0, .x = 13.5 },
    .{ .code = 0x6F, .row = 0, .x = 14.5 },
    .{ .code = 0x69, .row = 0, .x = 15.75 },
    .{ .code = 0x6B, .row = 0, .x = 16.75 },
    .{ .code = 0x71, .row = 0, .x = 17.75 },
    .{ .code = 0x6A, .row = 0, .x = 19.0 },
    .{ .code = 0x40, .row = 0, .x = 20.0 },
    .{ .code = 0x4F, .row = 0, .x = 21.0 },
    .{ .code = 0x50, .row = 0, .x = 22.0 },
    .{ .code = 0x5A, .row = 0, .x = 22.5 },
    .{ .code = 0x4A, .row = 0, .x = 12.5 },
    .{ .code = 0x49, .row = 0, .x = 13.5 },
    .{ .code = 0x48, .row = 0, .x = 14.5 },
    .{ .code = 0x32, .row = 1, .x = 0.5 },
    .{ .code = 0x0A, .row = 1, .x = 0.5 },
    .{ .code = 0x12, .row = 1, .x = 1.5 },
    .{ .code = 0x13, .row = 1, .x = 2.5 },
    .{ .code = 0x14, .row = 1, .x = 3.5 },
    .{ .code = 0x15, .row = 1, .x = 4.5 },
    .{ .code = 0x17, .row = 1, .x = 5.5 },
    .{ .code = 0x16, .row = 1, .x = 6.5 },
    .{ .code = 0x1A, .row = 1, .x = 7.5 },
    .{ .code = 0x1C, .row = 1, .x = 8.5 },
    .{ .code = 0x19, .row = 1, .x = 9.5 },
    .{ .code = 0x1D, .row = 1, .x = 10.5 },
    .{ .code = 0x1B, .row = 1, .x = 11.5 },
    .{ .code = 0x18, .row = 1, .x = 12.5 },
    .{ .code = 0x5D, .row = 1, .x = 13.5 },
    .{ .code = 0x33, .row = 1, .x = 14.0 },
    .{ .code = 0x72, .row = 1, .x = 15.75 },
    .{ .code = 0x73, .row = 1, .x = 16.75 },
    .{ .code = 0x74, .row = 1, .x = 17.75 },
    .{ .code = 0x47, .row = 1, .x = 19.0 },
    .{ .code = 0x51, .row = 1, .x = 20.0 },
    .{ .code = 0x4B, .row = 1, .x = 21.0 },
    .{ .code = 0x43, .row = 1, .x = 22.0 },
    .{ .code = 0x30, .row = 2, .x = 0.75 },
    .{ .code = 0x0C, .row = 2, .x = 2.0 },
    .{ .code = 0x0D, .row = 2, .x = 3.0 },
    .{ .code = 0x0E, .row = 2, .x = 4.0 },
    .{ .code = 0x0F, .row = 2, .x = 5.0 },
    .{ .code = 0x11, .row = 2, .x = 6.0 },
    .{ .code = 0x10, .row = 2, .x = 7.0 },
    .{ .code = 0x20, .row = 2, .x = 8.0 },
    .{ .code = 0x22, .row = 2, .x = 9.0 },
    .{ .code = 0x1F, .row = 2, .x = 10.0 },
    .{ .code = 0x23, .row = 2, .x = 11.0 },
    .{ .code = 0x21, .row = 2, .x = 12.0 },
    .{ .code = 0x1E, .row = 2, .x = 13.0 },
    .{ .code = 0x2A, .row = 2, .x = 14.25 },
    .{ .code = 0x75, .row = 2, .x = 15.75 },
    .{ .code = 0x77, .row = 2, .x = 16.75 },
    .{ .code = 0x79, .row = 2, .x = 17.75 },
    .{ .code = 0x59, .row = 2, .x = 19.0 },
    .{ .code = 0x5B, .row = 2, .x = 20.0 },
    .{ .code = 0x5C, .row = 2, .x = 21.0 },
    .{ .code = 0x4E, .row = 2, .x = 22.0 },
    .{ .code = 0x39, .row = 3, .x = 0.875 },
    .{ .code = 0x00, .row = 3, .x = 2.25 },
    .{ .code = 0x01, .row = 3, .x = 3.25 },
    .{ .code = 0x02, .row = 3, .x = 4.25 },
    .{ .code = 0x03, .row = 3, .x = 5.25 },
    .{ .code = 0x05, .row = 3, .x = 6.25 },
    .{ .code = 0x04, .row = 3, .x = 7.25 },
    .{ .code = 0x26, .row = 3, .x = 8.25 },
    .{ .code = 0x28, .row = 3, .x = 9.25 },
    .{ .code = 0x25, .row = 3, .x = 10.25 },
    .{ .code = 0x29, .row = 3, .x = 11.25 },
    .{ .code = 0x27, .row = 3, .x = 12.25 },
    .{ .code = 0x24, .row = 3, .x = 13.875 },
    .{ .code = 0x56, .row = 3, .x = 19.0 },
    .{ .code = 0x57, .row = 3, .x = 20.0 },
    .{ .code = 0x58, .row = 3, .x = 21.0 },
    .{ .code = 0x45, .row = 3, .x = 22.0 },
    .{ .code = 0x38, .row = 4, .x = 1.125 },
    .{ .code = 0x06, .row = 4, .x = 2.75 },
    .{ .code = 0x07, .row = 4, .x = 3.75 },
    .{ .code = 0x08, .row = 4, .x = 4.75 },
    .{ .code = 0x09, .row = 4, .x = 5.75 },
    .{ .code = 0x0B, .row = 4, .x = 6.75 },
    .{ .code = 0x2D, .row = 4, .x = 7.75 },
    .{ .code = 0x2E, .row = 4, .x = 8.75 },
    .{ .code = 0x2B, .row = 4, .x = 9.75 },
    .{ .code = 0x2F, .row = 4, .x = 10.75 },
    .{ .code = 0x2C, .row = 4, .x = 11.75 },
    .{ .code = 0x5E, .row = 4, .x = 12.75 },
    .{ .code = 0x3C, .row = 4, .x = 13.625 },
    .{ .code = 0x7E, .row = 4, .x = 16.75 },
    .{ .code = 0x53, .row = 4, .x = 19.0 },
    .{ .code = 0x54, .row = 4, .x = 20.0 },
    .{ .code = 0x55, .row = 4, .x = 21.0 },
    .{ .code = 0x4C, .row = 4, .x = 22.0 },
    .{ .code = 0x3F, .row = 5, .x = 0.5 },
    .{ .code = 0x3B, .row = 5, .x = 1.5 },
    .{ .code = 0x3A, .row = 5, .x = 2.5 },
    .{ .code = 0x37, .row = 5, .x = 3.75 },
    .{ .code = 0x66, .row = 5, .x = 4.75 },
    .{ .code = 0x31, .row = 5, .x = 7.0 },
    .{ .code = 0x68, .row = 5, .x = 9.25 },
    .{ .code = 0x36, .row = 5, .x = 10.25 },
    .{ .code = 0x3D, .row = 5, .x = 11.25 },
    .{ .code = 0x3E, .row = 5, .x = 12.5 },
    .{ .code = 0x6E, .row = 5, .x = 13.5 },
    .{ .code = 0x7B, .row = 5, .x = 15.75 },
    .{ .code = 0x7D, .row = 5, .x = 16.75 },
    .{ .code = 0x7C, .row = 5, .x = 17.75 },
    .{ .code = 0x52, .row = 5, .x = 19.5 },
    .{ .code = 0x41, .row = 5, .x = 21.0 },
    .{ .code = 0x5F, .row = 5, .x = 22.0 },
};

pub const Action = enum(c_int) {
    down = 1,
    up = 2,
    flags_changed = 3,
};

pub const Settings = struct {
    volume: f32 = 0.2,
    release: bool = true,
    variation: bool = true,
    spatial: bool = true,
    focused: bool = false,
    enabled: bool = true,
};

pub const Shared = struct {
    enabled: std.atomic.Value(bool) = .init(true),
    ghostty_active: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(true),
    variation: std.atomic.Value(bool) = .init(true),
    spatial: std.atomic.Value(bool) = .init(true),
    volume_bits: std.atomic.Value(u32) = .init(@bitCast(@as(f32, 1.0))),
    audio_running: std.atomic.Value(bool) = .init(false),
    silent_frames: std.atomic.Value(u64) = .init(0),
    shutdown: std.atomic.Value(bool) = .init(false),
    drop_before: std.atomic.Value(u64) = .init(0),
    next_seq: std.atomic.Value(u64) = .init(0),
    wake: std.atomic.Value(u32) = .init(0),
    wake_hook: ?*const fn (*std.atomic.Value(u32)) void = null,
    key_events: std.atomic.Value(u64) = .init(0),
    plays: std.atomic.Value(u64) = .init(0),
    dropped: std.atomic.Value(u64) = .init(0),

    pub fn init(s: Settings) Shared {
        var shared: Shared = .{};
        shared.setVolume(s.volume);
        shared.enabled.store(s.enabled, .monotonic);
        shared.ghostty_active.store(s.focused, .release);
        shared.release.store(s.release, .monotonic);
        shared.variation.store(s.variation, .monotonic);
        shared.spatial.store(s.spatial, .monotonic);
        return shared;
    }

    pub fn volume(self: *const Shared) f32 {
        return @bitCast(self.volume_bits.load(.monotonic));
    }

    pub fn setVolume(self: *Shared, value: f32) void {
        const clamped: f32 = if (!std.math.isFinite(value)) 0 else std.math.clamp(value, 0, 1);
        self.volume_bits.store(@bitCast(clamped), .monotonic);
    }

    pub fn masterGain(self: *const Shared) f32 {
        const v = self.volume();
        return v * v;
    }

    pub fn requestStart(self: *Shared) void {
        // SeqCst RMW: the play is visible to a stop that already observed a running device.
        _ = self.wake.fetchAdd(0, .seq_cst);
        if (self.audio_running.load(.seq_cst)) return;
        self.wake.store(1, .release);
        if (self.wake_hook) |hook| hook(&self.wake);
    }

    pub fn wakeNow(self: *Shared) void {
        self.wake.store(1, .release);
        if (self.wake_hook) |hook| hook(&self.wake);
    }
};

var seed_state: std.atomic.Value(u32) = .init(0x9E3779B9);

pub fn nextSeed() u32 {
    return seed_state.fetchAdd(0x85EBCA6B, .monotonic) | 1;
}

pub const Rng = struct {
    state: u32,

    pub fn init(seed: u32) Rng {
        return .{ .state = if (seed == 0) 0x9E3779B9 else seed };
    }

    pub fn next(self: *Rng) u32 {
        var x = self.state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.state = x;
        return x;
    }

    pub fn unit(self: *Rng) f32 {
        return @as(f32, @floatFromInt(self.next() >> 8)) / 16_777_216.0;
    }

    pub fn range(self: *Rng, lo: f32, hi: f32) f32 {
        return lo + (hi - lo) * self.unit();
    }
};

pub fn Ring(comptime T: type, comptime capacity: usize) type {
    comptime {
        if (capacity < 2 or capacity & (capacity - 1) != 0) {
            @compileError("ring capacity must be a power of two >= 2");
        }
    }
    const Memory = struct {
        head: std.atomic.Value(usize) align(128) = .init(0),
        tail: std.atomic.Value(usize) align(128) = .init(0),
        slots: [capacity]T = undefined,
    };
    return struct {
        const mask: usize = capacity - 1;

        pub const Shared = Memory;

        pub const Producer = struct {
            shared: *Memory,
            cached_head: usize,

            pub fn push(self: *Producer, item: T) bool {
                const tail = self.shared.tail.load(.monotonic);
                if (tail -% self.cached_head > mask) {
                    self.cached_head = self.shared.head.load(.acquire);
                    if (tail -% self.cached_head > mask) return false;
                }
                self.shared.slots[tail & mask] = item;
                self.shared.tail.store(tail +% 1, .release);
                return true;
            }
        };

        pub const Consumer = struct {
            shared: *Memory,
            cached_tail: usize,

            pub fn pop(self: *Consumer) ?T {
                const head = self.shared.head.load(.monotonic);
                if (head == self.cached_tail) {
                    self.cached_tail = self.shared.tail.load(.acquire);
                    if (head == self.cached_tail) return null;
                }
                const item = self.shared.slots[head & mask];
                self.shared.head.store(head +% 1, .release);
                return item;
            }

            /// The control thread may call this only while the render callback is not running.
            pub fn isEmpty(self: *const Consumer) bool {
                return self.shared.head.load(.monotonic) == self.shared.tail.load(.acquire);
            }
        };

        pub const Ends = struct { producer: Producer, consumer: Consumer };

        pub fn reset(shared: *Memory) Ends {
            shared.head.store(0, .monotonic);
            shared.tail.store(0, .monotonic);
            return .{
                .producer = .{ .shared = shared, .cached_head = 0 },
                .consumer = .{ .shared = shared, .cached_tail = 0 },
            };
        }
    };
}

pub const PlayRing = Ring(mixer.Play, 256);

pub const Transition = struct { keycode: u8, down: bool };

pub const KeyState = struct {
    pressed: [2]u64 = .{ 0, 0 },

    pub fn isPressed(self: *const KeyState, keycode: u8) bool {
        return self.pressed[keycode >> 6] & (@as(u64, 1) << @intCast(keycode & 63)) != 0;
    }

    pub fn ctrlHeld(self: *const KeyState) bool {
        return self.isPressed(code.control) or self.isPressed(code.right_control);
    }

    pub fn cmdHeld(self: *const KeyState) bool {
        return self.isPressed(code.command) or self.isPressed(code.right_command);
    }

    pub fn clear(self: *KeyState) void {
        self.pressed = .{ 0, 0 };
    }

    pub fn keyDown(self: *KeyState, keycode: u16, autorepeat: bool) ?Transition {
        const key = valid(keycode) orelse return null;
        if (autorepeat or self.isPressed(key)) return null;
        self.set(key, true);
        return .{ .keycode = key, .down = true };
    }

    pub fn keyUp(self: *KeyState, keycode: u16) ?Transition {
        const key = valid(keycode) orelse return null;
        if (!self.isPressed(key)) return null;
        self.set(key, false);
        return .{ .keycode = key, .down = false };
    }

    pub fn flagsChanged(self: *KeyState, keycode: u16, flags: u64) ?Transition {
        const key = valid(keycode) orelse return null;
        const down = switch (key) {
            code.caps_lock => return .{ .keycode = key, .down = true },
            code.function => flags & flag_fn != 0,
            else => blk: {
                const bit = deviceBit(key) orelse return null;
                break :blk if (flags & dev_all != 0) flags & bit != 0 else !self.isPressed(key);
            },
        };
        if (down == self.isPressed(key)) return null;
        self.set(key, down);
        return .{ .keycode = key, .down = down };
    }

    fn set(self: *KeyState, keycode: u8, down: bool) void {
        const mask = @as(u64, 1) << @intCast(keycode & 63);
        if (down) {
            self.pressed[keycode >> 6] |= mask;
        } else {
            self.pressed[keycode >> 6] &= ~mask;
        }
    }
};

fn valid(keycode: u16) ?u8 {
    if (keycode >= 128) return null;
    return @intCast(keycode);
}

fn deviceBit(keycode: u8) ?u64 {
    return switch (keycode) {
        0x38 => dev_lshift,
        0x3C => dev_rshift,
        0x3B => dev_lctl,
        0x3E => dev_rctl,
        0x3A => dev_lalt,
        0x3D => dev_ralt,
        0x37 => dev_lcmd,
        0x36 => dev_rcmd,
        else => null,
    };
}

pub const VoicedKeys = struct {
    bits: [2]u64 = .{ 0, 0 },

    pub fn press(self: *VoicedKeys, keycode: u8) void {
        if (keycode < 128) self.bits[keycode >> 6] |= @as(u64, 1) << @intCast(keycode & 63);
    }

    pub fn releaseWasVoiced(self: *VoicedKeys, keycode: u8) bool {
        if (keycode >= 128) return false;
        const mask = @as(u64, 1) << @intCast(keycode & 63);
        const was = self.bits[keycode >> 6] & mask != 0;
        self.bits[keycode >> 6] &= ~mask;
        return was;
    }

    pub fn clear(self: *VoicedKeys) void {
        self.bits = .{ 0, 0 };
    }
};

pub fn loseFocus(held: *KeyState, voiced: *VoicedKeys, shared: *Shared) void {
    shared.ghostty_active.store(false, .release);
    held.clear();
    voiced.clear();
    shared.drop_before.store(shared.next_seq.load(.monotonic), .release);
}

pub fn gainFocus(shared: *Shared) void {
    shared.ghostty_active.store(true, .release);
}

pub fn handleKey(
    held: *KeyState,
    voiced: *VoicedKeys,
    voicer: anytype,
    keycode: u16,
    action: Action,
    autorepeat: bool,
    flags: u64,
) void {
    if (!voicer.shared.ghostty_active.load(.acquire)) {
        held.clear();
        voiced.clear();
        return;
    }
    const event = switch (action) {
        .down => held.keyDown(keycode, autorepeat) orelse return,
        .up => held.keyUp(keycode) orelse return,
        .flags_changed => held.flagsChanged(keycode, flags) orelse return,
    };
    if (event.down) {
        if (voicer.key(event.keycode, true, held.ctrlHeld(), held.cmdHeld())) voiced.press(event.keycode);
    } else if (voiced.releaseWasVoiced(event.keycode)) {
        _ = voicer.key(event.keycode, false, held.ctrlHeld(), held.cmdHeld());
    }
}

const Special = struct {
    source: u8,
    pitch: f32,
    gain: f32,
    centered: bool,
    second_pitch: ?f32 = null,
    second_delay_us: u32 = 0,
};

fn specialVoice(keycode: u8, ctrl_held: bool, cmd_held: bool) ?Special {
    if (cmd_held) switch (keycode) {
        code.c => return .{
            .source = code.@"return",
            .pitch = copy_pitch_first,
            .gain = 1,
            .centered = true,
            .second_pitch = copy_pitch_second,
            .second_delay_us = copy_paste_delay_us,
        },
        code.v => return .{
            .source = code.@"return",
            .pitch = paste_pitch_first,
            .gain = 1,
            .centered = true,
            .second_pitch = paste_pitch_second,
            .second_delay_us = copy_paste_delay_us,
        },
        else => {},
    };
    if (ctrl_held) switch (keycode) {
        code.c => return .{ .source = code.@"return", .pitch = ctrl_c_pitch, .gain = 1, .centered = true },
        code.d => return .{ .source = code.@"return", .pitch = ctrl_d_pitch, .gain = 1, .centered = true },
        else => {},
    };
    return switch (keycode) {
        code.escape => .{ .source = code.escape, .pitch = esc_pitch, .gain = esc_gain, .centered = true },
        code.left_arrow => .{ .source = code.left_arrow, .pitch = arrow_pitch_left, .gain = arrow_gain, .centered = false },
        code.down_arrow => .{ .source = code.down_arrow, .pitch = arrow_pitch_down, .gain = arrow_gain, .centered = false },
        code.up_arrow => .{ .source = code.up_arrow, .pitch = 1, .gain = arrow_gain, .centered = false },
        code.right_arrow => .{ .source = code.right_arrow, .pitch = arrow_pitch_right, .gain = arrow_gain, .centered = false },
        else => null,
    };
}

pub fn Voicer(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        const Commands = Ring(mixer.Play, capacity);

        shared: *Shared,
        pack: *const pack.Pack,
        producer: Commands.Producer,
        rng: Rng,
        pan: [128]f32,
        last_choice: [128]u16,

        pub fn init(
            shared: *Shared,
            sound_pack: *const pack.Pack,
            producer: Commands.Producer,
            seed: u32,
        ) Self {
            var pan: [128]f32 = @splat(0);
            for (keys) |placed| pan[placed.code] = panForX(placed.x);
            return .{
                .shared = shared,
                .pack = sound_pack,
                .producer = producer,
                .rng = .init(seed),
                .pan = pan,
                .last_choice = @splat(std.math.maxInt(u16)),
            };
        }

        pub fn key(self: *Self, keycode: u8, down: bool, ctrl_held: bool, cmd_held: bool) bool {
            _ = self.shared.key_events.fetchAdd(1, .monotonic);
            if (!self.shared.enabled.load(.monotonic) or !self.shared.ghostty_active.load(.acquire)) return false;
            if (!down and !self.shared.release.load(.monotonic)) return false;
            if (down) if (specialVoice(keycode, ctrl_held, cmd_held)) |voice| return self.queueSpecial(keycode, voice);
            return self.queue(keycode, down, 0);
        }

        fn queue(self: *Self, keycode: u8, down: bool, delay_us: u32) bool {
            const clips = if (down) self.pack.press(keycode) else self.pack.release(keycode);
            if (clips.isNone()) return false;
            const index = self.choose(keycode, clips);
            var gain: f32 = 1;
            var pitch: f32 = 1;
            if (self.shared.variation.load(.monotonic)) {
                gain = dbToGain(self.rng.range(-gain_jitter_db, gain_jitter_db));
                pitch = centsToRatio(self.rng.range(-pitch_jitter_cents, pitch_jitter_cents));
            }
            const gains = if (self.shared.spatial.load(.monotonic))
                panGains(self.pan[keycode & 0x7F])
            else
                [2]f32{ 1, 1 };
            return self.emit(.{
                .samples = self.pack.clipWithGuards(index),
                .src_rate = self.pack.sample_rate,
                .pitch = pitch,
                .gain_l = gain * gains[0],
                .gain_r = gain * gains[1],
                .delay_us = delay_us,
            });
        }

        fn queueSpecial(self: *Self, keycode: u8, voice: Special) bool {
            const clips = self.pack.press(voice.source);
            if (clips.isNone()) return false;
            const gains = if (voice.centered)
                [2]f32{ 1, 1 }
            else
                panGains(self.pan[keycode & 0x7F]);
            const index = self.choose(voice.source, clips);
            const first = self.emit(.{
                .samples = self.pack.clipWithGuards(index),
                .src_rate = self.pack.sample_rate,
                .pitch = voice.pitch,
                .gain_l = voice.gain * gains[0],
                .gain_r = voice.gain * gains[1],
                .delay_us = 0,
            });
            const second_pitch = voice.second_pitch orelse return first;
            const second_index = self.choose(voice.source, clips);
            const second = self.emit(.{
                .samples = self.pack.clipWithGuards(second_index),
                .src_rate = self.pack.sample_rate,
                .pitch = second_pitch,
                .gain_l = voice.gain * gains[0],
                .gain_r = voice.gain * gains[1],
                .delay_us = voice.second_delay_us,
            });
            return first or second;
        }

        fn emit(self: *Self, play: mixer.Play) bool {
            var queued = play;
            queued.seq = self.shared.next_seq.fetchAdd(1, .monotonic);
            if (self.producer.push(queued)) {
                _ = self.shared.plays.fetchAdd(1, .monotonic);
                self.shared.requestStart();
                return true;
            }
            _ = self.shared.dropped.fetchAdd(1, .monotonic);
            return false;
        }

        fn choose(self: *Self, keycode: u8, clips: pack.ClipRef) usize {
            if (clips.count <= 1) return clips.first;
            const slot: usize = keycode & 0x7F;
            var pick: u16 = @intCast(self.rng.next() % clips.count);
            if (pick == self.last_choice[slot]) pick = (pick + 1) % clips.count;
            self.last_choice[slot] = pick;
            return @as(usize, clips.first) + pick;
        }
    };
}

pub fn panForX(x: f32) f32 {
    return std.math.clamp((x - 7.25) / 7.75, -1, 1) * pan_width;
}

pub fn panGains(pan: f32) [2]f32 {
    const angle: f32 = (std.math.clamp(pan, -1, 1) + 1) * @as(f32, std.math.pi / 4.0);
    const scale: f32 = @sqrt(2.0);
    return .{ @cos(angle) * scale, @sin(angle) * scale };
}

fn dbToGain(db: f32) f32 {
    return std.math.pow(f32, 10, db / 20.0);
}

fn centsToRatio(cents: f32) f32 {
    return std.math.pow(f32, 2, cents / 1200.0);
}

const tone: [64]i16 = @splat(1000);
const release_tone: [32]i16 = @splat(-1000);
const space_a: [48]i16 = @splat(2000);
const space_b: [48]i16 = @splat(3000);
const fixture_clips = [_][]const i16{ &tone, &release_tone, &space_a, &space_b };

fn fixtureData(with_release: bool) pack.PackData {
    var press: [pack.key_slots]pack.ClipRef = @splat(.{});
    var release: [pack.key_slots]pack.ClipRef = @splat(.{});
    for (keys) |key| {
        press[key.code] = .{ .first = 0, .count = 1 };
        if (with_release) release[key.code] = .{ .first = 1, .count = 1 };
    }
    press[code.space] = .{ .first = 2, .count = 2 };
    return .{
        .sample_rate = 44_100,
        .meta = .{ .id = "p", .category = "linear", .color = "#808080", .credit = "test", .is_default = true },
        .press = press,
        .release = release,
        .clips = &fixture_clips,
    };
}

const Harness = struct {
    alloc: std.mem.Allocator,
    bytes: []align(16) u8,
    view: pack.Pack,
    shared: Shared,
    ring: Ring(mixer.Play, 4).Shared,
    voicer: Voicer(4),
    consumer: Ring(mixer.Play, 4).Consumer,

    fn deinit(self: *Harness) void {
        const alloc = self.alloc;
        alloc.free(self.bytes);
        alloc.destroy(self);
    }
};

fn setup(alloc: std.mem.Allocator, with_release: bool) !*Harness {
    const h = try alloc.create(Harness);
    errdefer alloc.destroy(h);
    h.alloc = alloc;
    const raw = try pack.encode(alloc, fixtureData(with_release));
    defer alloc.free(raw);
    h.bytes = try alloc.alignedAlloc(u8, .@"16", raw.len);
    errdefer alloc.free(h.bytes);
    @memcpy(h.bytes, raw);
    h.view = try pack.Pack.parse(h.bytes);
    h.shared = Shared.init(.{ .focused = true, .variation = false, .spatial = false });
    const ends = Ring(mixer.Play, 4).reset(&h.ring);
    h.consumer = ends.consumer;
    h.voicer = .init(&h.shared, &h.view, ends.producer, 7);
    return h;
}

fn geom(keycode: u8) ?KeyGeom {
    for (keys) |key| if (key.code == keycode) return key;
    return null;
}

test "sound: rng zero seed still produces values" {
    var rng = Rng.init(0);
    try std.testing.expect(rng.next() != 0);
}

test "sound: rng range stays inside and covers the interval" {
    var rng = Rng.init(42);
    var lo: f32 = std.math.floatMax(f32);
    var hi: f32 = -std.math.floatMax(f32);
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        const x = rng.range(-8, 8);
        try std.testing.expect(x >= -8 and x < 8);
        lo = @min(lo, x);
        hi = @max(hi, x);
    }
    try std.testing.expect(lo < -7 and hi > 7);
}

test "sound: ring keeps fifo order up to capacity" {
    var shared: Ring(u32, 4).Shared = undefined;
    var ends = Ring(u32, 4).reset(&shared);
    var i: u32 = 0;
    while (i < 4) : (i += 1) try std.testing.expect(ends.producer.push(i));
    try std.testing.expect(!ends.producer.push(99));
    i = 0;
    while (i < 4) : (i += 1) try std.testing.expectEqual(i, ends.consumer.pop().?);
    try std.testing.expectEqual(@as(?u32, null), ends.consumer.pop());
    try std.testing.expect(ends.consumer.isEmpty());
}

test "sound: ring wraps" {
    var shared: Ring(u64, 8).Shared = undefined;
    var ends = Ring(u64, 8).reset(&shared);
    var i: u64 = 0;
    while (i < 10_000) : (i += 1) {
        try std.testing.expect(ends.producer.push(i));
        try std.testing.expect(!ends.consumer.isEmpty());
        try std.testing.expectEqual(i, ends.consumer.pop().?);
    }
}

test "sound: ring publication keeps every field" {
    const Word = struct { a: u64, b: u64, c: u64 };
    var shared: Ring(Word, 8).Shared = undefined;
    var ends = Ring(Word, 8).reset(&shared);
    var i: u64 = 0;
    while (i < 5_000) : (i += 1) {
        try std.testing.expect(ends.producer.push(.{ .a = i, .b = i ^ 0xFFFF, .c = i +% 7 }));
        const word = ends.consumer.pop().?;
        try std.testing.expectEqual(i, word.a);
        try std.testing.expectEqual(i ^ 0xFFFF, word.b);
        try std.testing.expectEqual(i +% 7, word.c);
    }
}

test "sound: ring concurrent stress preserves order" {
    const n: u64 = 200_000;
    var shared: Ring(u64, 64).Shared = undefined;
    var ends = Ring(u64, 64).reset(&shared);
    const producer = try std.Thread.spawn(.{}, struct {
        fn run(tx: Ring(u64, 64).Producer) void {
            var local = tx;
            var i: u64 = 0;
            while (i < n) : (i += 1) while (!local.push(i)) {};
        }
    }.run, .{ends.producer});
    var expected: u64 = 0;
    while (expected < n) {
        if (ends.consumer.pop()) |value| {
            try std.testing.expectEqual(expected, value);
            expected += 1;
        }
    }
    producer.join();
}

test "sound: key press and release" {
    var keys_state: KeyState = .{};
    try std.testing.expectEqual(Transition{ .keycode = 0, .down = true }, keys_state.keyDown(0, false).?);
    try std.testing.expectEqual(Transition{ .keycode = 0, .down = false }, keys_state.keyUp(0).?);
}

test "sound: autorepeat and duplicate downs are ignored" {
    var keys_state: KeyState = .{};
    _ = keys_state.keyDown(0, false);
    try std.testing.expectEqual(@as(?Transition, null), keys_state.keyDown(0, true));
    try std.testing.expectEqual(@as(?Transition, null), keys_state.keyDown(0, false));
}

test "sound: release without press is ignored" {
    var keys_state: KeyState = .{};
    try std.testing.expectEqual(@as(?Transition, null), keys_state.keyUp(0));
}

test "sound: out of range keycodes are ignored" {
    var keys_state: KeyState = .{};
    try std.testing.expectEqual(@as(?Transition, null), keys_state.keyDown(128, false));
    try std.testing.expectEqual(@as(?Transition, null), keys_state.keyDown(std.math.maxInt(u16), false));
    try std.testing.expectEqual(@as(?Transition, null), keys_state.flagsChanged(300, 0x0002_0000));
}

test "sound: shift uses device bits and both sides" {
    var keys_state: KeyState = .{};
    const flag_shift: u64 = 0x0002_0000;
    try std.testing.expectEqual(Transition{ .keycode = 0x38, .down = true }, keys_state.flagsChanged(0x38, flag_shift | dev_lshift).?);
    try std.testing.expectEqual(Transition{ .keycode = 0x38, .down = false }, keys_state.flagsChanged(0x38, 0).?);
    try std.testing.expectEqual(Transition{ .keycode = 0x38, .down = true }, keys_state.flagsChanged(0x38, flag_shift | dev_lshift).?);
    try std.testing.expectEqual(Transition{ .keycode = 0x3C, .down = true }, keys_state.flagsChanged(0x3C, flag_shift | dev_lshift | dev_rshift).?);
    try std.testing.expectEqual(Transition{ .keycode = 0x38, .down = false }, keys_state.flagsChanged(0x38, flag_shift | dev_rshift).?);
    try std.testing.expectEqual(Transition{ .keycode = 0x3C, .down = false }, keys_state.flagsChanged(0x3C, 0).?);
}

test "sound: modifiers without device bits toggle" {
    var keys_state: KeyState = .{};
    try std.testing.expectEqual(Transition{ .keycode = 0x38, .down = true }, keys_state.flagsChanged(0x38, 0x0002_0000).?);
    try std.testing.expectEqual(Transition{ .keycode = 0x38, .down = false }, keys_state.flagsChanged(0x38, 0).?);
    try std.testing.expectEqual(Transition{ .keycode = 0x37, .down = true }, keys_state.flagsChanged(0x37, 0x0010_0000).?);
    try std.testing.expectEqual(Transition{ .keycode = 0x37, .down = false }, keys_state.flagsChanged(0x37, 0).?);
}

test "sound: caps lock clicks on every change" {
    var keys_state: KeyState = .{};
    try std.testing.expectEqual(Transition{ .keycode = 0x39, .down = true }, keys_state.flagsChanged(0x39, 0x0001_0000).?);
    try std.testing.expectEqual(Transition{ .keycode = 0x39, .down = true }, keys_state.flagsChanged(0x39, 0).?);
    try std.testing.expect(!keys_state.isPressed(0x39));
}

test "sound: fn follows its flag" {
    var keys_state: KeyState = .{};
    try std.testing.expectEqual(Transition{ .keycode = 0x3F, .down = true }, keys_state.flagsChanged(0x3F, flag_fn).?);
    try std.testing.expectEqual(@as(?Transition, null), keys_state.flagsChanged(0x3F, flag_fn));
    try std.testing.expectEqual(Transition{ .keycode = 0x3F, .down = false }, keys_state.flagsChanged(0x3F, 0).?);
}

test "sound: non modifier flag changes are ignored" {
    var keys_state: KeyState = .{};
    try std.testing.expectEqual(@as(?Transition, null), keys_state.flagsChanged(0, 0x0002_0000));
}

test "sound: ctrl held tracks both control keys" {
    var keys_state: KeyState = .{};
    try std.testing.expect(!keys_state.ctrlHeld());
    _ = keys_state.flagsChanged(0x3B, 0x0004_0000 | dev_lctl);
    try std.testing.expect(keys_state.ctrlHeld());
    _ = keys_state.keyDown(0x08, false);
    try std.testing.expect(keys_state.ctrlHeld());
    _ = keys_state.flagsChanged(0x3B, 0);
    try std.testing.expect(!keys_state.ctrlHeld());
    _ = keys_state.flagsChanged(0x3E, 0x0004_0000 | dev_rctl);
    try std.testing.expect(keys_state.ctrlHeld());
}

test "sound: cmd held tracks both command keys" {
    var keys_state: KeyState = .{};
    try std.testing.expect(!keys_state.cmdHeld());
    _ = keys_state.flagsChanged(code.command, 0x0010_0000 | dev_lcmd);
    try std.testing.expect(keys_state.cmdHeld());
    _ = keys_state.keyDown(code.c, false);
    try std.testing.expect(keys_state.cmdHeld());
    _ = keys_state.flagsChanged(code.command, 0);
    try std.testing.expect(!keys_state.cmdHeld());
    _ = keys_state.flagsChanged(code.right_command, 0x0010_0000 | dev_rcmd);
    try std.testing.expect(keys_state.cmdHeld());
}

test "sound: voiced release matches the press that sounded" {
    var voiced: VoicedKeys = .{};
    try std.testing.expect(!voiced.releaseWasVoiced(0));
    voiced.press(0);
    try std.testing.expect(voiced.releaseWasVoiced(0));
    try std.testing.expect(!voiced.releaseWasVoiced(0));
    voiced.press(0x31);
    voiced.clear();
    try std.testing.expect(!voiced.releaseWasVoiced(0x31));
}

test "sound: geometry has each physical key once" {
    try std.testing.expectEqual(@as(usize, 120), keys.len);
    var seen: [128]bool = @splat(false);
    for (keys) |key| {
        try std.testing.expect(key.code < 128);
        try std.testing.expect(!seen[key.code]);
        seen[key.code] = true;
        try std.testing.expect(key.row <= 5);
        try std.testing.expect(key.x >= 0 and key.x <= 23);
    }
    try std.testing.expectEqual(@as(u8, 0), geom(code.escape).?.row);
    try std.testing.expectEqual(@as(u8, 1), geom(0x33).?.row);
    try std.testing.expectEqual(@as(u8, 2), geom(0x30).?.row);
    try std.testing.expectEqual(@as(u8, 3), geom(code.a).?.row);
    try std.testing.expectEqual(@as(u8, 3), geom(code.@"return").?.row);
    try std.testing.expectEqual(@as(u8, 4), geom(code.shift).?.row);
    try std.testing.expectEqual(@as(u8, 5), geom(code.space).?.row);
    try std.testing.expectEqual(@as(?KeyGeom, null), geom(0x34));
}

test "sound: letters run left to right" {
    const qwerty = [_]u8{ 0x0C, 0x0D, 0x0E, 0x0F, 0x11, 0x10, 0x20, 0x22, 0x1F, 0x23 };
    for (qwerty[0 .. qwerty.len - 1], qwerty[1..]) |left, right| {
        try std.testing.expect(geom(left).?.x < geom(right).?.x);
    }
    try std.testing.expect(geom(code.a).?.x < geom(0x26).?.x);
}

test "sound: pan law is unity at the centre" {
    const center = panGains(0);
    try std.testing.expect(@abs(center[0] - 1) < 1e-6);
    try std.testing.expect(@abs(center[1] - 1) < 1e-6);
    try std.testing.expect(panForX(0) < 0);
    try std.testing.expect(panForX(14) > 0);
    try std.testing.expectEqual(pan_width, panForX(22));
}

test "sound: key down queues the press clip at unity" {
    const alloc = std.testing.allocator;
    const h = try setup(alloc, false);
    defer h.deinit();
    try std.testing.expect(h.voicer.key(code.a, true, false, false));
    const play = h.consumer.pop().?;
    try std.testing.expectEqual(pack.guard_before + 64 + pack.guard_after, play.samples.len);
    try std.testing.expectEqual(@as(f32, 1), play.pitch);
    try std.testing.expectEqual(@as(f32, 1), play.gain_l);
    try std.testing.expectEqual(@as(f32, 1), play.gain_r);
    try std.testing.expectEqual(@as(u32, 0), play.delay_us);
    try std.testing.expectEqual(@as(u32, 44_100), play.src_rate);
    try std.testing.expectEqual(@as(u64, 1), h.shared.plays.load(.monotonic));
}

test "sound: disabled queues nothing" {
    const alloc = std.testing.allocator;
    const h = try setup(alloc, false);
    defer h.deinit();
    h.shared.enabled.store(false, .monotonic);
    try std.testing.expect(!h.voicer.key(code.a, true, false, false));
    try std.testing.expectEqual(@as(?mixer.Play, null), h.consumer.pop());
    try std.testing.expectEqual(@as(u64, 1), h.shared.key_events.load(.monotonic));
}

test "sound: release sounds follow the setting and the pack" {
    const alloc = std.testing.allocator;
    const h = try setup(alloc, true);
    defer h.deinit();
    try std.testing.expect(h.voicer.key(code.a, false, false, false));
    try std.testing.expectEqual(pack.guard_before + 32 + pack.guard_after, h.consumer.pop().?.samples.len);
    h.shared.release.store(false, .monotonic);
    try std.testing.expect(!h.voicer.key(code.a, false, false, false));
    const quiet = try setup(alloc, false);
    defer quiet.deinit();
    try std.testing.expect(!quiet.voicer.key(code.a, false, false, false));
}

test "sound: spatial pans left keys left and right keys right" {
    const alloc = std.testing.allocator;
    const h = try setup(alloc, false);
    defer h.deinit();
    h.shared.spatial.store(true, .monotonic);
    try std.testing.expect(h.voicer.key(code.a, true, false, false));
    const left = h.consumer.pop().?;
    try std.testing.expect(left.gain_l > left.gain_r);
    try std.testing.expect(h.voicer.key(code.@"return", true, false, false));
    const right = h.consumer.pop().?;
    try std.testing.expect(right.gain_r > right.gain_l);
    try std.testing.expect(@abs(left.gain_l * left.gain_l + left.gain_r * left.gain_r - 2) < 1e-4);
}

test "sound: variation stays within bounds" {
    const alloc = std.testing.allocator;
    const h = try setup(alloc, false);
    defer h.deinit();
    h.shared.variation.store(true, .monotonic);
    const max_pitch = centsToRatio(pitch_jitter_cents);
    const max_gain = dbToGain(gain_jitter_db);
    var seen: [200]u32 = undefined;
    var distinct: usize = 0;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        try std.testing.expect(h.voicer.key(code.a, true, false, false));
        const play = h.consumer.pop().?;
        try std.testing.expect(play.pitch <= max_pitch and play.pitch >= 1 / max_pitch);
        try std.testing.expect(play.gain_l <= max_gain and play.gain_l >= 1 / max_gain);
        const bits: u32 = @bitCast(play.pitch);
        var known = false;
        for (seen[0..distinct]) |item| if (item == bits) {
            known = true;
        };
        if (!known) {
            seen[distinct] = bits;
            distinct += 1;
        }
    }
    try std.testing.expect(distinct > 100);
}

test "sound: variants never repeat back to back" {
    const alloc = std.testing.allocator;
    const h = try setup(alloc, false);
    defer h.deinit();
    var last: ?[*]const i16 = null;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try std.testing.expect(h.voicer.key(code.space, true, false, false));
        const ptr = h.consumer.pop().?.samples.ptr;
        try std.testing.expect(last == null or last.? != ptr);
        last = ptr;
    }
}

test "sound: a full ring drops and counts" {
    const alloc = std.testing.allocator;
    const h = try setup(alloc, false);
    defer h.deinit();
    var i: usize = 0;
    while (i < 4) : (i += 1) try std.testing.expect(h.voicer.key(code.a, true, false, false));
    try std.testing.expect(!h.voicer.key(code.a, true, false, false));
    try std.testing.expectEqual(@as(u64, 1), h.shared.dropped.load(.monotonic));
}

test "sound: ctrl chords and arrows use the special voices" {
    const alloc = std.testing.allocator;
    const h = try setup(alloc, false);
    defer h.deinit();
    try std.testing.expect(h.voicer.key(code.c, true, true, false));
    const ctrl_c = h.consumer.pop().?;
    try std.testing.expectEqual(ctrl_c_pitch, ctrl_c.pitch);
    try std.testing.expectEqual(@as(f32, 1), ctrl_c.gain_l);
    try std.testing.expectEqual(@as(f32, 1), ctrl_c.gain_r);
    try std.testing.expect(h.voicer.key(code.d, true, true, false));
    try std.testing.expectEqual(ctrl_d_pitch, h.consumer.pop().?.pitch);
    try std.testing.expect(ctrl_d_pitch > ctrl_c_pitch);
    h.shared.variation.store(true, .monotonic);
    h.shared.spatial.store(true, .monotonic);
    try std.testing.expect(h.voicer.key(code.c, true, true, false));
    const steady = h.consumer.pop().?;
    try std.testing.expectEqual(ctrl_c_pitch, steady.pitch);
    try std.testing.expectEqual(@as(f32, 1), steady.gain_l);
    try std.testing.expect(h.voicer.key(code.c, true, false, false));
    try std.testing.expect(h.consumer.pop().?.pitch != ctrl_c_pitch);
    try std.testing.expect(h.voicer.key(code.a, true, true, false));
    const plain = h.consumer.pop().?;
    try std.testing.expect(plain.pitch <= centsToRatio(pitch_jitter_cents));
    try std.testing.expect(h.voicer.key(code.escape, true, false, false));
    const esc = h.consumer.pop().?;
    try std.testing.expectEqual(esc_pitch, esc.pitch);
    try std.testing.expectEqual(esc_gain, esc.gain_l);
    try std.testing.expectEqual(esc_gain, esc.gain_r);
    const arrows = [_]u8{ code.left_arrow, code.down_arrow, code.up_arrow, code.right_arrow };
    for (arrows) |key| try std.testing.expect(h.voicer.key(key, true, false, false));
    var pitches: [4]f32 = undefined;
    for (&pitches) |*pitch| pitch.* = h.consumer.pop().?.pitch;
    try std.testing.expect(pitches[0] < pitches[1] and pitches[1] < pitches[2] and pitches[2] < pitches[3]);
    try std.testing.expect(h.voicer.key(code.left_arrow, true, false, false));
    const arrow = h.consumer.pop().?;
    try std.testing.expectEqual(arrow_pitch_left, arrow.pitch);
    try std.testing.expect(arrow.gain_r > arrow.gain_l);
    const semitone = struct {
        fn of(pitch: f32) f32 {
            return @log2(pitch) * 12;
        }
    };
    try std.testing.expect(@abs(semitone.of(ctrl_c_pitch) + 4) < 0.01);
    try std.testing.expect(@abs(semitone.of(ctrl_d_pitch) + 2) < 0.01);
    try std.testing.expect(@abs(semitone.of(esc_pitch) - 3) < 0.01);
    try std.testing.expect(@abs(semitone.of(arrow_pitch_left) + 2) < 0.01);
    try std.testing.expect(@abs(semitone.of(arrow_pitch_down) + 1) < 0.01);
    try std.testing.expect(@abs(semitone.of(arrow_pitch_right) - 1) < 0.01);
}

test "sound: cmd copy and paste use mirrored two-note chimes" {
    const alloc = std.testing.allocator;
    const h = try setup(alloc, false);
    defer h.deinit();
    try std.testing.expect(h.voicer.key(code.c, true, false, true));
    const copy_first = h.consumer.pop().?;
    const copy_second = h.consumer.pop().?;
    try std.testing.expectEqual(copy_pitch_first, copy_first.pitch);
    try std.testing.expectEqual(copy_pitch_second, copy_second.pitch);
    try std.testing.expect(copy_second.pitch > copy_first.pitch);
    try std.testing.expectEqual(@as(f32, 1), copy_first.gain_l);
    try std.testing.expectEqual(@as(f32, 1), copy_first.gain_r);
    try std.testing.expectEqual(@as(u32, 0), copy_first.delay_us);
    try std.testing.expectEqual(copy_paste_delay_us, copy_second.delay_us);
    try std.testing.expect(h.voicer.key(code.v, true, false, true));
    const paste_first = h.consumer.pop().?;
    const paste_second = h.consumer.pop().?;
    try std.testing.expectEqual(paste_pitch_first, paste_first.pitch);
    try std.testing.expectEqual(paste_pitch_second, paste_second.pitch);
    try std.testing.expect(paste_second.pitch < paste_first.pitch);
    try std.testing.expectEqual(copy_pitch_first, paste_second.pitch);
    try std.testing.expectEqual(copy_pitch_second, paste_first.pitch);
    try std.testing.expectEqual(copy_paste_delay_us, paste_second.delay_us);
    try std.testing.expect(h.voicer.key(code.c, true, false, false));
    try std.testing.expect(h.consumer.pop().?.pitch != copy_pitch_first);
    try std.testing.expect(h.voicer.key(code.a, true, false, true));
    const plain_cmd = h.consumer.pop().?;
    try std.testing.expectEqual(@as(f32, 1), plain_cmd.pitch);
    try std.testing.expectEqual(@as(?mixer.Play, null), h.consumer.pop());
    h.shared.variation.store(true, .monotonic);
    h.shared.spatial.store(true, .monotonic);
    try std.testing.expect(h.voicer.key(code.c, true, false, true));
    const steady_first = h.consumer.pop().?;
    const steady_second = h.consumer.pop().?;
    try std.testing.expectEqual(copy_pitch_first, steady_first.pitch);
    try std.testing.expectEqual(copy_pitch_second, steady_second.pitch);
    try std.testing.expectEqual(@as(f32, 1), steady_first.gain_l);
    try std.testing.expectEqual(@as(f32, 1), steady_first.gain_r);
    try std.testing.expect(h.voicer.key(code.c, true, true, true));
    try std.testing.expectEqual(copy_pitch_first, h.consumer.pop().?.pitch);
    _ = h.consumer.pop();
    const semitone = struct {
        fn of(pitch: f32) f32 {
            return @log2(pitch) * 12;
        }
    };
    try std.testing.expect(@abs(semitone.of(copy_pitch_first) - 4) < 0.01);
    try std.testing.expect(@abs(semitone.of(copy_pitch_second) - 8) < 0.01);
}

test "sound: cmd copy chime follows held command keys" {
    const alloc = std.testing.allocator;
    const h = try setup(alloc, true);
    defer h.deinit();
    var keys_state: KeyState = .{};
    var voiced: VoicedKeys = .{};
    handleKey(&keys_state, &voiced, &h.voicer, code.command, .flags_changed, false, 0x0010_0000 | dev_lcmd);
    try std.testing.expect(keys_state.cmdHeld());
    _ = h.consumer.pop();
    handleKey(&keys_state, &voiced, &h.voicer, code.c, .down, false, 0);
    const first = h.consumer.pop().?;
    const second = h.consumer.pop().?;
    try std.testing.expectEqual(copy_pitch_first, first.pitch);
    try std.testing.expectEqual(copy_pitch_second, second.pitch);
    try std.testing.expectEqual(copy_paste_delay_us, second.delay_us);
    try std.testing.expectEqual(@as(?mixer.Play, null), h.consumer.pop());
}

test "sound: one physical press and release" {
    const alloc = std.testing.allocator;
    const h = try setup(alloc, true);
    defer h.deinit();
    var keys_state: KeyState = .{};
    var voiced: VoicedKeys = .{};
    handleKey(&keys_state, &voiced, &h.voicer, code.a, .down, false, 0);
    handleKey(&keys_state, &voiced, &h.voicer, code.a, .down, true, 0);
    handleKey(&keys_state, &voiced, &h.voicer, code.a, .down, false, 0);
    handleKey(&keys_state, &voiced, &h.voicer, code.a, .up, false, 0);
    try std.testing.expectEqual(pack.guard_before + 64 + pack.guard_after, h.consumer.pop().?.samples.len);
    try std.testing.expectEqual(pack.guard_before + 32 + pack.guard_after, h.consumer.pop().?.samples.len);
    try std.testing.expectEqual(@as(?mixer.Play, null), h.consumer.pop());
}

test "sound: focus loss clears held keys and drops queued plays" {
    const alloc = std.testing.allocator;
    const h = try setup(alloc, true);
    defer h.deinit();
    var keys_state: KeyState = .{};
    var voiced: VoicedKeys = .{};
    handleKey(&keys_state, &voiced, &h.voicer, code.a, .down, false, 0);
    const queued = h.consumer.pop().?;
    loseFocus(&keys_state, &voiced, &h.shared);
    try std.testing.expect(queued.seq < h.shared.drop_before.load(.acquire));
    try std.testing.expect(!h.shared.ghostty_active.load(.monotonic));
    handleKey(&keys_state, &voiced, &h.voicer, code.a, .up, false, 0);
    try std.testing.expectEqual(@as(?mixer.Play, null), h.consumer.pop());
    gainFocus(&h.shared);
    handleKey(&keys_state, &voiced, &h.voicer, code.a, .down, false, 0);
    try std.testing.expect(h.consumer.pop() != null);
}

test "sound: inactive events do not stick keys or sound" {
    const alloc = std.testing.allocator;
    const h = try setup(alloc, false);
    defer h.deinit();
    h.shared.ghostty_active.store(false, .release);
    var keys_state: KeyState = .{};
    var voiced: VoicedKeys = .{};
    handleKey(&keys_state, &voiced, &h.voicer, code.a, .down, false, 0);
    try std.testing.expect(!keys_state.isPressed(code.a));
    try std.testing.expectEqual(@as(?mixer.Play, null), h.consumer.pop());
}

test "sound: command modifier and caps each produce one attack" {
    const alloc = std.testing.allocator;
    const h = try setup(alloc, true);
    defer h.deinit();
    var keys_state: KeyState = .{};
    var voiced: VoicedKeys = .{};
    handleKey(&keys_state, &voiced, &h.voicer, code.command, .flags_changed, false, 0x0010_0000 | dev_lcmd);
    handleKey(&keys_state, &voiced, &h.voicer, code.command, .flags_changed, false, 0x0010_0000 | dev_lcmd);
    handleKey(&keys_state, &voiced, &h.voicer, code.a, .down, false, 0);
    handleKey(&keys_state, &voiced, &h.voicer, code.caps_lock, .flags_changed, false, 0x0001_0000);
    handleKey(&keys_state, &voiced, &h.voicer, code.caps_lock, .flags_changed, false, 0);
    try std.testing.expect(h.consumer.pop() != null);
    try std.testing.expect(h.consumer.pop() != null);
    try std.testing.expect(h.consumer.pop() != null);
    try std.testing.expect(h.consumer.pop() != null);
    try std.testing.expectEqual(@as(?mixer.Play, null), h.consumer.pop());
}
