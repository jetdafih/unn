const std = @import("std");
const Scanner = @import("wayland").Scanner;

const release_version: std.SemanticVersion = .{ .major = 0, .minor = 1, .patch = 0 };

pub fn build(b: *std.Build) void {
    // Default to the baseline CPU so a release built on a modern runner doesn't emit
    // AVX-512 and SIGILL elsewhere. An explicit -Dcpu still overrides.
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_model = .baseline },
    });
    const optimize = b.standardOptimizeOption(.{});
    const version = versionString(b);

    // D-Bus backs notifications, xdg-desktop-portal opening and GTK theme signals. It degrades
    // gracefully without a session bus, so minimal builds may compile it out.
    const enable_dbus = b.option(
        bool,
        "dbus",
        "Enable native D-Bus desktop integration: notifications, xdg-desktop-portal, GTK theme changes (default: true)",
    ) orelse true;

    // Pin the Wayland protocol definitions so generated bindings don't depend on the host's
    // wayland/wayland-protocols version.
    const scanner = Scanner.create(b, .{
        .wayland_xml = b.path("protocols/wayland.xml"),
        .wayland_protocols = b.path("protocols"),
    });
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("stable/viewporter/viewporter.xml");
    scanner.addSystemProtocol("stable/tablet/tablet-v2.xml");
    scanner.addSystemProtocol("staging/xdg-activation/xdg-activation-v1.xml");
    scanner.addSystemProtocol("staging/fractional-scale/fractional-scale-v1.xml");
    scanner.addSystemProtocol("staging/cursor-shape/cursor-shape-v1.xml");
    scanner.addSystemProtocol("staging/xdg-system-bell/xdg-system-bell-v1.xml");
    scanner.addSystemProtocol("staging/xdg-toplevel-icon/xdg-toplevel-icon-v1.xml");
    scanner.addSystemProtocol("unstable/xdg-decoration/xdg-decoration-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/primary-selection/primary-selection-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/text-input/text-input-unstable-v3.xml");
    // Generate against current stable protocols; runtime binding still negotiates the
    // compositor's version and Window falls back for optional features.
    scanner.generate("wl_compositor", 7);
    scanner.generate("wl_output", 4);
    scanner.generate("wl_shm", 2);
    scanner.generate("wl_seat", 10);
    scanner.generate("xdg_wm_base", 7);
    scanner.generate("xdg_activation_v1", 1);
    scanner.generate("wp_viewporter", 1);
    scanner.generate("wp_fractional_scale_manager_v1", 1);
    scanner.generate("wp_cursor_shape_manager_v1", 2);
    scanner.generate("xdg_system_bell_v1", 1);
    scanner.generate("xdg_toplevel_icon_manager_v1", 1);
    scanner.generate("zxdg_decoration_manager_v1", 2);
    scanner.generate("wl_data_device_manager", 4);
    scanner.generate("zwp_primary_selection_device_manager_v1", 1);
    scanner.generate("zwp_text_input_manager_v3", 1);
    const wayland_mod = b.createModule(.{ .root_source_file = scanner.result });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = b.option(bool, "strip", "Strip debug information from the executable"),
    });
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);
    build_options.addOption(bool, "enable_dbus", enable_dbus);
    root_module.addOptions("build_options", build_options);
    root_module.addAnonymousImport("unn-terminfo-source", .{
        .root_source_file = b.path("dist/unn.terminfo"),
    });
    root_module.addImport("wayland", wayland_mod);
    root_module.linkSystemLibrary("wayland-client", .{});
    root_module.linkSystemLibrary("wayland-cursor", .{});

    const ghostty_dep = b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
    });

    // Font stack: fontconfig (discovery), FreeType (raster), HarfBuzz (shaping) and stb image
    // helpers via one translated C header.
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.linkSystemLibrary("fontconfig", .{});
    translate_c.linkSystemLibrary("freetype2", .{});
    translate_c.linkSystemLibrary("harfbuzz", .{});
    translate_c.linkSystemLibrary("xkbcommon", .{});
    root_module.addImport("c", translate_c.createModule());

    if (b.lazyDependency("z2d", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        root_module.addImport("z2d", dep.module("z2d"));
    }

    if (ghostty_dep) |dep| {
        const ghostty_vt = dep.module("ghostty-vt");
        root_module.addImport("ghostty-vt", ghostty_vt);
        // Zig can't assign one source file to two modules and ghostty-vt reaches these files
        // indirectly. Cache copies keep one upstream definition and make the terminfo package importable.
        const terminfo_files = b.addWriteFiles();
        _ = terminfo_files.addCopyFile(dep.path("src/terminfo/Source.zig"), "Source.zig");
        _ = terminfo_files.addCopyFile(dep.path("src/terminfo/ghostty.zig"), "ghostty.zig");
        const terminfo_root = terminfo_files.addCopyFile(dep.path("src/terminfo/main.zig"), "main.zig");
        root_module.addImport("ghostty-terminfo", b.createModule(.{
            .root_source_file = terminfo_root,
            .target = target,
            .optimize = optimize,
        }));
        root_module.addImport(
            "uucode",
            ghostty_vt.import_table.get("uucode") orelse
                @panic("ghostty-vt does not provide uucode"),
        );

        const terminfo_gen = b.addExecutable(.{
            .name = "unn-terminfo-gen",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/terminfo_gen.zig"),
                .target = b.graph.host,
                .optimize = .ReleaseSafe,
            }),
        });
        terminfo_gen.root_module.addImport("ghostty-terminfo", b.createModule(.{
            .root_source_file = terminfo_root,
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }));

        const generate_terminfo = b.addRunArtifact(terminfo_gen);
        const terminfo_source = generate_terminfo.captureStdOut(.{});
        const compile_terminfo = std.Build.Step.Run.create(b, "compile terminfo");
        compile_terminfo.addArgs(&.{ "tic", "-x", "-o" });
        const terminfo_dir = compile_terminfo.addOutputFileArg("terminfo");
        compile_terminfo.addFileArg(terminfo_source);
        _ = compile_terminfo.captureStdErr(.{});

        b.installDirectory(.{
            .source_dir = terminfo_dir,
            .install_dir = .prefix,
            .install_subdir = "share/terminfo",
        });

        const update_terminfo = b.addUpdateSourceFiles();
        update_terminfo.addCopyFileToSource(terminfo_source, "dist/unn.terminfo");
        b.step("update-terminfo", "Regenerate dist/unn.terminfo").dependOn(&update_terminfo.step);
    }

    const exe = b.addExecutable(.{
        .name = "unn",
        .root_module = root_module,
        .version = std.SemanticVersion.parse(version) catch unreachable,
        // uucode's generated tables crash the x86_64 self-hosted backend.
        // Ghostty uses LLVM for the same reason.
        .use_llvm = true,
    });
    root_module.addCSourceFile(.{ .file = b.path("vendor/stb_image_resize.c") });
    root_module.addCSourceFile(.{ .file = b.path("vendor/stb_image.c") });
    // SVG documents sent as kitty graphics are rasterized by nanosvg (src/svg.zig).
    root_module.addCSourceFile(.{ .file = b.path("vendor/nanosvg.c"), .flags = &.{"-fno-sanitize=undefined"} });

    b.installArtifact(exe);
    b.installFile("dist/jetdafih.unn.desktop", "share/applications/jetdafih.unn.desktop");
    b.installFile("dist/jetdafih.unn.svg", "share/icons/hicolor/scalable/apps/jetdafih.unn.svg");
    b.installFile("dist/unn.1", "share/man/man1/unn.1");
    b.installFile("dist/unn.5", "share/man/man5/unn.5");
    b.installFile("dist/50-unn.conf", "share/doc/unn/examples/50-unn.conf");

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    const exe_tests = b.addTest(.{
        .root_module = root_module,
        .use_llvm = true,
    });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    const fmt_step = b.step("fmt", "Check code formatting");
    const fmt_check = b.addFmt(.{ .paths = &.{ b.path("src"), b.path("build.zig"), b.path("build.zig.zon") }, .check = true });
    fmt_step.dependOn(&fmt_check.step);
    test_step.dependOn(fmt_step);
}

fn versionString(b: *std.Build) []const u8 {
    const release = b.fmt("{f}", .{release_version});
    const build_root = b.root.toString(b.allocator) catch ".";
    var code: u8 = undefined;
    const git_prefix_raw = b.runAllowFail(&.{
        "git",
        "-C",
        build_root,
        "rev-parse",
        "--show-prefix",
    }, &code, .ignore) catch return release;
    // Source archives may unpack inside another repo (e.g. an AUR checkout); only use Git
    // metadata when the build root is that repo's root.
    if (std.mem.trim(u8, git_prefix_raw, " \r\n").len != 0) return release;

    const raw = b.runAllowFail(&.{
        "git",
        "-C",
        build_root,
        "describe",
        "--tags",
        "--long",
        "--dirty",
        "--always",
        "--match",
        "v[0-9]*",
    }, &code, .ignore) catch return release;
    const description = std.mem.trim(u8, raw, " \r\n");
    if (description.len == 0) return release;

    const dirty = std.mem.endsWith(u8, description, "-dirty");
    const clean = if (dirty) description[0 .. description.len - "-dirty".len] else description;
    if (!std.mem.startsWith(u8, clean, "v")) {
        const count_raw = b.runAllowFail(&.{
            "git",
            "-C",
            build_root,
            "rev-list",
            "--count",
            "HEAD",
        }, &code, .ignore) catch return release;
        const count = std.mem.trim(u8, count_raw, " \r\n");
        _ = std.fmt.parseInt(usize, count, 10) catch return release;
        return developmentVersion(b, release, count, clean, dirty);
    }

    const hash_sep = std.mem.lastIndexOfScalar(u8, clean, '-') orelse
        std.process.fatal("unexpected git describe output: {s}", .{description});
    const before_hash = clean[0..hash_sep];
    const distance_sep = std.mem.lastIndexOfScalar(u8, before_hash, '-') orelse
        std.process.fatal("unexpected git describe output: {s}", .{description});
    const tag = before_hash[0..distance_sep];
    const distance = before_hash[distance_sep + 1 ..];
    const hash = clean[hash_sep + 1 ..];
    if (hash.len < 2 or hash[0] != 'g')
        std.process.fatal("unexpected git describe output: {s}", .{description});

    const tagged_version = std.SemanticVersion.parse(tag[1..]) catch
        std.process.fatal("version tag is not semantic: {s}", .{tag});
    const commit_count = std.fmt.parseInt(usize, distance, 10) catch
        std.process.fatal("unexpected git describe output: {s}", .{description});
    if (commit_count == 0) {
        if (release_version.order(tagged_version) != .eq)
            std.process.fatal("release version {s} does not match tag {s}", .{ release, tag });
        if (!dirty) return release;
    } else if (release_version.order(tagged_version) != .gt) {
        std.process.fatal("release version {s} must be newer than tag {s}", .{ release, tag });
    }
    return developmentVersion(b, release, distance, hash[1..], dirty);
}

fn developmentVersion(
    b: *std.Build,
    release: []const u8,
    distance: []const u8,
    hash: []const u8,
    dirty: bool,
) []const u8 {
    return if (dirty)
        b.fmt("{s}-dev.{s}+g{s}.dirty", .{ release, distance, hash })
    else
        b.fmt("{s}-dev.{s}+g{s}", .{ release, distance, hash });
}
