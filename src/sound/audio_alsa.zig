//! ALSA output for keyboard sound and the bell. One thread owns the device:
//! it opens it when a sound is queued, renders and writes one period at a
//! time while anything sounds, and closes it after a short silence so other
//! programs can use the card. The device is plain hardware access, with no
//! mixing plugin, so it fails to open while another program holds it.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const engine = @import("engine.zig");
const render = @import("render.zig");
const alsa = @import("alsa.zig");

comptime {
    if (builtin.os.tag != .linux) @compileError("ALSA output is Linux only");
}

const log = std.log.scoped(.sound);

/// A device held open costs other programs the card, so it is released
/// shortly after the last sound.
const idle_seconds: f64 = 2;
const max_period_frames = 4096;

const Selector = union(enum) {
    first_free,
    device: alsa.Device,
};

const Control = struct {
    shared: *engine.Shared,
    state: render.RenderState,
    selector: Selector,
    pcm: ?alsa.Pcm = null,
    idle_frames: u64 = 0,
    fail_logged: bool = false,

    fn run(self: *Control) void {
        while (!self.shared.shutdown.load(.acquire)) {
            if (self.pcm != null) {
                self.pump();
            } else if (!self.state.consumer.isEmpty()) {
                self.open();
            } else {
                park(self.shared);
            }
        }
        self.stop();
    }

    fn open(self: *Control) void {
        const opened: alsa.Error!struct { pcm: alsa.Pcm, device: alsa.Device } = switch (self.selector) {
            .first_free => if (alsa.openFirst()) |any| .{ .pcm = any.pcm, .device = any.device } else |err| err,
            .device => |device| if (alsa.Pcm.open(device)) |pcm| .{ .pcm = pcm, .device = device } else |err| err,
        };
        const found = opened catch |err| {
            self.noteFailure(err);
            self.discardPending();
            return;
        };
        if (found.pcm.config.period_frames > max_period_frames) {
            var pcm = found.pcm;
            pcm.close();
            self.noteFailure(error.Unsupported);
            self.discardPending();
            return;
        }
        self.pcm = found.pcm;
        const rate: f64 = @floatFromInt(found.pcm.config.rate);
        self.state.setOutRate(rate);
        self.idle_frames = render.idleFrames(rate, idle_seconds);
        self.shared.silent_frames.store(0, .monotonic);
        self.shared.audio_running.store(true, .seq_cst);
        self.fail_logged = false;
        log.debug("sound output started on hw:{d},{d} at {d} Hz", .{
            found.device.card,
            found.device.device,
            found.pcm.config.rate,
        });
    }

    fn pump(self: *Control) void {
        const pcm = &self.pcm.?;
        const frames: usize = pcm.config.period_frames;
        var left: [max_period_frames]f32 = undefined;
        var right: [max_period_frames]f32 = undefined;
        var bytes: [max_period_frames * 2 * 4]u8 = undefined;

        const result = render.renderInto(&self.state, left[0..frames], right[0..frames]);
        if (result.sounding or result.fresh) {
            self.shared.silent_frames.store(0, .monotonic);
        } else {
            _ = self.shared.silent_frames.fetchAdd(frames, .monotonic);
        }
        const len = interleave(pcm.config.format, left[0..frames], right[0..frames], &bytes);
        pcm.write(bytes[0..len]) catch |err| {
            self.noteFailure(err);
            self.stop();
            return;
        };
        if (self.shared.silent_frames.load(.monotonic) >= self.idle_frames) self.stop();
    }

    /// Releases the device. A sound queued just before this runs is seen
    /// by the next trip around `run`.
    fn stop(self: *Control) void {
        if (self.pcm) |*pcm| {
            pcm.close();
            log.debug("sound output stopped", .{});
        }
        self.pcm = null;
        self.shared.audio_running.store(false, .seq_cst);
        _ = self.shared.wake.fetchAdd(0, .seq_cst);
        self.state.clear();
    }

    /// Sounds queued while the device could not be opened are stale by the
    /// time it frees up, so they are dropped rather than replayed.
    fn discardPending(self: *Control) void {
        while (self.state.consumer.pop()) |_| {}
    }

    fn noteFailure(self: *Control, err: alsa.Error) void {
        if (self.fail_logged) return;
        self.fail_logged = true;
        switch (err) {
            error.Busy => log.warn("sound output unavailable: the audio device is in use by another program", .{}),
            error.Denied => log.warn("sound output unavailable: no permission to use /dev/snd; is the user in the audio group?", .{}),
            error.NoDevice => log.warn("sound output unavailable: no ALSA playback device found", .{}),
            else => log.warn("sound output failed: {t}", .{err}),
        }
    }
};

pub const Output = struct {
    alloc: std.mem.Allocator,
    control: *Control,
    thread: std.Thread,

    pub const Error = error{InvalidDevice} || std.mem.Allocator.Error || std.Thread.SpawnError;

    /// `device` is `hw:CARD,DEVICE`, or empty to use the first free
    /// playback device that is not an HDMI or DisplayPort output.
    pub fn start(
        alloc: std.mem.Allocator,
        shared: *engine.Shared,
        consumer: engine.PlayRing.Consumer,
        device: []const u8,
    ) Error!*Output {
        const selector: Selector = if (device.len == 0)
            .first_free
        else
            .{ .device = alsa.Device.parse(device) orelse return error.InvalidDevice };

        const control = try alloc.create(Control);
        errdefer alloc.destroy(control);
        control.* = .{
            .shared = shared,
            .state = .{ .shared = shared, .mixer = .init(48_000), .consumer = consumer },
            .selector = selector,
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
    _ = linux.futex_3arg(&flag.raw, .{ .cmd = .WAKE, .private = true }, 1);
}

fn park(shared: *engine.Shared) void {
    if (shared.wake.swap(0, .acquire) == 1) return;
    _ = linux.futex_4arg(&shared.wake.raw, .{ .cmd = .WAIT, .private = true }, 0, null);
}

/// Interleaves stereo float samples in the device's format and returns the
/// byte count written to `out`.
fn interleave(format: alsa.Format, left: []const f32, right: []const f32, out: []u8) usize {
    var offset: usize = 0;
    for (left, right) |l, r| {
        for ([2]f32{ l, r }) |sample| {
            const x = std.math.clamp(sample, -1, 1);
            switch (format) {
                .s16 => {
                    const v: i16 = @intFromFloat(@round(x * 32767));
                    std.mem.writeInt(i16, out[offset..][0..2], v, .little);
                    offset += 2;
                },
                .s32 => {
                    const v: i32 = @intFromFloat(@round(x * 2147483520.0));
                    std.mem.writeInt(i32, out[offset..][0..4], v, .little);
                    offset += 4;
                },
                .f32 => {
                    std.mem.writeInt(u32, out[offset..][0..4], @bitCast(x), .little);
                    offset += 4;
                },
            }
        }
    }
    return offset;
}

test "interleave writes left then right in every format" {
    const left = [_]f32{ 1.0, -1.0 };
    const right = [_]f32{ 0.0, 2.0 };
    var out: [16]u8 = undefined;

    const n16 = interleave(.s16, &left, &right, &out);
    try std.testing.expectEqual(@as(usize, 8), n16);
    try std.testing.expectEqual(@as(i16, 32767), std.mem.readInt(i16, out[0..2], .little));
    try std.testing.expectEqual(@as(i16, 0), std.mem.readInt(i16, out[2..4], .little));
    try std.testing.expectEqual(@as(i16, -32767), std.mem.readInt(i16, out[4..6], .little));
    try std.testing.expectEqual(@as(i16, 32767), std.mem.readInt(i16, out[6..8], .little));

    const n32 = interleave(.s32, &left, &right, &out);
    try std.testing.expectEqual(@as(usize, 16), n32);
    try std.testing.expect(std.mem.readInt(i32, out[0..4], .little) > 2_147_000_000);
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, out[4..8], .little));

    const nf = interleave(.f32, &left, &right, &out);
    try std.testing.expectEqual(@as(usize, 16), nf);
    try std.testing.expectEqual(@as(f32, 1.0), @as(f32, @bitCast(std.mem.readInt(u32, out[0..4], .little))));
    try std.testing.expectEqual(@as(f32, 1.0), @as(f32, @bitCast(std.mem.readInt(u32, out[12..16], .little))));
}

test "output rejects a device that is not hw:card,device" {
    var shared = engine.Shared.init(.{});
    var ring: engine.PlayRing.Shared = .{};
    const ends = engine.PlayRing.reset(&ring);
    try std.testing.expectError(
        error.InvalidDevice,
        Output.start(std.testing.allocator, &shared, ends.consumer, "default"),
    );
}
