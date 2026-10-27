//! Follows build results on the main thread and answers clients on a Unix socket. Results come
//! from text output on stdin, from the text output of a `zig build --watch` child process, or
//! from a `zig build --listen=-` child process over the build system protocol.
//! One task accepts connections and each connection gets its own task, all using blocking I/O.
//!
//! Protocol: the client sends one request line with tab-separated fields and the server replies
//! with the exit code on the first line, followed by a JSON object, then closes the connection.
//!
//!     mark
//!     status <step>
//!     wait <cursor> <timeout ms> <step>
//!
//! An empty step name refers to the whole build.
const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const State = @import("State.zig");
const Step = State.Step;
const TextParser = @import("TextParser.zig");
const Bsp = @import("Bsp.zig");

const Server = @This();

pub const exit_success = 0;
pub const exit_failure = 1;
pub const exit_error = 2;

const max_failures = 16;
const max_listed_steps = 256;
/// Space for copying diagnostics out of the state while holding the lock.
const text_capacity = 4 << 20;

state: *State,
io: Io,
session: [8]u8,

pub const Input = union(enum) {
    /// `zig build --watch --color off` output piped into stdin.
    stdin,
    /// Start `zig build --watch` and parse its text output.
    text: Build,
    /// Start `zig build --listen=-` and use the build system protocol.
    bsp: Build,
};

pub const Build = struct {
    /// Top-level steps to build.
    steps: []const []const u8,
    /// Further arguments for `zig build`.
    args: []const []const u8,
};

pub fn serve(gpa: mem.Allocator, arena: mem.Allocator, io: Io, socket_path: []const u8, input: Input) !void {
    const address = try Io.net.UnixAddress.init(socket_path);
    if (address.connect(io)) |stream| {
        stream.close(io);
        return error.AlreadyRunning;
    } else |_| {}
    // Left behind by an observer that was killed.
    Io.Dir.cwd().deleteFile(io, socket_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);
    defer Io.Dir.cwd().deleteFile(io, socket_path) catch {};

    var state: State = .init(gpa, io);
    defer state.deinit();

    var session_bytes: [4]u8 = undefined;
    io.random(&session_bytes);
    var server: Server = .{ .state = &state, .io = io, .session = undefined };
    _ = std.fmt.bufPrint(&server.session, "{x:0>8}", .{mem.readInt(u32, &session_bytes, .little)}) catch unreachable;

    var accept_task = try io.concurrent(acceptLoop, .{ &server, &listener });
    defer accept_task.cancel(io) catch {};

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer: Io.File.Writer = .initStreaming(.stderr(), io, &stderr_buffer);
    const log = &stderr_writer.interface;

    switch (input) {
        .stdin => {
            var parser: TextParser = .init(&state);
            try readLines(io, .stdin(), &parser, null);
            parser.finish("stdin ended");
        },
        .text => |build| {
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.appendSlice(arena, &.{ "zig", "build" });
            try argv.appendSlice(arena, build.steps);
            try argv.appendSlice(arena, build.args);
            try argv.appendSlice(arena, &.{ "--watch", "-fincremental", "--color", "off", "--summary", "new" });
            var child = try std.process.spawn(io, .{
                .argv = argv.items,
                .stdin = .ignore,
                .stderr = .pipe,
            });
            defer child.kill(io);
            forwardSignalsTo(child.id.?);

            var parser: TextParser = .init(&state);
            // Zig writes everything to stderr. Echo it so the terminal shows the usual output.
            try readLines(io, child.stderr.?, &parser, log);
            var reason_buf: [128]u8 = undefined;
            forward_pid.store(0, .release);
            parser.finish(exitReason(&reason_buf, try child.wait(io)));
        },
        .bsp => |build| {
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.appendSlice(arena, &.{ "zig", "build" });
            try argv.appendSlice(arena, build.args);
            try argv.appendSlice(arena, &.{ "-fincremental", "--listen=-" });
            var child = try std.process.spawn(io, .{
                .argv = argv.items,
                .stdin = .pipe,
                .stdout = .pipe,
            });
            defer child.kill(io);
            forwardSignalsTo(child.id.?);

            var read_buffer: [64 * 1024]u8 = undefined;
            var child_reader = child.stdout.?.reader(io, &read_buffer);
            var write_buffer: [4096]u8 = undefined;
            var child_writer = child.stdin.?.writer(io, &write_buffer);
            var bsp: Bsp = .init(gpa, io, &state, build.steps, &child_reader.interface, &child_writer.interface, log);
            defer bsp.deinit();
            bsp.run() catch |err| switch (err) {
                error.ReadFailed => return child_reader.err.?,
                else => |e| return e,
            };
            var reason_buf: [128]u8 = undefined;
            forward_pid.store(0, .release);
            state.endOfStream(bsp.inBuild(), exitReason(&reason_buf, try child.wait(io)));
        },
    }
    if (stopping.load(.acquire)) return;
    try log.print("input ended ({s}), still serving {s}\n", .{ state.endReason(), socket_path });
    try log.flush();
    try accept_task.await(io);
}

/// The zig build child that SIGINT and SIGTERM are passed on to, or 0.
var forward_pid: std.atomic.Value(std.posix.pid_t) = .init(0);
/// Set once zicwatch was asked to stop.
var stopping: std.atomic.Value(bool) = .init(false);

/// Makes SIGINT and SIGTERM stop the child the way Ctrl-C stops a plain `zig build --watch`.
/// Killing only zicwatch would otherwise leave the child watching and compiling in the
/// background, where it races with the next build on the same cache. Once the child exits,
/// its output ends and `serve` returns.
fn forwardSignalsTo(pid: std.posix.pid_t) void {
    forward_pid.store(pid, .release);
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = forwardSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);
}

fn forwardSignal(_: std.posix.SIG) callconv(.c) void {
    stopping.store(true, .release);
    const pid = forward_pid.load(.acquire);
    if (pid != 0) std.posix.kill(pid, .INT) catch {};
}

fn exitReason(buf: []u8, term: std.process.Child.Term) []const u8 {
    return switch (term) {
        .exited => |code| std.fmt.bufPrint(buf, "zig build exited with code {d}", .{code}),
        .signal => |sig| std.fmt.bufPrint(buf, "zig build was terminated by signal {t}", .{sig}),
        .stopped => |sig| std.fmt.bufPrint(buf, "zig build was stopped by signal {t}", .{sig}),
        .unknown => |code| std.fmt.bufPrint(buf, "zig build ended with status {d}", .{code}),
    } catch "zig build ended";
}

fn readLines(io: Io, file: Io.File, parser: *TextParser, echo: ?*Io.Writer) !void {
    var buffer: [64 * 1024]u8 = undefined;
    var file_reader: Io.File.Reader = .init(file, io, &buffer);
    const reader = &file_reader.interface;
    while (true) {
        const line = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                // Keep the start of overlong lines and drop the rest.
                const start = reader.buffered();
                if (echo) |w| try w.print("{s}...\n", .{start});
                try parser.feedLine(start);
                reader.toss(reader.bufferedLen());
                _ = reader.discardDelimiterInclusive('\n') catch |e| switch (e) {
                    error.EndOfStream => {},
                    error.ReadFailed => return file_reader.err.?,
                };
                continue;
            },
            error.ReadFailed => return file_reader.err.?,
        } orelse break;
        if (echo) |w| {
            try w.print("{s}\n", .{line});
            if (reader.bufferedLen() == 0) try w.flush();
        }
        try parser.feedLine(line);
    }
    if (echo) |w| try w.flush();
}

fn acceptLoop(server: *Server, listener: *Io.net.Server) Io.Cancelable!void {
    const io = server.io;
    var group: Io.Group = .init;
    defer group.cancel(io);
    while (true) {
        const stream = listener.accept(io) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => {
                std.log.warn("accepting a connection failed: {t}", .{err});
                try io.sleep(.fromMilliseconds(100), .awake);
                continue;
            },
        };
        group.concurrent(io, handleConnection, .{ server, stream }) catch {
            stream.close(io);
        };
    }
}

fn handleConnection(server: *Server, stream: Io.net.Stream) void {
    const io = server.io;
    defer stream.close(io);

    var read_buffer: [1024]u8 = undefined;
    var stream_reader = stream.reader(io, &read_buffer);
    const line = (stream_reader.interface.takeDelimiter('\n') catch return) orelse return;

    var write_buffer: [16 * 1024]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buffer);
    const w = &stream_writer.interface;
    server.respond(line, w) catch return;
    w.flush() catch return;
}

const Failure = struct {
    step: *Step,
    updated_in_build: u64,
    start: usize,
    len: usize,
    truncated: bool,
};

/// A copy of everything a response needs, so the response can be written without the lock.
/// Steps are never freed and their names never change, so pointers to them stay valid.
const Snapshot = struct {
    build: u64,
    failed: u32,
    ended: bool,
    ended_mid_build: bool,
    end_reason_buf: [256]u8,
    end_reason_len: usize,
    summary_buf: [256]u8,
    summary_len: usize,
    step: ?*Step,
    step_status: State.Status,
    step_updated_in_build: u64,
    failures: [max_failures]Failure,
    failures_len: usize,
    more_failures: usize,
    /// Steps suggested for an unknown step name: those containing it, or else all steps.
    listed: [max_listed_steps]*Step,
    listed_len: usize,
    listed_matches: bool,
    text: []u8,
};

pub const Error = struct {
    code: []const u8,
    message: []const u8,
};

threadlocal var text_buffer: ?[]u8 = null;

/// Each thread allocates its buffer once, without filling it, so unused pages are never committed.
fn textBuffer() ?[]u8 {
    if (text_buffer == null) {
        const bytes = std.heap.page_allocator.rawAlloc(text_capacity, .@"1", @returnAddress()) orelse return null;
        text_buffer = bytes[0..text_capacity];
    }
    return text_buffer;
}

fn respond(server: *Server, line: []const u8, w: *Io.Writer) !void {
    var fields = mem.splitScalar(u8, line, '\t');
    const command = fields.first();

    if (mem.eql(u8, command, "mark")) {
        server.state.mutex.lock(server.io) catch return;
        const build = server.state.build;
        server.state.mutex.unlock(server.io);
        var j: std.json.Stringify = .{ .writer = w };
        try w.print("{d}\n", .{exit_success});
        try j.beginObject();
        try server.writeCursor(&j, build);
        try j.endObject();
        try w.writeByte('\n');
        return;
    }

    var after: ?u64 = null;
    var timeout_ms: i64 = 0;
    if (mem.eql(u8, command, "wait")) {
        const cursor = fields.next() orelse "";
        after = server.parseCursor(cursor) orelse return writeError(w, .{
            .code = "invalid_cursor",
            .message = "the cursor was not created by this observer; it may have been restarted, so run mark again",
        });
        timeout_ms = std.fmt.parseInt(i64, fields.next() orelse "", 10) catch
            return writeError(w, .{ .code = "bad_request", .message = "invalid timeout" });
    } else if (!mem.eql(u8, command, "status")) {
        return writeError(w, .{ .code = "bad_request", .message = "unknown command" });
    }
    const step_name = fields.rest();

    const text = textBuffer() orelse return writeError(w, .{ .code = "out_of_memory", .message = "out of memory" });
    var snapshot: Snapshot = undefined;
    snapshot.text = text;
    const err = server.collect(&snapshot, after, timeout_ms, step_name) catch |e| switch (e) {
        error.Canceled => return,
    };
    if (err) |e| return server.writeErrorWithState(w, e, &snapshot);
    return server.writeResult(w, &snapshot);
}

/// Waits for a build newer than `after` if given, then fills `snapshot`.
fn collect(server: *Server, snapshot: *Snapshot, after: ?u64, timeout_ms: i64, step_name: []const u8) Io.Cancelable!?Error {
    const state = server.state;
    const io = server.io;
    try state.mutex.lock(io);
    defer state.mutex.unlock(io);

    snapshot.listed_len = 0;
    const result: ?Error = result: {
        if (after) |a| {
            if (a > state.build) break :result .{
                .code = "invalid_cursor",
                .message = "the cursor is ahead of the latest build",
            };
            const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } };
            const deadline = timeout.toDeadline(io);
            while (state.build <= a) {
                if (state.ended) break :result .{
                    .code = "stream_ended",
                    .message = "the build output ended before a newer build completed",
                };
                state.changed.waitTimeout(io, &state.mutex, deadline) catch |e| switch (e) {
                    error.Timeout => if (state.build <= a) break :result .{
                        .code = "timeout",
                        .message = "no newer build completed before the timeout",
                    },
                    error.Canceled => |c| return c,
                };
            }
        }
        if (state.build == 0) break :result .{
            .code = "no_build",
            .message = "no build has completed yet",
        };
        break :result null;
    };

    snapshot.build = state.build;
    snapshot.failed = state.failed;
    snapshot.ended = state.ended;
    snapshot.ended_mid_build = state.ended_mid_build;
    const end_reason = state.endReason();
    @memcpy(snapshot.end_reason_buf[0..end_reason.len], end_reason);
    snapshot.end_reason_len = end_reason.len;
    const summary = state.summary();
    @memcpy(snapshot.summary_buf[0..summary.len], summary);
    snapshot.summary_len = summary.len;
    snapshot.step = null;
    snapshot.failures_len = 0;
    snapshot.more_failures = 0;
    if (result != null) return result;

    var causes_buf: [max_failures]*Step = undefined;
    var causes: []*Step = &.{};
    if (step_name.len > 0) {
        const step = state.findStep(step_name) orelse {
            snapshot.listed_matches = true;
            listSteps(state, snapshot, step_name);
            if (snapshot.listed_len == 0) {
                snapshot.listed_matches = false;
                listSteps(state, snapshot, null);
            }
            return .{
                .code = "unknown_step",
                .message = "no step has this exact name; use a full name as printed in the build summary",
            };
        };
        snapshot.step = step;
        snapshot.step_status = step.status;
        snapshot.step_updated_in_build = step.updated_in_build;
        causes = state.failureCauses(step, &causes_buf);
    } else {
        var it = state.steps.valueIterator();
        while (it.next()) |s| {
            if (s.*.status != .failure) continue;
            if (causes.len == max_failures) {
                snapshot.more_failures += 1;
                continue;
            }
            causes_buf[causes.len] = s.*;
            causes = causes_buf[0 .. causes.len + 1];
        }
    }

    var text_len: usize = 0;
    for (causes) |cause| {
        const diagnostics = cause.diagnostics();
        const n = @min(diagnostics.len, snapshot.text.len - text_len);
        @memcpy(snapshot.text[text_len..][0..n], diagnostics[0..n]);
        snapshot.failures[snapshot.failures_len] = .{
            .step = cause,
            .updated_in_build = cause.updated_in_build,
            .start = text_len,
            .len = n,
            .truncated = n < diagnostics.len or cause.diagnosticsTruncated(),
        };
        snapshot.failures_len += 1;
        text_len += n;
    }
    return null;
}

fn listSteps(state: *State, snapshot: *Snapshot, containing: ?[]const u8) void {
    var it = state.steps.valueIterator();
    while (it.next()) |s| {
        const step = s.*;
        if (snapshot.listed_len == max_listed_steps) return;
        if (containing) |part| if (mem.find(u8, step.name(), part) == null) continue;
        snapshot.listed[snapshot.listed_len] = step;
        snapshot.listed_len += 1;
    }
}

fn parseCursor(server: *Server, cursor: []const u8) ?u64 {
    const session = cursor[0 .. mem.findScalar(u8, cursor, ':') orelse return null];
    if (!mem.eql(u8, session, &server.session)) return null;
    return std.fmt.parseInt(u64, cursor[session.len + 1 ..], 10) catch null;
}

fn writeCursor(server: *Server, j: *std.json.Stringify, build: u64) !void {
    var buf: [32]u8 = undefined;
    try j.objectField("cursor");
    try j.write(std.fmt.bufPrint(&buf, "{s}:{d}", .{ &server.session, build }) catch unreachable);
}

fn writeResult(server: *Server, w: *Io.Writer, snapshot: *const Snapshot) !void {
    const outcome: []const u8, const exit_code: u8 = if (snapshot.step != null) switch (snapshot.step_status) {
        .success => .{ "success", exit_success },
        .skipped, .transitive_skip => .{ "skipped", exit_success },
        .failure, .transitive_failure => .{ "failure", exit_failure },
        .unknown => .{ "unknown", exit_error },
    } else if (snapshot.failed > 0)
        .{ "failure", exit_failure }
    else
        .{ "success", exit_success };

    try w.print("{d}\n", .{exit_code});
    var j: std.json.Stringify = .{ .writer = w };
    try j.beginObject();
    try server.writeCursor(&j, snapshot.build);
    try j.objectField("build");
    try j.write(snapshot.build);
    try j.objectField("summary");
    try j.write(snapshot.summary_buf[0..snapshot.summary_len]);
    try j.objectField("outcome");
    try j.write(outcome);
    if (snapshot.step) |step| {
        try j.objectField("step");
        try j.beginObject();
        try j.objectField("name");
        try j.write(step.name());
        try j.objectField("status");
        try j.write(@tagName(snapshot.step_status));
        try j.objectField("updated_in_build");
        try j.write(snapshot.step_updated_in_build);
        try j.endObject();
    }
    try j.objectField("failures");
    try j.beginArray();
    for (snapshot.failures[0..snapshot.failures_len]) |failure| {
        try j.beginObject();
        try j.objectField("step");
        try j.write(failure.step.name());
        try j.objectField("updated_in_build");
        try j.write(failure.updated_in_build);
        try j.objectField("diagnostics");
        try j.write(snapshot.text[failure.start..][0..failure.len]);
        try j.objectField("truncated");
        try j.write(failure.truncated);
        try j.endObject();
    }
    try j.endArray();
    if (snapshot.more_failures > 0) {
        try j.objectField("more_failures");
        try j.write(snapshot.more_failures);
    }
    try writeStreamState(&j, snapshot);
    try j.endObject();
    try w.writeByte('\n');
}

fn writeErrorWithState(server: *Server, w: *Io.Writer, err: Error, snapshot: *Snapshot) !void {
    try w.print("{d}\n", .{exit_error});
    var j: std.json.Stringify = .{ .writer = w };
    try j.beginObject();
    try j.objectField("error");
    try j.write(err.code);
    try j.objectField("message");
    try j.write(err.message);
    try server.writeCursor(&j, snapshot.build);
    if (snapshot.listed_len > 0) {
        mem.sort(*Step, snapshot.listed[0..snapshot.listed_len], {}, struct {
            fn lessThan(_: void, a: *Step, b: *Step) bool {
                return mem.order(u8, a.name(), b.name()) == .lt;
            }
        }.lessThan);
        try j.objectField(if (snapshot.listed_matches) "matching_steps" else "steps");
        try j.beginArray();
        for (snapshot.listed[0..snapshot.listed_len]) |step| try j.write(step.name());
        try j.endArray();
    }
    try writeStreamState(&j, snapshot);
    try j.endObject();
    try w.writeByte('\n');
}

fn writeStreamState(j: *std.json.Stringify, snapshot: *const Snapshot) !void {
    try j.objectField("stream_ended");
    try j.write(snapshot.ended);
    if (snapshot.ended) {
        try j.objectField("stream_end_reason");
        try j.write(snapshot.end_reason_buf[0..snapshot.end_reason_len]);
    }
    if (snapshot.ended_mid_build) {
        try j.objectField("stream_ended_mid_build");
        try j.write(true);
    }
}

fn writeError(w: *Io.Writer, err: Error) !void {
    try w.print("{d}\n", .{exit_error});
    try writeErrorJson(w, err);
}

/// Writes an error result without the protocol's exit code line.
pub fn writeErrorJson(w: *Io.Writer, err: Error) !void {
    var j: std.json.Stringify = .{ .writer = w };
    try j.beginObject();
    try j.objectField("error");
    try j.write(err.code);
    try j.objectField("message");
    try j.write(err.message);
    try j.endObject();
    try w.writeByte('\n');
}
