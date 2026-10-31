//! CoreAudio output for keyboard sound. The render callback is real-time:
//! it allocates nothing, takes no locks, and does no I/O, logging, or
//! Objective-C.

const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine.zig");
const render_mod = @import("render.zig");

comptime {
    if (builtin.os.tag != .macos) @compileError("keyboard sound audio is macOS only");
}

const log = std.log.scoped(.sound);

const poll_ns: u64 = 500 * std.time.ns_per_ms;
const idle_ns: u64 = 15 * std.time.ns_per_s;
const buffer_frames: u32 = 128;
const max_frames: u32 = 4096;
const output_is_silence: u32 = 1 << 4;

const AudioComponent = *anyopaque;
const AudioUnit = *anyopaque;

const AudioComponentDescription = extern struct {
    component_type: u32,
    component_sub_type: u32,
    component_manufacturer: u32,
    component_flags: u32 = 0,
    component_flags_mask: u32 = 0,
};

const AudioStreamBasicDescription = extern struct {
    sample_rate: f64,
    format_id: u32,
    format_flags: u32,
    bytes_per_packet: u32,
    frames_per_packet: u32,
    bytes_per_frame: u32,
    channels_per_frame: u32,
    bits_per_channel: u32,
    reserved: u32 = 0,
};

const AudioBuffer = extern struct {
    number_channels: u32,
    data_byte_size: u32,
    data: ?*anyopaque,
};

const AudioBufferList = extern struct {
    number_buffers: u32,
    buffers: [1]AudioBuffer,
};

const RenderCallback = *const fn (
    ?*anyopaque,
    ?*u32,
    ?*const anyopaque,
    u32,
    u32,
    ?*AudioBufferList,
) callconv(.c) i32;

const RenderCallbackStruct = extern struct {
    input_proc: RenderCallback,
    input_proc_ref_con: ?*anyopaque,
};

comptime {
    if (@sizeOf(AudioStreamBasicDescription) != 40) @compileError("ASBD layout");
    if (@sizeOf(AudioComponentDescription) != 20) @compileError("component description layout");
    if (@sizeOf(AudioBuffer) != 16) @compileError("AudioBuffer layout");
    if (@sizeOf(AudioBufferList) != 24) @compileError("AudioBufferList layout");
}

fn fourcc(comptime code: *const [4]u8) u32 {
    return std.mem.readInt(u32, code, .big);
}

const unit_type_output = fourcc("auou");
const unit_subtype_default = fourcc("def ");
const unit_manufacturer_apple = fourcc("appl");
const format_linear_pcm = fourcc("lpcm");
const format_flag_float: u32 = 1;
const format_flag_packed: u32 = 1 << 3;
const format_flag_non_interleaved: u32 = 1 << 5;
const prop_stream_format: u32 = 8;
const prop_max_frames: u32 = 14;
const prop_render_callback: u32 = 23;
const prop_is_running: u32 = 2001;
const prop_buffer_frame_size = fourcc("fsiz");
const scope_global: u32 = 0;
const scope_input: u32 = 1;
const scope_output: u32 = 2;

extern "c" fn AudioComponentFindNext(component: ?AudioComponent, desc: *const AudioComponentDescription) ?AudioComponent;
extern "c" fn AudioComponentInstanceNew(component: AudioComponent, out: *AudioUnit) i32;
extern "c" fn AudioComponentInstanceDispose(unit: AudioUnit) i32;
extern "c" fn AudioUnitInitialize(unit: AudioUnit) i32;
extern "c" fn AudioUnitUninitialize(unit: AudioUnit) i32;
extern "c" fn AudioUnitSetProperty(unit: AudioUnit, id: u32, scope: u32, element: u32, data: ?*const anyopaque, size: u32) i32;
extern "c" fn AudioUnitGetProperty(unit: AudioUnit, id: u32, scope: u32, element: u32, data: ?*anyopaque, size: *u32) i32;
extern "c" fn AudioOutputUnitStart(unit: AudioUnit) i32;
extern "c" fn AudioOutputUnitStop(unit: AudioUnit) i32;
extern "c" fn pthread_setname_np(name: [*:0]const u8) void;

const RenderResult = render_mod.RenderResult;
const RenderState = render_mod.RenderState;
const renderInto = render_mod.renderInto;

fn discard(state: *RenderState, frames: usize) RenderResult {
    var fresh = false;
    var left: usize = frames;
    var scratch_l: [256]f32 = undefined;
    var scratch_r: [256]f32 = undefined;
    while (left > 0) {
        const n = @min(left, scratch_l.len);
        const result = renderInto(state, scratch_l[0..n], scratch_r[0..n]);
        fresh = fresh or result.fresh;
        left -= n;
    }
    return .{ .sounding = false, .fresh = fresh };
}

fn account(state: *RenderState, frames: usize, result: RenderResult, flags: ?*u32) void {
    if (result.sounding or result.fresh) {
        state.shared.silent_frames.store(0, .monotonic);
    } else {
        _ = state.shared.silent_frames.fetchAdd(frames, .monotonic);
        if (flags) |slot| slot.* |= output_is_silence;
    }
}

fn bufferSlice(list: *AudioBufferList) []AudioBuffer {
    if (list.number_buffers == 0) return &.{};
    const ptr: [*]AudioBuffer = @ptrCast(&list.buffers[0]);
    return ptr[0..list.number_buffers];
}

fn channel(buffer: *AudioBuffer, frames: usize) []f32 {
    const data = buffer.data orelse return &.{};
    const available = buffer.data_byte_size / @sizeOf(f32);
    const n = @min(frames, available);
    if (n == 0) return &.{};
    const ptr: [*]f32 = @ptrCast(@alignCast(data));
    return ptr[0..n];
}

fn render(
    ref_con: ?*anyopaque,
    flags: ?*u32,
    _: ?*const anyopaque,
    _: u32,
    frames: u32,
    data: ?*AudioBufferList,
) callconv(.c) i32 {
    const state: *RenderState = @ptrCast(@alignCast(ref_con orelse return 0));
    const n: usize = frames;
    const result = if (data) |list| stereo: {
        const bufs = bufferSlice(list);
        if (bufs.len < 2) {
            for (bufs) |*buf| @memset(channel(buf, n), 0);
            break :stereo discard(state, n);
        }
        const left = channel(&bufs[0], n);
        const right = channel(&bufs[1], n);
        const count = @min(left.len, right.len);
        const rendered = renderInto(state, left[0..count], right[0..count]);
        if (left.len > count) @memset(left[count..], 0);
        if (right.len > count) @memset(right[count..], 0);
        break :stereo rendered;
    } else discard(state, n);
    account(state, n, result, flags);
    return 0;
}

const Unit = struct {
    au: AudioUnit,
    rate: f64,
    initialized: bool,
    status: i32,

    fn open(state: *RenderState) ?Unit {
        const desc = AudioComponentDescription{
            .component_type = unit_type_output,
            .component_sub_type = unit_subtype_default,
            .component_manufacturer = unit_manufacturer_apple,
        };
        const component = AudioComponentFindNext(null, &desc) orelse return null;
        var au: AudioUnit = undefined;
        if (AudioComponentInstanceNew(component, &au) != 0) return null;
        var unit = Unit{ .au = au, .rate = 48_000, .initialized = false, .status = 0 };
        const callback = RenderCallbackStruct{
            .input_proc = render,
            .input_proc_ref_con = state,
        };
        if (!unit.set(prop_render_callback, scope_input, &callback)) {
            unit.dispose();
            return null;
        }
        return unit;
    }

    fn configure(self: *Unit) ?f64 {
        const hw = self.get(AudioStreamBasicDescription, prop_stream_format, scope_output) orelse return null;
        const rate = if (hw.sample_rate > 0 and std.math.isFinite(hw.sample_rate)) hw.sample_rate else 48_000;
        if (!self.initialized or rate != self.rate) {
            if (self.initialized) self.uninitialize();
            const format = AudioStreamBasicDescription{
                .sample_rate = rate,
                .format_id = format_linear_pcm,
                .format_flags = format_flag_float | format_flag_packed | format_flag_non_interleaved,
                .bytes_per_packet = 4,
                .frames_per_packet = 1,
                .bytes_per_frame = 4,
                .channels_per_frame = 2,
                .bits_per_channel = 32,
            };
            if (!self.set(prop_stream_format, scope_input, &format)) return null;
            if (!self.set(prop_max_frames, scope_global, &max_frames)) return null;
            self.status = AudioUnitInitialize(self.au);
            if (self.status != 0) return null;
            self.initialized = true;
            self.rate = rate;
        }
        const frames = self.get(u32, prop_buffer_frame_size, scope_global) orelse 0;
        if (frames != buffer_frames) {
            _ = self.set(prop_buffer_frame_size, scope_global, &buffer_frames);
        }
        return rate;
    }

    fn start(self: *Unit) i32 {
        self.status = AudioOutputUnitStart(self.au);
        return self.status;
    }

    fn halt(self: *Unit) void {
        _ = AudioOutputUnitStop(self.au);
        self.uninitialize();
    }

    fn uninitialize(self: *Unit) void {
        if (!self.initialized) return;
        _ = AudioUnitUninitialize(self.au);
        self.initialized = false;
    }

    fn dispose(self: *Unit) void {
        self.halt();
        _ = AudioComponentInstanceDispose(self.au);
    }

    fn isRunning(self: *Unit) bool {
        const running = self.get(u32, prop_is_running, scope_global) orelse return false;
        return running != 0;
    }

    fn set(self: *Unit, id: u32, scope: u32, value: anytype) bool {
        self.status = AudioUnitSetProperty(
            self.au,
            id,
            scope,
            0,
            value,
            @intCast(@sizeOf(@TypeOf(value.*))),
        );
        return self.status == 0;
    }

    fn get(self: *Unit, comptime T: type, id: u32, scope: u32) ?T {
        var value: T = undefined;
        var size: u32 = @intCast(@sizeOf(T));
        self.status = AudioUnitGetProperty(self.au, id, scope, 0, &value, &size);
        if (self.status != 0) return null;
        return value;
    }
};

const Control = struct {
    shared: *engine.Shared,
    state: RenderState,
    unit: ?Unit = null,
    running: bool = false,
    rate: f64 = 48_000,
    fail_logged: bool = false,

    fn run(self: *Control) void {
        pthread_setname_np("ghostty-sound");
        if (!self.shared.shutdown.load(.acquire)) _ = self.prepare();
        while (!self.shared.shutdown.load(.acquire)) {
            if (self.running) {
                park(self.shared, poll_ns);
                if (self.shared.shutdown.load(.acquire)) break;
                const silent = self.shared.silent_frames.load(.monotonic);
                const idle = silent >= render_mod.idleFrames(self.rate, 15.0);
                const alive = if (self.unit) |*unit| unit.isRunning() else false;
                if (idle or !alive) self.stop();
            } else if (self.hasPending()) {
                self.start();
                if (!self.running) park(self.shared, poll_ns);
            } else if (self.deviceHeld()) {
                park(self.shared, idle_ns);
                if (self.shared.shutdown.load(.acquire)) break;
                if (!self.running and !self.hasPending()) self.release();
            } else {
                park(self.shared, null);
            }
        }
        self.finish();
    }

    fn hasPending(self: *Control) bool {
        return !self.state.consumer.isEmpty();
    }

    fn live(self: *Control) *Unit {
        return if (self.unit) |*unit| unit else unreachable;
    }

    fn deviceHeld(self: *const Control) bool {
        return if (self.unit) |unit| unit.initialized else false;
    }

    fn prepare(self: *Control) bool {
        if (self.unit == null) {
            self.unit = Unit.open(&self.state) orelse {
                self.noteFailure("create", -1);
                return false;
            };
        }
        const unit = self.live();
        const rate = unit.configure() orelse {
            self.noteFailure("configure", unit.status);
            return false;
        };
        self.state.setOutRate(rate);
        self.rate = rate;
        return true;
    }

    fn start(self: *Control) void {
        if (self.shared.shutdown.load(.acquire)) return;
        if (!self.prepare()) return;
        self.shared.silent_frames.store(0, .monotonic);
        const status = self.live().start();
        if (status != 0) {
            self.noteFailure("start", status);
            return;
        }
        self.fail_logged = false;
        self.running = true;
        self.shared.audio_running.store(true, .seq_cst);
        log.debug("keyboard sound output started at {d} Hz", .{self.rate});
    }

    fn stop(self: *Control) void {
        if (self.unit) |*unit| unit.halt();
        self.running = false;
        self.shared.audio_running.store(false, .seq_cst);
        _ = self.shared.wake.fetchAdd(0, .seq_cst);
        self.state.clear();
        log.debug("keyboard sound output stopped", .{});
    }

    fn release(self: *Control) void {
        if (self.unit) |*unit| unit.uninitialize();
    }

    fn finish(self: *Control) void {
        if (self.unit) |*unit| unit.dispose();
        self.unit = null;
        self.running = false;
        self.shared.audio_running.store(false, .seq_cst);
        self.state.clear();
    }

    fn noteFailure(self: *Control, what: []const u8, status: i32) void {
        if (self.fail_logged) return;
        self.fail_logged = true;
        log.warn("keyboard sound {s} failed: OSStatus {d}", .{ what, status });
    }
};

pub const Output = struct {
    alloc: std.mem.Allocator,
    control: *Control,
    thread: std.Thread,

    pub fn start(
        alloc: std.mem.Allocator,
        shared: *engine.Shared,
        consumer: engine.PlayRing.Consumer,
    ) (std.mem.Allocator.Error || std.Thread.SpawnError)!*Output {
        const control = try alloc.create(Control);
        errdefer alloc.destroy(control);
        control.* = .{
            .shared = shared,
            .state = .{
                .shared = shared,
                .mixer = .init(48_000),
                .consumer = consumer,
            },
        };
        const output = try alloc.create(Output);
        errdefer alloc.destroy(output);
        if (shared.wake_hook == null) shared.wake_hook = &wake;
        output.* = .{
            .alloc = alloc,
            .control = control,
            .thread = try std.Thread.spawn(.{}, Control.run, .{control}),
        };
        return output;
    }

    pub fn deinit(self: *Output) void {
        const shared = self.control.shared;
        shared.shutdown.store(true, .release);
        shared.enabled.store(false, .monotonic);
        shared.wakeNow();
        self.thread.join();
        const alloc = self.alloc;
        alloc.destroy(self.control);
        alloc.destroy(self);
    }
};

pub fn wake(flag: *std.atomic.Value(u32)) void {
    const op: std.c.UL = .{
        .op = .COMPARE_AND_WAIT,
        .NO_ERRNO = true,
    };
    _ = std.c.__ulock_wake(op, &flag.raw, 0);
}

/// `__ulock_wait2` treats a timeout of 0 as forever, so a finite wait passes at least 1 ns.
fn park(shared: *engine.Shared, timeout_ns: ?u64) void {
    if (shared.wake.swap(0, .acquire) == 1) return;
    const op: std.c.UL = .{
        .op = .COMPARE_AND_WAIT,
        .NO_ERRNO = true,
    };
    const timeout: u64 = if (timeout_ns) |ns| @max(ns, 1) else 0;
    _ = std.c.__ulock_wait2(op, &shared.wake.raw, 0, timeout, 0);
}

test "sound: coreaudio struct sizes" {
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(AudioStreamBasicDescription));
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(AudioComponentDescription));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(AudioBuffer));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(AudioBufferList));
    try std.testing.expectEqual(@as(u32, 0x61756F75), unit_type_output);
}

test "sound: audio output starts and stops" {
    var shared = engine.Shared.init(.{ .focused = true });
    var ring: engine.PlayRing.Shared = .{};
    const ends = engine.PlayRing.reset(&ring);
    var cycle: usize = 0;
    while (cycle < 3) : (cycle += 1) {
        shared.shutdown.store(false, .monotonic);
        shared.enabled.store(true, .monotonic);
        shared.audio_running.store(false, .monotonic);
        shared.wake.store(0, .monotonic);
        const output = try Output.start(std.testing.allocator, &shared, ends.consumer);
        output.deinit();
    }
}
