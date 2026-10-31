const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const linux = std.os.linux;
const libc = std.c;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const apprt = @import("../../apprt.zig");
const terminal = @import("../../terminal/main.zig");
const compat_fd = @import("../../lib/compat/fd.zig");
const Seat = @import("seat.zig").Seat;

const log = std.log.scoped(.wayland);

const text_mimes = [_][:0]const u8{
    "text/plain;charset=utf-8",
    "text/plain",
    "UTF8_STRING",
    "TEXT",
    "STRING",
};

pub const CompleteFn = *const fn (
    ud: ?*anyopaque,
    req: apprt.ClipboardRequest,
    data: [:0]const u8,
) void;

pub const Clipboard = struct {
    alloc: Allocator,
    manager: *wl.DataDeviceManager,
    seat: *Seat,
    device: *wl.DataDevice = undefined,
    sources: std.ArrayListUnmanaged(*Source) = .empty,
    selection: ?*Offer = null,
    pending: ?*Offer = null,
    reads: std.ArrayListUnmanaged(Read) = .empty,
    writes: std.ArrayListUnmanaged(Write) = .empty,

    pub fn init(self: *Clipboard) !void {
        self.device = try self.manager.getDataDevice(self.seat.seat);
        self.device.setListener(*Clipboard, onDeviceEvent, self);
    }

    pub fn deinit(self: *Clipboard) void {
        for (self.reads.items) |*pending_read| pending_read.deinit(self.alloc);
        self.reads.deinit(self.alloc);
        for (self.writes.items) |*pending_write| pending_write.deinit(self.alloc);
        self.writes.deinit(self.alloc);

        const pending = self.pending;
        self.pending = null;
        const selection = self.selection;
        self.selection = null;
        if (pending) |offer| offer.destroy();
        if (selection) |offer| {
            if (pending == null or offer != pending.?) offer.destroy();
        }

        while (self.sources.items.len > 0) {
            self.sources.items[self.sources.items.len - 1].destroy();
        }
        self.sources.deinit(self.alloc);

        if (self.device.getVersion() >= wl.DataDevice.release_since_version) {
            self.device.release();
        } else {
            self.device.destroy();
        }
    }

    pub fn set(
        self: *Clipboard,
        contents: []const apprt.ClipboardContent,
        serial: u32,
    ) !void {
        if (contents.len == 0) {
            self.device.setSelection(null, serial);
            return;
        }

        const source = try Source.create(self, contents);
        self.device.setSelection(source.source.?, serial);
    }

    pub fn read(
        self: *Clipboard,
        req: apprt.ClipboardRequest,
        ud: ?*anyopaque,
        complete: CompleteFn,
    ) !apprt.ClipboardReadResult {
        const offer = self.selection orelse return .unavailable;
        const mime = findTextMime(offer.mimes.items) orelse return .unavailable;

        const fds = try compat_fd.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
        errdefer compat_fd.close(fds[0]);
        offer.offer.receive(mime.ptr, fds[1]);
        compat_fd.close(fds[1]);
        try self.reads.append(self.alloc, .{
            .fd = fds[0],
            .request = req,
            .ud = ud,
            .complete = complete,
        });
        return .started;
    }

    pub fn list(self: *const Clipboard) ?[]const [:0]const u8 {
        const offer = self.selection orelse return null;
        if (offer.mimes.items.len == 0) return null;
        return offer.mimes.items;
    }

    pub fn cancel(self: *Clipboard, ud: ?*anyopaque) void {
        var i: usize = 0;
        while (i < self.reads.items.len) {
            if (self.reads.items[i].ud == ud) {
                var pending_read = self.reads.swapRemove(i);
                pending_read.deinit(self.alloc);
            } else {
                i += 1;
            }
        }
    }

    pub fn appendPollFds(
        self: *const Clipboard,
        alloc: Allocator,
        fds: *std.ArrayListUnmanaged(posix.pollfd),
    ) !void {
        try fds.ensureUnusedCapacity(
            alloc,
            self.reads.items.len + self.writes.items.len,
        );
        for (self.reads.items) |pending_read| {
            fds.appendAssumeCapacity(.{
                .fd = pending_read.fd,
                .events = linux.POLL.IN,
                .revents = 0,
            });
        }
        for (self.writes.items) |pending_write| {
            fds.appendAssumeCapacity(.{
                .fd = pending_write.fd,
                .events = linux.POLL.OUT,
                .revents = 0,
            });
        }
    }

    pub fn service(self: *Clipboard) void {
        var i: usize = 0;
        while (i < self.reads.items.len) {
            const eof = self.reads.items[i].drain(self.alloc) catch |err| {
                log.warn("clipboard read failed err={}", .{err});
                var pending_read = self.reads.swapRemove(i);
                pending_read.complete(pending_read.ud, pending_read.request, "");
                pending_read.deinit(self.alloc);
                continue;
            };

            if (!eof) {
                i += 1;
                continue;
            }

            var pending_read = self.reads.swapRemove(i);
            defer pending_read.deinit(self.alloc);

            if (pending_read.buffer.items.len == 0) {
                pending_read.complete(pending_read.ud, pending_read.request, "");
                continue;
            }

            pending_read.buffer.append(self.alloc, 0) catch |err| {
                log.warn("clipboard sentinel allocation failed err={}", .{err});
                pending_read.complete(pending_read.ud, pending_read.request, "");
                continue;
            };
            const data = pending_read.buffer.items[0 .. pending_read.buffer.items.len - 1 :0];
            pending_read.complete(pending_read.ud, pending_read.request, data);
        }

        self.serviceWrites();
    }

    fn serviceWrites(self: *Clipboard) void {
        var i: usize = 0;
        while (i < self.writes.items.len) {
            const done = self.writes.items[i].flush() catch |err| {
                log.warn("clipboard write failed err={}", .{err});
                var pending_write = self.writes.swapRemove(i);
                pending_write.deinit(self.alloc);
                continue;
            };
            if (!done) {
                i += 1;
                continue;
            }

            var pending_write = self.writes.swapRemove(i);
            pending_write.deinit(self.alloc);
        }
    }

    fn removeSource(self: *Clipboard, source: *Source) void {
        for (self.sources.items, 0..) |candidate, i| {
            if (candidate == source) {
                _ = self.sources.swapRemove(i);
                return;
            }
        }
    }

    fn onDataOffer(self: *Clipboard, id: *wl.DataOffer) void {
        if (self.pending) |offer| {
            self.pending = null;
            offer.destroy();
        }
        self.pending = Offer.create(self, id) catch |err| {
            log.warn("clipboard offer creation failed err={}", .{err});
            id.destroy();
            return;
        };
    }

    fn onSelection(self: *Clipboard, id: ?*wl.DataOffer) void {
        if (self.selection) |offer| {
            self.selection = null;
            offer.destroy();
        }

        const offer_id = id orelse return;
        if (self.pending) |offer| {
            if (offer.offer == offer_id) {
                self.selection = offer;
                self.pending = null;
                return;
            }
            self.pending = null;
            offer.destroy();
        }

        self.selection = Offer.create(self, offer_id) catch |err| {
            log.warn("clipboard selection creation failed err={}", .{err});
            offer_id.destroy();
            return;
        };
    }
};

const Read = struct {
    fd: posix.fd_t,
    request: apprt.ClipboardRequest,
    ud: ?*anyopaque,
    complete: CompleteFn,
    buffer: std.ArrayListUnmanaged(u8) = .empty,

    fn drain(self: *Read, alloc: Allocator) !bool {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = posix.read(self.fd, &buf) catch |err| switch (err) {
                error.WouldBlock => return false,
                else => return err,
            };
            if (n == 0) {
                return true;
            }
            try self.buffer.appendSlice(alloc, buf[0..n]);
        }
    }

    fn deinit(self: *Read, alloc: Allocator) void {
        compat_fd.close(self.fd);
        self.buffer.deinit(alloc);
    }
};

const Offer = struct {
    owner: *Clipboard,
    offer: *wl.DataOffer,
    mimes: std.ArrayListUnmanaged([:0]const u8) = .empty,

    fn create(owner: *Clipboard, offer: *wl.DataOffer) !*Offer {
        const self = try owner.alloc.create(Offer);
        self.* = .{
            .owner = owner,
            .offer = offer,
        };
        offer.setListener(*Offer, onOfferEvent, self);
        return self;
    }

    fn destroy(self: *Offer) void {
        self.offer.destroy();
        for (self.mimes.items) |mime| self.owner.alloc.free(mime);
        self.mimes.deinit(self.owner.alloc);
        self.owner.alloc.destroy(self);
    }
};

fn onOfferEvent(offer: *wl.DataOffer, event: wl.DataOffer.Event, self: *Offer) void {
    _ = offer;
    switch (event) {
        .offer => |e| {
            const mime = std.mem.span(e.mime_type);
            const copy = self.owner.alloc.dupeSentinel(u8, mime, 0) catch |err| {
                log.warn("clipboard mime allocation failed err={}", .{err});
                return;
            };
            self.mimes.append(self.owner.alloc, copy) catch |err| {
                log.warn("clipboard mime append failed err={}", .{err});
                self.owner.alloc.free(copy);
            };
        },
        .source_actions, .action => {},
    }
}

fn onDeviceEvent(
    device: *wl.DataDevice,
    event: wl.DataDevice.Event,
    self: *Clipboard,
) void {
    _ = device;
    switch (event) {
        .data_offer => |e| self.onDataOffer(e.id),
        .selection => |e| self.onSelection(e.id),
        .enter => {
            if (self.pending) |offer| {
                self.pending = null;
                offer.destroy();
            }
        },
        .leave, .motion, .drop => {},
    }
}

const Write = struct {
    fd: posix.fd_t,
    data: []u8,
    offset: usize = 0,

    fn flush(self: *Write) error{WriteFailed}!bool {
        while (self.offset < self.data.len) {
            const n = libc.write(
                self.fd,
                self.data.ptr + self.offset,
                self.data.len - self.offset,
            );
            if (n < 0) {
                switch (posix.errno(n)) {
                    .INTR => continue,
                    .AGAIN => return false,
                    else => return error.WriteFailed,
                }
            }
            if (n == 0) return true;
            self.offset += @intCast(n);
        }
        return true;
    }

    fn deinit(self: *Write, alloc: Allocator) void {
        compat_fd.close(self.fd);
        alloc.free(self.data);
    }
};

const Stored = struct {
    mime: [:0]const u8,
    data: [:0]const u8,
};

const Source = struct {
    owner: *Clipboard,
    source: ?*wl.DataSource = null,
    contents: []Stored = &.{},
    offered: std.ArrayListUnmanaged([:0]const u8) = .empty,

    fn create(
        owner: *Clipboard,
        contents: []const apprt.ClipboardContent,
    ) !*Source {
        const self = try owner.alloc.create(Source);
        self.* = .{ .owner = owner };
        errdefer self.destroy();

        var stored: std.ArrayListUnmanaged(Stored) = .empty;
        errdefer {
            for (stored.items) |content| freeStored(owner.alloc, content);
            stored.deinit(owner.alloc);
        }
        for (contents) |content| {
            const item = try duplicateStored(owner.alloc, content);
            stored.append(owner.alloc, item) catch |err| {
                freeStored(owner.alloc, item);
                return err;
            };
        }

        self.contents = try stored.toOwnedSlice(owner.alloc);
        self.source = try owner.manager.createDataSource();
        self.source.?.setListener(*Source, onSourceEvent, self);
        try owner.sources.append(owner.alloc, self);

        for (self.contents) |content| {
            if (terminal.clipboard.isTextMime(content.mime)) {
                for (text_mimes) |mime| try self.offer(mime);
            } else {
                try self.offer(content.mime);
            }
        }

        return self;
    }

    fn destroy(self: *Source) void {
        self.owner.removeSource(self);
        if (self.source) |source| source.destroy();
        freeContents(self.owner.alloc, self.contents);
        self.offered.deinit(self.owner.alloc);
        self.owner.alloc.destroy(self);
    }

    fn offer(self: *Source, mime: [:0]const u8) !void {
        for (self.offered.items) |existing| {
            if (std.mem.eql(u8, existing, mime)) return;
        }
        try self.offered.append(self.owner.alloc, mime);
        self.source.?.offer(mime.ptr);
    }

    fn send(self: *Source, mime_type: [*:0]const u8, fd: posix.fd_t) void {
        const mime = std.mem.span(mime_type);
        const data = findContent(self.contents, mime) orelse {
            compat_fd.close(fd);
            return;
        };

        const copy = self.owner.alloc.dupe(u8, data) catch |err| {
            log.warn("clipboard write allocation failed err={}", .{err});
            compat_fd.close(fd);
            return;
        };
        setNonblock(fd) catch {
            compat_fd.close(fd);
            self.owner.alloc.free(copy);
            return;
        };
        self.owner.writes.append(self.owner.alloc, .{
            .fd = fd,
            .data = copy,
        }) catch |err| {
            log.warn("clipboard write append failed err={}", .{err});
            compat_fd.close(fd);
            self.owner.alloc.free(copy);
            return;
        };
        self.owner.serviceWrites();
    }
};

fn setNonblock(fd: posix.fd_t) error{SetNonblockFailed}!void {
    const raw = posix.system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
    if (posix.errno(raw) != .SUCCESS) return error.SetNonblockFailed;
    const flags: u32 = @intCast(raw);
    const nonblock: u32 = @bitCast(posix.O{ .NONBLOCK = true });
    if (posix.errno(posix.system.fcntl(fd, posix.F.SETFL, flags | nonblock)) != .SUCCESS) {
        return error.SetNonblockFailed;
    }
}

fn onSourceEvent(
    source: *wl.DataSource,
    event: wl.DataSource.Event,
    self: *Source,
) void {
    _ = source;
    switch (event) {
        .send => |e| self.send(e.mime_type, e.fd),
        .cancelled => self.destroy(),
        .target, .dnd_drop_performed, .dnd_finished, .action => {},
    }
}

fn findTextMime(mimes: []const [:0]const u8) ?[:0]const u8 {
    for (text_mimes) |preferred| {
        for (mimes) |mime| {
            if (std.mem.eql(u8, preferred, mime)) return mime;
        }
    }
    return null;
}

fn findContent(contents: []const Stored, mime: []const u8) ?[]const u8 {
    for (contents) |content| {
        if (std.mem.eql(u8, content.mime, mime)) return content.data;
        if (terminal.clipboard.isTextMime(mime) and
            terminal.clipboard.isTextMime(content.mime))
        {
            return content.data;
        }
    }
    return null;
}

fn duplicateStored(
    alloc: Allocator,
    content: apprt.ClipboardContent,
) !Stored {
    const mime = try alloc.dupeSentinel(u8, content.mime, 0);
    errdefer alloc.free(mime);
    const data = try alloc.dupeSentinel(u8, content.data, 0);
    return .{ .mime = mime, .data = data };
}

fn freeStored(alloc: Allocator, content: Stored) void {
    alloc.free(content.mime);
    alloc.free(content.data);
}

fn freeContents(alloc: Allocator, contents: []Stored) void {
    for (contents) |content| freeStored(alloc, content);
    if (contents.len > 0) alloc.free(contents);
}

test "findTextMime prefers utf-8" {
    const mimes = [_][:0]const u8{
        "text/plain",
        "text/plain;charset=utf-8",
    };
    try std.testing.expectEqualStrings(
        "text/plain;charset=utf-8",
        findTextMime(&mimes).?,
    );
}

test "findTextMime ignores non-text" {
    const mimes = [_][:0]const u8{ "text/html", "image/png" };
    try std.testing.expect(findTextMime(&mimes) == null);
}

test "findContent matches text aliases" {
    const contents = [_]Stored{
        .{ .mime = "text/plain", .data = "hello" },
        .{ .mime = "text/html", .data = "<b>hello</b>" },
    };
    try std.testing.expectEqualStrings("hello", findContent(&contents, "UTF8_STRING").?);
    try std.testing.expectEqualStrings(
        "<b>hello</b>",
        findContent(&contents, "text/html").?,
    );
}
