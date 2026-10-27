//! Follows a `zig build --listen=-` process over the build system protocol and updates `State`.
//!
//! Zig sends a handshake and the path of its configuration file. We load that file to map step
//! names to indices, ask Zig to build and watch the requested steps, and then receive a
//! started/completed message for every step of every build. Steps that did not run again are not
//! reported, just like with `--summary new`.
const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const Configuration = std.Build.Configuration;
const Message = std.zig.Server.Message;
const State = @import("State.zig");
const Step = State.Step;
const Status = State.Status;

const Bsp = @This();

/// Name of the pseudo-step that reports `build.zig` failing to compile.
const configure_step_name = "build.zig";

gpa: mem.Allocator,
io: Io,
state: *State,
/// Requested top-level steps.
step_names: []const []const u8,
reader: *Io.Reader,
client: std.zig.Client,
/// Echo of build results for the person running zicwatch.
log: *Io.Writer,

/// Holds the current configuration and everything derived from it.
arena_state: std.heap.ArenaAllocator,
configuration: ?*const Configuration = null,
by_index: []?*Step = &.{},
/// Status of each step reported in the current build.
build_status: []?Status = &.{},

extra: std.ArrayList(u32) = .empty,
strings: std.ArrayList(u8) = .empty,
rendered: Io.Writer.Allocating,

in_build: bool = false,
ran: u32 = 0,
failed: u32 = 0,
transitive: u32 = 0,
skipped: u32 = 0,

pub fn init(
    gpa: mem.Allocator,
    io: Io,
    state: *State,
    step_names: []const []const u8,
    reader: *Io.Reader,
    writer: *Io.Writer,
    log: *Io.Writer,
) Bsp {
    return .{
        .gpa = gpa,
        .io = io,
        .state = state,
        .step_names = step_names,
        .reader = reader,
        .client = .{ .in = reader, .out = writer },
        .log = log,
        .arena_state = .init(gpa),
        .rendered = .init(gpa),
    };
}

pub fn deinit(b: *Bsp) void {
    b.arena_state.deinit();
    b.extra.deinit(b.gpa);
    b.strings.deinit(b.gpa);
    b.rendered.deinit();
}

/// Processes messages until Zig closes its output.
pub fn run(b: *Bsp) !void {
    while (true) {
        const header = b.reader.takeStruct(Message.Header, .little) catch |err| switch (err) {
            error.EndOfStream => return,
            error.ReadFailed => |e| return e,
        };
        switch (header.tag) {
            .bsp_handshake => {
                const handshake = try b.reader.takeStruct(Message.Handshake, .little);
                if (handshake.version != std.zig.Server.build_system_version) return error.UnsupportedProtocolVersion;
                if (!handshake.flags.file_system_watch_supported) return error.WatchUnsupported;
                try b.reader.discardAll(header.bytes_len - @sizeOf(Message.Handshake));
            },
            .bsp_configuration => {
                const path = try b.reader.take(header.bytes_len);
                try b.configure(path);
            },
            .bsp_configuration_failed => try b.configurationFailed(),
            .bsp_build_started => {
                b.in_build = true;
                b.ran = 0;
                b.failed = 0;
                b.transitive = 0;
                b.skipped = 0;
                @memset(b.build_status, null);
            },
            .bsp_step_completed => try b.stepCompleted(header.bytes_len),
            .bsp_build_completed => try b.buildCompleted(),
            else => try b.reader.discardAll(header.bytes_len),
        }
    }
}

pub fn inBuild(b: *const Bsp) bool {
    return b.in_build;
}

fn configure(b: *Bsp, path: []const u8) !void {
    const io = b.io;
    _ = b.arena_state.reset(.free_all);
    const arena = b.arena_state.allocator();

    const c = try arena.create(Configuration);
    {
        const file = try Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        c.* = try Configuration.loadFile(arena, io, file);
    }
    b.configuration = c;
    b.by_index = try arena.alloc(?*Step, c.steps.len);
    @memset(b.by_index, null);
    b.build_status = try arena.alloc(?Status, c.steps.len);
    @memset(b.build_status, null);

    var requested: std.ArrayList(Configuration.Step.Index) = .empty;
    for (b.step_names) |name| try requested.append(arena, try b.findTopLevelStep(c, name));

    // Register the requested steps and everything they depend on.
    var queue: std.ArrayList(u32) = .empty;
    for (requested.items) |index| try b.register(c, &queue, @backingInt(index));
    var i: usize = 0;
    while (i < queue.items.len) : (i += 1) {
        const index = queue.items[i];
        for (c.steps[index].deps.slice(c)) |dep| {
            try b.register(c, &queue, @backingInt(dep));
            b.state.addDependency(b.by_index[index].?, b.by_index[@backingInt(dep)].?);
        }
    }

    try b.client.serveBuildSteps(requested.items, .{ .watch = true });
}

fn findTopLevelStep(b: *Bsp, c: *const Configuration, name: []const u8) !Configuration.Step.Index {
    for (c.steps, 0..) |*step, i| {
        if (step.owner != .root or step.flags(c).tag != .top_level) continue;
        if (mem.eql(u8, step.name.slice(c), name)) return @fromBackingInt(@intCast(i));
    }
    try b.log.print("error: no top-level step named '{s}'; available:", .{name});
    for (c.steps) |*step| {
        if (step.owner != .root or step.flags(c).tag != .top_level) continue;
        try b.log.print(" {s}", .{step.name.slice(c)});
    }
    try b.log.writeByte('\n');
    try b.log.flush();
    return error.UnknownBuildStep;
}

fn register(b: *Bsp, c: *const Configuration, queue: *std.ArrayList(u32), index: u32) !void {
    if (b.by_index[index] != null) return;
    b.by_index[index] = try b.state.getOrCreate(c.steps[index].name.slice(c));
    try queue.append(b.arena_state.allocator(), index);
}

fn stepCompleted(b: *Bsp, bytes_len: u32) !void {
    const body = try b.reader.takeStruct(Message.BuildStepCompleted, .little);
    const bundle = try b.readErrorBundle(body.error_bundle);
    const consumed = @sizeOf(Message.BuildStepCompleted) + 4 * bundle.extra.len + bundle.string_bytes.len;
    try b.reader.discardAll(bytes_len - consumed);

    const c = b.configuration orelse return;
    const index = @backingInt(body.step_index);
    if (index >= b.by_index.len) return;
    const step = b.by_index[index] orelse return;

    const status: Status = switch (body.status) {
        .success => .success,
        .skipped, .skipped_oom => .skipped,
        // Zig reports steps that failed because a dependency failed as failures too.
        .failure => if (bundle.extra.len == 0 and b.anyDepFailed(c, index)) .transitive_failure else .failure,
    };
    b.build_status[index] = status;
    step.stage(status);
    b.ran += 1;
    switch (status) {
        .failure => b.failed += 1,
        .transitive_failure => b.transitive += 1,
        .skipped => b.skipped += 1,
        else => {},
    }

    if (bundle.extra.len > 0) {
        b.rendered.clearRetainingCapacity();
        try bundle.renderToWriter(.{}, &b.rendered.writer);
        step.appendDiagnostics(b.rendered.written());
        try b.log.print("{s}:\n{s}\n", .{ step.name(), b.rendered.written() });
        try b.log.flush();
    }
}

fn anyDepFailed(b: *Bsp, c: *const Configuration, index: u32) bool {
    for (c.steps[index].deps.slice(c)) |dep| {
        const i = @backingInt(dep);
        // Dependencies that did not run again keep their previous result.
        const status = b.build_status[i] orelse b.by_index[i].?.status;
        if (status.isFailure()) return true;
    }
    return false;
}

fn buildCompleted(b: *Bsp) !void {
    var buf: [256]u8 = undefined;
    const summary = std.fmt.bufPrint(&buf, "{d} steps ran: {d} succeeded, {d} failed, {d} failed transitively, {d} skipped", .{
        b.ran, b.ran - b.failed - b.transitive - b.skipped, b.failed, b.transitive, b.skipped,
    }) catch unreachable;
    b.state.commit(summary, b.failed);
    b.in_build = false;
    try b.log.print("build {d}: {s}\n", .{ b.state.build, summary });
    try b.log.flush();
}

fn configurationFailed(b: *Bsp) !void {
    const header = try b.reader.takeStruct(Message.ErrorBundle, .little);
    const bundle = try b.readErrorBundle(header);
    b.rendered.clearRetainingCapacity();
    try bundle.renderToWriter(.{}, &b.rendered.writer);

    const step = try b.state.getOrCreate(configure_step_name);
    step.stage(.failure);
    step.appendDiagnostics(b.rendered.written());
    b.state.commit("build.zig failed to compile", 1);
    try b.log.print("build.zig failed to compile:\n{s}\n", .{b.rendered.written()});
    try b.log.flush();
}

/// Reads an error bundle into buffers that only grow when a larger bundle arrives.
fn readErrorBundle(b: *Bsp, header: Message.ErrorBundle) !std.zig.ErrorBundle {
    try b.extra.resize(b.gpa, header.extra_len);
    try b.strings.resize(b.gpa, header.string_bytes_len);
    try b.reader.readSliceEndian(u32, b.extra.items, .little);
    try b.reader.readSliceAll(b.strings.items);
    return .{ .string_bytes = b.strings.items, .extra = b.extra.items };
}
