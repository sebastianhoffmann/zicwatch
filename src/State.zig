//! Per-step build results, updated by one input thread (`TextParser` or `Bsp`) and read by
//! client threads.
//!
//! Everything clients read (the step map, `Step.status`, `Step.updated_in_build`, `Step.deps`,
//! the current diagnostics, `build`, `failed`, `summary`, `ended`, `end_reason`) is only changed
//! while holding `mutex`, and clients must hold it while reading. The input thread stages each
//! step's next result without locking, and `commit` makes all staged results current at once.
//! `changed` is broadcast whenever a build is committed or the input ends.
const std = @import("std");
const Io = std.Io;
const mem = std.mem;

const State = @This();

pub const Status = enum {
    unknown,
    success,
    failure,
    transitive_failure,
    skipped,
    transitive_skip,

    pub fn isFailure(s: Status) bool {
        return s == .failure or s == .transitive_failure;
    }
};

pub const half_size = 1 << 20;
pub const max_name_len = 256;
pub const max_deps = 64;
const step_alignment: mem.Alignment = .of(Step);

pub const Step = struct {
    name_buf: [max_name_len]u8,
    name_len: u16,
    /// Result from the most recent build that reported this step.
    status: Status,
    /// Build in which `status` and the current diagnostics were last reported.
    updated_in_build: u64,
    deps: [max_deps]*Step,
    deps_len: u8,
    /// Marks steps already seen by `failureCauses`.
    visit: u32,

    /// Staged by the input thread until the build is committed.
    next_status: ?Status,
    touched: bool,

    /// Two halves of `half_size` bytes. Clients read half `current`, the input thread fills
    /// the other.
    diag: [2 * half_size]u8,
    diag_len: [2]u32,
    diag_truncated: [2]bool,
    current: u1,

    pub fn name(s: *const Step) []const u8 {
        return s.name_buf[0..s.name_len];
    }

    pub fn diagnostics(s: *const Step) []const u8 {
        return s.diag[@as(usize, s.current) * half_size ..][0..s.diag_len[s.current]];
    }

    pub fn diagnosticsTruncated(s: *const Step) bool {
        return s.diag_truncated[s.current];
    }

    pub fn dependencies(s: *const Step) []const *Step {
        return s.deps[0..s.deps_len];
    }

    /// Stages the step's result for the next commit.
    pub fn stage(s: *Step, status: Status) void {
        s.next_status = status;
        s.touched = true;
    }

    /// Appends to the step's diagnostics for the next commit.
    pub fn appendDiagnostics(s: *Step, bytes: []const u8) void {
        const next = s.current ^ 1;
        const len = s.diag_len[next];
        const n = @min(bytes.len, half_size - len);
        @memcpy(s.diag[@as(usize, next) * half_size + len ..][0..n], bytes[0..n]);
        s.diag_len[next] = len + @as(u32, @intCast(n));
        if (n < bytes.len) s.diag_truncated[next] = true;
        s.touched = true;
    }

    /// Makes the staged result current.
    fn flip(s: *Step, build: u64) void {
        if (s.next_status) |status| s.status = status;
        s.current ^= 1;
        const next = s.current ^ 1;
        s.diag_len[next] = 0;
        s.diag_truncated[next] = false;
        s.updated_in_build = build;
        s.next_status = null;
        s.touched = false;
    }
};

gpa: mem.Allocator,
io: Io,
mutex: Io.Mutex = .init,
changed: Io.Condition = .init,
steps: std.StringHashMapUnmanaged(*Step) = .empty,
/// Number of committed builds.
build: u64 = 0,
/// Steps that failed in the latest build, not counting transitive failures.
failed: u32 = 0,
summary_buf: [256]u8 = undefined,
summary_len: u16 = 0,
/// The input ended. `ended_mid_build` is set if output of an unfinished build was discarded.
ended: bool = false,
ended_mid_build: bool = false,
end_reason_buf: [256]u8 = undefined,
end_reason_len: u16 = 0,
visit_gen: u32 = 0,

pub fn init(gpa: mem.Allocator, io: Io) State {
    return .{ .gpa = gpa, .io = io };
}

pub fn deinit(state: *State) void {
    var it = state.steps.valueIterator();
    while (it.next()) |step| {
        const bytes: [*]u8 = @ptrCast(step.*);
        std.heap.page_allocator.rawFree(bytes[0..@sizeOf(Step)], step_alignment, @returnAddress());
    }
    state.steps.deinit(state.gpa);
}

pub fn summary(state: *const State) []const u8 {
    return state.summary_buf[0..state.summary_len];
}

pub fn endReason(state: *const State) []const u8 {
    return state.end_reason_buf[0..state.end_reason_len];
}

pub fn findStep(state: *const State, name: []const u8) ?*Step {
    return state.steps.get(name[0..@min(name.len, max_name_len)]);
}

/// Collects the steps that actually failed among `step` and the dependencies it failed through.
/// The caller must hold `mutex`.
pub fn failureCauses(state: *State, step: *Step, out: []*Step) []*Step {
    state.visit_gen +%= 1;
    var len: usize = 0;
    state.collectCauses(step, out, &len);
    return out[0..len];
}

fn collectCauses(state: *State, step: *Step, out: []*Step, len: *usize) void {
    if (step.visit == state.visit_gen) return;
    step.visit = state.visit_gen;
    switch (step.status) {
        .failure => if (len.* < out.len) {
            out[len.*] = step;
            len.* += 1;
        },
        .transitive_failure => for (step.dependencies()) |dep| state.collectCauses(dep, out, len),
        else => {},
    }
}

/// Returns the step with this name, creating it on first use. Only the input thread may call this.
pub fn getOrCreate(state: *State, full_name: []const u8) !*Step {
    const name = full_name[0..@min(full_name.len, max_name_len)];
    // Only this thread changes the map, so looking up without the lock is fine.
    if (state.steps.get(name)) |step| return step;

    // Allocate without `create`, which fills the memory in debug builds and would thereby
    // commit all pages of the diagnostics buffer.
    const bytes = std.heap.page_allocator.rawAlloc(@sizeOf(Step), step_alignment, @returnAddress()) orelse
        return error.OutOfMemory;
    const step: *Step = @ptrCast(@alignCast(bytes));
    @memcpy(step.name_buf[0..name.len], name);
    step.name_len = @intCast(name.len);
    step.status = .unknown;
    step.updated_in_build = 0;
    step.deps_len = 0;
    step.visit = 0;
    step.next_status = null;
    step.touched = false;
    step.diag_len = .{ 0, 0 };
    step.diag_truncated = .{ false, false };
    step.current = 0;

    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    state.steps.putNoClobber(state.gpa, step.name(), step) catch |err| {
        std.heap.page_allocator.rawFree(bytes[0..@sizeOf(Step)], step_alignment, @returnAddress());
        return err;
    };
    return step;
}

pub fn addDependency(state: *State, step: *Step, dep: *Step) void {
    if (mem.findScalar(*Step, step.dependencies(), dep) != null) return;
    if (step.deps_len == max_deps) return;
    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    step.deps[step.deps_len] = dep;
    step.deps_len += 1;
}

/// Makes all staged results current as one new build.
pub fn commit(state: *State, build_summary: []const u8, failed: u32) void {
    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    defer state.changed.broadcast(state.io);

    state.build += 1;
    state.failed = failed;
    var it = state.steps.valueIterator();
    while (it.next()) |entry| {
        const step = entry.*;
        if (step.touched) {
            step.flip(state.build);
        } else if (failed == 0 and step.status.isFailure()) {
            // Builds may leave out steps that did not run again, but if nothing failed in
            // this build, nothing is failing anymore.
            step.next_status = .success;
            step.flip(state.build);
        }
    }
    const n = @min(build_summary.len, state.summary_buf.len);
    @memcpy(state.summary_buf[0..n], build_summary[0..n]);
    state.summary_len = @intCast(n);
}

/// Marks the input as ended. `mid_build` reports that output of an unfinished build was dropped.
pub fn endOfStream(state: *State, mid_build: bool, reason: []const u8) void {
    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    state.ended = true;
    state.ended_mid_build = mid_build;
    const n = @min(reason.len, state.end_reason_buf.len);
    @memcpy(state.end_reason_buf[0..n], reason[0..n]);
    state.end_reason_len = @intCast(n);
    state.changed.broadcast(state.io);
}
