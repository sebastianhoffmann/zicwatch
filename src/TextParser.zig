//! Updates `State` line by line from `zig build --watch --color off` output.
//!
//! The output consists of blocks separated by blank lines. Each build prints one error block
//! per failing step (the path from a top-level step down to the failing step, followed by its
//! diagnostics), then one summary block (`Build Summary: ...` followed by a tree of the steps
//! that ran). A build is committed when its summary block ends.
const std = @import("std");
const mem = std.mem;
const tree = @import("tree.zig");
const State = @import("State.zig");
const Step = State.Step;
const Status = State.Status;

const TextParser = @This();

const max_depth = 64;

const Block = enum {
    /// Between blocks.
    none,
    summary,
    /// The first line of a block that may start an error header, waiting for the second line.
    root_pending,
    /// Step lines leading to the failing step.
    header,
    /// Diagnostics of `diag_step`.
    body,
    /// Output that cannot be attributed to a step.
    unattributed,
};

state: *State,
block: Block = .none,
stack: [max_depth]*Step = undefined,
stack_len: u16 = 0,
diag_step: ?*Step = null,
pending_root_buf: [State.max_name_len]u8 = undefined,
pending_root_len: u16 = 0,
summary_buf: [256]u8 = undefined,
summary_len: u16 = 0,
failed: u32 = 0,
build_started: bool = false,

pub fn init(state: *State) TextParser {
    return .{ .state = state };
}

/// Feeds one line of output, without its trailing newline.
pub fn feedLine(p: *TextParser, line: []const u8) error{OutOfMemory}!void {
    if (line.len == 0) return p.endBlock();
    p.build_started = true;
    switch (p.block) {
        .none => try p.startBlock(line),
        .summary => try p.summaryLine(line),
        .root_pending => if (tree.parseChild(line)) |child| {
            const root = try p.state.getOrCreate(p.pending_root_buf[0..p.pending_root_len]);
            p.stack[0] = root;
            p.stack_len = 1;
            p.diag_step = root;
            p.block = .header;
            try p.headerLine(child);
        } else {
            p.continuation(p.pending_root_buf[0..p.pending_root_len]);
            if (p.block == .body) p.bodyLine(line);
        },
        .header => if (tree.parseChild(line)) |child| {
            try p.headerLine(child);
        } else {
            p.block = .body;
            p.bodyLine(line);
        },
        .body => p.bodyLine(line),
        .unattributed => {},
    }
}

/// Handles the end of input. A summary that was not followed by a blank line is still committed.
pub fn finish(p: *TextParser, reason: []const u8) void {
    switch (p.block) {
        .summary => p.commit(),
        .root_pending => p.continuation(p.pending_root_buf[0..p.pending_root_len]),
        else => {},
    }
    p.block = .none;
    p.state.endOfStream(p.build_started, reason);
}

fn startBlock(p: *TextParser, line: []const u8) !void {
    if (tree.parseSummary(line)) |s| {
        p.block = .summary;
        p.failed = s.failed;
        const n = @min(line.len, p.summary_buf.len);
        @memcpy(p.summary_buf[0..n], line[0..n]);
        p.summary_len = @intCast(n);
        p.stack_len = 0;
        return;
    }

    const root = tree.parseRoot(line);
    if (root.status != null and root.status.?.isFailure()) {
        // A failing top-level step has no path leading to it.
        const step = try p.state.getOrCreate(root.name);
        step.stage(root.status.?);
        p.stack[0] = step;
        p.stack_len = 1;
        p.diag_step = step;
        p.block = .header;
        return;
    }

    if (line.len <= State.max_name_len) {
        @memcpy(p.pending_root_buf[0..line.len], line);
        p.pending_root_len = @intCast(line.len);
        p.block = .root_pending;
    } else {
        p.continuation(line);
    }
}

fn endBlock(p: *TextParser) void {
    switch (p.block) {
        .summary => p.commit(),
        .root_pending => p.continuation(p.pending_root_buf[0..p.pending_root_len]),
        else => {},
    }
    p.block = .none;
}

/// Output starting a new block that is not a summary or error header. Zig separates blocks with
/// blank lines, but a step's stderr may contain blank lines too, so this text is attributed to
/// the step whose diagnostics came right before it.
fn continuation(p: *TextParser, line: []const u8) void {
    if (p.diag_step) |step| {
        step.appendDiagnostics("\n");
        p.block = .body;
        p.bodyLine(line);
    } else {
        p.block = .unattributed;
    }
}

fn headerLine(p: *TextParser, child: tree.Line) !void {
    const step = try p.state.getOrCreate(child.name);
    if (child.depth <= p.stack_len and child.depth < max_depth) {
        p.state.addDependency(p.stack[child.depth - 1], step);
        p.stack[child.depth] = step;
        p.stack_len = child.depth + 1;
    }
    if (child.status) |status| step.stage(status);
    p.diag_step = step;
}

fn bodyLine(p: *TextParser, line: []const u8) void {
    // The full compiler command line is several kilobytes and of no use to agents.
    if (mem.startsWith(u8, line, "failed command: ")) return;
    const step = p.diag_step.?;
    step.appendDiagnostics(line);
    step.appendDiagnostics("\n");
}

fn summaryLine(p: *TextParser, line: []const u8) !void {
    const parsed = tree.parseChild(line) orelse tree.parseRoot(line);
    const step = try p.state.getOrCreate(parsed.name);
    if (parsed.depth == 0) {
        p.stack[0] = step;
        p.stack_len = 1;
    } else if (parsed.depth <= p.stack_len and parsed.depth < max_depth) {
        p.state.addDependency(p.stack[parsed.depth - 1], step);
        p.stack[parsed.depth] = step;
        p.stack_len = parsed.depth + 1;
    }
    if (parsed.status) |status| step.stage(status);
}

fn commit(p: *TextParser) void {
    p.state.commit(p.summary_buf[0..p.summary_len], p.failed);
    p.diag_step = null;
    p.build_started = false;
}

fn feedText(p: *TextParser, text: []const u8) !void {
    var lines = mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| try p.feedLine(line);
}

fn expectStep(state: *State, name: []const u8, status: Status, updated_in_build: u64) !void {
    const step = state.findStep(name) orelse {
        std.debug.print("missing step: {s}\n", .{name});
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqual(status, step.status);
    try std.testing.expectEqual(updated_in_build, step.updated_in_build);
}

fn expectCauses(state: *State, name: []const u8, expected: []const []const u8) !void {
    var buf: [8]*Step = undefined;
    const causes = state.failureCauses(state.findStep(name).?, &buf);
    try std.testing.expectEqual(expected.len, causes.len);
    for (expected, causes) |e, c| try std.testing.expectEqualStrings(e, c.name());
}

test "watch.log" {
    var state: State = .init(std.testing.allocator, std.testing.io);
    defer state.deinit();
    var p: TextParser = .init(&state);

    const exe = "compile exe example debug native";
    const physics = "compile lib physics fast native";

    var lines = mem.splitScalar(u8, @embedFile("testdata/watch.log"), '\n');
    var checked: u64 = 0;
    while (lines.next()) |line| {
        try p.feedLine(line);
        if (state.build == checked) continue;
        checked = state.build;
        switch (state.build) {
            // Clean build.
            1 => {
                try std.testing.expectEqualStrings("Build Summary: 67/67 steps succeeded", state.summary());
                try expectStep(&state, "install", .success, 1);
                try expectStep(&state, "install editor", .success, 1);
                try expectStep(&state, "check-tests", .success, 1);
                const editor = state.findStep("compile exe editor debug native").?;
                try std.testing.expect(mem.findScalar(*Step, editor.dependencies(), state.findStep(physics).?) != null);
            },
            // Syntax error in the main exe.
            2 => {
                try std.testing.expectEqualStrings("Build Summary: 64/67 steps succeeded (1 failed)", state.summary());
                try expectStep(&state, exe, .failure, 2);
                try expectStep(&state, "install example", .transitive_failure, 2);
                try expectStep(&state, "install", .transitive_failure, 2);
                try expectStep(&state, "install editor", .success, 1);
                try expectCauses(&state, "install", &.{exe});
                const diags = state.findStep(exe).?.diagnostics();
                try std.testing.expect(mem.startsWith(u8, diags, "src/main.zig:167:55: error: string literal contains invalid byte: '\\n'\n"));
                try std.testing.expect(mem.endsWith(u8, diags, "error: 1 compilation errors\n"));
                try std.testing.expect(mem.find(u8, diags, "failed command") == null);
            },
            // Fix.
            3 => {
                try expectStep(&state, exe, .success, 3);
                try expectStep(&state, "install", .success, 3);
                try std.testing.expectEqualStrings("", state.findStep(exe).?.diagnostics());
            },
            // No-op save.
            4 => try expectStep(&state, exe, .success, 4),
            // Syntax error in a lib used by several steps.
            5 => {
                try std.testing.expectEqualStrings("Build Summary: 54/67 steps succeeded (1 failed)", state.summary());
                try expectStep(&state, physics, .failure, 5);
                try expectStep(&state, "install editor", .transitive_failure, 5);
                try expectStep(&state, "check-tests", .transitive_failure, 5);
                try expectStep(&state, "install audio-tool", .success, 1);
                try expectCauses(&state, "install editor", &.{physics});
                try expectCauses(&state, "install", &.{physics});
                const diags = state.findStep(physics).?.diagnostics();
                try std.testing.expect(mem.startsWith(u8, diags, "src/physics/collision.zig:10:46: error: expected ',' after parameter\n"));
            },
            // Fix.
            6 => {
                try expectStep(&state, physics, .success, 6);
                try expectStep(&state, "install editor", .success, 6);
                try expectStep(&state, "check-tests", .success, 6);
                try expectCauses(&state, "install", &.{});
            },
            else => return error.TestUnexpectedResult,
        }
    }
    p.finish("");
    try std.testing.expectEqual(6, state.build);
    try std.testing.expect(!state.ended_mid_build);
}

test "blank lines in diagnostics" {
    var state: State = .init(std.testing.allocator, std.testing.io);
    defer state.deinit();
    var p: TextParser = .init(&state);
    try p.feedText(
        \\install
        \\+- run gen failure
        \\first
        \\
        \\second
        \\
        \\Build Summary: 1/2 steps succeeded (1 failed)
        \\install transitive failure
        \\+- run gen failure
        \\
    );
    try std.testing.expectEqualStrings("first\n\nsecond\n", state.findStep("run gen").?.diagnostics());
    try expectCauses(&state, "install", &.{"run gen"});
}

test "end of stream" {
    var state: State = .init(std.testing.allocator, std.testing.io);
    defer state.deinit();
    var p: TextParser = .init(&state);
    try p.feedText(
        \\Build Summary: 1/1 steps succeeded
        \\install success
        \\
        \\install
        \\+- compile exe x debug native 1 errors
        \\src/main.zig:1:1: error: x
    );
    p.finish("zig build exited with code 1");
    try std.testing.expectEqual(1, state.build);
    try std.testing.expect(state.ended_mid_build);
    try std.testing.expectEqualStrings("zig build exited with code 1", state.endReason());
    try expectStep(&state, "install", .success, 1);
}
