//! SVG rasterization for kitty graphics.
//!
//! The protocol has no SVG format (f=24 RGB, f=32 RGBA, f=100 PNG). As an extension, an SVG
//! sent with f=100 is accepted: the PNG decode hook sniffs the payload and rasterizes SVG-like
//! ones to straight-alpha RGBA.
//!
//! nanosvg (vendor/nanosvg.h, zlib) rasterizes at the intrinsic size, 96 dpi. A viewer wanting
//! a crisper result can place the image in a smaller cell box (c=/r=); downscaling stays sharp.

const std = @import("std");

// The nanosvg C API slice used here, declared by hand (not translate-c): the surface is
// tiny and `NSVGimage`'s leading fields are stable public API.
const NSVGimage = extern struct {
    width: f32,
    height: f32,
    shapes: ?*anyopaque,
};
const NSVGrasterizer = opaque {};
extern fn nsvgParse(input: [*]u8, units: [*:0]const u8, dpi: f32) ?*NSVGimage;
extern fn nsvgDelete(image: *NSVGimage) void;
extern fn nsvgCreateRasterizer() ?*NSVGrasterizer;
extern fn nsvgDeleteRasterizer(r: *NSVGrasterizer) void;
extern fn nsvgRasterize(
    r: *NSVGrasterizer,
    image: *NSVGimage,
    tx: f32,
    ty: f32,
    scale: f32,
    dst: [*]u8,
    w: c_int,
    h: c_int,
    stride: c_int,
) void;

/// Largest side of a rasterized image. Larger documents are scaled down
/// to fit, keeping their aspect ratio.
pub const max_side: u32 = 4096;

/// Documents larger than this are refused outright.
pub const max_input: usize = 8 * 1024 * 1024;

pub const Decoded = struct {
    width: u32,
    height: u32,
    /// Straight-alpha RGBA, owned by the caller.
    data: []u8,
};

pub const Error = std.mem.Allocator.Error || error{InvalidData};

/// Cheap sniff: does `data` look like an SVG document (optionally after
/// a BOM, whitespace, an XML prolog, a doctype or comments)?
pub fn looksLikeSvg(data: []const u8) bool {
    var rest = data;
    if (std.mem.startsWith(u8, rest, "\xEF\xBB\xBF")) rest = rest[3..];
    rest = std.mem.trimStart(u8, rest, " \t\r\n");
    if (std.mem.startsWith(u8, rest, "\x89PNG")) return false;
    if (!(std.mem.startsWith(u8, rest, "<svg") or
        std.mem.startsWith(u8, rest, "<?xml") or
        std.mem.startsWith(u8, rest, "<!DOCTYPE") or
        std.mem.startsWith(u8, rest, "<!--")))
        return false;
    // An XML prolog, doctype or comment also starts other documents;
    // require an <svg element near the front.
    return std.mem.indexOf(u8, rest[0..@min(rest.len, 4096)], "<svg") != null;
}

/// Rasterize an SVG document to RGBA.
pub fn decode(alloc: std.mem.Allocator, data: []const u8) Error!Decoded {
    if (data.len == 0 or data.len > max_input) return error.InvalidData;

    // nanosvg parses in place and needs a NUL terminator.
    const copy = try alloc.allocSentinel(u8, data.len, 0);
    defer alloc.free(copy);
    @memcpy(copy, data);

    const image = nsvgParse(copy.ptr, "px", 96) orelse return error.InvalidData;
    defer nsvgDelete(image);

    const iw = image.width;
    const ih = image.height;
    if (!(iw > 0 and ih > 0) or !std.math.isFinite(iw) or !std.math.isFinite(ih)) {
        return error.InvalidData;
    }

    const longest = @max(iw, ih);
    const scale: f32 = if (longest > @as(f32, @floatFromInt(max_side)))
        @as(f32, @floatFromInt(max_side)) / longest
    else
        1.0;
    const w: u32 = @min(max_side, @max(1, @as(u32, @intFromFloat(@ceil(iw * scale)))));
    const h: u32 = @min(max_side, @max(1, @as(u32, @intFromFloat(@ceil(ih * scale)))));

    const len = std.math.mul(usize, @as(usize, w) * h, 4) catch return error.InvalidData;
    const out = try alloc.alloc(u8, len);
    errdefer alloc.free(out);
    @memset(out, 0);

    const rast = nsvgCreateRasterizer() orelse return error.OutOfMemory;
    defer nsvgDeleteRasterizer(rast);
    nsvgRasterize(rast, image, 0, 0, scale, out.ptr, @intCast(w), @intCast(h), @intCast(w * 4));

    return .{ .width = w, .height = h, .data = out };
}

test "looksLikeSvg" {
    try std.testing.expect(looksLikeSvg("<svg xmlns='http://www.w3.org/2000/svg'/>"));
    try std.testing.expect(looksLikeSvg("  \n<?xml version=\"1.0\"?>\n<svg width='1' height='1'/>"));
    try std.testing.expect(!looksLikeSvg("\x89PNG\r\n\x1a\n"));
    try std.testing.expect(!looksLikeSvg("<?xml version=\"1.0\"?><html/>"));
    try std.testing.expect(!looksLikeSvg(""));
}

test "decode rasterizes a solid rect at intrinsic size" {
    const doc = "<svg xmlns='http://www.w3.org/2000/svg' width='8' height='4'>" ++
        "<rect width='8' height='4' fill='#ff0000'/></svg>";
    const img = try decode(std.testing.allocator, doc);
    defer std.testing.allocator.free(img.data);
    try std.testing.expectEqual(@as(u32, 8), img.width);
    try std.testing.expectEqual(@as(u32, 4), img.height);
    try std.testing.expectEqual(@as(usize, 8 * 4 * 4), img.data.len);
    // Interior pixel is opaque red.
    const i = (2 * 8 + 4) * 4;
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, img.data[i .. i + 4]);
}

test "decode keeps transparency outside shapes" {
    const doc = "<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'>" ++
        "<rect x='5' width='5' height='10' fill='#0000ff'/></svg>";
    const img = try decode(std.testing.allocator, doc);
    defer std.testing.allocator.free(img.data);
    try std.testing.expectEqual(@as(u8, 0), img.data[(5 * 10 + 1) * 4 + 3]);
    try std.testing.expectEqual(@as(u8, 255), img.data[(5 * 10 + 8) * 4 + 3]);
}

test "decode rejects garbage" {
    try std.testing.expectError(error.InvalidData, decode(std.testing.allocator, ""));
    try std.testing.expectError(error.InvalidData, decode(std.testing.allocator, "<svg"));
}
