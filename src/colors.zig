//! Terminal color parsing and Unn's built-in default palette.

const std = @import("std");
const vt = @import("ghostty-vt");

/// A configured color that can be a concrete RGB value or a runtime
/// reference to the cell's foreground or background.
pub const TerminalColor = union(enum) {
    rgb: vt.color.RGB,
    cell_foreground,
    cell_background,

    pub fn toRgb(self: TerminalColor) ?vt.color.RGB {
        return switch (self) {
            .rgb => |color| color,
            .cell_foreground, .cell_background => null,
        };
    }

    pub fn resolve(self: TerminalColor, cell_fg: vt.color.RGB, cell_bg: vt.color.RGB) vt.color.RGB {
        return switch (self) {
            .rgb => |color| color,
            .cell_foreground => cell_fg,
            .cell_background => cell_bg,
        };
    }

    pub fn eql(self: TerminalColor, other: TerminalColor) bool {
        return switch (self) {
            .rgb => |color| switch (other) {
                .rgb => |other_color| color.eql(other_color),
                else => false,
            },
            .cell_foreground => switch (other) {
                .cell_foreground => true,
                else => false,
            },
            .cell_background => switch (other) {
                .cell_background => true,
                else => false,
            },
        };
    }
};

/// The single built-in color set. Roles not set in the configuration fall back to these values.
pub const Defaults = struct {
    background: vt.color.RGB,
    foreground: vt.color.RGB,
    cursor_color: vt.color.RGB,
    selection_background: vt.color.RGB,
    selection_foreground: vt.color.RGB,
    /// ANSI palette entries 0-15, ordered regular0-7 then bright0-7.
    palette: [16]vt.color.RGB,
};

pub const default_colors: Defaults = .{
    .background = .{ .r = 0x29, .g = 0x29, .b = 0x29 },
    .foreground = .{ .r = 0xff, .g = 0xff, .b = 0xff },
    .cursor_color = .{ .r = 0xff, .g = 0xff, .b = 0xff },
    .selection_background = .{ .r = 0x0f, .g = 0x6c, .b = 0xbd },
    .selection_foreground = .{ .r = 0xff, .g = 0xff, .b = 0xff },
    .palette = .{
        .{ .r = 0x5c, .g = 0x5c, .b = 0x5c },
        .{ .r = 0xe3, .g = 0x7d, .b = 0x80 },
        .{ .r = 0x54, .g = 0xb0, .b = 0x54 },
        .{ .r = 0xfe, .g = 0xee, .b = 0x66 },
        .{ .r = 0x47, .g = 0x9e, .b = 0xf5 },
        .{ .r = 0xd9, .g = 0x57, .b = 0xa8 },
        .{ .r = 0x56, .g = 0xbf, .b = 0xd7 },
        .{ .r = 0xd6, .g = 0xd6, .b = 0xd6 },
        .{ .r = 0x99, .g = 0x99, .b = 0x99 },
        .{ .r = 0xf1, .g = 0xbb, .b = 0xbc },
        .{ .r = 0x9f, .g = 0xd8, .b = 0x9f },
        .{ .r = 0xfe, .g = 0xf7, .b = 0xb2 },
        .{ .r = 0x96, .g = 0xc6, .b = 0xfa },
        .{ .r = 0xec, .g = 0xa5, .b = 0xd1 },
        .{ .r = 0xa4, .g = 0xde, .b = 0xeb },
        .{ .r = 0xff, .g = 0xff, .b = 0xff },
    },
};

/// "#RRGGBB" or "RRGGBB".
pub fn parseColor(value: []const u8) error{InvalidValue}!vt.color.RGB {
    const hex = if (value.len > 0 and value[0] == '#') value[1..] else value;
    if (hex.len != 6) return error.InvalidValue;
    const num = std.fmt.parseInt(u24, hex, 16) catch return error.InvalidValue;
    return .{
        .r = @intCast(num >> 16),
        .g = @intCast((num >> 8) & 0xff),
        .b = @intCast(num & 0xff),
    };
}

/// Hex color, `cell-foreground`, or `cell-background`.
pub fn parseTerminalColor(value: []const u8) error{InvalidValue}!TerminalColor {
    if (std.mem.eql(u8, value, "cell-foreground")) return .cell_foreground;
    if (std.mem.eql(u8, value, "cell-background")) return .cell_background;
    return .{ .rgb = try parseColor(value) };
}

test "parse terminal colors" {
    try std.testing.expectEqual(@as(TerminalColor, .cell_foreground), try parseTerminalColor("cell-foreground"));
    try std.testing.expectEqual(@as(TerminalColor, .cell_background), try parseTerminalColor("cell-background"));
    try std.testing.expectEqual(
        TerminalColor{ .rgb = .{ .r = 0xaa, .g = 0xbb, .b = 0xcc } },
        try parseTerminalColor("#aabbcc"),
    );
    try std.testing.expectError(error.InvalidValue, parseTerminalColor("cell-foo"));
    try std.testing.expectError(error.InvalidValue, parseColor("cell-foreground"));
}

test "terminal color resolve and equality" {
    const fg: vt.color.RGB = .{ .r = 1, .g = 2, .b = 3 };
    const bg: vt.color.RGB = .{ .r = 4, .g = 5, .b = 6 };
    const rgb: TerminalColor = .{ .rgb = fg };
    try std.testing.expectEqual(fg, @as(TerminalColor, .cell_foreground).resolve(fg, bg));
    try std.testing.expectEqual(bg, @as(TerminalColor, .cell_background).resolve(fg, bg));
    try std.testing.expectEqual(fg, rgb.resolve(bg, bg));
    try std.testing.expect(rgb.eql(.{ .rgb = fg }));
    try std.testing.expect(!rgb.eql(.cell_foreground));
    try std.testing.expect(@as(TerminalColor, .cell_foreground).eql(.cell_foreground));
    try std.testing.expect(!@as(TerminalColor, .cell_foreground).eql(.cell_background));
}
