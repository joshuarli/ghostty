/// Native foreground-color transitions for the terminal renderer.
///
/// When enabled, a cell that keeps its glyph but changes foreground color
/// fades from the previously displayed color to the new target color over
/// a configurable duration instead of snapping immediately. Background
/// colors always apply immediately and are never tracked here.
///
/// Design notes (see the task spec for full requirements):
///
/// - Interpolation happens on the CPU by rewriting the resolved RGB of
///   existing `CellText` instances. The GPU instance layout, shaders, and
///   all blending/color-space handling are untouched.
/// - All time is monotonic milliseconds; identical timestamps always
///   produce identical colors regardless of frame pacing.
/// - Colors are interpolated in sRGB u8 space with an ease-out cubic.
///   Endpoints are exact: t=0 yields `from`, t=1 yields `to`.
/// - State is bounded: one small entry per actively transitioning cell
///   (capped), plus fixed per-grid tracking arrays. No per-frame heap
///   allocation happens on the patch path.
const std = @import("std");
const Allocator = std.mem.Allocator;
const colorpkg = @import("../terminal/color.zig");

pub const RGB = colorpkg.RGB;

/// Upper bound for a configured transition duration. Larger values are
/// clamped in config finalization.
pub const max_duration_ms: u64 = 2000;

/// Upper bound for simultaneously tracked transitioning cells. Beyond
/// this, cells paint their target immediately. This bounds memory even
/// for full-screen color cycling.
pub const max_entries: u32 = 4096;

/// Kind of the last paint recorded for a grid cell.
pub const Kind = enum(u8) {
    /// Nothing plain was painted here (never painted, row changed,
    /// override active, invisible, preedit, ...). A new plain paint
    /// never starts a transition from this state.
    unknown = 0,
    /// A plain foreground paint (no selection/search/inverse override).
    /// A new plain paint with the same identity but a different color
    /// starts a transition from the recorded color.
    plain = 1,
    /// Painted while an override was active (selection, search
    /// highlight, inverse video, invisible, preedit). Never a
    /// transition source.
    override = 2,
};

/// Identity of the glyph painted in a cell. A transition only starts or
/// continues when the identity matches, so text changes never fade.
pub const Identity = packed struct(u32) {
    cp: u21 = 0,
    bold: bool = false,
    italic: bool = false,
    wide: u2 = 0,
    _pad: u7 = 0,

    pub fn eql(self: Identity, other: Identity) bool {
        return @as(u32, @bitCast(self)) == @as(u32, @bitCast(other));
    }
};

/// Ease-out cubic. Monotonic on [0,1] with no overshoot: f(0)=0, f(1)=1.
pub fn easeOut(t: f32) f32 {
    const u = 1 - t;
    return 1 - u * u * u;
}

/// Clamped linear progress in [0,1] for [start_ms, start_ms+duration_ms].
/// A zero duration is already complete.
pub fn progress(start_ms: u64, now_ms: u64, duration_ms: u64) f32 {
    if (duration_ms == 0) return 1;
    if (now_ms <= start_ms) return 0;
    const elapsed = now_ms - start_ms;
    if (elapsed >= duration_ms) return 1;
    return @as(f32, @floatFromInt(elapsed)) /
        @as(f32, @floatFromInt(duration_ms));
}

/// Interpolated color between endpoints at eased progress t in [0,1].
pub fn at(from: RGB, to: RGB, t: f32) RGB {
    const e = easeOut(@min(1, @max(0, t)));
    return .{
        .r = mix(from.r, to.r, e),
        .g = mix(from.g, to.g, e),
        .b = mix(from.b, to.b, e),
    };
}

fn mix(a: u8, b: u8, t: f32) u8 {
    const af: f32 = @floatFromInt(a);
    const bf: f32 = @floatFromInt(b);
    return @intFromFloat(@round(af + (bf - af) * t));
}

/// A single actively transitioning cell.
pub const Entry = struct {
    from: RGB,
    to: RGB,
    start_ms: u64,
    identity: Identity,
    /// Last color written for this entry. The per-frame patch only
    /// rewrites instances still holding this color, so decorations
    /// with explicit colors and override repaints are never touched.
    last: RGB,

    /// Currently displayed color. Exact endpoints at and beyond the
    /// duration bounds.
    pub fn colorAt(self: Entry, now_ms: u64, duration_ms: u64) RGB {
        return at(self.from, self.to, progress(
            self.start_ms,
            now_ms,
            duration_ms,
        ));
    }

    pub fn isDone(self: Entry, now_ms: u64, duration_ms: u64) bool {
        return progress(self.start_ms, now_ms, duration_ms) >= 1;
    }
};

/// Map key packing a (row, col) pair. Rows and cols are u16.
pub const Key = u32;

pub fn key(y: u16, x: u16) Key {
    return (@as(Key, y) << 16) | x;
}

pub fn keyRow(k: Key) u16 {
    return @intCast(k >> 16);
}

/// Per-grid transition bookkeeping owned by the renderer.
pub const State = struct {
    alloc: Allocator,
    entries: std.AutoHashMapUnmanaged(Key, Entry) = .{},

    /// Last resolved plain paint per cell (rows * cols).
    last_fg: []RGB = &.{},
    last_id: []Identity = &.{},
    kind: []Kind = &.{},

    /// Last seen terminal row identity per viewport row, for scroll
    /// and alternate-screen invalidation.
    row_serial: []u64 = &.{},
    row_y: []u16 = &.{},
    rows_synced: bool = false,

    rows: u16 = 0,
    cols: u16 = 0,

    pub fn init(alloc: Allocator) State {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *State) void {
        self.entries.deinit(self.alloc);
        self.alloc.free(self.last_fg);
        self.alloc.free(self.last_id);
        self.alloc.free(self.kind);
        self.alloc.free(self.row_serial);
        self.alloc.free(self.row_y);
        self.* = undefined;
    }

    pub fn count(self: *const State) usize {
        return self.entries.count();
    }

    /// Ensure tracking for a rows x cols grid. Reallocates (and drops
    /// all state) only when the size actually changes.
    pub fn ensureSize(
        self: *State,
        rows: u16,
        cols: u16,
    ) Allocator.Error!void {
        if (rows == self.rows and cols == self.cols and
            self.last_fg.len > 0) return;
        const cells: usize = @as(usize, rows) * cols;
        const last_fg = try self.alloc.alloc(RGB, cells);
        errdefer self.alloc.free(last_fg);
        const last_id = try self.alloc.alloc(Identity, cells);
        errdefer self.alloc.free(last_id);
        const kind = try self.alloc.alloc(Kind, cells);
        errdefer self.alloc.free(kind);
        const row_serial = try self.alloc.alloc(u64, rows);
        errdefer self.alloc.free(row_serial);
        const row_y = try self.alloc.alloc(u16, rows);
        errdefer self.alloc.free(row_y);

        self.alloc.free(self.last_fg);
        self.alloc.free(self.last_id);
        self.alloc.free(self.kind);
        self.alloc.free(self.row_serial);
        self.alloc.free(self.row_y);
        self.last_fg = last_fg;
        self.last_id = last_id;
        self.kind = kind;
        self.row_serial = row_serial;
        self.row_y = row_y;
        self.rows = rows;
        self.cols = cols;
        self.invalidateAll();
    }

    /// Drop everything. Next paints behave like first paint.
    pub fn invalidateAll(self: *State) void {
        self.entries.clearRetainingCapacity();
        @memset(self.kind, .unknown);
        self.rows_synced = false;
    }

    /// Drop state for one viewport row.
    pub fn invalidateRow(self: *State, y: u16) void {
        if (y >= self.rows) return;
        const cols: usize = self.cols;
        @memset(self.kind[@as(usize, y) * cols ..][0..cols], .unknown);
        var it = self.entries.iterator();
        var batch: [256]Key = undefined;
        while (true) {
            var n: usize = 0;
            while (it.next()) |kv| {
                if (keyRow(kv.key_ptr.*) != y) continue;
                batch[n] = kv.key_ptr.*;
                n += 1;
                if (n == batch.len) break;
            }
            if (n == 0) break;
            for (batch[0..n]) |k| _ = self.entries.remove(k);
        }
    }

    /// Sync stored row identities against the terminal. Rows whose
    /// identity changed (scroll, alt-screen, reflow) are invalidated.
    /// A majority change invalidates everything at once.
    pub fn syncRows(
        self: *State,
        serials: []const u64,
        pins: anytype,
    ) void {
        const n: usize = @min(serials.len, pins.len);
        const rows: usize = @min(n, self.rows);
        if (!self.rows_synced) {
            for (0..rows) |y| {
                self.row_serial[y] = serials[y];
                self.row_y[y] = pins[y].y;
            }
            self.rows_synced = true;
            return;
        }
        var changed: usize = 0;
        for (0..rows) |y| {
            if (self.row_serial[y] != serials[y] or
                self.row_y[y] != pins[y].y) changed += 1;
        }
        if (changed * 2 > rows) {
            self.invalidateAll();
            for (0..rows) |y| {
                self.row_serial[y] = serials[y];
                self.row_y[y] = pins[y].y;
            }
            self.rows_synced = true;
            return;
        }
        for (0..rows) |y| {
            if (self.row_serial[y] != serials[y] or
                self.row_y[y] != pins[y].y)
            {
                self.invalidateRow(@intCast(y));
                self.row_serial[y] = serials[y];
                self.row_y[y] = pins[y].y;
            }
        }
    }

    /// Record that a cell painted nothing plain (e.g. a preedit
    /// skip). Drops any active entry. No-ops when untracked.
    pub fn markOverride(self: *State, y: u16, x: u16) void {
        if (self.kind.len == 0) return;
        _ = self.entries.remove(key(y, x));
        if (y < self.rows and x < self.cols)
            self.kind[self.cellIndex(y, x)] = .override;
    }

    fn cellIndex(self: *const State, y: u16, x: u16) usize {
        return @as(usize, y) * self.cols + x;
    }

    /// Decide what to paint for a cell and maintain all bookkeeping.
    /// `plain` must be false for any override (selection, search,
    /// inverse, invisible, preedit): the entry is dropped and the
    /// resolved color paints immediately.
    pub fn stepCell(
        self: *State,
        y: u16,
        x: u16,
        new_fg: RGB,
        id: Identity,
        plain: bool,
        now_ms: u64,
        duration_ms: u64,
    ) Allocator.Error!RGB {
        const k = key(y, x);
        if (!plain) {
            _ = self.entries.remove(k);
            if (y < self.rows and x < self.cols)
                self.kind[self.cellIndex(y, x)] = .override;
            return new_fg;
        }

        if (self.entries.getPtr(k)) |e| {
            if (!e.identity.eql(id)) {
                // Different glyph: stop tracking, paint immediately.
                _ = self.entries.remove(k);
            } else {
                if (!e.to.eql(new_fg)) {
                    // Retarget from the currently displayed color.
                    e.from = e.colorAt(now_ms, duration_ms);
                    e.to = new_fg;
                    e.start_ms = now_ms;
                }
                const c = e.colorAt(now_ms, duration_ms);
                e.last = c;
                self.record(y, x, new_fg, id);
                return c;
            }
        }

        // No active entry: start one only from a previously recorded
        // plain paint of the same glyph with a different color.
        if (y < self.rows and x < self.cols) {
            const i = self.cellIndex(y, x);
            if (self.kind[i] == .plain and
                self.last_id[i].eql(id) and
                !self.last_fg[i].eql(new_fg) and
                self.entries.count() < max_entries)
            {
                const from = self.last_fg[i];
                const c = at(from, new_fg, progress(
                    now_ms,
                    now_ms,
                    duration_ms,
                ));
                try self.entries.put(self.alloc, k, .{
                    .from = from,
                    .to = new_fg,
                    .start_ms = now_ms,
                    .identity = id,
                    .last = c,
                });
                self.record(y, x, new_fg, id);
                return c;
            }
            self.record(y, x, new_fg, id);
        }
        return new_fg;
    }

    fn record(self: *State, y: u16, x: u16, fg: RGB, id: Identity) void {
        if (y >= self.rows or x >= self.cols) return;
        const i = self.cellIndex(y, x);
        self.kind[i] = .plain;
        self.last_fg[i] = fg;
        self.last_id[i] = id;
    }
};

const testing = std.testing;

test "easeOut endpoints and monotonicity" {
    try testing.expectEqual(@as(f32, 0), easeOut(0));
    try testing.expectEqual(@as(f32, 1), easeOut(1));
    var prev: f32 = 0;
    var t: f32 = 0.01;
    while (t < 1) : (t += 0.01) {
        const v = easeOut(t);
        try testing.expect(v >= 0 and v <= 1);
        try testing.expect(v >= prev);
        prev = v;
    }
}

test "progress clamps and completes" {
    try testing.expectEqual(@as(f32, 1), progress(100, 100, 0));
    try testing.expectEqual(@as(f32, 0), progress(100, 99, 200));
    try testing.expectEqual(@as(f32, 0), progress(100, 100, 200));
    try testing.expectEqual(@as(f32, 0.5), progress(100, 200, 200));
    try testing.expectEqual(@as(f32, 1), progress(100, 300, 200));
    try testing.expectEqual(@as(f32, 1), progress(100, 10_000, 200));
}

test "at endpoints are exact" {
    const from: RGB = .{ .r = 255, .g = 200, .b = 0 };
    const to: RGB = .{ .r = 0, .g = 255, .b = 100 };
    try testing.expect(at(from, to, 0).eql(from));
    try testing.expect(at(from, to, 1).eql(to));
    // Midpoint stays within the channel ranges (no overshoot/spike).
    const mid = at(from, to, 0.5);
    try testing.expect(mid.r <= 255 and mid.r >= 0);
    try testing.expect(mid.g <= 255 and mid.g >= 200);
    try testing.expect(mid.b <= 100 and mid.b >= 0);
}

test "transition lifecycle" {
    var s = State.init(testing.allocator);
    defer s.deinit();
    try s.ensureSize(2, 4);

    const id: Identity = .{ .cp = 'A' };
    const yellow: RGB = .{ .r = 255, .g = 200, .b = 0 };
    const green: RGB = .{ .r = 0, .g = 255, .b = 0 };

    // First paint: immediate, no state.
    try testing.expect((try s.stepCell(0, 0, yellow, id, true, 0, 200)).eql(yellow));
    try testing.expectEqual(@as(usize, 0), s.count());

    // Unchanged color: no state.
    try testing.expect((try s.stepCell(0, 0, yellow, id, true, 50, 200)).eql(yellow));
    try testing.expectEqual(@as(usize, 0), s.count());

    // New color, same glyph: transition starts at the old color.
    try testing.expect((try s.stepCell(0, 0, green, id, true, 100, 200)).eql(yellow));
    try testing.expectEqual(@as(usize, 1), s.count());

    // Rapid redraws with the same target keep the original start.
    const e0 = s.entries.get(key(0, 0)).?;
    try testing.expectEqual(@as(u64, 100), e0.start_ms);
    _ = try s.stepCell(0, 0, green, id, true, 150, 200);
    const e1 = s.entries.get(key(0, 0)).?;
    try testing.expectEqual(@as(u64, 100), e1.start_ms);

    // Intermediate color differs from both endpoints.
    const mid = e1.colorAt(150, 200);
    try testing.expect(!mid.eql(yellow));
    try testing.expect(!mid.eql(green));

    // Same timestamp always yields the same color (frame-rate independence).
    try testing.expect(e1.colorAt(150, 200).eql(mid));
    try testing.expect(e1.colorAt(150, 200).eql(mid));

    // Exact target at the deadline.
    try testing.expect(e1.colorAt(300, 200).eql(green));
    try testing.expect(e1.isDone(300, 200));
    try testing.expect(!e1.isDone(299, 200));
}

test "retarget restarts from the displayed intermediate" {
    var s = State.init(testing.allocator);
    defer s.deinit();
    try s.ensureSize(2, 4);

    const id: Identity = .{ .cp = 'B' };
    const yellow: RGB = .{ .r = 255, .g = 200, .b = 0 };
    const green: RGB = .{ .r = 0, .g = 255, .b = 0 };
    const cyan: RGB = .{ .r = 0, .g = 255, .b = 255 };

    _ = try s.stepCell(1, 2, yellow, id, true, 0, 200);
    _ = try s.stepCell(1, 2, green, id, true, 100, 200);
    const mid = s.entries.get(key(1, 2)).?.colorAt(150, 200);
    // New target mid-transition: from becomes the intermediate.
    const painted = try s.stepCell(1, 2, cyan, id, true, 150, 200);
    try testing.expect(painted.eql(mid));
    const e = s.entries.get(key(1, 2)).?;
    try testing.expect(e.from.eql(mid));
    try testing.expect(e.to.eql(cyan));
    try testing.expectEqual(@as(u64, 150), e.start_ms);
    // Still converges exactly.
    try testing.expect(e.colorAt(350, 200).eql(cyan));
}

test "glyph change and overrides paint immediately" {
    var s = State.init(testing.allocator);
    defer s.deinit();
    try s.ensureSize(2, 4);

    const a: Identity = .{ .cp = 'A' };
    const b: Identity = .{ .cp = 'B' };
    const yellow: RGB = .{ .r = 255, .g = 200, .b = 0 };
    const green: RGB = .{ .r = 0, .g = 255, .b = 0 };

    _ = try s.stepCell(0, 1, yellow, a, true, 0, 200);
    _ = try s.stepCell(0, 1, green, a, true, 100, 200);
    try testing.expectEqual(@as(usize, 1), s.count());

    // Different glyph: immediate, entry dropped.
    try testing.expect((try s.stepCell(0, 1, green, b, true, 150, 200)).eql(green));
    try testing.expectEqual(@as(usize, 0), s.count());

    // Same glyph again restarts from the recorded paint.
    _ = try s.stepCell(0, 1, yellow, b, true, 160, 200);
    try testing.expectEqual(@as(usize, 1), s.count());

    // Override (selection/search/inverse): immediate, entry dropped.
    try testing.expect((try s.stepCell(0, 1, green, b, false, 170, 200)).eql(green));
    try testing.expectEqual(@as(usize, 0), s.count());

    // Paint after an override never fades from the override color.
    try testing.expect((try s.stepCell(0, 1, yellow, b, true, 180, 200)).eql(yellow));
    try testing.expectEqual(@as(usize, 0), s.count());
}

test "bold and wide are distinct identities" {
    var s = State.init(testing.allocator);
    defer s.deinit();
    try s.ensureSize(1, 2);

    const plain_id: Identity = .{ .cp = 'A' };
    const bold_id: Identity = .{ .cp = 'A', .bold = true };
    const yellow: RGB = .{ .r = 255, .g = 200, .b = 0 };
    const green: RGB = .{ .r = 0, .g = 255, .b = 0 };

    _ = try s.stepCell(0, 0, yellow, plain_id, true, 0, 200);
    // Same codepoint but bold toggled: immediate, no transition.
    try testing.expect((try s.stepCell(0, 0, green, bold_id, true, 10, 200)).eql(green));
    try testing.expectEqual(@as(usize, 0), s.count());
}

test "row invalidation and scroll sync" {
    var s = State.init(testing.allocator);
    defer s.deinit();
    try s.ensureSize(4, 4);

    const id: Identity = .{ .cp = 'A' };
    const yellow: RGB = .{ .r = 255, .g = 200, .b = 0 };
    const green: RGB = .{ .r = 0, .g = 255, .b = 0 };

    _ = try s.stepCell(0, 0, yellow, id, true, 0, 200);
    _ = try s.stepCell(0, 0, green, id, true, 10, 200);
    _ = try s.stepCell(2, 3, yellow, id, true, 0, 200);
    _ = try s.stepCell(2, 3, green, id, true, 10, 200);
    try testing.expectEqual(@as(usize, 2), s.count());

    // Invalidate one row: only its entries and kinds drop.
    s.invalidateRow(0);
    try testing.expectEqual(@as(usize, 1), s.count());
    // Repainting the invalidated cell behaves like first paint.
    try testing.expect((try s.stepCell(0, 0, yellow, id, true, 20, 200)).eql(yellow));
    try testing.expectEqual(@as(usize, 1), s.count());

    // Establish baseline row identities on a clean slate, then
    // create transitions.
    s.invalidateAll();
    const Pin = struct { y: u16 };
    const serials_base = [_]u64{ 10, 11, 12, 13 };
    const pins0 = [_]Pin{
        .{ .y = 0 },
        .{ .y = 0 },
        .{ .y = 0 },
        .{ .y = 0 },
    };
    s.syncRows(&serials_base, &pins0);

    _ = try s.stepCell(1, 1, yellow, id, true, 30, 200);
    _ = try s.stepCell(1, 1, green, id, true, 40, 200);
    _ = try s.stepCell(3, 3, yellow, id, true, 30, 200);
    _ = try s.stepCell(3, 3, green, id, true, 40, 200);
    try testing.expectEqual(@as(usize, 2), s.count());

    // A full scroll (every row identity changes) drops everything.
    const serials_full = [_]u64{ 20, 21, 22, 23 };
    s.syncRows(&serials_full, &pins0);
    try testing.expectEqual(@as(usize, 0), s.count());

    // A single shifted row only drops that row.
    _ = try s.stepCell(0, 0, yellow, id, true, 50, 200);
    _ = try s.stepCell(0, 0, green, id, true, 60, 200);
    _ = try s.stepCell(2, 2, yellow, id, true, 50, 200);
    _ = try s.stepCell(2, 2, green, id, true, 60, 200);
    try testing.expectEqual(@as(usize, 2), s.count());
    const serials_shift = [_]u64{ 99, 21, 22, 23 };
    s.syncRows(&serials_shift, &pins0);
    try testing.expectEqual(@as(usize, 1), s.count());
    try testing.expect(s.entries.get(key(2, 2)) != null);
}

test "entry count is bounded" {
    var s = State.init(testing.allocator);
    defer s.deinit();
    try s.ensureSize(64, 64);

    const yellow: RGB = .{ .r = 255, .g = 200, .b = 0 };
    const green: RGB = .{ .r = 0, .g = 255, .b = 0 };
    var y: u16 = 0;
    while (y < 64) : (y += 1) {
        var x: u16 = 0;
        while (x < 64) : (x += 1) {
            const id: Identity = .{ .cp = @intCast(0x41 + (x % 26)) };
            _ = try s.stepCell(y, x, yellow, id, true, 0, 200);
            _ = try s.stepCell(y, x, green, id, true, 10, 200);
        }
    }
    try testing.expect(s.count() <= max_entries);
    try testing.expectEqual(@as(usize, max_entries), s.count());
}

test "resize drops state" {
    var s = State.init(testing.allocator);
    defer s.deinit();
    try s.ensureSize(2, 4);

    const id: Identity = .{ .cp = 'A' };
    const yellow: RGB = .{ .r = 255, .g = 200, .b = 0 };
    const green: RGB = .{ .r = 0, .g = 255, .b = 0 };
    _ = try s.stepCell(0, 0, yellow, id, true, 0, 200);
    _ = try s.stepCell(0, 0, green, id, true, 10, 200);
    try testing.expectEqual(@as(usize, 1), s.count());

    try s.ensureSize(3, 80);
    try testing.expectEqual(@as(usize, 0), s.count());
    try testing.expect((try s.stepCell(0, 0, yellow, id, true, 20, 200)).eql(yellow));
    try testing.expectEqual(@as(usize, 0), s.count());
}
