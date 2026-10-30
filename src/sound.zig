const std = @import("std");
const builtin = @import("builtin");
const engine = @import("sound/engine.zig");
const pack = @import("sound/pack.zig");

const log = std.log.scoped(.sound);

const license_text = @embedFile("sound/assets/LICENSE-kbsim.md");

export fn ghostty_keyboard_sound_license() [*:0]const u8 {
    return license_text;
}

pub const Action = engine.Action;
pub const Settings = engine.Settings;

pub const Sound = if (builtin.os.tag != .macos) struct {} else struct {
    const audio = @import("sound/audio.zig");
    const embed = @import("sound/embed.zig");

    alloc: std.mem.Allocator,
    shared: engine.Shared,
    view: pack.Pack,
    pack_copy: ?[]align(16) u8,
    ring: engine.PlayRing.Shared,
    voicer: engine.Voicer(256),
    keys: engine.KeyState,
    voiced: engine.VoicedKeys,
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
            .output = null,
        };
        self.view = try bindPack(alloc, &self.pack_copy);
        errdefer if (self.pack_copy) |bytes| alloc.free(bytes);
        const ends = engine.PlayRing.reset(&self.ring);
        self.voicer = engine.Voicer(256).init(&self.shared, &self.view, ends.producer, engine.nextSeed());
        self.shared.wake_hook = &audio.wake;
        self.output = try audio.Output.start(alloc, &self.shared, ends.consumer);
        return self;
    }

    pub fn deinit(self: *Sound) void {
        if (self.output) |output| {
            self.output = null;
            output.deinit();
        }
        if (self.pack_copy) |bytes| self.alloc.free(bytes);
        self.alloc.destroy(self);
    }

    pub fn apply(self: *Sound, settings: Settings) void {
        self.shared.setVolume(settings.volume);
        self.shared.release.store(settings.release, .monotonic);
        self.shared.variation.store(settings.variation, .monotonic);
        self.shared.spatial.store(settings.spatial, .monotonic);
        self.shared.enabled.store(settings.enabled, .monotonic);
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

fn bindPack(alloc: std.mem.Allocator, copy: *?[]align(16) u8) !pack.Pack {
    if (comptime builtin.os.tag != .macos) return error.Unsupported;
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
    _ = @import("sound/mixer.zig");
    if (comptime builtin.os.tag == .macos) {
        _ = @import("sound/audio.zig");
        _ = @import("sound/embed.zig");
    }
}

test "sound: kbsim license is embedded" {
    const text = std.mem.span(ghostty_keyboard_sound_license());
    try std.testing.expect(std.mem.indexOf(u8, text, "Thomas Lai") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Permission is hereby granted") != null);
}

test "sound: buckling spring pack parses" {
    if (comptime builtin.os.tag != .macos) return;
    const embed = @import("sound/embed.zig");
    const view = try pack.Pack.parse(&embed.pack);
    try std.testing.expectEqual(@as(u32, 44_100), view.sample_rate);
    try std.testing.expect(view.hasRelease());
    try std.testing.expectEqual(@as(usize, 12), view.clipCount());
    try std.testing.expect(!view.press(0x00).isNone());
    try std.testing.expect(!view.press(0x31).isNone());
    try std.testing.expect(!view.release(0x00).isNone());
}
