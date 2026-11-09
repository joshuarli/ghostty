const std = @import("std");
const Allocator = std.mem.Allocator;
const harfbuzz = @import("harfbuzz");

extern fn hb_ot_tags_from_script_and_language(
    script: harfbuzz.c.hb_script_t,
    language: ?*const anyopaque,
    script_count: *c_uint,
    script_tags: [*]u32,
    language_count: ?*c_uint,
    language_tags: ?[*]u32,
) void;

pub const FontId = extern struct { high: u64, low: u64 };

const c = struct {
    const UnicodeRange = extern struct { start: u32, end: u32 };

    const FontPath = extern struct {
        path: [*:0]u8,
        font_index: usize,
    };

    const FontMetadata = extern struct {
        copyright: ?[*:0]u8,
        designer: ?[*:0]u8,
        designer_url: ?[*:0]u8,
        font_family: ?[*:0]u8,
        font_subfamily: ?[*:0]u8,
        full_name: ?[*:0]u8,
        id_description: ?[*:0]u8,
        license: ?[*:0]u8,
        license_url: ?[*:0]u8,
        manufacturer: ?[*:0]u8,
        manufacturer_url: ?[*:0]u8,
        postscript_name: ?[*:0]u8,
        preferred_family: ?[*:0]u8,
        preferred_subfamily: ?[*:0]u8,
        trademark: ?[*:0]u8,
        unique_id: ?[*:0]u8,
        version: ?[*:0]u8,
    };

    const FontMatchNoFallback = extern struct {
        id: FontId,
        unicode_ranges: ?[*]UnicodeRange,
        unicode_ranges_count: usize,
    };

    const CssFallbackGroup = extern struct {
        css_name: ?[*:0]u8,
        fonts: ?[*]FontMatchNoFallback,
        fonts_count: usize,
    };

    const FontCandidate = extern struct {
        font_id: FontId,
        supports_script: bool,
        has_color: bool,
    };

    const TraceMsg = extern struct {
        level: c_int,
        path: ?[*:0]u8,
        reason: ?*anyopaque,
    };

    const CacheHandle = opaque {};
    const ChainHandle = opaque {};

    const match_true: c_int = 0;
    const match_false: c_int = 1;
    const weight_normal: c_int = 400;
    const weight_bold: c_int = 700;

    extern fn fc_cache_build() ?*CacheHandle;
    extern fn fc_cache_free(cache: *CacheHandle) void;
    extern fn fc_cache_get_font_path(cache: *const CacheHandle, id: *const FontId) ?*FontPath;
    extern fn fc_font_path_free(path: *FontPath) void;
    extern fn fc_cache_get_font_metadata(cache: *const CacheHandle, id: *const FontId) ?*FontMetadata;
    extern fn fc_font_metadata_free(metadata: *FontMetadata) void;
    extern fn fc_resolve_font_chain_with_scripts(
        cache: *const CacheHandle,
        families: [*]const [*:0]const u8,
        families_count: usize,
        weight: c_int,
        italic: c_int,
        oblique: c_int,
        scripts: [*]const UnicodeRange,
        scripts_count: usize,
        trace: *?[*]TraceMsg,
        trace_count: *usize,
    ) ?*ChainHandle;
    extern fn fc_font_chain_free(chain: *ChainHandle) void;
    extern fn fc_trace_free(trace: ?[*]TraceMsg, count: usize) void;
    extern fn fc_chain_get_css_fallbacks(chain: *const ChainHandle, groups_count: *usize) ?[*]CssFallbackGroup;
    extern fn fc_css_fallback_groups_free(groups: ?[*]CssFallbackGroup, count: usize) void;
    extern fn fc_chain_candidates_for_text(
        chain: *const ChainHandle,
        cache: *const CacheHandle,
        text: [*:0]const u8,
        script_tags: ?[*]const u32,
        script_tags_count: usize,
        candidates_count: *usize,
    ) ?[*]FontCandidate;
    extern fn fc_font_candidates_free(candidates: ?[*]FontCandidate, count: usize) void;
};

/// Unicode blocks that a chain resolves script fallback fonts for. The
/// library precomputes a font group per block, so a block missing here
/// has no fallback font at all.
const script_blocks = [_]c.UnicodeRange{
    .{ .start = 0x0100, .end = 0x024F },
    .{ .start = 0x0300, .end = 0x036F },
    .{ .start = 0x0370, .end = 0x03FF },
    .{ .start = 0x0400, .end = 0x052F },
    .{ .start = 0x0530, .end = 0x058F },
    .{ .start = 0x0590, .end = 0x05FF },
    .{ .start = 0x0600, .end = 0x06FF },
    .{ .start = 0x0700, .end = 0x077F },
    .{ .start = 0x0900, .end = 0x097F },
    .{ .start = 0x0980, .end = 0x09FF },
    .{ .start = 0x0A00, .end = 0x0A7F },
    .{ .start = 0x0A80, .end = 0x0AFF },
    .{ .start = 0x0B00, .end = 0x0B7F },
    .{ .start = 0x0B80, .end = 0x0BFF },
    .{ .start = 0x0C00, .end = 0x0C7F },
    .{ .start = 0x0C80, .end = 0x0CFF },
    .{ .start = 0x0D00, .end = 0x0D7F },
    .{ .start = 0x0D80, .end = 0x0DFF },
    .{ .start = 0x0E00, .end = 0x0E7F },
    .{ .start = 0x0E80, .end = 0x0EFF },
    .{ .start = 0x0F00, .end = 0x0FFF },
    .{ .start = 0x1000, .end = 0x109F },
    .{ .start = 0x10A0, .end = 0x10FF },
    .{ .start = 0x1100, .end = 0x11FF },
    .{ .start = 0x1200, .end = 0x139F },
    .{ .start = 0x1780, .end = 0x17FF },
    .{ .start = 0x1E00, .end = 0x1FFF },
    .{ .start = 0x2000, .end = 0x206F },
    .{ .start = 0x2190, .end = 0x2BFF },
    .{ .start = 0x3000, .end = 0x303F },
    .{ .start = 0x3040, .end = 0x30FF },
    .{ .start = 0x3400, .end = 0x4DBF },
    .{ .start = 0x4E00, .end = 0x9FFF },
    .{ .start = 0xAC00, .end = 0xD7AF },
    .{ .start = 0xFB50, .end = 0xFDFF },
    .{ .start = 0xFE70, .end = 0xFEFF },
    .{ .start = 0xFF00, .end = 0xFFEF },
    .{ .start = 0x1F000, .end = 0x1F2FF },
    .{ .start = 0x1F300, .end = 0x1FAFF },
    .{ .start = 0x20000, .end = 0x2FA1F },
};

pub const Error = error{
    CacheBuildFailed,
    ChainResolveFailed,
};

pub const Font = struct {
    path: [:0]const u8,
    index: i32,
    family: [:0]const u8,
    full_name: [:0]const u8,
    style: ?[:0]const u8,

    pub fn deinit(self: *Font, alloc: Allocator) void {
        alloc.free(self.path);
        alloc.free(self.family);
        alloc.free(self.full_name);
        if (self.style) |v| alloc.free(v);
        self.* = undefined;
    }
};

pub const Candidate = struct {
    id: FontId,
    supports_script: bool,
    has_color: bool,
};

pub const Cache = struct {
    handle: *c.CacheHandle,

    pub fn init() Error!Cache {
        return .{ .handle = c.fc_cache_build() orelse return error.CacheBuildFailed };
    }

    pub fn deinit(self: *Cache) void {
        c.fc_cache_free(self.handle);
        self.* = undefined;
    }

    pub const ChainOptions = struct {
        bold: bool = false,
        italic: bool = false,
    };

    pub fn resolveChain(
        self: *const Cache,
        families: []const [*:0]const u8,
        opts: ChainOptions,
    ) Error!Chain {
        var trace: ?[*]c.TraceMsg = null;
        var trace_count: usize = 0;
        defer c.fc_trace_free(trace, trace_count);
        const handle = c.fc_resolve_font_chain_with_scripts(
            self.handle,
            families.ptr,
            families.len,
            if (opts.bold) c.weight_bold else c.weight_normal,
            if (opts.italic) c.match_true else c.match_false,
            c.match_false,
            &script_blocks,
            script_blocks.len,
            &trace,
            &trace_count,
        ) orelse return error.ChainResolveFailed;
        return .{ .handle = handle, .cache = self };
    }

    pub fn font(self: *const Cache, alloc: Allocator, id: FontId) Allocator.Error!?Font {
        const path = c.fc_cache_get_font_path(self.handle, &id) orelse return null;
        defer c.fc_font_path_free(path);
        const index = std.math.cast(i32, path.font_index) orelse return null;

        const metadata = c.fc_cache_get_font_metadata(self.handle, &id);
        defer if (metadata) |m| c.fc_font_metadata_free(m);

        const path_owned = try alloc.dupeSentinel(u8, std.mem.span(path.path), 0);
        errdefer alloc.free(path_owned);

        const family_src = if (metadata) |m| m.preferred_family orelse m.font_family else null;
        const family_owned = try alloc.dupeSentinel(u8, if (family_src) |s| std.mem.span(s) else "", 0);
        errdefer alloc.free(family_owned);

        const full_name_src = if (metadata) |m| m.full_name else null;
        const full_name_owned = try alloc.dupeSentinel(
            u8,
            if (full_name_src) |s| std.mem.span(s) else family_owned,
            0,
        );
        errdefer alloc.free(full_name_owned);

        const style_src = if (metadata) |m| m.preferred_subfamily orelse m.font_subfamily else null;
        const style_owned: ?[:0]const u8 = if (style_src) |s| try alloc.dupeSentinel(u8, std.mem.span(s), 0) else null;

        return .{
            .path = path_owned,
            .index = index,
            .family = family_owned,
            .full_name = full_name_owned,
            .style = style_owned,
        };
    }
};

pub const Chain = struct {
    handle: *c.ChainHandle,
    cache: *const Cache,

    pub fn deinit(self: *Chain) void {
        c.fc_font_chain_free(self.handle);
        self.* = undefined;
    }

    pub fn families(self: *const Chain, alloc: Allocator) Allocator.Error![]FontId {
        var count: usize = 0;
        const groups = c.fc_chain_get_css_fallbacks(self.handle, &count);
        defer c.fc_css_fallback_groups_free(groups, count);

        var result: std.ArrayList(FontId) = .empty;
        errdefer result.deinit(alloc);
        for ((groups orelse return try result.toOwnedSlice(alloc))[0..count]) |group| {
            const fonts = group.fonts orelse continue;
            for (fonts[0..group.fonts_count]) |match| try result.append(alloc, match.id);
        }
        return try result.toOwnedSlice(alloc);
    }

    pub fn candidates(
        self: *const Chain,
        alloc: Allocator,
        text: [:0]const u8,
        script_tags: []const u32,
    ) Allocator.Error![]Candidate {
        var count: usize = 0;
        const found = c.fc_chain_candidates_for_text(
            self.handle,
            self.cache.handle,
            text.ptr,
            if (script_tags.len == 0) null else script_tags.ptr,
            script_tags.len,
            &count,
        );
        defer c.fc_font_candidates_free(found, count);

        const list = (found orelse return try alloc.alloc(Candidate, 0))[0..count];
        const result = try alloc.alloc(Candidate, list.len);
        for (list, result) |src, *dst| dst.* = .{
            .id = src.font_id,
            .supports_script = src.supports_script,
            .has_color = src.has_color,
        };
        return result;
    }
};

pub const max_script_tags = 4;

pub fn scriptTags(cluster: []const u21, buf: *[max_script_tags]u32) []const u32 {
    const funcs = harfbuzz.c.hb_unicode_funcs_get_default();
    for (cluster) |cp| {
        const script = harfbuzz.c.hb_unicode_script(funcs, cp);
        switch (script) {
            harfbuzz.c.HB_SCRIPT_COMMON,
            harfbuzz.c.HB_SCRIPT_INHERITED,
            harfbuzz.c.HB_SCRIPT_UNKNOWN,
            => continue,
            else => {},
        }
        var count: c_uint = buf.len;
        hb_ot_tags_from_script_and_language(script, null, &count, buf, null, null);
        return buf[0..@min(count, buf.len)];
    }
    return buf[0..0];
}
