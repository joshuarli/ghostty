//! ALSA PCM playback through the kernel's character devices, without
//! libasound. The structs and ioctl numbers mirror `sound/asound.h`, and the
//! flow follows tinyalsa: open `/dev/snd/pcmC{card}D{device}p`, negotiate
//! hardware parameters, set software parameters, then write interleaved
//! frames with `SNDRV_PCM_IOCTL_WRITEI_FRAMES`.
//!
//! Only plain hardware devices exist at this level. There is no mixing
//! plugin, so a device another program holds open cannot be opened here.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

const log = std.log.scoped(.alsa);

comptime {
    if (builtin.os.tag != .linux) @compileError("ALSA is Linux only");
    if (@sizeOf(usize) != 8) @compileError("the ALSA structs here assume 64-bit unsigned long");
}

pub const Format = enum {
    s16,
    s32,
    f32,

    fn alsa(self: Format) u5 {
        return switch (self) {
            .s16 => 2,
            .s32 => 10,
            .f32 => 14,
        };
    }

    pub fn bytes(self: Format) usize {
        return switch (self) {
            .s16 => 2,
            .s32, .f32 => 4,
        };
    }
};

const Mask = extern struct { bits: [8]u32 };

const Interval = extern struct {
    min: u32,
    max: u32,
    flags: u32,

    const open_min: u32 = 1;
    const open_max: u32 = 2;
    const integer: u32 = 4;
    const empty: u32 = 8;
};

const mask_count = 3;
const interval_first = 8;
const interval_count = 12;

const param_access = 0;
const param_format = 1;
const param_subformat = 2;
const param_channels = 10;
const param_rate = 11;
const param_period_time = 12;
const param_period_size = 13;
const param_periods = 15;
const param_buffer_time = 16;
const param_buffer_size = 17;

const access_rw_interleaved = 3;
const subformat_std = 0;

const HwParams = extern struct {
    flags: u32,
    masks: [mask_count]Mask,
    mres: [5]Mask,
    intervals: [interval_count]Interval,
    ires: [9]Interval,
    rmask: u32,
    cmask: u32,
    info: u32,
    msbits: u32,
    rate_num: u32,
    rate_den: u32,
    fifo_size: u64,
    sync: [16]u8,
    reserved: [48]u8,

    fn any() HwParams {
        var p = std.mem.zeroes(HwParams);
        for (&p.masks) |*m| m.bits = @splat(0xffff_ffff);
        for (&p.intervals) |*i| i.* = .{ .min = 0, .max = std.math.maxInt(u32), .flags = 0 };
        p.rmask = std.math.maxInt(u32);
        p.info = std.math.maxInt(u32);
        return p;
    }

    fn setMask(self: *HwParams, param: usize, bit: u5) void {
        self.masks[param].bits = @splat(0);
        self.masks[param].bits[0] = @as(u32, 1) << bit;
    }

    fn setExact(self: *HwParams, param: usize, exact: u32) void {
        self.intervals[param - interval_first] = .{ .min = exact, .max = exact, .flags = Interval.integer };
    }

    fn setRange(self: *HwParams, param: usize, min: u32, max: u32) void {
        self.intervals[param - interval_first] = .{ .min = min, .max = max, .flags = Interval.integer };
    }

    fn value(self: *const HwParams, param: usize) u32 {
        return self.intervals[param - interval_first].min;
    }
};

const SwParams = extern struct {
    tstamp_mode: u32,
    period_step: u32,
    sleep_min: u32,
    avail_min: u64,
    xfer_align: u64,
    start_threshold: u64,
    stop_threshold: u64,
    silence_threshold: u64,
    silence_size: u64,
    boundary: u64,
    proto: u32,
    tstamp_type: u32,
    reserved: [56]u8,
};

const Xferi = extern struct {
    result: i64,
    buf: ?*const anyopaque,
    frames: u64,
};

const PcmInfo = extern struct {
    device: u32,
    subdevice: u32,
    stream: i32,
    card: i32,
    id: [64]u8,
    name: [80]u8,
    subname: [32]u8,
    rest: [96]u8,
};

comptime {
    const assert = std.debug.assert;
    assert(@sizeOf(Mask) == 32);
    assert(@sizeOf(Interval) == 12);
    assert(@sizeOf(HwParams) == 608);
    assert(@offsetOf(HwParams, "intervals") == 260);
    assert(@offsetOf(HwParams, "rmask") == 512);
    assert(@offsetOf(HwParams, "fifo_size") == 536);
    assert(@sizeOf(SwParams) == 136);
    assert(@offsetOf(SwParams, "avail_min") == 16);
    assert(@offsetOf(SwParams, "boundary") == 64);
    assert(@offsetOf(SwParams, "proto") == 72);
    assert(@sizeOf(Xferi) == 24);
    assert(@sizeOf(PcmInfo) == 288);
    assert(@offsetOf(PcmInfo, "name") == 80);
}

fn ioc(dir: u32, nr: u32, size: u32) u32 {
    return (dir << 30) | (size << 16) | (@as(u32, 'A') << 8) | nr;
}

const io_none = 0;
const io_write = 1;
const io_read = 2;

const ioctl_pversion = ioc(io_read, 0x00, @sizeOf(c_int));
const ioctl_info = ioc(io_read, 0x01, @sizeOf(PcmInfo));
const ioctl_hw_params = ioc(io_read | io_write, 0x11, @sizeOf(HwParams));
const ioctl_sw_params = ioc(io_read | io_write, 0x13, @sizeOf(SwParams));
const ioctl_prepare = ioc(io_none, 0x40, 0);
const ioctl_drop = ioc(io_none, 0x43, 0);
const ioctl_writei_frames = ioc(io_write, 0x50, @sizeOf(Xferi));

const protocol_major_mask: c_int = ~@as(c_int, 0xffff);
const protocol_major: c_int = 2 << 16;

pub const Error = error{
    NoDevice,
    Busy,
    Denied,
    Unsupported,
    Disconnected,
    Suspended,
    Unexpected,
};

fn failure(rc: usize) Error {
    return switch (linux.errno(rc)) {
        .NOENT, .NXIO, .NODEV => error.NoDevice,
        .BUSY => error.Busy,
        .ACCES, .PERM => error.Denied,
        .INVAL, .NOSYS, .NOTTY, .OPNOTSUPP => error.Unsupported,
        .STRPIPE => error.Suspended,
        .IO => error.Disconnected,
        else => error.Unexpected,
    };
}

fn ioctl(fd: i32, request: u32, arg: usize) Error!void {
    while (true) {
        const rc = linux.ioctl(fd, request, arg);
        switch (linux.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => return failure(rc),
        }
    }
}

pub const Device = struct {
    card: u32,
    device: u32,

    /// Parses `hw:CARD,DEVICE`, the plain numeric form.
    pub fn parse(text: []const u8) ?Device {
        const rest = std.mem.trim(u8, text, " ");
        const prefix = "hw:";
        if (!std.mem.startsWith(u8, rest, prefix)) return null;
        var it = std.mem.splitScalar(u8, rest[prefix.len..], ',');
        const card = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
        const device = std.fmt.parseInt(u32, it.next() orelse "0", 10) catch return null;
        if (it.next() != null) return null;
        return .{ .card = card, .device = device };
    }

    fn path(self: Device, buf: *[48]u8) [:0]const u8 {
        return std.fmt.bufPrintSentinel(buf, "/dev/snd/pcmC{d}D{d}p", .{ self.card, self.device }, 0) catch unreachable;
    }
};

pub const Config = struct {
    format: Format,
    rate: u32,
    period_frames: u32,
    buffer_frames: u32,
};

const candidate_rates = [_]u32{ 48_000, 44_100, 96_000, 32_000 };
const candidate_formats = [_]Format{ .s16, .s32, .f32 };

/// A buffer of at most 20 ms made of periods of at least 5 ms keeps key
/// clicks prompt without risking underruns on a busy machine.
const period_time_us = [2]u32{ 5_000, 10_000 };
const buffer_time_us = [2]u32{ 15_000, 20_000 };

pub const Pcm = struct {
    fd: i32,
    config: Config,

    pub fn open(device: Device) Error!Pcm {
        const fd = try openFd(device);
        errdefer _ = linux.close(fd);
        return setup(fd);
    }

    /// The device's name, such as `ALC269VC Analog`, or empty when unknown.
    fn nameOf(fd: i32, out: []u8) []const u8 {
        var info = std.mem.zeroes(PcmInfo);
        ioctl(fd, ioctl_info, @intFromPtr(&info)) catch return "";
        return copyName(&info.name, out);
    }

    fn openFd(device: Device) Error!i32 {
        var buf: [48]u8 = undefined;
        const flags: linux.O = .{ .ACCMODE = .RDWR, .NONBLOCK = true, .CLOEXEC = true };
        const rc = linux.open(device.path(&buf), flags, 0);
        if (linux.errno(rc) != .SUCCESS) return failure(rc);
        const fd: i32 = @intCast(rc);
        errdefer _ = linux.close(fd);

        var version: c_int = 0;
        try ioctl(fd, ioctl_pversion, @intFromPtr(&version));
        if (version & protocol_major_mask != protocol_major) return error.Unsupported;
        return fd;
    }

    fn setup(fd: i32) Error!Pcm {
        var self: Pcm = .{ .fd = fd, .config = undefined };
        self.config = try self.negotiate();
        try self.setSoftwareParams();
        try self.setBlocking();
        try ioctl(fd, ioctl_prepare, 0);
        return self;
    }

    pub fn close(self: *Pcm) void {
        _ = linux.ioctl(self.fd, ioctl_drop, 0);
        _ = linux.close(self.fd);
        self.fd = -1;
    }

    fn negotiate(self: *Pcm) Error!Config {
        for (candidate_rates) |rate| {
            for (candidate_formats) |format| {
                var params = HwParams.any();
                params.setMask(param_access, access_rw_interleaved);
                params.setMask(param_format, format.alsa());
                params.setMask(param_subformat, subformat_std);
                params.setExact(param_channels, 2);
                params.setExact(param_rate, rate);
                params.setRange(param_period_time, period_time_us[0], period_time_us[1]);
                params.setRange(param_buffer_time, buffer_time_us[0], buffer_time_us[1]);
                ioctl(self.fd, ioctl_hw_params, @intFromPtr(&params)) catch |err| switch (err) {
                    error.Unsupported => continue,
                    else => return err,
                };
                return .{
                    .format = format,
                    .rate = rate,
                    .period_frames = params.value(param_period_size),
                    .buffer_frames = params.value(param_buffer_size),
                };
            }
        }
        return error.Unsupported;
    }

    fn setSoftwareParams(self: *Pcm) Error!void {
        var sw = std.mem.zeroes(SwParams);
        sw.period_step = 1;
        sw.avail_min = self.config.period_frames;
        sw.xfer_align = 1;
        sw.start_threshold = self.config.period_frames;
        sw.stop_threshold = self.config.buffer_frames;
        try ioctl(self.fd, ioctl_sw_params, @intFromPtr(&sw));
    }

    fn setBlocking(self: *Pcm) Error!void {
        const current = linux.fcntl(self.fd, linux.F.GETFL, 0);
        if (linux.errno(current) != .SUCCESS) return failure(current);
        const flags: linux.O = @bitCast(@as(u32, @intCast(current)));
        var blocking = flags;
        blocking.NONBLOCK = false;
        const rc = linux.fcntl(self.fd, linux.F.SETFL, @as(u32, @bitCast(blocking)));
        if (linux.errno(rc) != .SUCCESS) return failure(rc);
    }

    /// Writes whole frames, blocking until the device accepts them. An
    /// underrun is recovered by preparing the device again and carrying on.
    pub fn write(self: *Pcm, data: []const u8) Error!void {
        const frame_bytes = self.config.format.bytes() * 2;
        var offset: usize = 0;
        while (offset < data.len) {
            const remaining = data[offset..];
            var x: Xferi = .{
                .result = 0,
                .buf = remaining.ptr,
                .frames = remaining.len / frame_bytes,
            };
            const rc = linux.ioctl(self.fd, ioctl_writei_frames, @intFromPtr(&x));
            switch (linux.errno(rc)) {
                .SUCCESS => offset += @as(usize, @intCast(x.result)) * frame_bytes,
                .INTR => {},
                .PIPE => try ioctl(self.fd, ioctl_prepare, 0),
                else => return failure(rc),
            }
        }
    }
};

fn copyName(name: []const u8, out: []u8) []const u8 {
    const len = std.mem.indexOfScalar(u8, name, 0) orelse name.len;
    const n = @min(len, out.len);
    @memcpy(out[0..n], name[0..n]);
    return out[0..n];
}

/// True for the HDMI and DisplayPort outputs that accept audio and play it
/// to a monitor, which are rarely what a key click is meant for.
pub fn isDisplayOutput(name: []const u8) bool {
    var lower: [80]u8 = undefined;
    const n = @min(name.len, lower.len);
    for (name[0..n], lower[0..n]) |c, *out| out.* = std.ascii.toLower(c);
    const text = lower[0..n];
    return std.mem.indexOf(u8, text, "hdmi") != null or
        std.mem.indexOf(u8, text, "displayport") != null;
}

const max_cards = 16;
const max_devices = 16;

pub const OpenAny = struct {
    pcm: Pcm,
    device: Device,
};

/// Opens the first playback device that is not a display output and is free.
pub fn openFirst() Error!OpenAny {
    var saw_busy = false;
    var saw_denied = false;
    var card: u32 = 0;
    while (card < max_cards) : (card += 1) {
        var device: u32 = 0;
        while (device < max_devices) : (device += 1) {
            const candidate: Device = .{ .card = card, .device = device };
            const fd = Pcm.openFd(candidate) catch |err| {
                switch (err) {
                    error.Busy => saw_busy = true,
                    error.Denied => saw_denied = true,
                    else => {},
                }
                continue;
            };
            var name_buf: [80]u8 = undefined;
            if (isDisplayOutput(Pcm.nameOf(fd, &name_buf))) {
                _ = linux.close(fd);
                continue;
            }
            const pcm = Pcm.setup(fd) catch {
                _ = linux.close(fd);
                continue;
            };
            return .{ .pcm = pcm, .device = candidate };
        }
    }
    if (saw_busy) return error.Busy;
    if (saw_denied) return error.Denied;
    return error.NoDevice;
}

test "struct layouts and ioctl numbers match the kernel header" {
    try std.testing.expectEqual(@as(u32, 0x80044100), ioctl_pversion);
    try std.testing.expectEqual(@as(u32, 0x81204101), ioctl_info);
    try std.testing.expectEqual(@as(u32, 0xc2604111), ioctl_hw_params);
    try std.testing.expectEqual(@as(u32, 0xc0884113), ioctl_sw_params);
    try std.testing.expectEqual(@as(u32, 0x4140), ioctl_prepare);
    try std.testing.expectEqual(@as(u32, 0x4143), ioctl_drop);
    try std.testing.expectEqual(@as(u32, 0x40184150), ioctl_writei_frames);
}

test "hardware parameters pin one format and leave the rest open" {
    var p = HwParams.any();
    p.setMask(param_format, Format.s32.alsa());
    p.setExact(param_rate, 44_100);
    p.setRange(param_buffer_time, 15_000, 20_000);

    try std.testing.expectEqual(@as(u32, 1 << 10), p.masks[param_format].bits[0]);
    try std.testing.expectEqual(@as(u32, 0), p.masks[param_format].bits[1]);
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), p.masks[param_access].bits[0]);
    try std.testing.expectEqual(@as(u32, 44_100), p.value(param_rate));
    try std.testing.expectEqual(@as(u32, 44_100), p.intervals[param_rate - interval_first].max);
    try std.testing.expectEqual(@as(u32, 20_000), p.intervals[param_buffer_time - interval_first].max);
    try std.testing.expectEqual(std.math.maxInt(u32), p.intervals[param_channels - interval_first].max);
}

test "device names parse as hw:card,device" {
    try std.testing.expectEqual(Device{ .card = 1, .device = 0 }, Device.parse("hw:1,0").?);
    try std.testing.expectEqual(Device{ .card = 2, .device = 0 }, Device.parse("hw:2").?);
    try std.testing.expectEqual(Device{ .card = 0, .device = 7 }, Device.parse(" hw:0,7 ").?);
    try std.testing.expect(Device.parse("default") == null);
    try std.testing.expect(Device.parse("hw:x,0") == null);
    try std.testing.expect(Device.parse("hw:1,2,3") == null);
}

test "device paths follow the kernel naming" {
    var buf: [48]u8 = undefined;
    try std.testing.expectEqualStrings("/dev/snd/pcmC1D0p", (Device{ .card = 1, .device = 0 }).path(&buf));
}

test "display outputs are recognized by name" {
    try std.testing.expect(isDisplayOutput("HDMI 0"));
    try std.testing.expect(isDisplayOutput("Intel DisplayPort 1"));
    try std.testing.expect(!isDisplayOutput("ALC892 Analog"));
}
