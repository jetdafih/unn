//! Application entry point: `unn [options]` runs a shell in a Wayland terminal window.

const std = @import("std");
const build_options = @import("build_options");
const vt = @import("ghostty-vt");
const App = @import("App.zig");
const Config = @import("Config.zig");
const Font = @import("Font.zig");
const Link = @import("Link.zig");
const Pty = @import("Pty.zig");
const Renderer = @import("Renderer.zig");
const TerminalLayout = @import("TerminalLayout.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.main);

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    const cli = parseCli(arena, args[1..]) catch |err| switch (err) {
        error.InvalidCli => invalidCli(init),
        else => return err,
    };
    switch (cli.action) {
        .run => {},
        .help => return printUsage(init),
        .version => return printVersion(init),
    }

    return gui(init, cli) catch |err| switch (err) {
        error.InvalidCli => invalidCli(init),
        else => return err,
    };
}

const CliAction = enum { run, help, version };

const CliOptions = struct {
    action: CliAction = .run,
    config_path: ?[:0]const u8 = null,
    config_overrides: []const []const u8 = &.{},
    command: []const [:0]const u8 = &.{},
};

const CliError = error{InvalidCli} || std.mem.Allocator.Error;

fn parseCli(arena: std.mem.Allocator, args: []const [:0]const u8) CliError!CliOptions {
    var parser: CliParser = .{ .arena = arena, .args = args };
    return parser.parse();
}

const CliParser = struct {
    arena: std.mem.Allocator,
    args: []const [:0]const u8,
    index: usize = 0,
    cli: CliOptions = .{},
    overrides: std.ArrayList([]const u8) = .empty,

    fn parse(self: *CliParser) CliError!CliOptions {
        while (self.index < self.args.len) : (self.index += 1) {
            const arg = self.args[self.index];
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                self.cli.action = .help;
                return self.cli;
            } else if (std.mem.eql(u8, arg, "--version")) {
                self.cli.action = .version;
                return self.cli;
            } else if (std.mem.eql(u8, arg, "-e")) {
                if (self.index + 1 >= self.args.len) return error.InvalidCli;
                self.setCommand(self.index + 1);
                break;
            } else if (std.mem.eql(u8, arg, "-c")) {
                self.cli.config_path = try self.nextValue();
            } else if (try self.longValue(arg, "--working-directory")) |value| {
                try self.setWorkingDirectory(value);
            } else {
                // Keep bare words reserved for future subcommands. Commands
                // must use `-e` so option parsing stays extensible.
                return error.InvalidCli;
            }
        }

        self.cli.config_overrides = try self.overrides.toOwnedSlice(self.arena);
        return self.cli;
    }

    fn setCommand(self: *CliParser, start: usize) void {
        self.cli.command = self.args[start..];
        self.index = self.args.len;
    }

    /// Value of `--long VALUE` or `--long=VALUE`, or null if `arg` is not `long`.
    fn longValue(self: *CliParser, arg: []const u8, long: []const u8) CliError!?[]const u8 {
        if (std.mem.eql(u8, arg, long)) return try self.nextValue();
        return self.optionValue(arg, long);
    }

    /// Check the directory now so a bad flag fails at launch, and make it
    /// absolute so the override matches the config key's contract.
    fn setWorkingDirectory(self: *CliParser, value: []const u8) CliError!void {
        const path = if (std.fs.path.isAbsolute(value))
            try self.arena.dupeSentinel(u8, value, 0)
        else path: {
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
            if (std.os.linux.errno(rc) != .SUCCESS) return error.InvalidCli;
            const cwd = std.mem.sliceTo(&cwd_buf, 0);
            break :path try std.fmt.allocPrintSentinel(self.arena, "{s}/{s}", .{ cwd, value }, 0);
        };
        try validateWorkingDirectory(path);
        try self.appendOverride("working-directory", path);
    }

    fn nextValue(self: *CliParser) CliError![:0]const u8 {
        if (self.index + 1 >= self.args.len) return error.InvalidCli;
        self.index += 1;
        return self.args[self.index];
    }

    fn optionValue(_: *CliParser, arg: []const u8, long: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, arg, long) or arg.len <= long.len or arg[long.len] != '=') return null;
        const value = arg[long.len + 1 ..];
        return if (value.len == 0) null else value;
    }

    fn appendOverride(self: *CliParser, key: []const u8, value: []const u8) !void {
        try self.overrides.append(self.arena, try std.fmt.allocPrint(self.arena, "{s}={s}", .{ key, value }));
    }
};

fn printUsage(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buf);
    defer writer.interface.flush() catch {};
    try writer.interface.writeAll(
        \\usage: unn [options]
        \\       unn [options] -e command [args...]
        \\
        \\Options:
        \\  -h, --help                   Show this help
        \\      --version                Show version
        \\      --working-directory DIR  Run the child in DIR
        \\  -c FILE                      Load FILE instead of the default config
        \\  -e command [args...]         Execute command directly
        \\
    );
}

fn printVersion(init: std.process.Init) !void {
    var buf: [128]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buf);
    defer writer.interface.flush() catch {};
    try writer.interface.writeAll("unn " ++ build_options.version ++ "\n");
}

fn invalidCli(init: std.process.Init) noreturn {
    var buf: [256]u8 = undefined;
    var writer = std.Io.File.stderr().writer(init.io, &buf);
    writer.interface.writeAll("unn: invalid command line\nTry 'unn --help' for usage.\n") catch {};
    writer.interface.flush() catch {};
    std.process.exit(2);
}

/// GUI mode: run a live terminal session in a window.
fn gui(init: std.process.Init, cli: CliOptions) !void {
    const arena = init.arena.allocator();

    var config = if (cli.config_path) |path|
        Config.loadPath(arena, path)
    else
        Config.load(arena, init.minimal.environ);
    for (cli.config_overrides) |override| {
        config.applyOverride(arena, override) catch return error.InvalidCli;
    }
    const working_directory = try resolveWorkingDirectory(arena, init.minimal.environ, config.working_directory);

    const command = try buildCommand(arena, config, init.minimal.environ, cli.command, working_directory);
    const envp = try buildEnvp(init.io, arena, init.minimal.environ, working_directory);

    const app = try App.init(
        init.io,
        init.gpa,
        config,
        init.minimal.environ,
        command.path,
        command.argv.ptr,
        envp,
        .{
            .config_path = cli.config_path,
            .config_overrides = cli.config_overrides,
            .working_directory = working_directory,
            .initial_size = initialSize(config),
        },
    );
    defer app.deinit();
    app.window.initial_activation_token = init.minimal.environ.getPosix("XDG_ACTIVATION_TOKEN");
    try app.run();
}

/// The configured grid size applies only when both `window-width` and
/// `window-height` are set.
fn initialSize(config: Config) App.InitialSize {
    if (config.window_width == 0 or config.window_height == 0) return .default;
    return .{ .chars = .{ .cols = config.window_width, .rows = config.window_height } };
}

/// Expand `~` and check the configured directory. An unusable one warns and inherits ours
/// so a stale config can't block startup; `--working-directory` was checked at arg parsing.
fn resolveWorkingDirectory(
    arena: std.mem.Allocator,
    environ: std.process.Environ,
    configured: ?[:0]const u8,
) error{OutOfMemory}!?[:0]const u8 {
    const value = configured orelse return null;
    const path = if (value[0] == '~') path: {
        const home = environ.getPosix("HOME") orelse {
            log.warn("working-directory {s}: HOME is unset; ignoring", .{value});
            return null;
        };
        break :path try std.fmt.allocPrintSentinel(arena, "{s}{s}", .{ home, value[1..] }, 0);
    } else value;
    validateWorkingDirectory(path) catch {
        log.warn("working-directory {s} is not an accessible directory; ignoring", .{path});
        return null;
    };
    return path;
}

const ChildCommand = struct {
    path: [*:0]const u8,
    argv: [:null]const ?[*:0]const u8,
};

fn buildCommand(
    arena: std.mem.Allocator,
    config: Config,
    environ: std.process.Environ,
    command: []const [:0]const u8,
    cwd: ?[:0]const u8,
) !ChildCommand {
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    var path: [*:0]const u8 = undefined;
    if (command.len > 0) {
        path = try App.resolveCommandPath(arena, environ, command[0], cwd);
        for (command) |arg| try argv.append(arena, arg.ptr);
    } else if (config.command) |configured| switch (configured) {
        .shell => |value| {
            path = "/bin/sh";
            try argv.appendSlice(arena, &.{ "/bin/sh", "-c", value.ptr });
        },
        .direct => |args| {
            path = try App.resolveCommandPath(arena, environ, args[0], cwd);
            for (args) |arg| try argv.append(arena, arg.ptr);
        },
    } else {
        const shell: [:0]const u8 = environ.getPosix("SHELL") orelse
            "/bin/sh";
        path = shell.ptr;
        try argv.append(arena, shell.ptr);
    }
    return .{ .path = path, .argv = try argv.toOwnedSliceSentinel(arena, null) };
}

fn validateWorkingDirectory(path: [:0]const u8) !void {
    const linux = std.os.linux;
    const rc = linux.openat(linux.AT.FDCWD, path, .{
        .CLOEXEC = true,
        .DIRECTORY = true,
        .PATH = true,
    }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.InvalidCli;
    const fd: std.posix.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    if (linux.errno(linux.faccessat(fd, "", linux.X_OK, linux.AT.EMPTY_PATH)) != .SUCCESS)
        return error.InvalidCli;
}

/// Build the child's environment with Unn's terminal definition and PWD
/// matching the resolved working-directory override, if any.
fn buildEnvp(
    io: std.Io,
    arena: std.mem.Allocator,
    environ: std.process.Environ,
    cwd: ?[:0]const u8,
) ![*:null]const ?[*:0]const u8 {
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    var has_terminfo = false;
    for (environ.block.slice) |entry| {
        const e = entry orelse continue;
        const value = std.mem.span(e);
        if (std.mem.startsWith(u8, value, "TERM=")) continue;
        if (std.mem.startsWith(u8, value, "COLORTERM=")) continue;
        if (cwd != null and std.mem.startsWith(u8, value, "PWD=")) continue;
        // The launcher token belongs to our window, not the shell or its children.
        if (std.mem.startsWith(u8, value, "XDG_ACTIVATION_TOKEN=")) continue;
        if (std.mem.startsWith(u8, value, "TERMINFO=")) has_terminfo = true;
        try list.append(arena, e);
    }
    if (cwd) |path| try list.append(arena, try std.mem.joinZ(arena, "", &.{ "PWD=", path }));
    try list.append(arena, "TERM=unn");
    try list.append(arena, "COLORTERM=truecolor");
    if (!has_terminfo) {
        var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.process.executableDirPath(io, &exe_dir_buf)) |len| {
            const terminfo_dir = try std.fs.path.joinZ(arena, &.{ exe_dir_buf[0..len], "..", "share", "terminfo" });
            // tic files an entry under its first letter, so `unn` lives in `u/`.
            const entry = try std.fs.path.joinZ(arena, &.{ terminfo_dir, "u", "unn" });
            if (std.os.linux.errno(std.os.linux.access(entry, std.os.linux.R_OK)) == .SUCCESS) {
                try list.append(arena, try std.mem.joinZ(arena, "", &.{ "TERMINFO=", terminfo_dir }));
            }
        } else |_| {}
    }
    const slice = try list.toOwnedSliceSentinel(arena, null);
    return slice.ptr;
}

test "shell environment excludes the launch activation token" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const envp = [_:null]?[*:0]const u8{
        "XDG_ACTIVATION_TOKEN=launcher-token",
        "TERM=old-terminal",
        "COLORTERM=old-color",
        "TERMINFO=/custom/terminfo",
        "KEEP=value",
    };
    const environ: std.process.Environ = .{ .block = .{ .slice = &envp } };
    const child = try buildEnvp(std.testing.io, arena_state.allocator(), environ, null);
    const expected = [_][]const u8{
        "TERMINFO=/custom/terminfo",
        "KEEP=value",
        "TERM=unn",
        "COLORTERM=truecolor",
    };
    const actual = std.mem.span(child);
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, entry| {
        try std.testing.expectEqualStrings(want, std.mem.span(entry.?));
    }
    try std.testing.expectEqualStrings("launcher-token", environ.getPosix("XDG_ACTIVATION_TOKEN").?);
}

test "child environment updates PWD only when changing working directory" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const inherited = [_:null]?[*:0]const u8{ "PWD=/launcher", "PWD_EXTRA=keep" };
    for ([_]std.process.Environ{ .{ .block = .{ .slice = &inherited } }, .empty }) |environ| {
        for ([_]?[:0]const u8{ null, "/tmp/unn project" }) |cwd| {
            const envp = try buildEnvp(std.testing.io, arena_state.allocator(), environ, cwd);
            const child: std.process.Environ = .{ .block = .{ .slice = std.mem.span(envp) } };
            const expected = cwd orelse environ.getPosix("PWD");
            if (expected) |path| {
                try std.testing.expectEqualStrings(path, child.getPosix("PWD") orelse "<missing>");
            } else {
                try std.testing.expectEqual(null, child.getPosix("PWD"));
            }
            var pwd_count: usize = 0;
            for (child.block.slice) |entry| {
                if (std.mem.startsWith(u8, std.mem.span(entry.?), "PWD=")) pwd_count += 1;
            }
            try std.testing.expectEqual(@as(usize, @intFromBool(expected != null)), pwd_count);
            if (environ.getPosix("PWD_EXTRA")) |value| {
                try std.testing.expectEqualStrings(value, child.getPosix("PWD_EXTRA").?);
            }
        }
    }
}

test {
    _ = App;
    _ = @import("AsyncJobSnapshot.zig");
    _ = @import("AsyncRaster.zig");
    _ = @import("CellDamageTracker.zig");
    _ = @import("Clipboard.zig");
    _ = @import("CommandNotification.zig");
    _ = @import("KittyClipboard.zig");
    _ = @import("KittyDrag.zig");
    _ = @import("drag_preview.zig");
    _ = @import("FrameDamageTracker.zig");
    _ = Config;
    _ = Font;
    _ = @import("dbus/Connection.zig");
    _ = @import("clipboard_format.zig");
    _ = @import("terminfo_gen.zig");
    _ = @import("colors.zig");
    _ = @import("glyph_constraints.zig");
    _ = @import("Keyboard.zig");
    _ = @import("keybind.zig");
    _ = @import("KittyImageCache.zig");
    _ = @import("kitty_graphics.zig");
    _ = Link;
    _ = Pty;
    _ = @import("ReadPipeline.zig");
    _ = Renderer;
    _ = @import("ScrollDetector.zig");
    _ = @import("pixel_copy.zig");
    _ = @import("pixel_raster.zig");
    _ = @import("sprite.zig");
    _ = @import("sprite/canvas.zig");
    _ = @import("sprite/draw/box.zig");
    _ = @import("sprite/draw/block.zig");
    _ = @import("sprite/draw/powerline.zig");
    _ = @import("sprite/draw/braille.zig");
    _ = @import("sprite/draw/geometric_shapes.zig");
    _ = @import("sprite/draw/branch.zig");
    _ = @import("sprite/draw/symbols_for_legacy_computing.zig");
    _ = @import("sprite/draw/symbols_for_legacy_computing_supplement.zig");
    _ = @import("sprite/draw/special.zig");
    _ = @import("TextShaper.zig");
    _ = Window;
}

test "parse CLI options and config overrides" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = [_][:0]const u8{
        "-c",                  "/tmp/unn.conf",
        "--working-directory", "/tmp",
        "-e",                  "env",
        "A=B",
    };
    const cli = try parseCli(arena, &args);

    try std.testing.expectEqualStrings("/tmp/unn.conf", cli.config_path.?);
    try std.testing.expectEqualStrings("env", cli.command[0]);
    try std.testing.expectEqualStrings("A=B", cli.command[1]);
    const overrides = [_][]const u8{"working-directory=/tmp"};
    try std.testing.expectEqual(overrides.len, cli.config_overrides.len);
    for (overrides, cli.config_overrides) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
}

test "working directory flag is checked and made absolute" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cli = try parseCli(arena, &.{"--working-directory=."});
    const override = cli.config_overrides[0];
    try std.testing.expect(std.mem.startsWith(u8, override, "working-directory=/"));
    try std.testing.expect(std.mem.endsWith(u8, override, "/."));

    var config: Config = .{};
    try config.applyOverride(arena, override);
    try std.testing.expectError(error.InvalidCli, parseCli(arena, &.{"--working-directory=/nonexistent/unn"}));
}

test "configured working directory expands home and ignores unusable paths" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const envp = [_:null]?[*:0]const u8{"HOME=/tmp"};
    const environ: std.process.Environ = .{ .block = .{ .slice = &envp } };
    try std.testing.expectEqualStrings("/tmp", (try resolveWorkingDirectory(arena, environ, "~")).?);
    try std.testing.expectEqualStrings("/", (try resolveWorkingDirectory(arena, environ, "/")).?);
    try std.testing.expectEqual(null, try resolveWorkingDirectory(arena, environ, "~/nonexistent-unn"));
    try std.testing.expectEqual(null, try resolveWorkingDirectory(arena, .empty, "~"));
    try std.testing.expectEqual(null, try resolveWorkingDirectory(arena, environ, null));
}

test "configured window size applies only when both dimensions are set" {
    try std.testing.expectEqual(.default, std.meta.activeTag(initialSize(.{ .window_width = 100 })));
    const configured = initialSize(.{ .window_width = 100, .window_height = 30 });
    try std.testing.expectEqual(@as(u16, 100), configured.chars.cols);
    try std.testing.expectEqual(@as(u16, 30), configured.chars.rows);
}

test "configured shell command runs through sh" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const command = try buildCommand(
        arena_state.allocator(),
        .{ .command = .{ .shell = "printf '%s' hello" } },
        .empty,
        &.{},
        null,
    );
    try std.testing.expectEqualStrings("/bin/sh", std.mem.span(command.path));
    try std.testing.expectEqualStrings("/bin/sh", std.mem.span(command.argv[0].?));
    try std.testing.expectEqualStrings("-c", std.mem.span(command.argv[1].?));
    try std.testing.expectEqualStrings("printf '%s' hello", std.mem.span(command.argv[2].?));
}

test "configured direct command preserves arguments" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const command = try buildCommand(
        arena_state.allocator(),
        .{ .command = .{ .direct = &.{ "/usr/bin/env", "A=B" } } },
        .empty,
        &.{},
        null,
    );
    try std.testing.expectEqualStrings("/usr/bin/env", std.mem.span(command.path));
    try std.testing.expectEqualStrings("/usr/bin/env", std.mem.span(command.argv[0].?));
    try std.testing.expectEqualStrings("A=B", std.mem.span(command.argv[1].?));
}

test "direct commands search PATH in the child working directory" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "bin");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "bin/unn-path-test",
        .data = "#!/bin/sh\nexit 42\n",
        .flags = .{ .permissions = .fromMode(0o700) },
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "unn-path-test",
        .data = "#!/bin/sh\nexit 41\n",
        .flags = .{ .permissions = .fromMode(0o700) },
    });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const cwd = try arena.dupeSentinel(u8, path_buf[0..path_len], 0);
    const cases = [_]struct { path: [:0]const u8, exit_code: u32 }{
        .{ .path = "PATH=bin", .exit_code = 42 },
        .{ .path = "PATH=bin:.", .exit_code = 42 },
        .{ .path = "PATH=:bin", .exit_code = 41 },
        .{ .path = "PATH=.", .exit_code = 41 },
        .{ .path = "PATH=", .exit_code = 41 },
        .{ .path = try std.fmt.allocPrintSentinel(arena, "PATH={s}/bin", .{cwd}, 0), .exit_code = 42 },
    };
    for (cases) |case| {
        const envp = [_:null]?[*:0]const u8{case.path.ptr};
        const environ: std.process.Environ = .{ .block = .{ .slice = &envp } };
        for ([_]bool{ false, true }) |configured| {
            const command = try buildCommand(
                arena,
                if (configured) .{ .command = .{ .direct = &.{"unn-path-test"} } } else .{},
                environ,
                if (configured) &.{} else &.{"unn-path-test"},
                cwd,
            );
            var pty: Pty = try .open(.{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 });
            defer pty.deinit();
            const pid = try pty.spawn(command.path, command.argv.ptr, &envp, .{ .cwd = cwd });
            try std.testing.expectEqual(case.exit_code << 8, try Pty.wait(pid));
        }
    }

    // A failed PATH search must not implicitly execute the copy in cwd.
    const envp = [_:null]?[*:0]const u8{"PATH=missing"};
    const environ: std.process.Environ = .{ .block = .{ .slice = &envp } };
    for ([_]bool{ false, true }) |configured| {
        try std.testing.expectError(error.CommandNotFound, buildCommand(
            arena,
            if (configured) .{ .command = .{ .direct = &.{"unn-path-test"} } } else .{},
            environ,
            if (configured) &.{} else &.{"unn-path-test"},
            cwd,
        ));
    }

    // An explicit relative path bypasses PATH, even when lookup would fail.
    const command = try buildCommand(arena, .{}, environ, &.{"./unn-path-test"}, cwd);
    var pty: Pty = try .open(.{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 });
    defer pty.deinit();
    const pid = try pty.spawn(command.path, command.argv.ptr, &envp, .{ .cwd = cwd });
    try std.testing.expectEqual(@as(u32, 41 << 8), try Pty.wait(pid));
}

test "parse CLI rejects removed flags and a missing config file" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    for ([_][]const [:0]const u8{ &.{"-c"}, &.{"--"}, &.{"--font=x"}, &.{ "-o", "a=b" }, &.{"--window-size-chars=80x24"} }) |args| {
        try std.testing.expectError(error.InvalidCli, parseCli(arena_state.allocator(), args));
    }
}

test "parse CLI reserves bare words for future subcommands" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const args = [_][:0]const u8{ "echo", "hello" };
    try std.testing.expectError(error.InvalidCli, parseCli(arena_state.allocator(), &args));
}

test "working directory needs search permission but not read permission" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const path = try std.testing.allocator.dupeSentinel(u8, path_buf[0..path_len], 0);
    defer std.testing.allocator.free(path);

    try std.testing.expectEqual(.SUCCESS, std.os.linux.errno(std.os.linux.chmod(path, 0o111)));
    defer _ = std.os.linux.chmod(path, 0o700);
    try validateWorkingDirectory(path);

    try std.testing.expectEqual(.SUCCESS, std.os.linux.errno(std.os.linux.chmod(path, 0o600)));
    try std.testing.expectError(error.InvalidCli, validateWorkingDirectory(path));
}

test "terminal emulation of simple output" {
    const alloc = std.testing.allocator;
    var term: vt.Terminal = try .init(std.testing.io, alloc, .{ .cols = 10, .rows = 3 });
    defer term.deinit(alloc);

    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("a\r\n\x1b[1;32mb\x1b[0m\r\nc");

    const text = try term.screens.active.dumpStringAlloc(alloc, .{ .viewport = .{} });
    defer alloc.free(text);
    try std.testing.expectEqualStrings("a\nb\nc", text);
}
