//! Parsing of single lines from `zig build --watch --color off` output.
//! The formats mirror `printTreeStep`, `printStepStatus` and `printErrorMessages`
//! in the build runner (`lib/compiler/Maker.zig`).
const std = @import("std");
const mem = std.mem;

pub const Status = @import("State.zig").Status;

/// A step as printed in a summary tree or an error header.
pub const Line = struct {
    /// 0 for top-level steps, which are printed without a prefix.
    depth: u16,
    name: []const u8,
    /// Null for error header lines leading to the failing step.
    status: ?Status,
    /// The step was already printed earlier in the same tree.
    reused: bool,
};

pub const Summary = struct {
    failed: u32,
};

/// Parses a `Build Summary: ...` line.
pub fn parseSummary(line: []const u8) ?Summary {
    const rest = mem.cutPrefix(u8, line, "Build Summary: ") orelse return null;
    // Anything after ';' describes tests, whose failures are counted as failed steps already.
    const steps = rest[0 .. mem.findScalar(u8, rest, ';') orelse rest.len];
    const failed_end = mem.find(u8, steps, " failed") orelse return .{ .failed = 0 };
    const failed_start = if (mem.findLastAny(u8, steps[0..failed_end], " (")) |i| i + 1 else 0;
    return .{ .failed = std.fmt.parseInt(u32, steps[failed_start..failed_end], 10) catch 0 };
}

/// Parses a line with a `+- ` tree prefix, or returns null if it has none.
pub fn parseChild(line: []const u8) ?Line {
    var i: usize = 0;
    var depth: u16 = 1;
    while (true) : ({
        i += 3;
        depth += 1;
    }) {
        const rest = line[i..];
        if (mem.startsWith(u8, rest, "+- ")) {
            var result = parseStep(rest[3..]);
            result.depth = depth;
            return result;
        }
        if (!mem.startsWith(u8, rest, "|  ") and !mem.startsWith(u8, rest, "   ")) return null;
    }
}

/// Parses a top-level step line, which has no prefix.
pub fn parseRoot(line: []const u8) Line {
    return parseStep(line);
}

fn parseStep(text: []const u8) Line {
    var line: Line = .{ .depth = 0, .name = text, .status = null, .reused = false };
    if (mem.cutSuffix(u8, text, " (reused)")) |name| {
        line.name = name;
        line.reused = true;
        return line;
    }
    if (mem.endsWith(u8, text, " more reused dependencies)")) {
        if (mem.findLast(u8, text, " (+")) |i| {
            line.name = text[0..i];
            line.reused = true;
            return line;
        }
    }

    // Successful steps may be followed by a duration and peak memory usage.
    const trimmed = trimMetrics(text);
    if (cutStatus(trimmed, " success") orelse cutStatus(trimmed, " cached")) |name| {
        line.name = name;
        line.status = .success;
        return line;
    }
    if (cutTestResults(trimmed)) |r| {
        line.name = r.name;
        line.status = if (r.failed) .failure else .success;
        return line;
    }

    if (mem.find(u8, text, " skipped (not enough memory)")) |i| {
        line.name = text[0..i];
        line.status = .skipped;
        return line;
    }
    const plain = [_]struct { []const u8, Status }{
        .{ " transitive failure", .transitive_failure },
        .{ " transitive skip", .transitive_skip },
        .{ " skipped", .skipped },
        .{ " failure", .failure },
        // Printed for steps that failed only by writing to stderr.
        .{ " w", .failure },
    };
    for (plain) |p| {
        if (cutStatus(text, p[0])) |name| {
            line.name = name;
            line.status = p[1];
            return line;
        }
    }
    if (mem.cutSuffix(u8, text, " errors")) |before| {
        const i = mem.findScalarLast(u8, before, ' ') orelse return line;
        if (isNumber(before[i + 1 ..]) and i > 0) {
            line.name = before[0..i];
            line.status = .failure;
        }
    }
    return line;
}

/// Like `cutSuffix`, but never leaves an empty name.
fn cutStatus(text: []const u8, suffix: []const u8) ?[]const u8 {
    const name = mem.cutSuffix(u8, text, suffix) orelse return null;
    return if (name.len == 0) null else name;
}

fn trimMetrics(text: []const u8) []const u8 {
    var s = text;
    if (mem.findScalarLast(u8, s, ' ')) |i| {
        if (mem.startsWith(u8, s[i + 1 ..], "MaxRSS:")) s = s[0..i];
    }
    if (mem.findScalarLast(u8, s, ' ')) |i| {
        if (isDuration(s[i + 1 ..])) s = s[0..i];
    }
    return s;
}

fn isDuration(token: []const u8) bool {
    const digits = mem.findNone(u8, token, "0123456789") orelse return false;
    if (digits == 0) return false;
    const unit = token[digits..];
    for ([_][]const u8{ "ns", "us", "ms", "s", "m" }) |u| {
        if (mem.eql(u8, unit, u)) return true;
    }
    return false;
}

fn isNumber(token: []const u8) bool {
    return token.len > 0 and mem.findNone(u8, token, "0123456789") == null;
}

/// Matches `N pass[, N skip][, N fail][, N crash][, N timeout] (N total)[; ...]`.
fn cutTestResults(text: []const u8) ?struct { name: []const u8, failed: bool } {
    const total = mem.findLast(u8, text, " total)") orelse return null;
    const pass = mem.findLast(u8, text[0..total], " pass") orelse return null;
    const number = mem.findScalarLast(u8, text[0..pass], ' ') orelse return null;
    if (number == 0 or !isNumber(text[number + 1 .. pass])) return null;
    const results = text[number..];
    const failed = mem.find(u8, results, " fail") != null or
        mem.find(u8, results, " crash") != null or
        mem.find(u8, results, " timeout") != null or
        // Leaks and error logs are appended after the total.
        !mem.endsWith(u8, results, " total)");
    return .{ .name = text[0..number], .failed = failed };
}

fn expectStep(line: Line, name: []const u8, status: ?Status, reused: bool) !void {
    try std.testing.expectEqualStrings(name, line.name);
    try std.testing.expectEqual(status, line.status);
    try std.testing.expectEqual(reused, line.reused);
}

test parseSummary {
    try std.testing.expectEqual(null, parseSummary("install success"));
    try std.testing.expectEqual(0, parseSummary("Build Summary: 67/67 steps succeeded").?.failed);
    try std.testing.expectEqual(1, parseSummary("Build Summary: 64/67 steps succeeded (1 failed)").?.failed);
    try std.testing.expectEqual(2, parseSummary("Build Summary: 3/7 steps succeeded (2 skipped, 2 failed)").?.failed);
    try std.testing.expectEqual(0, parseSummary("Build Summary: 3/3 steps succeeded; 4/5 tests passed (1 failed)").?.failed);
}

test parseRoot {
    try expectStep(parseRoot("install success"), "install", .success, false);
    try expectStep(parseRoot("install transitive failure"), "install", .transitive_failure, false);
    try expectStep(parseRoot("install"), "install", null, false);
}

test parseChild {
    try std.testing.expectEqual(null, parseChild("install"));
    try std.testing.expectEqual(null, parseChild("src/main.zig:1:1: error: x"));

    const exe = parseChild("|     +- compile exe editor debug native success 34ms").?;
    try std.testing.expectEqual(3, exe.depth);
    try expectStep(exe, "compile exe editor debug native", .success, false);

    try expectStep(parseChild("+- install editor transitive failure").?, "install editor", .transitive_failure, false);
    try expectStep(parseChild("   +- compile exe x debug native 1 errors").?, "compile exe x debug native", .failure, false);
    try expectStep(parseChild("   +- compile exe x debug native").?, "compile exe x debug native", null, false);
    try expectStep(parseChild("   +- compile lib imgui debug native (reused)").?, "compile lib imgui debug native", null, true);
    try expectStep(parseChild("   +- compile lib geometry fast native (+1 more reused dependencies)").?, "compile lib geometry fast native", null, true);
    try expectStep(parseChild("+- run test 4 pass (4 total) 3ms MaxRSS:4M").?, "run test", .success, false);
    try expectStep(parseChild("+- run test 4 pass, 1 skip (5 total)").?, "run test", .success, false);
    try expectStep(parseChild("+- run test 3 pass, 1 fail (4 total)").?, "run test", .failure, false);
    try expectStep(parseChild("+- run test 4 pass (4 total); 2 leaks").?, "run test", .failure, false);
    try expectStep(parseChild("+- compile exe x cached 1ms").?, "compile exe x", .success, false);
    try expectStep(parseChild("+- run x skipped (not enough memory) upper bound of 9 exceeded runner limit (1)").?, "run x", .skipped, false);
    try expectStep(parseChild("+- run x failure").?, "run x", .failure, false);
}
