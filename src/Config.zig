//! A `key = value` INI file with `#` comments and optional `[section]` groups, at
//! $XDG_CONFIG_HOME/unn/unn.ini (or ~/.config/unn/unn.ini). The first run writes a
//! template; invalid lines warn and keep previous settings.

const Config = @This();

const std = @import("std");
const builtin = @import("builtin");
const vt = @import("ghostty-vt");
const color = @import("colors.zig");
const keybind = @import("keybind.zig");

const log = std.log.scoped(.config);
const baseline_dpi = 96.0;
const points_per_inch = 72.0;
const min_window_width = 10;
const min_window_height = 4;

fn warn(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) log.warn(fmt, args);
}

pub const app_id = "jetdafih.unn";

/// Ready-to-edit template written to the default path on first run. Every
/// value matches the built-in default; uncomment or change what you need.
pub const default_config_text =
    \\# Unn configuration. Written on first run; edit to taste.
    \\# Reload a running instance with Ctrl+Shift+, or just relaunch unn.
    \\
    \\# ── Font ──
    \\font-family = monospace
    \\# pt, or a px suffix for logical pixels.
    \\font-size = 12
    \\# adjust-cell-height = 0
    \\# adjust-box-thickness = 0
    \\# adjust-underline-thickness = 0
    \\# adjust-strikethrough-thickness = 0
    \\# adjust-overline-thickness = 0
    \\# adjust-cursor-thickness = 0
    \\
    \\# ── Window ──
    \\window-padding-x = 0
    \\window-padding-y = 0
    \\window-width = 0
    \\# Both must be set to take effect.
    \\window-height = 0
    \\# working-directory = ~
    \\# command = /bin/bash -l
    \\
    \\# ── Shell integration ──
    \\# pipe-command-output = wl-copy
    \\# never | unfocused | always; actions: bell, notify.
    \\notify-on-command-finish = never
    \\notify-on-command-finish-action = bell
    \\notify-on-command-finish-after = 5s
    \\
    \\# ── Process ──
    \\scrollback-limit = 50000000
    \\image-storage-limit = 320000000
    \\
    \\# ── Scrolling ──
    \\# One value for both devices, or precision:V,discrete:V.
    \\mouse-scroll-multiplier = precision:1,discrete:3
    \\inertial-scrolling = true
    \\smooth-scrolling = true
    \\
    \\# ── Background ──
    \\background-opacity = 1
    \\background-opacity-cells = false
    \\
    \\# ── Keybindings ──
    \\# trigger=action; only scroll_page_lines:±N and unbind.
    \\# keybind = ctrl+shift+k=scroll_page_lines:-1
    \\
    \\# ── Colors ──
    \\background = #292929
    \\foreground = #ffffff
    \\cursor = #ffffff
    \\# cursor-text = #292929
    \\selection-background = #0f6cbd
    \\selection-foreground = #ffffff
    \\
    \\# regular0-7 then bright0-7.
    \\regular0 = #5c5c5c
    \\regular1 = #e37d80
    \\regular2 = #54b054
    \\regular3 = #feee66
    \\regular4 = #479ef5
    \\regular5 = #d957a8
    \\regular6 = #56bfd7
    \\regular7 = #d6d6d6
    \\bright0 = #999999
    \\bright1 = #f1bbbc
    \\bright2 = #9fd89f
    \\bright3 = #fef7b2
    \\bright4 = #96c6fa
    \\bright5 = #eca5d1
    \\bright6 = #a4deeb
    \\bright7 = #ffffff
    \\
;

pub const WindowPadding = struct {
    first: u31 = 0,
    second: u31 = 0,
};

pub const Command = union(enum) {
    shell: [:0]const u8,
    direct: []const [:0]const u8,
};

pub const MouseScrollMultiplier = struct {
    precision: f64 = 1,
    discrete: f64 = 3,
};

pub const TerminalColor = color.TerminalColor;
pub const default_colors = color.default_colors;

pub const FontSize = union(enum) {
    points: f32,
    pixels: f32,

    pub fn value(self: FontSize) f32 {
        return switch (self) {
            .points => |size| size,
            .pixels => |size| size,
        };
    }

    pub fn unit(self: FontSize) []const u8 {
        return switch (self) {
            .points => "pt",
            .pixels => "px",
        };
    }
};

/// Adjustment to a font-derived metric: absolute values are physical pixel deltas,
/// percentages scale the natural metric. Results are at least one pixel.
pub const MetricModifier = union(enum) {
    absolute: i32,
    percent: f64,

    pub fn apply(self: MetricModifier, natural: u31) u31 {
        return switch (self) {
            .absolute => |delta| @intCast(std.math.clamp(
                @as(i64, natural) + delta,
                1,
                std.math.maxInt(u31),
            )),
            .percent => |percent| percent: {
                const multiplier = @max(0, 1 + percent / 100);
                const adjusted = @round(@as(f64, @floatFromInt(natural)) * multiplier);
                break :percent @intFromFloat(std.math.clamp(
                    adjusted,
                    1,
                    @as(f64, @floatFromInt(std.math.maxInt(u31))),
                ));
            },
        };
    }
};

/// Adjustments to primary-font metrics; unset fields keep the natural ones. Line positions
/// use the natural thickness, before thickness adjustments.
pub const MetricAdjustments = struct {
    cell_height: ?MetricModifier = null,
    box_thickness: ?MetricModifier = null,
    underline_thickness: ?MetricModifier = null,
    strikethrough_thickness: ?MetricModifier = null,
    overline_thickness: ?MetricModifier = null,
    /// Bar, underline, and hollow cursor strokes.
    cursor_thickness: ?MetricModifier = null,
};

font_family: [:0]const u8 = "monospace",
/// Bare and `pt` values are typographic points; `px` values are logical
/// pixels. Both apply the output's fractional scale during rasterization.
font_size: FontSize = .{ .points = 12 },
metric_adjustments: MetricAdjustments = .{},
/// Minimum window padding in logical pixels. One configured value applies to
/// both sides; two values are left/right for X and top/bottom for Y.
window_padding_x: WindowPadding = .{},
window_padding_y: WindowPadding = .{},
/// Initial grid size in cells; 0 leaves a dimension unset and both must be set to apply.
/// Clamped to at least 10x4. Startup only; reloads don't resize.
window_width: u16 = 0,
window_height: u16 = 0,
/// Starting directory for the child: an absolute path, `~`, or `~/path`.
/// Unset inherits Unn's directory. This only affects startup.
working_directory: ?[:0]const u8 = null,
/// Command to run; unset falls back to $SHELL, then /bin/sh. This only
/// affects startup because reloading does not replace a running child.
command: ?Command = null,
/// Shell command that receives the last semantic command output on stdin.
pipe_command_output: ?[:0]const u8 = null,
notify_on_command_finish: NotifyOnCommandFinish = .never,
notify_on_command_finish_action: CommandFinishAction = .{},
/// Minimum command duration in nanoseconds; equality does not notify.
notify_on_command_finish_after: u64 = 5 * std.time.ns_per_s,
/// Logical terminal page storage in bytes, including the active screen. This
/// only affects startup because libghostty-vt does not resize live scrollback.
scrollback_limit: usize = 50_000_000,
/// Per-screen byte limit for kitty images; 0 disables the protocol. A single larger
/// image is rejected, so it must fit a fullscreen RGBA frame.
image_storage_limit: usize = 320 * 1000 * 1000,
mouse_scroll_multiplier: MouseScrollMultiplier = .{},
/// Whether finger scrolling continues with inertial motion after release.
inertial_scrolling: bool = true,
/// Render scrollback movement in pixels rather than whole rows, easing mouse wheel steps.
smooth_scrolling: bool = true,
/// User keybindings, backed by the config arena. Defaults are resolved separately.
keybinds: std.ArrayList(keybind.Binding) = .empty,
/// Effective alpha of the default terminal background. Keeping this as an
/// 8-bit value matches the wl_shm buffer and makes the opaque fast path exact.
background_opacity: u8 = 255,

/// Whether background opacity also applies to explicit cell backgrounds.
background_opacity_cells: bool = false,

background: ?vt.color.RGB = null,
foreground: ?vt.color.RGB = null,
cursor_color: ?TerminalColor = null,
cursor_text: ?TerminalColor = null,
selection_background: ?vt.color.RGB = null,
selection_foreground: ?vt.color.RGB = null,
/// ANSI palette overrides for entries 0-15 (regular0-7, bright0-7).
palette: [16]?vt.color.RGB = @splat(null),

pub const NotifyOnCommandFinish = enum { never, unfocused, always };
pub const CommandFinishAction = struct {
    bell: bool = true,
    notify: bool = false,
};

/// Absolute path of the default configuration file, or null when neither
/// XDG_CONFIG_HOME nor HOME is available.
pub fn defaultPath(arena: std.mem.Allocator, environ: std.process.Environ) ?[:0]const u8 {
    // XDG base directories must be absolute; empty values use defaults.
    const base = environ.getPosix("XDG_CONFIG_HOME") orelse "";
    if (std.fs.path.isAbsolute(base)) {
        return std.fmt.allocPrintSentinel(arena, "{s}/unn/unn.ini", .{base}, 0) catch null;
    }
    if (environ.getPosix("HOME")) |home| {
        return std.fmt.allocPrintSentinel(arena, "{s}/.config/unn/unn.ini", .{home}, 0) catch null;
    }
    return null;
}

/// Load the default config, writing a full template on first run. Strings live in `arena`.
pub fn load(arena: std.mem.Allocator, environ: std.process.Environ) Config {
    const path = defaultPath(arena, environ) orelse return .{};
    if (readFile(arena, path)) |text| {
        log.info("loaded {s}", .{path});
        return parse(arena, text);
    }
    writeDefaultConfig(path);
    return parse(arena, default_config_text);
}

/// Write the default template, creating parent directories. Failures are
/// non-fatal: the built-in defaults still apply.
fn writeDefaultConfig(path: [:0]const u8) void {
    const dir = std.fs.path.dirname(path) orelse {
        warn("cannot resolve config directory for {s}", .{path});
        return;
    };
    makeDirs(dir) catch |err| {
        warn("cannot create config directory {s}: {}", .{ dir, err });
        return;
    };

    const linux = std.os.linux;
    const rc = linux.openat(linux.AT.FDCWD, path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
        .CLOEXEC = true,
    }, 0o644);
    if (linux.errno(rc) != .SUCCESS) return; // Existing file or unwritable.
    const fd: std.posix.fd_t = @intCast(rc);
    defer _ = linux.close(fd);

    var written: usize = 0;
    while (written < default_config_text.len) {
        const n = linux.write(fd, default_config_text.ptr + written, default_config_text.len - written);
        if (linux.errno(n) != .SUCCESS) {
            warn("cannot write {s}", .{path});
            return;
        }
        if (n == 0) return;
        written += n;
    }
    log.info("wrote default config to {s}", .{path});
}

/// Create every component of an absolute directory path, ignoring components that already exist.
fn makeDirs(path: []const u8) !void {
    if (path.len == 0 or path.len > std.fs.max_path_bytes) return error.InvalidPath;
    var start: usize = if (path[0] == '/') 1 else 0;
    while (std.mem.indexOfScalarPos(u8, path, start, '/')) |slash| {
        try makeDir(path[0..slash]);
        start = slash + 1;
    }
    try makeDir(path);
}

fn makeDir(path: []const u8) !void {
    const linux = std.os.linux;
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len == 0 or path.len > std.fs.max_path_bytes) return error.InvalidPath;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const rc = linux.mkdirat(linux.AT.FDCWD, buf[0..path.len :0], 0o755);
    const err = linux.errno(rc);
    if (err != .SUCCESS and err != .EXIST) return error.MakeDirFailed;
}

/// Load a specific config file. Missing or unreadable file means defaults.
pub fn loadPath(arena: std.mem.Allocator, path: [:0]const u8) Config {
    const text = readFile(arena, path) orelse return .{};
    log.info("loaded {s}", .{path});
    return parse(arena, text);
}

pub fn parse(arena: std.mem.Allocator, text: []const u8) Config {
    var config: Config = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 0;
    var section: []const u8 = "";
    while (lines.next()) |raw_line| {
        line_no += 1;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        // `[section]` headers group entries. In a section a key tries `section-key` first
        // (`[font]` + `family` -> `font-family`), then the bare key, so shared names like
        // `background` under `[colors]` still resolve. Section names are case-insensitive.
        if (line[0] == '[') {
            const close = std.mem.indexOfScalar(u8, line, ']') orelse {
                warn("line {d}: missing ']' in section header, ignoring: {s}", .{ line_no, line });
                continue;
            };
            const raw_name = std.mem.trim(u8, line[1..close], " \t");
            if (raw_name.len == 0) {
                warn("line {d}: empty section name, ignoring", .{line_no});
                continue;
            }
            const rest = std.mem.trim(u8, line[close + 1 ..], " \t");
            if (rest.len != 0 and rest[0] != '#') {
                warn("line {d}: trailing text after section header, ignoring: {s}", .{ line_no, line });
                continue;
            }
            const name = arena.dupe(u8, raw_name) catch return config;
            _ = std.ascii.lowerString(name, name);
            section = name;
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            warn("line {d}: missing '=', ignoring: {s}", .{ line_no, line });
            continue;
        };
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (value.len == 0) {
            warn("line {d}: empty value for '{s}', ignoring", .{ line_no, key });
            continue;
        }

        if (section.len != 0) {
            const prefixed = std.fmt.allocPrint(arena, "{s}-{s}", .{ section, key }) catch return config;
            if (config.set(arena, prefixed, value)) |_| {
                continue;
            } else |err| switch (err) {
                error.UnknownKey => {},
                else => {
                    warn("line {d}: invalid value for '{s}': {s}", .{ line_no, prefixed, value });
                    continue;
                },
            }
        }

        config.set(arena, key, value) catch |err| switch (err) {
            error.UnknownKey => warn("line {d}: unknown key '{s}', ignoring", .{ line_no, key }),
            else => warn("line {d}: invalid value for '{s}': {s}", .{ line_no, key, value }),
        };
    }
    return config;
}

pub const SetError = error{ InvalidValue, UnknownKey, OutOfMemory };

pub fn applyOverride(self: *Config, arena: std.mem.Allocator, text: []const u8) SetError!void {
    const eq = std.mem.indexOfScalar(u8, text, '=') orelse return error.InvalidValue;
    const key = std.mem.trim(u8, text[0..eq], " \t");
    const value = std.mem.trim(u8, text[eq + 1 ..], " \t");
    if (key.len == 0 or value.len == 0) return error.InvalidValue;
    try self.set(arena, key, value);
}

pub fn set(self: *Config, arena: std.mem.Allocator, key: []const u8, value: []const u8) SetError!void {
    if (std.mem.eql(u8, key, "font-family")) {
        self.font_family = try arena.dupeSentinel(u8, value, 0);
    } else if (std.mem.eql(u8, key, "font-size")) {
        self.font_size = try parseFontSize(value);
    } else if (std.mem.eql(u8, key, "adjust-cell-height")) {
        self.metric_adjustments.cell_height = try parseMetricModifier(value);
    } else if (std.mem.eql(u8, key, "adjust-box-thickness")) {
        self.metric_adjustments.box_thickness = try parseMetricModifier(value);
    } else if (std.mem.eql(u8, key, "adjust-underline-thickness")) {
        self.metric_adjustments.underline_thickness = try parseMetricModifier(value);
    } else if (std.mem.eql(u8, key, "adjust-strikethrough-thickness")) {
        self.metric_adjustments.strikethrough_thickness = try parseMetricModifier(value);
    } else if (std.mem.eql(u8, key, "adjust-overline-thickness")) {
        self.metric_adjustments.overline_thickness = try parseMetricModifier(value);
    } else if (std.mem.eql(u8, key, "adjust-cursor-thickness")) {
        self.metric_adjustments.cursor_thickness = try parseMetricModifier(value);
    } else if (std.mem.eql(u8, key, "window-padding-x")) {
        self.window_padding_x = try parseWindowPadding(value);
    } else if (std.mem.eql(u8, key, "window-padding-y")) {
        self.window_padding_y = try parseWindowPadding(value);
    } else if (std.mem.eql(u8, key, "window-width")) {
        self.window_width = try parseWindowCells(value, min_window_width);
    } else if (std.mem.eql(u8, key, "window-height")) {
        self.window_height = try parseWindowCells(value, min_window_height);
    } else if (std.mem.eql(u8, key, "working-directory")) {
        const home_relative = std.mem.eql(u8, value, "~") or std.mem.startsWith(u8, value, "~/");
        if (!home_relative and !std.fs.path.isAbsolute(value)) return error.InvalidValue;
        self.working_directory = try arena.dupeSentinel(u8, value, 0);
    } else if (std.mem.eql(u8, key, "command")) {
        self.command = try parseCommand(arena, value);
    } else if (std.mem.eql(u8, key, "pipe-command-output")) {
        self.pipe_command_output = try arena.dupeSentinel(u8, value, 0);
    } else if (std.mem.eql(u8, key, "notify-on-command-finish")) {
        self.notify_on_command_finish = std.meta.stringToEnum(NotifyOnCommandFinish, value) orelse return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "notify-on-command-finish-action")) {
        self.notify_on_command_finish_action = try parseCommandFinishAction(value);
    } else if (std.mem.eql(u8, key, "notify-on-command-finish-after")) {
        self.notify_on_command_finish_after = try parseDuration(value);
    } else if (std.mem.eql(u8, key, "scrollback-limit")) {
        self.scrollback_limit = std.fmt.parseInt(usize, value, 10) catch return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "image-storage-limit")) {
        const limit = std.fmt.parseInt(usize, value, 10) catch return error.InvalidValue;
        // Same cap as Ghostty's image-storage-limit (4GiB).
        if (limit > std.math.maxInt(u32)) return error.InvalidValue;
        self.image_storage_limit = limit;
    } else if (std.mem.eql(u8, key, "mouse-scroll-multiplier")) {
        self.mouse_scroll_multiplier = try parseMouseScrollMultiplier(self.mouse_scroll_multiplier, value);
    } else if (std.mem.eql(u8, key, "keybind")) {
        try keybind.put(&self.keybinds, arena, value);
    } else if (std.mem.eql(u8, key, "inertial-scrolling")) {
        self.inertial_scrolling = if (std.mem.eql(u8, value, "true"))
            true
        else if (std.mem.eql(u8, value, "false"))
            false
        else
            return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "smooth-scrolling")) {
        self.smooth_scrolling = if (std.mem.eql(u8, value, "true"))
            true
        else if (std.mem.eql(u8, value, "false"))
            false
        else
            return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "background-opacity")) {
        self.background_opacity = try parseOpacity(value);
    } else if (std.mem.eql(u8, key, "background-opacity-cells")) {
        self.background_opacity_cells = if (std.mem.eql(u8, value, "true"))
            true
        else if (std.mem.eql(u8, value, "false"))
            false
        else
            return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "background")) {
        self.background = try color.parseColor(value);
    } else if (std.mem.eql(u8, key, "foreground")) {
        self.foreground = try color.parseColor(value);
    } else if (std.mem.eql(u8, key, "cursor")) {
        self.cursor_color = try color.parseTerminalColor(value);
    } else if (std.mem.eql(u8, key, "cursor-text")) {
        self.cursor_text = try color.parseTerminalColor(value);
    } else if (std.mem.eql(u8, key, "selection-background")) {
        self.selection_background = try color.parseColor(value);
    } else if (std.mem.eql(u8, key, "selection-foreground")) {
        self.selection_foreground = try color.parseColor(value);
    } else if (paletteIndexForKey(key)) |index| {
        self.palette[index] = try color.parseColor(value);
    } else {
        return error.UnknownKey;
    }
}

/// Map the foot-style `regular0`-`regular7` and `bright0`-`bright7` keys to
/// ANSI palette indices 0-15. Any other key returns null.
fn paletteIndexForKey(key: []const u8) ?u8 {
    const Group = struct { prefix: []const u8, base: u8 };
    const groups = [_]Group{
        .{ .prefix = "regular", .base = 0 },
        .{ .prefix = "bright", .base = 8 },
    };
    for (groups) |group| {
        if (!std.mem.startsWith(u8, key, group.prefix)) continue;
        const suffix = key[group.prefix.len..];
        if (suffix.len != 1) return null;
        const digit = suffix[0] -% '0';
        if (digit > 7) return null;
        return group.base + digit;
    }
    return null;
}

fn parseCommandFinishAction(value: []const u8) error{InvalidValue}!CommandFinishAction {
    for ([_][]const u8{ "true", "1", "t", "T" }) |name| {
        if (std.mem.eql(u8, value, name)) return .{ .bell = true, .notify = true };
    }
    for ([_][]const u8{ "false", "0", "f", "F" }) |name| {
        if (std.mem.eql(u8, value, name)) return .{ .bell = false, .notify = false };
    }
    // Each assignment starts from the defaults, not the preceding assignment.
    var result: CommandFinishAction = .{};
    var tokens = std.mem.splitScalar(u8, value, ',');
    while (tokens.next()) |token| {
        var name = std.mem.trim(u8, token, &std.ascii.whitespace);
        const enabled = !std.mem.startsWith(u8, name, "no-");
        if (!enabled) name = name[3..];
        if (std.mem.eql(u8, name, "bell")) {
            result.bell = enabled;
        } else if (std.mem.eql(u8, name, "notify")) {
            result.notify = enabled;
        } else return error.InvalidValue;
    }
    return result;
}

fn parseDuration(value: []const u8) error{InvalidValue}!u64 {
    const units = .{
        .{ "y", 365 * std.time.ns_per_day },
        .{ "w", std.time.ns_per_week },
        .{ "d", std.time.ns_per_day },
        .{ "h", std.time.ns_per_hour },
        .{ "m", std.time.ns_per_min },
        .{ "s", std.time.ns_per_s },
        .{ "ms", std.time.ns_per_ms },
        .{ "us", std.time.ns_per_us },
        .{ "µs", std.time.ns_per_us },
        .{ "ns", 1 },
    };
    var rest = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (std.mem.eql(u8, rest, "0")) return 0;
    if (rest.len == 0) return error.InvalidValue;
    var total: u64 = 0;
    while (rest.len > 0) {
        var end: usize = 0;
        while (end < rest.len and std.ascii.isDigit(rest[end])) : (end += 1) {}
        if (end == 0) return error.InvalidValue;
        const number = std.fmt.parseUnsigned(u64, rest[0..end], 10) catch return error.InvalidValue;
        rest = rest[end..];
        var unit_len: usize = 0;
        var factor: u64 = 0;
        inline for (units) |unit| {
            if (unit[0].len > unit_len and std.mem.startsWith(u8, rest, unit[0])) {
                unit_len = unit[0].len;
                factor = unit[1];
            }
        }
        if (unit_len == 0) return error.InvalidValue;
        total +|= number *| factor;
        rest = std.mem.trimStart(u8, rest[unit_len..], &std.ascii.whitespace);
    }
    return total;
}

fn parseFontSize(value: []const u8) error{InvalidValue}!FontSize {
    var number = value;
    var unit: std.meta.Tag(FontSize) = .points;
    if (std.mem.endsWith(u8, value, "pt")) {
        number = value[0 .. value.len - 2];
    } else if (std.mem.endsWith(u8, value, "px")) {
        number = value[0 .. value.len - 2];
        unit = .pixels;
    }
    if (number.len == 0) return error.InvalidValue;

    const size = std.fmt.parseFloat(f32, number) catch return error.InvalidValue;
    if (!std.math.isFinite(size) or size <= 0 or size > 512) return error.InvalidValue;
    return switch (unit) {
        .points => .{ .points = size },
        .pixels => .{ .pixels = size },
    };
}

fn parseMetricModifier(value: []const u8) error{InvalidValue}!MetricModifier {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (std.mem.endsWith(u8, trimmed, "%")) {
        const number = trimmed[0 .. trimmed.len - 1];
        if (number.len == 0) return error.InvalidValue;
        const percent = std.fmt.parseFloat(f64, number) catch return error.InvalidValue;
        if (!std.math.isFinite(percent)) return error.InvalidValue;
        return .{ .percent = percent };
    }
    return .{
        .absolute = std.fmt.parseInt(i32, trimmed, 10) catch return error.InvalidValue,
    };
}

fn parseCommand(arena: std.mem.Allocator, value: []const u8) SetError!Command {
    const trimmed = std.mem.trim(u8, value, " \t");
    const mode: std.meta.Tag(Command), const text = mode: {
        if (std.mem.startsWith(u8, trimmed, "direct:")) {
            break :mode .{ .direct, std.mem.trim(u8, trimmed["direct:".len..], " \t") };
        }
        if (std.mem.startsWith(u8, trimmed, "shell:")) {
            break :mode .{ .shell, std.mem.trim(u8, trimmed["shell:".len..], " \t") };
        }
        break :mode .{ .shell, trimmed };
    };
    if (text.len == 0) return error.InvalidValue;

    return switch (mode) {
        .shell => .{ .shell = try arena.dupeSentinel(u8, text, 0) },
        .direct => direct: {
            var args: std.ArrayList([:0]const u8) = .empty;
            var tokens = std.mem.tokenizeAny(u8, text, " \t");
            while (tokens.next()) |arg| try args.append(arena, try arena.dupeSentinel(u8, arg, 0));
            if (args.items.len == 0) return error.InvalidValue;
            break :direct .{ .direct = try args.toOwnedSlice(arena) };
        },
    };
}

fn parseMouseScrollMultiplier(current: MouseScrollMultiplier, value: []const u8) error{InvalidValue}!MouseScrollMultiplier {
    if (std.mem.indexOfScalar(u8, value, ':') == null) {
        const multiplier = try parseScrollMultiplier(value);
        return .{ .precision = multiplier, .discrete = multiplier };
    }

    var result = current;
    var entries = std.mem.splitScalar(u8, value, ',');
    while (entries.next()) |entry| {
        const colon = std.mem.indexOfScalar(u8, entry, ':') orelse return error.InvalidValue;
        if (std.mem.indexOfScalarPos(u8, entry, colon + 1, ':') != null) return error.InvalidValue;
        const name = std.mem.trim(u8, entry[0..colon], " \t");
        const multiplier = try parseScrollMultiplier(entry[colon + 1 ..]);
        if (std.mem.eql(u8, name, "precision")) {
            result.precision = multiplier;
        } else if (std.mem.eql(u8, name, "discrete")) {
            result.discrete = multiplier;
        } else {
            return error.InvalidValue;
        }
    }
    return result;
}

fn parseScrollMultiplier(value: []const u8) error{InvalidValue}!f64 {
    const multiplier = std.fmt.parseFloat(f64, std.mem.trim(u8, value, " \t")) catch return error.InvalidValue;
    if (!std.math.isFinite(multiplier)) return error.InvalidValue;
    return std.math.clamp(multiplier, 0.01, 10_000);
}

fn parseOpacity(value: []const u8) error{InvalidValue}!u8 {
    const opacity = std.fmt.parseFloat(f64, std.mem.trim(u8, value, " \t")) catch return error.InvalidValue;
    if (!std.math.isFinite(opacity) or opacity < 0 or opacity > 1) return error.InvalidValue;
    if (opacity == 1) return 255;
    return @min(254, @as(u8, @intFromFloat(@round(opacity * 255))));
}

fn parseWindowPadding(value: []const u8) error{InvalidValue}!WindowPadding {
    var values = std.mem.splitScalar(u8, value, ',');
    const first_text = std.mem.trim(u8, values.next() orelse return error.InvalidValue, " \t");
    if (first_text.len == 0) return error.InvalidValue;
    const first = std.fmt.parseInt(u31, first_text, 10) catch return error.InvalidValue;
    const second_text = values.next() orelse return .{ .first = first, .second = first };
    if (values.next() != null) return error.InvalidValue;
    const trimmed_second = std.mem.trim(u8, second_text, " \t");
    if (trimmed_second.len == 0) return error.InvalidValue;
    return .{
        .first = first,
        .second = std.fmt.parseInt(u31, trimmed_second, 10) catch return error.InvalidValue,
    };
}

fn parseWindowCells(value: []const u8, min: u16) error{InvalidValue}!u16 {
    const cells = std.fmt.parseInt(u16, value, 10) catch return error.InvalidValue;
    return if (cells == 0) 0 else @max(min, cells);
}

/// Convert a size to physical pixels: points use the 96 DPI baseline, pixel sizes are
/// already logical. Rounding is left to Font so grid and 26.6 outline sizes stay independent.
pub fn fontSizePixels(size: FontSize, scale120: u32) f64 {
    std.debug.assert(std.math.isFinite(size.value()) and size.value() > 0);
    std.debug.assert(scale120 > 0);

    const output_scale = @as(f64, @floatFromInt(scale120)) / 120.0;
    const logical_pixels: f64 = switch (size) {
        .points => |points| @as(f64, points) * baseline_dpi / points_per_inch,
        .pixels => |pixels| pixels,
    };
    const pixels = logical_pixels * output_scale;
    return @max(1, pixels);
}

fn effectiveColor(self: *const Config, comptime field: []const u8) vt.color.RGB {
    return @field(self, field) orelse @field(color.default_colors, field);
}

pub fn effectiveSelectionBackground(self: *const Config) vt.color.RGB {
    return self.effectiveColor("selection_background");
}

pub fn effectiveSelectionForeground(self: *const Config) vt.color.RGB {
    return self.effectiveColor("selection_foreground");
}

pub fn effectiveCursorColor(self: *const Config) TerminalColor {
    return self.cursor_color orelse .{ .rgb = color.default_colors.cursor_color };
}

pub fn effectiveCursorText(self: *const Config) ?TerminalColor {
    return self.cursor_text;
}

/// Terminal colors from this config form the *default* layer, so OSC 10/11/12/4 can still
/// override and reset. The caller owns the palette unless a successful `vt.Terminal.init`
/// takes it.
pub fn terminalColors(self: *const Config, alloc: std.mem.Allocator) !vt.Terminal.Colors {
    var palette: [256]vt.color.RGB = vt.color.default;
    for (color.default_colors.palette, 0..) |rgb, i| palette[i] = rgb;
    for (&self.palette, 0..) |entry, i| {
        if (entry) |rgb| palette[i] = rgb;
    }
    return .{
        .background = .init(self.effectiveColor("background")),
        .foreground = .init(self.effectiveColor("foreground")),
        .cursor = if (self.effectiveCursorColor().toRgb()) |rgb|
            .init(rgb)
        else
            .unset,
        .palette = try .init(alloc, palette),
    };
}

fn readFile(arena: std.mem.Allocator, path: [:0]const u8) ?[]const u8 {
    const linux = std.os.linux;
    const rc = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: std.posix.fd_t = @intCast(rc);
    defer _ = linux.close(fd);

    const max_size = 1024 * 1024;
    var buf = std.ArrayList(u8).initCapacity(arena, 4096) catch return null;
    while (buf.items.len < max_size) {
        buf.ensureUnusedCapacity(arena, 4096) catch return null;
        const dest = buf.unusedCapacitySlice();
        const n = std.posix.read(fd, dest) catch return null;
        if (n == 0) break;
        buf.items.len += n;
    }
    return buf.items;
}

test "defaults" {
    const config: Config = .{};
    try std.testing.expectEqualStrings("monospace", config.font_family);
    try std.testing.expectEqual(FontSize{ .points = 12 }, config.font_size);
    try std.testing.expectEqual(WindowPadding{}, config.window_padding_x);
    try std.testing.expectEqual(WindowPadding{}, config.window_padding_y);
    try std.testing.expectEqual(@as(?Command, null), config.command);
    try std.testing.expectEqual(@as(?[:0]const u8, null), config.pipe_command_output);
    try std.testing.expectEqual(.never, config.notify_on_command_finish);
    try std.testing.expect(config.notify_on_command_finish_action.bell);
    try std.testing.expect(!config.notify_on_command_finish_action.notify);
    try std.testing.expectEqual(@as(u64, 5_000_000_000), config.notify_on_command_finish_after);
    try std.testing.expectEqual(@as(usize, 50_000_000), config.scrollback_limit);
    try std.testing.expectEqual(@as(usize, 320_000_000), config.image_storage_limit);
    try std.testing.expectEqual(@as(f64, 1), config.mouse_scroll_multiplier.precision);
    try std.testing.expectEqual(@as(f64, 3), config.mouse_scroll_multiplier.discrete);
    try std.testing.expect(config.inertial_scrolling);
    try std.testing.expectEqual(@as(i16, -1), keybind.getEvent(config.keybinds.items, .{
        .key = .arrow_up,
        .mods = .{ .shift = true },
    }).?.scroll_page_lines);
    try std.testing.expectEqual(@as(i16, 1), keybind.getEvent(config.keybinds.items, .{
        .key = .arrow_down,
        .mods = .{ .shift = true },
    }).?.scroll_page_lines);
    try std.testing.expectEqual(@as(u8, 255), config.background_opacity);

    try std.testing.expect(!config.background_opacity_cells);
    try std.testing.expectEqual(@as(?vt.color.RGB, null), config.background);
    try std.testing.expectEqual(@as(?vt.color.RGB, null), config.foreground);
    try std.testing.expectEqual(@as(?TerminalColor, null), config.cursor_color);
    try std.testing.expectEqual(@as(?TerminalColor, null), config.cursor_text);
    try std.testing.expectEqual(@as(?vt.color.RGB, null), config.selection_background);
    try std.testing.expectEqual(@as(?vt.color.RGB, null), config.selection_foreground);
    for (config.palette) |entry| try std.testing.expectEqual(@as(?vt.color.RGB, null), entry);
    try std.testing.expectEqual(default_colors.selection_background, config.effectiveSelectionBackground());
    try std.testing.expectEqual(default_colors.selection_foreground, config.effectiveSelectionForeground());
}

test "default config template matches built-in defaults" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const config = parse(arena_state.allocator(), default_config_text);

    try std.testing.expectEqualStrings("monospace", config.font_family);
    try std.testing.expectEqual(FontSize{ .points = 12 }, config.font_size);
    try std.testing.expectEqual(.never, config.notify_on_command_finish);
    try std.testing.expect(config.notify_on_command_finish_action.bell);
    try std.testing.expect(!config.notify_on_command_finish_action.notify);
    try std.testing.expectEqual(@as(u64, 5_000_000_000), config.notify_on_command_finish_after);
    try std.testing.expectEqual(@as(usize, 50_000_000), config.scrollback_limit);
    try std.testing.expectEqual(@as(usize, 320_000_000), config.image_storage_limit);
    try std.testing.expectEqual(@as(f64, 1), config.mouse_scroll_multiplier.precision);
    try std.testing.expectEqual(@as(f64, 3), config.mouse_scroll_multiplier.discrete);
    try std.testing.expect(config.inertial_scrolling);
    try std.testing.expect(config.smooth_scrolling);
    try std.testing.expectEqual(@as(u8, 255), config.background_opacity);

    try std.testing.expect(!config.background_opacity_cells);
    try std.testing.expectEqual(default_colors.background, config.background.?);
    try std.testing.expectEqual(default_colors.foreground, config.foreground.?);
    try std.testing.expectEqual(default_colors.cursor_color, config.cursor_color.?.toRgb().?);
    try std.testing.expectEqual(@as(?TerminalColor, null), config.cursor_text);
    try std.testing.expectEqual(default_colors.selection_background, config.selection_background.?);
    try std.testing.expectEqual(default_colors.selection_foreground, config.selection_foreground.?);
    for (default_colors.palette, 0..) |expected, i| {
        try std.testing.expectEqual(expected, config.palette[i].?);
    }
}

test "load writes the default config on first run" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try tmp.dir.createDirPath(io, "home");
    const home = try tmp.dir.realPathFileAlloc(io, "home", arena);
    const home_entry = try std.fmt.allocPrintSentinel(arena, "HOME={s}", .{home}, 0);
    const environ: std.process.Environ = .{ .block = .{ .slice = &.{home_entry.ptr} } };

    _ = load(arena, environ);

    const written = try tmp.dir.readFileAlloc(io, "home/.config/unn/unn.ini", arena, .limited(1 << 20));
    try std.testing.expectEqualStrings(default_config_text, written);
}

test "parse config" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const config = parse(arena,
        \\# a comment
        \\font-family = Fira Code
        \\font-size = 14.5
        \\window-padding-x = 4
        \\window-padding-y = 6, 10
        \\command = /usr/bin/fish --login
        \\pipe-command-output = cat > /tmp/unn-output
        \\scrollback-limit = 50000000
        \\image-storage-limit = 50000000
        \\mouse-scroll-multiplier = precision:1.5,discrete:5
        \\keybind = ctrl+shift+k=scroll_page_lines:-1
        \\keybind = alt+j=scroll_page_lines:1
        \\keybind = ctrl+shift+k=scroll_page_lines:-5
        \\keybind = ctrl+shift+k=scroll_page_lines:invalid
        \\inertial-scrolling = false
        \\background-opacity = 0.8
        \\background-opacity-cells = true
        \\background = #1a1b26
        \\foreground = c0caf5
        \\cursor = #aabbcc
        \\cursor-text = #010203
        \\selection-background = #040506
        \\selection-foreground = #070809
        \\regular1 = #f7768e
        \\bright0 = #123456
        \\
        \\bogus-key = whatever
        \\font-size = not-a-number
    );

    try std.testing.expectEqualStrings("Fira Code", config.font_family);
    // invalid re-assignment keeps the previous valid value
    try std.testing.expectEqual(FontSize{ .points = 14.5 }, config.font_size);
    try std.testing.expectEqual(WindowPadding{ .first = 4, .second = 4 }, config.window_padding_x);
    try std.testing.expectEqual(WindowPadding{ .first = 6, .second = 10 }, config.window_padding_y);
    try std.testing.expectEqualStrings("/usr/bin/fish --login", config.command.?.shell);
    try std.testing.expectEqualStrings("cat > /tmp/unn-output", config.pipe_command_output.?);
    try std.testing.expectEqual(@as(usize, 50_000_000), config.scrollback_limit);
    try std.testing.expectEqual(@as(usize, 50_000_000), config.image_storage_limit);
    try std.testing.expectEqual(@as(f64, 1.5), config.mouse_scroll_multiplier.precision);
    try std.testing.expectEqual(@as(f64, 5), config.mouse_scroll_multiplier.discrete);
    try std.testing.expectEqual(@as(i16, -5), keybind.getEvent(config.keybinds.items, .{
        .key = .key_k,
        .unshifted_codepoint = 'k',
        .mods = .{ .ctrl = true, .shift = true },
    }).?.scroll_page_lines);
    try std.testing.expectEqual(@as(i16, 1), keybind.getEvent(config.keybinds.items, .{
        .key = .key_j,
        .unshifted_codepoint = 'j',
        .mods = .{ .alt = true },
    }).?.scroll_page_lines);
    try std.testing.expect(!config.inertial_scrolling);
    try std.testing.expectEqual(@as(u8, 204), config.background_opacity);

    try std.testing.expect(config.background_opacity_cells);
    try std.testing.expectEqual(vt.color.RGB{ .r = 0x1a, .g = 0x1b, .b = 0x26 }, config.background.?);
    try std.testing.expectEqual(vt.color.RGB{ .r = 0xc0, .g = 0xca, .b = 0xf5 }, config.foreground.?);
    try std.testing.expectEqual(TerminalColor{ .rgb = .{ .r = 0xaa, .g = 0xbb, .b = 0xcc } }, config.cursor_color.?);
    try std.testing.expectEqual(TerminalColor{ .rgb = .{ .r = 1, .g = 2, .b = 3 } }, config.cursor_text.?);
    try std.testing.expectEqual(vt.color.RGB{ .r = 4, .g = 5, .b = 6 }, config.selection_background.?);
    try std.testing.expectEqual(vt.color.RGB{ .r = 7, .g = 8, .b = 9 }, config.selection_foreground.?);
    try std.testing.expectEqual(vt.color.RGB{ .r = 0xf7, .g = 0x76, .b = 0x8e }, config.palette[1].?);
    try std.testing.expectEqual(@as(?vt.color.RGB, null), config.palette[2]);
    try std.testing.expectEqual(vt.color.RGB{ .r = 0x12, .g = 0x34, .b = 0x56 }, config.palette[8].?);
}

test "config sections expand prefixed keys and fall back to bare keys" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const config = parse(arena,
        \\[Font]
        \\family = Fira Code
        \\size = 14.5
        \\[window]
        \\padding-x = 4
        \\width = 100
        \\height = 30
        \\[colors]
        \\background = #1a1b26
        \\foreground = c0caf5
        \\cursor = #aabbcc
        \\regular0 = #111111
        \\[font]
        \\font-family = Iosevka
        \\bogus = nope
    );

    // Same key spelled fully inside its own section still resolves.
    try std.testing.expectEqualStrings("Iosevka", config.font_family);
    try std.testing.expectEqual(FontSize{ .points = 14.5 }, config.font_size);
    try std.testing.expectEqual(WindowPadding{ .first = 4, .second = 4 }, config.window_padding_x);
    try std.testing.expectEqual(@as(u16, 100), config.window_width);
    try std.testing.expectEqual(@as(u16, 30), config.window_height);
    // `[colors]` has no `colors-background`, so the bare key is used.
    try std.testing.expectEqual(vt.color.RGB{ .r = 0x1a, .g = 0x1b, .b = 0x26 }, config.background.?);
    try std.testing.expectEqual(vt.color.RGB{ .r = 0xc0, .g = 0xca, .b = 0xf5 }, config.foreground.?);
    try std.testing.expectEqual(TerminalColor{ .rgb = .{ .r = 0xaa, .g = 0xbb, .b = 0xcc } }, config.cursor_color.?);
    try std.testing.expectEqual(vt.color.RGB{ .r = 0x11, .g = 0x11, .b = 0x11 }, config.palette[0].?);
}

test "command finish settings replace flags atomically and parse durations" {
    var config: Config = .{};
    const alloc = std.testing.allocator;
    try config.applyOverride(alloc, "notify-on-command-finish=unfocused");
    try std.testing.expectEqual(.unfocused, config.notify_on_command_finish);
    try config.applyOverride(alloc, "notify-on-command-finish=always");
    try std.testing.expectEqual(.always, config.notify_on_command_finish);
    try std.testing.expectError(error.InvalidValue, config.applyOverride(alloc, "notify-on-command-finish=true"));
    try std.testing.expectEqual(.always, config.notify_on_command_finish);

    for ([_]struct { value: []const u8, bell: bool, notify: bool }{
        .{ .value = "notify", .bell = true, .notify = true },
        .{ .value = "no-bell", .bell = false, .notify = false },
        .{ .value = "no-bell, notify", .bell = false, .notify = true },
        .{ .value = "notify,no-notify,bell", .bell = true, .notify = false },
        .{ .value = "false", .bell = false, .notify = false },
        .{ .value = "true", .bell = true, .notify = true },
    }) |case| {
        try config.set(alloc, "notify-on-command-finish-action", case.value);
        try std.testing.expectEqualDeep(CommandFinishAction{ .bell = case.bell, .notify = case.notify }, config.notify_on_command_finish_action);
    }
    for ([_][]const u8{ "notify,", "no-bell,unknown", "true,notify" }) |value| {
        try std.testing.expectError(error.InvalidValue, config.set(alloc, "notify-on-command-finish-action", value));
        try std.testing.expectEqualDeep(CommandFinishAction{ .bell = true, .notify = true }, config.notify_on_command_finish_action);
    }

    for ([_]struct { value: []const u8, ns: u64 }{
        .{ .value = "0", .ns = 0 },
        .{ .value = "1m2s 3ms4us5µs6ns", .ns = 62_003_009_006 },
        .{ .value = "1y2w3d4h", .ns = 33_019_200_000_000_000 },
        .{ .value = "2s2s", .ns = 4_000_000_000 },
        .{ .value = "600y", .ns = std.math.maxInt(u64) },
    }) |case| {
        try config.set(alloc, "notify-on-command-finish-after", case.value);
        try std.testing.expectEqual(case.ns, config.notify_on_command_finish_after);
    }
    for ([_][]const u8{ "", "5", "-1s", "1.5s", "1 s", "1msjunk", "18446744073709551616ns" }) |value| {
        try std.testing.expectError(error.InvalidValue, config.set(alloc, "notify-on-command-finish-after", value));
        try std.testing.expectEqual(std.math.maxInt(u64), config.notify_on_command_finish_after);
    }
}

test "unknown override is rejected" {
    var config: Config = .{};
    try std.testing.expectError(
        error.UnknownKey,
        config.applyOverride(std.testing.allocator, "font-famly=monospace"),
    );
}

test "keybind overrides and reloading start from defaults" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var config = parse(arena,
        \\keybind = alt+j=scroll_page_lines:1
        \\keybind = shift+up=unbind
    );
    try config.applyOverride(arena, "keybind=alt+j=scroll_page_lines:5");
    try config.applyOverride(arena, "keybind=ctrl+==scroll_page_lines:-2");
    try std.testing.expectEqual(@as(usize, 3), config.keybinds.items.len);
    try std.testing.expectEqual(@as(i16, 5), keybind.getEvent(config.keybinds.items, .{ .unshifted_codepoint = 'j', .mods = .{ .alt = true } }).?.scroll_page_lines);
    try std.testing.expectEqual(@as(i16, -2), keybind.getEvent(config.keybinds.items, .{ .unshifted_codepoint = '=', .mods = .{ .ctrl = true } }).?.scroll_page_lines);

    config = parse(arena, "");
    try std.testing.expectEqual(null, keybind.getEvent(config.keybinds.items, .{ .unshifted_codepoint = 'j', .mods = .{ .alt = true } }));
    try std.testing.expectEqual(@as(i16, -1), keybind.getEvent(config.keybinds.items, .{ .key = .arrow_up, .mods = .{ .shift = true } }).?.scroll_page_lines);
}

test "direct command parsing" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const config = parse(arena_state.allocator(),
        \\command = direct:fish --no-config
    );
    const command = config.command.?.direct;
    try std.testing.expectEqual(@as(usize, 2), command.len);
    try std.testing.expectEqualStrings("fish", command[0]);
    try std.testing.expectEqualStrings("--no-config", command[1]);
}

test "regular and bright palette keys map to ANSI indices" {
    var config: Config = .{};
    try config.set(std.testing.allocator, "regular0", "#010203");
    try config.set(std.testing.allocator, "regular7", "#040506");
    try config.set(std.testing.allocator, "bright0", "#070809");
    try config.set(std.testing.allocator, "bright7", "#0a0b0c");
    try std.testing.expectEqual(vt.color.RGB{ .r = 1, .g = 2, .b = 3 }, config.palette[0].?);
    try std.testing.expectEqual(vt.color.RGB{ .r = 4, .g = 5, .b = 6 }, config.palette[7].?);
    try std.testing.expectEqual(vt.color.RGB{ .r = 7, .g = 8, .b = 9 }, config.palette[8].?);
    try std.testing.expectEqual(vt.color.RGB{ .r = 10, .g = 11, .b = 12 }, config.palette[15].?);

    for ([_][]const u8{ "regular8", "regular", "regular00", "bright10", "regularx" }) |key| {
        try std.testing.expectError(error.UnknownKey, config.set(std.testing.allocator, key, "#000000"));
    }
    try std.testing.expectError(error.InvalidValue, config.set(std.testing.allocator, "regular1", "not-a-color"));
}

test "mouse scroll multiplier forms and clamps" {
    var config: Config = .{};
    try config.set(std.testing.allocator, "mouse-scroll-multiplier", "2.5");
    try std.testing.expectEqual(@as(f64, 2.5), config.mouse_scroll_multiplier.precision);
    try std.testing.expectEqual(@as(f64, 2.5), config.mouse_scroll_multiplier.discrete);

    try config.set(std.testing.allocator, "mouse-scroll-multiplier", "precision:0,discrete:20000");
    try std.testing.expectEqual(@as(f64, 0.01), config.mouse_scroll_multiplier.precision);
    try std.testing.expectEqual(@as(f64, 10_000), config.mouse_scroll_multiplier.discrete);
}

test "inertial scrolling accepts booleans" {
    var config: Config = .{};
    try config.set(std.testing.allocator, "inertial-scrolling", "false");
    try std.testing.expect(!config.inertial_scrolling);
    try config.set(std.testing.allocator, "inertial-scrolling", "true");
    try std.testing.expect(config.inertial_scrolling);
    try std.testing.expectError(error.InvalidValue, config.set(std.testing.allocator, "inertial-scrolling", "yes"));
}

test "smooth scrolling defaults on and accepts booleans independently of inertia" {
    var config: Config = .{};
    try std.testing.expect(config.smooth_scrolling);
    try config.set(std.testing.allocator, "smooth-scrolling", "false");
    try std.testing.expect(!config.smooth_scrolling and config.inertial_scrolling);
    try config.set(std.testing.allocator, "inertial-scrolling", "false");
    try config.set(std.testing.allocator, "smooth-scrolling", "true");
    try std.testing.expect(config.smooth_scrolling and !config.inertial_scrolling);
    try std.testing.expectError(error.InvalidValue, config.set(std.testing.allocator, "smooth-scrolling", "yes"));
}

test "background opacity accepts the closed unit interval" {
    var config: Config = .{};
    try config.set(std.testing.allocator, "background-opacity", "0");
    try std.testing.expectEqual(@as(u8, 0), config.background_opacity);
    try config.set(std.testing.allocator, "background-opacity", "0.5");
    try std.testing.expectEqual(@as(u8, 128), config.background_opacity);
    try config.set(std.testing.allocator, "background-opacity", "1");
    try std.testing.expectEqual(@as(u8, 255), config.background_opacity);
    try config.set(std.testing.allocator, "background-opacity", "0.999");
    try std.testing.expectEqual(@as(u8, 254), config.background_opacity);
    try std.testing.expectError(error.InvalidValue, config.set(std.testing.allocator, "background-opacity", "-0.1"));
    try std.testing.expectError(error.InvalidValue, config.set(std.testing.allocator, "background-opacity", "1.1"));
    try std.testing.expectError(error.InvalidValue, config.set(std.testing.allocator, "background-opacity", "nan"));
}

test "background opacity cells accepts booleans" {
    var config: Config = .{};
    try config.set(std.testing.allocator, "background-opacity-cells", "true");
    try std.testing.expect(config.background_opacity_cells);
    try config.set(std.testing.allocator, "background-opacity-cells", "false");
    try std.testing.expect(!config.background_opacity_cells);
    try std.testing.expectError(error.InvalidValue, config.set(std.testing.allocator, "background-opacity-cells", "yes"));
}

test "font size points convert to scaled physical pixels" {
    try std.testing.expectEqual(@as(f64, 16), fontSizePixels(.{ .points = 12 }, 120));
    try std.testing.expectEqual(@as(f64, 24), fontSizePixels(.{ .points = 12 }, 180));
    try std.testing.expectEqual(@as(f64, 32), fontSizePixels(.{ .points = 12 }, 240));
    try std.testing.expectApproxEqAbs(@as(f64, 50.0 / 3.0), fontSizePixels(.{ .points = 12.5 }, 120), 0.000001);
    try std.testing.expectEqual(@as(f64, 25), fontSizePixels(.{ .points = 12.5 }, 180));
    try std.testing.expectApproxEqAbs(@as(f64, 100.0 / 3.0), fontSizePixels(.{ .points = 12.5 }, 240), 0.000001);
    try std.testing.expectEqual(@as(f64, 17), @round(fontSizePixels(.{ .pixels = 17.499 }, 120)));
    try std.testing.expectEqual(@as(f64, 18), @round(fontSizePixels(.{ .pixels = 17.501 }, 120)));
    try std.testing.expectEqual(@as(f64, 1), fontSizePixels(.{ .pixels = 0.1 }, 120));
}

test "font size pixels scale directly with the output" {
    try std.testing.expectEqual(@as(f64, 12), fontSizePixels(.{ .pixels = 12 }, 120));
    try std.testing.expectEqual(@as(f64, 18), fontSizePixels(.{ .pixels = 12 }, 180));
    try std.testing.expectEqual(@as(f64, 24), fontSizePixels(.{ .pixels = 12 }, 240));
}

test "font size accepts bare points and explicit point or pixel units" {
    var config: Config = .{};

    try config.set(std.testing.allocator, "font-size", "12");
    try std.testing.expectEqual(FontSize{ .points = 12 }, config.font_size);
    try config.set(std.testing.allocator, "font-size", "12pt");
    try std.testing.expectEqual(FontSize{ .points = 12 }, config.font_size);
    try config.set(std.testing.allocator, "font-size", "12px");
    try std.testing.expectEqual(FontSize{ .pixels = 12 }, config.font_size);
    try std.testing.expectEqual(@as(f64, 12), fontSizePixels(config.font_size, 120));

    try config.set(std.testing.allocator, "font-size", "16.5px");
    try std.testing.expectEqual(FontSize{ .pixels = 16.5 }, config.font_size);
    try std.testing.expectError(error.InvalidValue, config.set(std.testing.allocator, "font-size", "12em"));
    try std.testing.expectError(error.InvalidValue, config.set(std.testing.allocator, "font-size", "px"));
}

test "cell height adjustment accepts signed pixels and percentages" {
    var config: Config = .{};
    try std.testing.expectEqual(@as(?MetricModifier, null), config.metric_adjustments.cell_height);

    try config.set(std.testing.allocator, "adjust-cell-height", "2");
    try std.testing.expectEqual(MetricModifier{ .absolute = 2 }, config.metric_adjustments.cell_height.?);
    try std.testing.expectEqual(@as(u31, 22), config.metric_adjustments.cell_height.?.apply(20));

    try config.set(std.testing.allocator, "adjust-cell-height", "-2");
    try std.testing.expectEqual(MetricModifier{ .absolute = -2 }, config.metric_adjustments.cell_height.?);
    try std.testing.expectEqual(@as(u31, 18), config.metric_adjustments.cell_height.?.apply(20));

    try config.set(std.testing.allocator, "adjust-cell-height", "20%");
    try std.testing.expectEqual(MetricModifier{ .percent = 20 }, config.metric_adjustments.cell_height.?);
    try std.testing.expectEqual(@as(u31, 24), config.metric_adjustments.cell_height.?.apply(20));

    try config.set(std.testing.allocator, "adjust-cell-height", "-150%");
    try std.testing.expectEqual(@as(u31, 1), config.metric_adjustments.cell_height.?.apply(20));
    try std.testing.expectEqual(@as(u31, 1), (MetricModifier{ .absolute = -100 }).apply(20));

    try std.testing.expectError(error.InvalidValue, config.set(std.testing.allocator, "adjust-cell-height", "1.5"));
    try std.testing.expectError(error.InvalidValue, config.set(std.testing.allocator, "adjust-cell-height", "2px"));
    try std.testing.expectError(error.InvalidValue, config.set(std.testing.allocator, "adjust-cell-height", "nan%"));
    try std.testing.expectError(error.InvalidValue, config.set(std.testing.allocator, "adjust-cell-height", ""));
}

test "thickness adjustments set only their own metric" {
    var config: Config = .{};
    try config.set(std.testing.allocator, "adjust-box-thickness", "2");
    try config.set(std.testing.allocator, "adjust-underline-thickness", "-1");
    try config.set(std.testing.allocator, "adjust-strikethrough-thickness", "50%");
    try config.set(std.testing.allocator, "adjust-overline-thickness", "3");
    try config.set(std.testing.allocator, "adjust-cursor-thickness", "-25%");
    try std.testing.expectEqual(MetricAdjustments{
        .box_thickness = .{ .absolute = 2 },
        .underline_thickness = .{ .absolute = -1 },
        .strikethrough_thickness = .{ .percent = 50 },
        .overline_thickness = .{ .absolute = 3 },
        .cursor_thickness = .{ .percent = -25 },
    }, config.metric_adjustments);
    try std.testing.expectError(error.InvalidValue, config.set(std.testing.allocator, "adjust-box-thickness", "1.5"));
}

test "invalid window padding keeps the previous value" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const config = parse(arena_state.allocator(),
        \\window-padding-x = 3,7
        \\window-padding-x = 1,2,3
        \\window-padding-y = -1
    );
    try std.testing.expectEqual(WindowPadding{ .first = 3, .second = 7 }, config.window_padding_x);
    try std.testing.expectEqual(WindowPadding{}, config.window_padding_y);
}

test "window size accepts cells, clamps minimums, and keeps zero unset" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const config = parse(arena,
        \\window-width = 120
        \\window-height = 40
        \\window-width = -1
        \\window-height = 70000
    );
    try std.testing.expectEqual(@as(u16, 120), config.window_width);
    try std.testing.expectEqual(@as(u16, 40), config.window_height);

    const small = parse(arena,
        \\window-width = 3
        \\window-height = 1
    );
    try std.testing.expectEqual(@as(u16, 10), small.window_width);
    try std.testing.expectEqual(@as(u16, 4), small.window_height);

    const unset = parse(arena,
        \\window-width = 0
    );
    try std.testing.expectEqual(@as(u16, 0), unset.window_width);
    try std.testing.expectEqual(@as(u16, 0), unset.window_height);
}

test "working directory accepts absolute and home-relative paths" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const config = parse(arena,
        \\working-directory = ~/src
        \\working-directory = src
        \\working-directory = ~user/src
    );
    try std.testing.expectEqualStrings("~/src", config.working_directory.?);
    try std.testing.expectEqualStrings("/srv/work", parse(arena, "working-directory = /srv/work").working_directory.?);
    try std.testing.expectEqualStrings("~", parse(arena, "working-directory = ~").working_directory.?);
}

test "terminal colors from config" {
    var config: Config = .{};
    config.background = .{ .r = 1, .g = 2, .b = 3 };
    var colors = try config.terminalColors(std.testing.allocator);
    defer colors.palette.deinit(std.testing.allocator);
    try std.testing.expectEqual(vt.color.RGB{ .r = 1, .g = 2, .b = 3 }, colors.background.get().?);
    try std.testing.expectEqual(default_colors.foreground, colors.foreground.get().?);
    try std.testing.expectEqual(default_colors.cursor_color, colors.cursor.get().?);
    try std.testing.expectEqual(default_colors.palette[0], colors.palette.current[0]);
    try std.testing.expectEqual(default_colors.palette[15], colors.palette.current[15]);
}

test "built-in colors apply without configuration" {
    const config: Config = .{};
    var colors = try config.terminalColors(std.testing.allocator);
    defer colors.palette.deinit(std.testing.allocator);
    try std.testing.expectEqual(default_colors.background, colors.background.get().?);
    try std.testing.expectEqual(default_colors.foreground, colors.foreground.get().?);
    try std.testing.expectEqual(default_colors.cursor_color, colors.cursor.get().?);
    try std.testing.expectEqual(default_colors.selection_background, config.effectiveSelectionBackground());
    try std.testing.expectEqual(default_colors.selection_foreground, config.effectiveSelectionForeground());
    try std.testing.expectEqual(default_colors.palette[1], colors.palette.current[1]);
}

test "built-in colors do not replace explicit color overrides" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const config = parse(arena,
        \\background = #010203
        \\regular1 = #040506
        \\selection-background = #070809
    );

    const colors = try config.terminalColors(arena);
    try std.testing.expectEqual(vt.color.RGB{ .r = 1, .g = 2, .b = 3 }, colors.background.get().?);
    try std.testing.expectEqual(default_colors.foreground, colors.foreground.get().?);
    try std.testing.expectEqual(vt.color.RGB{ .r = 4, .g = 5, .b = 6 }, colors.palette.current[1]);
    try std.testing.expectEqual(vt.color.RGB{ .r = 7, .g = 8, .b = 9 }, config.effectiveSelectionBackground());
    try std.testing.expectEqual(default_colors.selection_foreground, config.effectiveSelectionForeground());
}

test "cell cursor colors stay out of the VT default layer" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const config = parse(arena_state.allocator(),
        \\cursor = cell-foreground
        \\cursor-text = cell-background
        \\cursor = not-a-color
    );
    try std.testing.expectEqual(@as(TerminalColor, .cell_foreground), config.cursor_color.?);
    try std.testing.expectEqual(@as(TerminalColor, .cell_background), config.cursor_text.?);
    try std.testing.expectEqual(@as(TerminalColor, .cell_foreground), config.effectiveCursorColor());
    try std.testing.expectEqual(@as(TerminalColor, .cell_background), config.effectiveCursorText().?);
    var colors = try config.terminalColors(std.testing.allocator);
    defer colors.palette.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?vt.color.RGB, null), colors.cursor.get());
}

test "config ignores an empty or relative XDG_CONFIG_HOME" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const locations = [_][]const u8{ "home/.config", "xdg" };
    const names = [_][]const u8{ "fallback", "override" };
    const backgrounds = [_][]const u8{ "123456", "abcdef" };
    for (locations, names, backgrounds) |location, name, background| {
        try tmp.dir.createDirPath(io, try std.fmt.allocPrint(arena, "{s}/unn", .{location}));
        try tmp.dir.writeFile(io, .{
            .sub_path = try std.fmt.allocPrint(arena, "{s}/unn/unn.ini", .{location}),
            .data = try std.fmt.allocPrint(arena, "font-family = {s}\nbackground = #{s}\n", .{ name, background }),
        });
    }

    const home = try tmp.dir.realPathFileAlloc(io, "home", arena);
    const xdg = try tmp.dir.realPathFileAlloc(io, "xdg", arena);
    var cwd_dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer cwd_dir.close(io);
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = cwd_buf[0..try cwd_dir.realPath(io, &cwd_buf)];
    // This relative path really contains a config: ignoring it must not
    // depend on the file being absent.
    const relative = try std.fs.path.relativePosix(arena, cwd, cwd, xdg);
    const home_entry = try std.fmt.allocPrintSentinel(arena, "HOME={s}", .{home}, 0);
    const cases = [_]struct { xdg: ?[]const u8, location: usize }{
        .{ .xdg = null, .location = 0 },
        .{ .xdg = xdg, .location = 1 },
        .{ .xdg = "", .location = 0 },
        .{ .xdg = relative, .location = 0 },
    };
    for (cases) |case| {
        const environ: std.process.Environ = .{ .block = .{ .slice = if (case.xdg) |value|
            &.{ home_entry.ptr, (try std.fmt.allocPrintSentinel(arena, "XDG_CONFIG_HOME={s}", .{value}, 0)).ptr }
        else
            &.{home_entry.ptr} } };
        const config = load(arena, environ);
        try std.testing.expectEqualStrings(names[case.location], config.font_family);
        try std.testing.expectEqual(
            try color.parseColor(backgrounds[case.location]),
            config.background.?,
        );
    }
}
