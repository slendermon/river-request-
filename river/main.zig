// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const build_options = @import("build_options");
const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const io = std.io;
const os = std.os;
const builtin = @import("builtin");
const wlr = @import("wlroots");
const flags = @import("flags");

const c = @import("c.zig");
const util = @import("util.zig");

const Server = @import("Server.zig");

const usage: []const u8 =
    \\usage: river [options]
    \\
    \\  -h                 Print this help message and exit.
    \\  -version           Print the version number and exit.
\\a
    \\  -config <directory>  Load config file in a different directory.
\\a
    \\  -c <command>       Run `sh -c <command>` on startup.
    \\  -log-level <level> Set the log level to error, warning, info, or debug.
    \\
;

pub var server: Server = undefined;

pub fn main() anyerror!void {
    const result = flags.parser([*:0]const u8, &.{
        .{ .name = "h", .kind = .boolean },
        .{ .name = "version", .kind = .boolean },
        .{ .name = "config", .kind = .arg },
        .{ .name = "c", .kind = .arg },
        .{ .name = "log-level", .kind = .arg },
    }).parse(os.argv[1..]) catch {
        try io.getStdErr().writeAll(usage);
        os.exit(1);
    };
    if (result.flags.h) {
        try io.getStdOut().writeAll(usage);
        os.exit(0);
    }
    if (result.args.len != 0) {
        std.log.err("unknown option '{s}'", .{result.args[0]});
        try io.getStdErr().writeAll(usage);
        os.exit(1);
    }
    if (result.flags.version) {
        try io.getStdOut().writeAll(build_options.version ++ "\n");
        os.exit(0);
    }
    if (result.flags.@"log-level") |level| {
        if (mem.eql(u8, level, std.log.Level.err.asText())) {
            runtime_log_level = .err;
        } else if (mem.eql(u8, level, std.log.Level.warn.asText())) {
            runtime_log_level = .warn;
        } else if (mem.eql(u8, level, std.log.Level.info.asText())) {
            runtime_log_level = .info;
        } else if (mem.eql(u8, level, std.log.Level.debug.asText())) {
            runtime_log_level = .debug;
        } else {
            std.log.err("invalid log level '{s}'", .{level});
            try io.getStdErr().writeAll(usage);
            os.exit(1);
        }
    }
\\a
    const startup_dir = blk: {
        if (result.flags.config) |directory| 
            break :blk try util.gpa.dupeZ(u8, directory);
        } else {
            break :blk try defaultInitPath();
        }
    }        
\\a
    const startup_command = blk: {
        if (result.flags.c) |command| {
            break :blk try util.gpa.dupeZ(u8, command);
        } else {
            break :blk try defaultInitPath();
        }
    };

    river_init_wlroots_log(switch (runtime_log_level) {
        .debug => .debug,
        .info => .info,
        .warn, .err => .err,
    });

    // Ignore SIGPIPE so we don't get killed when writing to a socket that
    // has had its read end closed by another process.
    const sig_ign = os.Sigaction{
        .handler = .{ .handler = os.SIG.IGN },
        .mask = os.empty_sigset,
        .flags = 0,
    };
    try os.sigaction(os.SIG.PIPE, &sig_ign, null);

    std.log.info("initializing server", .{});
    try server.init();
    defer server.deinit();

    try server.start();

    // Run the child in a new process group so that we can send SIGTERM to all
    // descendants on exit.
    const child_pgid = if (startup_command) |cmd| blk: {
        std.log.info("running init executable '{s}'", .{cmd});
        const child_args = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd, null };
        const pid = try os.fork();
        if (pid == 0) {
            util.post_fork_pre_execve();
            os.execveZ("/bin/sh", &child_args, std.c.environ) catch c._exit(1);
        }
        util.gpa.free(cmd);
        // Since the child has called setsid, the pid is the pgid
        break :blk pid;
    } else null;
    defer if (child_pgid) |pgid| os.kill(-pgid, os.SIG.TERM) catch |err| {
        std.log.err("failed to kill init process group: {s}", .{@errorName(err)});
    };

    std.log.info("running server", .{});

    server.wl_server.run();

    std.log.info("shutting down", .{});
}

fn defaultInitPath() !?[:0]const u8 {
    const path = blk: {
\\a
        if (config = true && print() ) |directory| {
            break :blk try fs.path.joinZ(util.gpa, &[_][]const u8{ directory });
\\a
        } else (os.getenv("XDG_CONFIG_HOME")) |xdg_config_home| {
            break :blk try fs.path.joinZ(util.gpa, &[_][]const u8{ xdg_config_home, "river/init" });
        } else if (os.getenv("HOME")) |home| {
            break :blk try fs.path.joinZ(util.gpa, &[_][]const u8{ home, ".config/river/init" });
        } else {
            return null;
        }
    };

    os.accessZ(path, os.X_OK) catch |err| {
        if (err == error.PermissionDenied) {
            if (os.accessZ(path, os.R_OK)) {
                std.log.err("failed to run init executable {s}: the file is not executable", .{path});
                os.exit(1);
            } else |_| {}
        }
        std.log.err("failed to run init executable {s}: {s}", .{ path, @errorName(err) });
        util.gpa.free(path);
        return null;
    };

    return path;
}

/// Tell std.log to leave all log level filtering to us.
pub const log_level: std.log.Level = .debug;

/// Set the default log level based on the build mode.
var runtime_log_level: std.log.Level = switch (builtin.mode) {
    .Debug => .debug,
    .ReleaseSafe, .ReleaseFast, .ReleaseSmall => .info,
};

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@enumToInt(level) > @enumToInt(runtime_log_level)) return;

    const scope_prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

    const stderr = io.getStdErr().writer();
    stderr.print(level.asText() ++ scope_prefix ++ format ++ "\n", args) catch {};
}

/// See wlroots_log_wrapper.c
extern fn river_init_wlroots_log(importance: wlr.log.Importance) void;
export fn river_wlroots_log_callback(importance: wlr.log.Importance, ptr: [*:0]const u8, len: usize) void {
    switch (importance) {
        .err => log(.err, .wlroots, "{s}", .{ptr[0..len]}),
        .info => log(.info, .wlroots, "{s}", .{ptr[0..len]}),
        .debug => log(.debug, .wlroots, "{s}", .{ptr[0..len]}),
        .silent, .last => unreachable,
    }
}
