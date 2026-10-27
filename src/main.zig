const std = @import("std");
const Io = std.Io;
const mem = std.mem;

const Server = @import("Server.zig");

const usage =
    \\Usage:
    \\  zig build ... --watch --color off 2>&1 | zicwatch serve --socket PATH
    \\  zicwatch serve  --socket PATH --steps STEP,... [--bsp] [-- ZIG BUILD ARGS...]
    \\  zicwatch mark   --socket PATH
    \\  zicwatch status --socket PATH [--step NAME]
    \\  zicwatch wait   --socket PATH --after CURSOR [--step NAME] [--timeout 60s]
    \\
    \\serve follows build results and answers the other commands. Without --steps it
    \\reads the output of a watching zig build from stdin. With --steps it starts
    \\  zig build STEP... ARGS... --watch -fincremental --color off --summary new
    \\itself, or with --bsp it starts
    \\  zig build ARGS... -fincremental --listen=-
    \\and requests the steps over the build system protocol.
    \\mark prints a cursor for the latest completed build. Take one before editing.
    \\wait blocks until a build newer than CURSOR completes, then reports it.
    \\status reports the latest completed build immediately.
    \\Without --step, results cover the whole build.
    \\
    \\Exit codes: 0 success, 1 build failure, 2 any other error.
    \\Results are printed as JSON.
    \\
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var command: ?[]const u8 = null;
    var socket: ?[]const u8 = null;
    var step: []const u8 = "";
    var after: ?[]const u8 = null;
    var timeout_ms: i64 = 60 * std.time.ms_per_s;
    var bsp = false;
    var build_steps: ?[]const u8 = null;
    var build_args: ?[]const []const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
            try writeStderr(io, usage);
            return;
        }
        if (mem.eql(u8, arg, "--")) {
            build_args = args[i + 1 ..];
            break;
        }
        if (mem.eql(u8, arg, "--bsp")) {
            bsp = true;
            continue;
        }
        if (!mem.startsWith(u8, arg, "--")) {
            if (command != null) return usageError(io, "unexpected argument");
            command = arg;
            continue;
        }
        i += 1;
        if (i == args.len) return usageError(io, "missing option value");
        const value = args[i];
        if (mem.eql(u8, arg, "--socket")) {
            socket = value;
        } else if (mem.eql(u8, arg, "--step")) {
            step = value;
        } else if (mem.eql(u8, arg, "--after")) {
            after = value;
        } else if (mem.eql(u8, arg, "--steps")) {
            build_steps = value;
        } else if (mem.eql(u8, arg, "--timeout")) {
            timeout_ms = parseDuration(value) orelse return usageError(io, "invalid timeout");
        } else {
            return usageError(io, "unknown option");
        }
    }

    const cmd = command orelse return usageError(io, "missing command");
    const socket_path = socket orelse return usageError(io, "missing --socket");
    if (mem.findScalar(u8, step, '\t') != null) return usageError(io, "invalid step name");

    if (mem.eql(u8, cmd, "serve")) return serve(init, socket_path, bsp, build_steps, build_args);
    if (bsp or build_steps != null or build_args != null) return usageError(io, "--bsp, --steps and -- only apply to serve");

    var request_buf: [1024]u8 = undefined;
    const request = if (mem.eql(u8, cmd, "mark"))
        "mark"
    else if (mem.eql(u8, cmd, "status"))
        std.fmt.bufPrint(&request_buf, "status\t{s}", .{step}) catch return usageError(io, "step name too long")
    else if (mem.eql(u8, cmd, "wait"))
        std.fmt.bufPrint(&request_buf, "wait\t{s}\t{d}\t{s}", .{
            after orelse return usageError(io, "missing --after"), timeout_ms, step,
        }) catch return usageError(io, "step name too long")
    else
        return usageError(io, "unknown command");

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .initStreaming(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    const exit_code = try query(io, socket_path, request, stdout);
    try stdout.flush();
    std.process.exit(exit_code);
}

fn serve(
    init: std.process.Init,
    socket_path: []const u8,
    bsp: bool,
    build_steps: ?[]const u8,
    build_args: ?[]const []const u8,
) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var steps: std.ArrayList([]const u8) = .empty;
    if (build_steps) |list| {
        var it = mem.tokenizeScalar(u8, list, ',');
        while (it.next()) |name| try steps.append(arena, name);
    }
    if (build_steps == null and (bsp or build_args != null)) return usageError(io, "--bsp and \"--\" need --steps");
    if (build_steps != null and steps.items.len == 0) return usageError(io, "--steps needs at least one step");
    const input: Server.Input = if (build_steps != null) blk: {
        const build: Server.Build = .{ .steps = steps.items, .args = build_args orelse &.{} };
        break :blk if (bsp) .{ .bsp = build } else .{ .text = build };
    } else .stdin;

    Server.serve(init.gpa, arena, io, socket_path, input) catch |err| switch (err) {
        error.AlreadyRunning => {
            var buf: [256]u8 = undefined;
            try writeStderr(io, std.fmt.bufPrint(&buf, "error: another observer is already serving {s}\n", .{socket_path}) catch "error: another observer is already serving this socket\n");
            std.process.exit(Server.exit_error);
        },
        error.UnknownBuildStep => std.process.exit(Server.exit_error),
        else => |e| return e,
    };
}

/// Sends `request` to the observer and copies its JSON response to `out`.
fn query(io: Io, socket_path: []const u8, request: []const u8, out: *Io.Writer) !u8 {
    const address = Io.net.UnixAddress.init(socket_path) catch {
        try writeUnavailable(out, "socket path is too long");
        return Server.exit_error;
    };
    const stream = address.connect(io) catch {
        try writeUnavailable(out, "cannot connect to the observer; is zicwatch serve running?");
        return Server.exit_error;
    };
    defer stream.close(io);

    var write_buffer: [1024]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buffer);
    stream_writer.interface.print("{s}\n", .{request}) catch {
        try writeUnavailable(out, "sending the request failed");
        return Server.exit_error;
    };
    stream_writer.interface.flush() catch {
        try writeUnavailable(out, "sending the request failed");
        return Server.exit_error;
    };

    var read_buffer: [16 * 1024]u8 = undefined;
    var stream_reader = stream.reader(io, &read_buffer);
    const reader = &stream_reader.interface;
    const status_line = (reader.takeDelimiter('\n') catch null) orelse {
        try writeUnavailable(out, "the observer closed the connection without answering");
        return Server.exit_error;
    };
    const exit_code = std.fmt.parseInt(u8, status_line, 10) catch Server.exit_error;
    _ = reader.streamRemaining(out) catch |err| switch (err) {
        error.ReadFailed => return Server.exit_error,
        error.WriteFailed => return err,
    };
    return exit_code;
}

fn writeUnavailable(out: *Io.Writer, message: []const u8) !void {
    try Server.writeErrorJson(out, .{ .code = "unavailable", .message = message });
}

/// Parses durations like `500ms`, `10s` and `2m`. Plain numbers are seconds.
fn parseDuration(text: []const u8) ?i64 {
    const digits = mem.findNone(u8, text, "0123456789") orelse text.len;
    const number = std.fmt.parseInt(i64, text[0..digits], 10) catch return null;
    const unit = text[digits..];
    const factor: i64 = if (unit.len == 0 or mem.eql(u8, unit, "s"))
        std.time.ms_per_s
    else if (mem.eql(u8, unit, "ms"))
        1
    else if (mem.eql(u8, unit, "m"))
        std.time.ms_per_min
    else
        return null;
    return std.math.mul(i64, number, factor) catch null;
}

fn usageError(io: Io, message: []const u8) !void {
    var buf: [256]u8 = undefined;
    try writeStderr(io, std.fmt.bufPrint(&buf, "error: {s}\n\n", .{message}) catch message);
    try writeStderr(io, usage);
    std.process.exit(Server.exit_error);
}

fn writeStderr(io: Io, bytes: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var stderr_writer: Io.File.Writer = .initStreaming(.stderr(), io, &buffer);
    try stderr_writer.interface.writeAll(bytes);
    try stderr_writer.interface.flush();
}

test parseDuration {
    try std.testing.expectEqual(10_000, parseDuration("10s"));
    try std.testing.expectEqual(10_000, parseDuration("10"));
    try std.testing.expectEqual(500, parseDuration("500ms"));
    try std.testing.expectEqual(120_000, parseDuration("2m"));
    try std.testing.expectEqual(null, parseDuration("2h"));
    try std.testing.expectEqual(null, parseDuration("s"));
}

test {
    _ = Server;
    _ = @import("TextParser.zig");
    _ = @import("tree.zig");
}
