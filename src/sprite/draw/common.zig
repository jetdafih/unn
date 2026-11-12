//! Vendored and adapted from ghostty (src/font/sprite/draw/common.zig), MIT licensed. Original copyright Mitchell Hashimoto and ghostty contributors.
//! This file contains a set of useful helper functions
//! and types for drawing our sprite font glyphs. These
//! are generally applicable to multiple sets of glyphs
//! rather than being single-use.

const std = @import("std");
const Allocator = std.mem.Allocator;

const font = @import("../metrics.zig");
const sprite = @import("../canvas.zig");

const log = std.log.scoped(.sprite_font);

// Utility names for common fractions
pub const one_eighth: f64 = 0.125;
pub const one_quarter: f64 = 0.25;
pub const one_third: f64 = (1.0 / 3.0);
pub const three_eighths: f64 = 0.375;
pub const half: f64 = 0.5;
pub const five_eighths: f64 = 0.625;
pub const two_thirds: f64 = (2.0 / 3.0);
pub const three_quarters: f64 = 0.75;
pub const seven_eighths: f64 = 0.875;

/// The thickness of a line.
pub const Thickness = enum {
    super_light,
    light,
    heavy,

    /// Real height of a line from its thickness and a base thickness (in pixels).
    pub fn height(self: Thickness, base: u32) u32 {
        return switch (self) {
            .super_light => @max(base / 2, 1),
            .light => base,
            .heavy => base * 2,
        };
    }
};

/// Shades.
pub const Shade = enum(u8) {
    off = 0x00,
    light = 0x40,
    medium = 0x80,
    dark = 0xc0,
    on = 0xff,

    _,
};

/// Applicable to any set of glyphs with features that may be present or not in each quadrant.
pub const Quads = packed struct(u4) {
    tl: bool = false,
    tr: bool = false,
    bl: bool = false,
    br: bool = false,
};

/// A corner of a cell.
pub const Corner = enum(u2) {
    tl,
    tr,
    bl,
    br,
};

/// An edge of a cell.
pub const Edge = enum(u2) {
    top,
    left,
    bottom,
    right,
};

/// Alignment of a figure within a cell.
pub const Alignment = struct {
    horizontal: enum {
        left,
        right,
        center,
    } = .center,

    vertical: enum {
        top,
        bottom,
        middle,
    } = .middle,

    pub const upper: Alignment = .{ .vertical = .top };
    pub const lower: Alignment = .{ .vertical = .bottom };
    pub const left: Alignment = .{ .horizontal = .left };
    pub const right: Alignment = .{ .horizontal = .right };

    pub const upper_left: Alignment = .{ .vertical = .top, .horizontal = .left };
    pub const upper_right: Alignment = .{ .vertical = .top, .horizontal = .right };
    pub const lower_left: Alignment = .{ .vertical = .bottom, .horizontal = .left };
    pub const lower_right: Alignment = .{ .vertical = .bottom, .horizontal = .right };

    pub const center: Alignment = .{};

    pub const upper_center = upper;
    pub const lower_center = lower;
    pub const middle_left = left;
    pub const middle_right = right;
    pub const middle_center: Alignment = center;

    pub const top = upper;
    pub const bottom = lower;

    pub const top_left = upper_left;
    pub const top_right = upper_right;
    pub const bottom_left = lower_left;
    pub const bottom_right = lower_right;
};

/// A fraction across the cell, horizontally or vertically, with redundant names so you can
/// use whichever reads best.
pub const Fraction = enum {
    // Names for the min edge
    start,
    left,
    top,
    zero,

    // Names based on eighths
    eighth,
    one_eighth,
    two_eighths,
    three_eighths,
    four_eighths,
    five_eighths,
    six_eighths,
    seven_eighths,

    // Names based on quarters
    quarter,
    one_quarter,
    two_quarters,
    three_quarters,

    // Names based on thirds
    third,
    one_third,
    two_thirds,

    // Names based on halves
    half,
    one_half,

    // Alternative names for 1/2
    center,
    middle,

    // Names for the max edge
    end,
    right,
    bottom,
    one,
    full,

    /// This can be indexed to get the fraction for `i/8`.
    pub const eighths: [9]Fraction = .{
        .zero,
        .one_eighth,
        .two_eighths,
        .three_eighths,
        .four_eighths,
        .five_eighths,
        .six_eighths,
        .seven_eighths,
        .one,
    };

    /// This can be indexed to get the fraction for `i/4`.
    pub const quarters: [5]Fraction = .{
        .zero,
        .one_quarter,
        .two_quarters,
        .three_quarters,
        .one,
    };

    /// Position for this fraction across `size` (width or height) as a min (left/top) block
    /// coordinate. `size` can be any integer type; it's coerced with `@floatFromInt`.
    pub inline fn min(self: Fraction, size: anytype) i32 {
        const s: f64 = @as(f64, @floatFromInt(size));
        // Align min coordinates with the complementary fraction taken from the end so rounding
        // evens out: for `size` 7 at `half`, `size - round(0.5 * size)` is 3, while the max
        // coordinate rounds directly, so start->half and half->end are both 4px (0->4, 3->7).
        return @intFromFloat(s - @round((1.0 - self.fraction()) * s));
    }

    /// Position for this fraction across `size` as a max (right/bottom) block coordinate.
    /// `size` can be any integer type; it's coerced with `@floatFromInt`.
    pub inline fn max(self: Fraction, size: anytype) i32 {
        const s: f64 = @as(f64, @floatFromInt(size));
        // See explanation of why these are different in `min`.
        return @intFromFloat(@round(self.fraction() * s));
    }

    /// This fraction across `size` as a float. For integers use `min`/`max`, which align
    /// consistently; this is for path drawing where pixel alignment doesn't matter.
    pub inline fn float(self: Fraction, size: anytype) f64 {
        return self.fraction() * @as(f64, @floatFromInt(size));
    }

    /// Get a float for the fraction this represents.
    pub inline fn fraction(self: Fraction) f64 {
        return switch (self) {
            .start,
            .left,
            .top,
            .zero,
            => 0.0,

            .eighth,
            .one_eighth,
            => 0.125,

            .quarter,
            .one_quarter,
            .two_eighths,
            => 0.25,

            .third,
            .one_third,
            => 1.0 / 3.0,

            .three_eighths,
            => 0.375,

            .half,
            .one_half,
            .two_quarters,
            .four_eighths,
            .center,
            .middle,
            => 0.5,

            .five_eighths,
            => 0.625,

            .two_thirds,
            => 2.0 / 3.0,

            .three_quarters,
            .six_eighths,
            => 0.75,

            .seven_eighths,
            => 0.875,

            .end,
            .right,
            .bottom,
            .one,
            .full,
            => 1.0,
        };
    }
};

/// Fill a section of the cell, specified by a horizontal and vertical pair of fraction lines.
pub fn fill(
    metrics: font.Metrics,
    canvas: *sprite.Canvas,
    x0: Fraction,
    x1: Fraction,
    y0: Fraction,
    y1: Fraction,
) void {
    canvas.box(
        x0.min(metrics.cell_width),
        y0.min(metrics.cell_height),
        x1.max(metrics.cell_width),
        y1.max(metrics.cell_height),
        .on,
    );
}

/// Centered vertical line of the provided thickness.
pub fn vlineMiddle(
    metrics: font.Metrics,
    canvas: *sprite.Canvas,
    thickness: Thickness,
) void {
    const thick_px = thickness.height(metrics.box_thickness);
    vline(
        canvas,
        0,
        @intCast(metrics.cell_height),
        @intCast((metrics.cell_width -| thick_px) / 2),
        thick_px,
    );
}

/// Centered horizontal line of the provided thickness.
pub fn hlineMiddle(
    metrics: font.Metrics,
    canvas: *sprite.Canvas,
    thickness: Thickness,
) void {
    const thick_px = thickness.height(metrics.box_thickness);
    hline(
        canvas,
        0,
        @intCast(metrics.cell_width),
        @intCast((metrics.cell_height -| thick_px) / 2),
        thick_px,
    );
}

/// Vertical line with the left edge at `x`, between `y1` and `y2`.
pub fn vline(
    canvas: *sprite.Canvas,
    y1: i32,
    y2: i32,
    x: i32,
    thickness_px: u32,
) void {
    canvas.box(x, y1, x + @as(i32, @intCast(thickness_px)), y2, .on);
}

/// Horizontal line with the top edge at `y`, between `x1` and `x2`.
pub fn hline(
    canvas: *sprite.Canvas,
    x1: i32,
    x2: i32,
    y: i32,
    thickness_px: u32,
) void {
    canvas.box(x1, y, x2, y + @as(i32, @intCast(thickness_px)), .on);
}
