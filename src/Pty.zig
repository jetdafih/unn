//! Pseudo-terminal handling: opens a master/slave PTY pair and spawns a
//! child process attached to the slave side as its controlling terminal.

const Pty = @This();

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const log = std.log.scoped(.pty);

master: posix.fd_t,
slave: posix.fd_t,

pub const Error = error{PtyFailed};

pub const SpawnOptions = struct {
    /// Child working directory. Null inherits the parent's cwd.
    cwd: ?[*:0]const u8 = null,
};

/// Open a master/slave PTY pair with the given window size.
pub fn open(size: posix.winsize) Error!Pty {
    const master = openRw("/dev/ptmx") orelse return error.PtyFailed;
    errdefer _ = linux.close(master);

    // Unlock the slave side, then resolve its /dev/pts/N path.
    var unlock: c_int = 0;
    try check(linux.ioctl(master, linux.T.IOCSPTLCK, @intFromPtr(&unlock)));
    var pts_num: c_uint = undefined;
    try check(linux.ioctl(master, linux.T.IOCGPTN, @intFromPtr(&pts_num)));

    var path_buf: [32]u8 = undefined;
    const path = std.mem.printSentinel(&path_buf, "/dev/pts/{d}", .{pts_num}, 0) catch
        unreachable; // 32 bytes always fits "/dev/pts/" + u32

    const slave = openRw(path) orelse return error.PtyFailed;
    errdefer _ = linux.close(slave);

    try check(linux.ioctl(master, linux.T.IOCSWINSZ, @intFromPtr(&size)));

    return .{ .master = master, .slave = slave };
}

pub fn deinit(self: *Pty) void {
    self.closeMaster();
    self.closeMaster();
    if (self.slave >= 0) _ = linux.close(self.slave);
    self.* = undefined;
}

pub fn closeMaster(self: *Pty) void {
    if (self.master >= 0) {
        _ = linux.close(self.master);
        self.master = -1;
    }
}

/// Fork and exec `path` with the slave as the child's controlling terminal and stdio.
/// Returns the child pid.
///
/// The parent keeps its slave fd open for the pty's lifetime, so the master never returns
/// EIO/EOF/HUP when a child briefly closes every slave (some shells reopen their tty).
/// Child exit is detected via SIGCHLD, never the master.
///
/// `argv` and `envp` must outlive the call (the child copies them via execve).
pub fn spawn(
    self: *Pty,
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    options: SpawnOptions,
) Error!posix.pid_t {
    std.debug.assert(self.slave >= 0);

    const fork_rc = linux.fork();
    if (linux.errno(fork_rc) != .SUCCESS) return error.PtyFailed;
    const pid: posix.pid_t = @intCast(fork_rc);

    if (pid == 0) {
        // Child: async-signal-safe calls only. Start with a clean signal mask (the parent blocks
        // SIGCHLD for its signalfd, but shells need it).
        const empty_mask = posix.sigemptyset();
        posix.sigprocmask(linux.SIG.SETMASK, &empty_mask, null);
        if (linux.errno(linux.setsid()) != .SUCCESS) linux.exit(126);
        if (linux.errno(linux.ioctl(self.slave, linux.T.IOCSCTTY, 0)) != .SUCCESS) linux.exit(126);
        // Inherited stdio may be closed, so the master can occupy fd 0,
        // 1, or 2. Finish using it before installing child stdio.
        _ = linux.close(self.master);
        if (options.cwd) |cwd| {
            if (linux.errno(linux.chdir(cwd)) != .SUCCESS) linux.exit(126);
        }
        if (linux.errno(linux.dup2(self.slave, 0)) != .SUCCESS) linux.exit(126);
        if (linux.errno(linux.dup2(self.slave, 1)) != .SUCCESS) linux.exit(126);
        if (linux.errno(linux.dup2(self.slave, 2)) != .SUCCESS) linux.exit(126);
        if (self.slave > 2) {
            _ = linux.close(self.slave);
        } else {
            // dup2(fd, fd) leaves CLOEXEC set on the original slave.
            if (linux.errno(linux.fcntl(self.slave, linux.F.SETFD, 0)) != .SUCCESS) linux.exit(126);
        }
        _ = linux.execve(path, argv, envp);
        linux.exit(127); // exec failed
    }

    // Parent: keep our slave fd (see doc comment); it is CLOEXEC so it
    // cannot leak into exec'd children.
    return pid;
}

/// Propagate a new window size to the PTY (and thus the child via SIGWINCH).
pub fn setWinsize(self: *Pty, size: posix.winsize) Error!void {
    try check(linux.ioctl(self.master, linux.T.IOCSWINSZ, @intFromPtr(&size)));
}

/// Wait for the child to exit; returns its wait status.
pub fn wait(pid: posix.pid_t) Error!u32 {
    var status: i32 = undefined;
    try check(linux.wait4(pid, &status, 0, null));
    return @bitCast(status);
}

/// Reap the child if it has exited; null while it is still running.
pub fn tryWait(pid: posix.pid_t) Error!?u32 {
    var status: i32 = undefined;
    const rc = linux.wait4(pid, &status, linux.W.NOHANG, null);
    return switch (linux.errno(rc)) {
        .SUCCESS => if (rc == 0) null else @as(u32, @bitCast(status)),
        .CHILD => 0,
        else => |err| {
            log.err("wait4 failed: {}", .{err});
            return error.PtyFailed;
        },
    };
}

fn openRw(path: [*:0]const u8) ?posix.fd_t {
    const rc = linux.openat(linux.AT.FDCWD, path, .{
        .ACCMODE = .RDWR,
        .NOCTTY = true,
        .CLOEXEC = true,
    }, 0);
    if (linux.errno(rc) != .SUCCESS) {
        log.err("open {s} failed: {}", .{ path, linux.errno(rc) });
        return null;
    }
    return @intCast(rc);
}

fn check(rc: usize) Error!void {
    const err = linux.errno(rc);
    if (err != .SUCCESS) {
        log.err("syscall failed: {}", .{err});
        return error.PtyFailed;
    }
}

test "pty open and resize" {
    var pty: Pty = try .open(.{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 });
    defer pty.deinit();
    try std.testing.expect(pty.master >= 0);
    try std.testing.expect(pty.slave >= 0);
}

test "spawn installs stdio with closed inherited descriptors" {
    for (0..8) |closed_mask| {
        // Isolate descriptor closure from the test runner and exercise
        // exec: a surviving CLOEXEC flag is invisible before execve.
        const fork_rc = linux.fork();
        try std.testing.expectEqual(.SUCCESS, linux.errno(fork_rc));
        const pid: posix.pid_t = @intCast(fork_rc);
        if (pid == 0) {
            for (0..3) |fd| {
                if (closed_mask & (@as(usize, 1) << @intCast(fd)) != 0)
                    _ = linux.close(@intCast(fd));
            }
            var pty = Pty.open(.{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 }) catch linux.exit(120);
            const argv = [_:null]?[*:0]const u8{
                "/bin/sh", "-c", "test -t 0 && test -t 1 && test -t 2",
            };
            const envp = [_:null]?[*:0]const u8{};
            const child = pty.spawn("/bin/sh", &argv, &envp, .{}) catch linux.exit(121);
            const status = Pty.wait(child) catch linux.exit(122);
            pty.deinit();
            linux.exit(if (status == 0) 0 else 123);
        }
        try std.testing.expectEqual(@as(u32, 0), try Pty.wait(pid));
    }
}
