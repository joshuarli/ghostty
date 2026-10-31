const std = @import("std");
const Allocator = std.mem.Allocator;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwp = wayland.client.zwp;

const log = std.log.scoped(.wayland);

/// Surface-local, in logical pixels.
pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const ImeEvents = struct {
    preedit_fn: ?*const fn (ud: ?*anyopaque, text: ?[]const u8) void = null,
    commit_fn: ?*const fn (ud: ?*anyopaque, text: []const u8) void = null,
    cursor_rect_fn: ?*const fn (ud: ?*anyopaque) ?Rect = null,
    ud: ?*anyopaque = null,
};

/// text-input-v3 batches `preedit_string` and `commit_string` and applies
/// them at `done`: the previous preedit is replaced, any commit is inserted,
/// and the new preedit follows. A batch without a preedit clears it.
pub const Composition = struct {
    alloc: Allocator,
    pending_preedit: std.ArrayListUnmanaged(u8) = .empty,
    has_pending_preedit: bool = false,
    pending_commit: std.ArrayListUnmanaged(u8) = .empty,
    has_pending_commit: bool = false,
    preedit_shown: bool = false,

    pub fn deinit(self: *Composition) void {
        self.pending_preedit.deinit(self.alloc);
        self.pending_commit.deinit(self.alloc);
    }

    pub fn setPreedit(self: *Composition, text: ?[]const u8) !void {
        self.pending_preedit.clearRetainingCapacity();
        self.has_pending_preedit = false;
        const bytes = text orelse return;
        try self.pending_preedit.appendSlice(self.alloc, bytes);
        self.has_pending_preedit = bytes.len > 0;
    }

    pub fn setCommit(self: *Composition, text: ?[]const u8) !void {
        self.pending_commit.clearRetainingCapacity();
        self.has_pending_commit = false;
        const bytes = text orelse return;
        try self.pending_commit.appendSlice(self.alloc, bytes);
        self.has_pending_commit = bytes.len > 0;
    }

    /// `sink` provides `preedit(?[]const u8)` and `commit([]const u8)`.
    pub fn done(self: *Composition, sink: anytype) void {
        const next: ?[]const u8 = if (self.has_pending_preedit) self.pending_preedit.items else null;
        if (self.has_pending_commit) {
            if (self.preedit_shown) sink.preedit(null);
            sink.commit(self.pending_commit.items);
            if (next) |text| sink.preedit(text);
        } else if (next) |text| {
            sink.preedit(text);
        } else if (self.preedit_shown) {
            sink.preedit(null);
        }
        self.preedit_shown = next != null;
        self.discardPending();
    }

    /// Drop unapplied state and any visible preedit, as when focus leaves.
    pub fn reset(self: *Composition, sink: anytype) void {
        self.discardPending();
        if (self.preedit_shown) sink.preedit(null);
        self.preedit_shown = false;
    }

    fn discardPending(self: *Composition) void {
        self.pending_preedit.clearRetainingCapacity();
        self.has_pending_preedit = false;
        self.pending_commit.clearRetainingCapacity();
        self.has_pending_commit = false;
    }
};

const Sink = struct {
    events: ImeEvents,

    fn preedit(self: Sink, text: ?[]const u8) void {
        if (self.events.preedit_fn) |f| f(self.events.ud, text);
    }

    fn commit(self: Sink, text: []const u8) void {
        if (self.events.commit_fn) |f| f(self.events.ud, text);
    }
};

/// The compositor sends `enter` and `leave` as keyboard focus moves, and the
/// client enables the input method only while it holds focus.
pub const TextInput = struct {
    alloc: Allocator,
    input: *zwp.TextInputV3,
    events: ImeEvents,
    composition: Composition,
    enabled: bool = false,
    sent_rect: ?Rect = null,

    pub fn create(
        alloc: Allocator,
        manager: *zwp.TextInputManagerV3,
        seat: *wl.Seat,
        events: ImeEvents,
    ) !*TextInput {
        const self = try alloc.create(TextInput);
        errdefer alloc.destroy(self);
        const input = try manager.getTextInput(seat);
        self.* = .{
            .alloc = alloc,
            .input = input,
            .events = events,
            .composition = .{ .alloc = alloc },
        };
        input.setListener(*TextInput, onEvent, self);
        return self;
    }

    pub fn destroy(self: *TextInput) void {
        self.input.destroy();
        self.composition.deinit();
        self.alloc.destroy(self);
    }

    /// Tell the compositor where to place its candidate window.
    pub fn refreshCursorRect(self: *TextInput) void {
        if (!self.enabled) return;
        if (self.sendCursorRect()) self.input.commit();
    }

    fn sendCursorRect(self: *TextInput) bool {
        const f = self.events.cursor_rect_fn orelse return false;
        const rect = f(self.events.ud) orelse return false;
        if (self.sent_rect) |sent| {
            if (std.meta.eql(sent, rect)) return false;
        }
        self.input.setCursorRectangle(rect.x, rect.y, rect.width, rect.height);
        self.sent_rect = rect;
        return true;
    }

    fn sink(self: *const TextInput) Sink {
        return .{ .events = self.events };
    }
};

fn onEvent(input: *zwp.TextInputV3, event: zwp.TextInputV3.Event, self: *TextInput) void {
    switch (event) {
        .enter => {
            self.enabled = true;
            self.sent_rect = null;
            input.enable();
            input.setContentType(.{}, .terminal);
            _ = self.sendCursorRect();
            input.commit();
        },
        .leave => {
            self.enabled = false;
            self.composition.reset(self.sink());
            input.disable();
            input.commit();
        },
        .preedit_string => |p| {
            const text: ?[]const u8 = if (p.text) |t| std.mem.span(t) else null;
            self.composition.setPreedit(text) catch |err| {
                log.err("input method preedit dropped err={}", .{err});
            };
        },
        .commit_string => |c| {
            const text: ?[]const u8 = if (c.text) |t| std.mem.span(t) else null;
            self.composition.setCommit(text) catch |err| {
                log.err("input method commit dropped err={}", .{err});
            };
        },
        .delete_surrounding_text => {},
        .done => {
            self.composition.done(self.sink());
            self.refreshCursorRect();
        },
    }
}

const Recorder = struct {
    log: std.ArrayListUnmanaged(u8) = .empty,
    alloc: Allocator,

    fn preedit(self: *Recorder, text: ?[]const u8) void {
        self.log.print(self.alloc, "P({s})", .{text orelse "-"}) catch unreachable;
    }

    fn commit(self: *Recorder, text: []const u8) void {
        self.log.print(self.alloc, "C({s})", .{text}) catch unreachable;
    }
};

fn expectBatch(
    comp: *Composition,
    rec: *Recorder,
    preedit: ?[]const u8,
    commit: ?[]const u8,
    expected: []const u8,
) !void {
    rec.log.clearRetainingCapacity();
    try comp.setPreedit(preedit);
    try comp.setCommit(commit);
    comp.done(rec);
    try std.testing.expectEqualStrings(expected, rec.log.items);
}

test "preedit updates replace, then commit clears and inserts" {
    const alloc = std.testing.allocator;
    var comp: Composition = .{ .alloc = alloc };
    defer comp.deinit();
    var rec: Recorder = .{ .alloc = alloc };
    defer rec.log.deinit(alloc);

    try expectBatch(&comp, &rec, "ka", null, "P(ka)");
    try expectBatch(&comp, &rec, "かn", null, "P(かn)");
    try expectBatch(&comp, &rec, null, "かん", "P(-)C(かん)");
    try expectBatch(&comp, &rec, null, null, "");
}

test "a commit with a follow-on preedit keeps composing" {
    const alloc = std.testing.allocator;
    var comp: Composition = .{ .alloc = alloc };
    defer comp.deinit();
    var rec: Recorder = .{ .alloc = alloc };
    defer rec.log.deinit(alloc);

    try expectBatch(&comp, &rec, "안", null, "P(안)");
    try expectBatch(&comp, &rec, "ㄴ", "안", "P(-)C(안)P(ㄴ)");
}

test "a commit without a visible preedit does not touch preedit" {
    const alloc = std.testing.allocator;
    var comp: Composition = .{ .alloc = alloc };
    defer comp.deinit();
    var rec: Recorder = .{ .alloc = alloc };
    defer rec.log.deinit(alloc);

    try expectBatch(&comp, &rec, null, "é", "C(é)");
}

test "an empty batch after a preedit clears it" {
    const alloc = std.testing.allocator;
    var comp: Composition = .{ .alloc = alloc };
    defer comp.deinit();
    var rec: Recorder = .{ .alloc = alloc };
    defer rec.log.deinit(alloc);

    try expectBatch(&comp, &rec, "ni", null, "P(ni)");
    try expectBatch(&comp, &rec, null, null, "P(-)");
    try expectBatch(&comp, &rec, "", null, "");
}

test "losing focus clears a visible preedit and drops pending text" {
    const alloc = std.testing.allocator;
    var comp: Composition = .{ .alloc = alloc };
    defer comp.deinit();
    var rec: Recorder = .{ .alloc = alloc };
    defer rec.log.deinit(alloc);

    try expectBatch(&comp, &rec, "ni", null, "P(ni)");
    try comp.setCommit("stale");
    rec.log.clearRetainingCapacity();
    comp.reset(&rec);
    try std.testing.expectEqualStrings("P(-)", rec.log.items);
    try expectBatch(&comp, &rec, null, null, "");
}
