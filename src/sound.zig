const std = @import("std");
const builtin = @import("builtin");
const engine = @import("sound/engine.zig");
const pack = @import("sound/pack.zig");
const bell = @import("sound/bell.zig");
const global = @import("global.zig");

const log = std.log.scoped(.sound);

const license_text = @embedFile("sound/assets/LICENSE-kbsim.md");

export fn ghostty_keyboard_sound_license() [*:0]const u8 {
    return license_text;
}

pub const Action = engine.Action;
pub const Settings = engine.Settings;
pub const Bell = engine.Bell;

/// Keyboard sound and the bell play on macOS through CoreAudio and on Linux
/// through ALSA. Other platforms have no output.
pub const supported = builtin.os.tag == .macos or builtin.os.tag == .linux;

pub const Sound = if (!supported) struct {} else struct {
    const audio = switch (builtin.os.tag) {
        .macos => @import("sound/audio.zig"),
        .linux => @import("sound/audio_alsa.zig"),
        else => unreachable,
    };
    const embed = @import("sound/embed.zig");

    alloc: std.mem.Allocator,
    shared: engine.Shared,
    view: pack.Pack,
    pack_copy: ?[]align(16) u8,
    ring: engine.PlayRing.Shared,
    voicer: engine.Voicer(256),
    keys: engine.KeyState,
    voiced: engine.VoicedKeys,
    bell_clip: ?bell.Clip,
    output: ?*audio.Output,

    pub fn create(alloc: std.mem.Allocator, settings: Settings) !*Sound {
        const self = try alloc.create(Sound);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .shared = engine.Shared.init(settings),
            .view = undefined,
            .pack_copy = null,
            .ring = .{},
            .voicer = undefined,
            .keys = .{},
            .voiced = .{},
            .bell_clip = null,
            .output = null,
        };
        self.view = try bindPack(alloc, &self.pack_copy);
        errdefer if (self.pack_copy) |bytes| alloc.free(bytes);
        if (settings.bell.enabled) self.bell_clip = try loadBell(alloc, settings.bell.path);
        errdefer if (self.bell_clip) |clip| clip.deinit(alloc);
        const ends = engine.PlayRing.reset(&self.ring);
        self.voicer = engine.Voicer(256).init(&self.shared, &self.view, ends.producer, engine.nextSeed());
        self.shared.wake_hook = &audio.wake;
        self.output = if (comptime builtin.os.tag == .macos)
            try audio.Output.start(alloc, &self.shared, ends.consumer)
        else
            try audio.Output.start(alloc, &self.shared, ends.consumer, settings.device);
        return self;
    }

    pub fn deinit(self: *Sound) void {
        if (self.output) |output| {
            self.output = null;
            output.deinit();
        }
        if (self.bell_clip) |clip| clip.deinit(self.alloc);
        if (self.pack_copy) |bytes| self.alloc.free(bytes);
        self.alloc.destroy(self);
    }

    pub fn apply(self: *Sound, settings: Settings) void {
        self.shared.setVolume(settings.volume);
        self.shared.release.store(settings.release, .monotonic);
        self.shared.variation.store(settings.variation, .monotonic);
        self.shared.spatial.store(settings.spatial, .monotonic);
        self.shared.enabled.store(settings.enabled, .monotonic);
        self.shared.applyBell(settings.bell);
    }

    /// Rings the bell. It sounds without keyboard focus and at its own volume.
    pub fn ringBell(self: *Sound) void {
        const clip = self.bell_clip orelse return;
        _ = self.voicer.ringBell(clip.samples, clip.rate);
    }

    pub fn setFocused(self: *Sound, focused: bool) void {
        if (focused) {
            engine.gainFocus(&self.shared);
        } else {
            engine.loseFocus(&self.keys, &self.voiced, &self.shared);
        }
    }

    pub fn key(self: *Sound, keycode: u16, action: Action, autorepeat: bool, flags: u64) void {
        engine.handleKey(&self.keys, &self.voiced, &self.voicer, keycode, action, autorepeat, flags);
    }
};

/// The custom bell file when it plays, otherwise the built-in tone.
fn loadBell(alloc: std.mem.Allocator, path: ?[]const u8) !bell.Clip {
    const file = path orelse return bell.tone(alloc);
    const data = std.Io.Dir.cwd().readFileAlloc(global.io(), file, alloc, .limited(32 << 20)) catch |err| {
        log.warn("bell-audio-path {s} cannot be read ({t}); using the built-in bell", .{ file, err });
        return bell.tone(alloc);
    };
    defer alloc.free(data);
    return bell.wav(alloc, data) catch |err| {
        log.warn("bell-audio-path {s} is not a playable PCM WAV file ({t}); using the built-in bell", .{ file, err });
        return bell.tone(alloc);
    };
}

fn bindPack(alloc: std.mem.Allocator, copy: *?[]align(16) u8) !pack.Pack {
    if (comptime !supported) return error.Unsupported;
    const embed = @import("sound/embed.zig");
    const bytes = &embed.pack;
    if (pack.Pack.parse(bytes)) |view| {
        return view;
    } else |err| switch (err) {
        error.Misaligned => {},
        else => return err,
    }
    const owned = try alloc.alignedAlloc(u8, .@"16", bytes.len);
    errdefer alloc.free(owned);
    @memcpy(owned, bytes);
    const view = try pack.Pack.parse(owned);
    copy.* = owned;
    return view;
}

test {
    _ = engine;
    _ = pack;
    _ = bell;
    _ = @import("sound/mixer.zig");
    _ = @import("sound/render.zig");
    switch (builtin.os.tag) {
        .macos => {
            _ = @import("sound/audio.zig");
            _ = @import("sound/embed.zig");
        },
        .linux => {
            _ = @import("sound/alsa.zig");
            _ = @import("sound/audio_alsa.zig");
            _ = @import("sound/embed.zig");
        },
        else => {},
    }
}

test "sound: kbsim license is embedded" {
    const text = std.mem.span(ghostty_keyboard_sound_license());
    try std.testing.expect(std.mem.indexOf(u8, text, "Thomas Lai") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Permission is hereby granted") != null);
}

test "sound: buckling spring pack parses" {
    if (comptime !supported) return;
    const embed = @import("sound/embed.zig");
    const view = try pack.Pack.parse(&embed.pack);
    try std.testing.expectEqual(@as(u32, 44_100), view.sample_rate);
    try std.testing.expect(view.hasRelease());
    try std.testing.expectEqual(@as(usize, 12), view.clipCount());
    try std.testing.expect(!view.press(0x00).isNone());
    try std.testing.expect(!view.press(0x31).isNone());
    try std.testing.expect(!view.release(0x00).isNone());
}
