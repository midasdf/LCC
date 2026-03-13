const std = @import("std");
const jh = @import("json_helper.zig");
const terminal = @import("terminal.zig");

/// Configuration for the claude CLI process
pub const Config = struct {
    model: ?[]const u8 = null,
    max_turns: ?u32 = null,
    resume_session_id: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
    allowed_tools: ?[]const u8 = null,
    permission_mode: ?[]const u8 = null,
};

/// Events parsed from claude CLI stream-json output
pub const Event = union(enum) {
    init: InitData,
    content_delta: []const u8,
    tool_start: ToolStartData,
    result: ResultData,
    unknown: void,
};

pub const InitData = struct {
    session_id: []const u8,
    model: []const u8,
};

pub const ToolStartData = struct {
    name: []const u8,
};

pub const ResultData = struct {
    result_text: []const u8,
    session_id: []const u8,
    is_error: bool,
    duration_ms: i64,
    cost_usd: f64,
};

/// Persistent claude CLI subprocess
pub const Process = struct {
    child: std.process.Child,
    alloc: std.mem.Allocator,
    session_id: []const u8,
    line_buf: std.ArrayList(u8),
    env_map: std.process.EnvMap,
    alive: bool,

    pub fn start(alloc: std.mem.Allocator, config: Config) !Process {
        var argv_list: std.ArrayList([]const u8) = .empty;

        try argv_list.append(alloc, "claude");
        try argv_list.append(alloc, "-p");
        try argv_list.append(alloc, "--output-format");
        try argv_list.append(alloc, "stream-json");
        try argv_list.append(alloc, "--input-format");
        try argv_list.append(alloc, "stream-json");
        try argv_list.append(alloc, "--verbose");
        try argv_list.append(alloc, "--include-partial-messages");

        if (config.model) |m| {
            try argv_list.append(alloc, "--model");
            try argv_list.append(alloc, m);
        }
        if (config.max_turns) |mt| {
            const s = try std.fmt.allocPrint(alloc, "{d}", .{mt});
            try argv_list.append(alloc, "--max-turns");
            try argv_list.append(alloc, s);
        }
        if (config.resume_session_id) |sid| {
            try argv_list.append(alloc, "--resume");
            try argv_list.append(alloc, sid);
        }
        if (config.system_prompt) |sp| {
            try argv_list.append(alloc, "--append-system-prompt");
            try argv_list.append(alloc, sp);
        }
        if (config.allowed_tools) |at| {
            try argv_list.append(alloc, "--allowedTools");
            try argv_list.append(alloc, at);
        }
        if (config.permission_mode) |pm| {
            try argv_list.append(alloc, "--permission-mode");
            try argv_list.append(alloc, pm);
        }

        // Initial prompt required by -p; use empty string since we send via stdin
        try argv_list.append(alloc, "");

        const argv = try argv_list.toOwnedSlice(alloc);

        // Build env without CLAUDECODE to allow nested invocation
        var env_map = std.process.EnvMap.init(alloc);
        const env_vars = std.process.getEnvMap(alloc) catch return error.EnvError;
        var env_it = env_vars.iterator();
        while (env_it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, "CLAUDECODE")) continue;
            if (std.mem.eql(u8, entry.key_ptr.*, "CLAUDE_CODE_ENTRY_POINT")) continue;
            try env_map.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        var self = Process{
            .child = undefined,
            .alloc = alloc,
            .session_id = "",
            .line_buf = .empty,
            .env_map = env_map,
            .alive = false,
        };

        self.child = std.process.Child.init(argv, alloc);
        self.child.env_map = &self.env_map;
        self.child.stdin_behavior = .Pipe;
        self.child.stdout_behavior = .Pipe;
        self.child.stderr_behavior = .Pipe;

        try self.child.spawn();
        self.alive = true;

        return self;
    }

    /// Send a user message via stdin (NDJSON)
    pub fn sendMessage(self: *Process, content: []const u8) !void {
        if (!self.alive) return error.ProcessDead;

        const stdin = self.child.stdin orelse return error.ProcessDead;

        // Build: {"type":"user","message":{"role":"user","content":"..."}}
        var msg_obj = jh.object(self.alloc);
        try msg_obj.put("role", jh.string("user"));
        try msg_obj.put("content", jh.string(content));

        var outer = jh.object(self.alloc);
        try outer.put("type", jh.string("user"));
        try outer.put("message", .{ .object = msg_obj });

        const json_str = try jh.stringify(self.alloc, .{ .object = outer });

        _ = stdin.write(json_str) catch |err| {
            self.alive = false;
            return err;
        };
        _ = stdin.write("\n") catch |err| {
            self.alive = false;
            return err;
        };
    }

    /// Read the next event from stdout. Returns null on EOF (process died).
    pub fn readEvent(self: *Process) !?Event {
        if (!self.alive) return null;

        const stdout = self.child.stdout orelse return null;

        while (true) {
            // Check if we already have a complete line in the buffer
            if (std.mem.indexOf(u8, self.line_buf.items, "\n")) |nl_pos| {
                const line = try self.alloc.dupe(u8, self.line_buf.items[0..nl_pos]);
                // Remove processed line from buffer
                const remaining = self.line_buf.items.len - nl_pos - 1;
                if (remaining > 0) {
                    std.mem.copyForwards(u8, self.line_buf.items[0..remaining], self.line_buf.items[nl_pos + 1 ..]);
                }
                self.line_buf.items.len = remaining;

                if (line.len > 0) {
                    return parseLine(self.alloc, line);
                }
                continue;
            }

            // Read more data
            var buf: [4096]u8 = undefined;
            const n = stdout.read(&buf) catch |err| {
                // EINTR from signal - check if we should stop
                if (err == error.Unexpected) return null;
                self.alive = false;
                return null;
            };
            if (n == 0) {
                self.alive = false;
                return null;
            }

            try self.line_buf.appendSlice(self.alloc, buf[0..n]);
        }
    }

    /// Kill the subprocess
    pub fn kill(self: *Process) void {
        if (!self.alive) return;
        self.alive = false;

        // Send SIGTERM
        const pid = self.child.id;
        std.posix.kill(pid, std.posix.SIG.TERM) catch {};

        // Wait for cleanup
        _ = self.child.wait() catch {};
    }

    /// Get the child PID (for signal handler to kill)
    pub fn getPid(self: *const Process) std.posix.pid_t {
        if (!self.alive) return 0;
        return self.child.id;
    }

    pub fn deinit(self: *Process) void {
        self.kill();
        self.line_buf.deinit(self.alloc);
    }
};

fn parseLine(alloc: std.mem.Allocator, line: []const u8) Event {
    const parsed = jh.parse(alloc, line) catch return .unknown;
    const event_type = jh.getString(parsed.value, "type") orelse return .unknown;

    if (std.mem.eql(u8, event_type, "system")) {
        return .{ .init = .{
            .session_id = jh.getString(parsed.value, "session_id") orelse "",
            .model = jh.getString(parsed.value, "model") orelse "",
        } };
    } else if (std.mem.eql(u8, event_type, "stream_event")) {
        // Real-time streaming events
        const inner = jh.getObject(parsed.value, "event") orelse return .unknown;
        const inner_type = jh.getString(inner, "type") orelse return .unknown;

        if (std.mem.eql(u8, inner_type, "content_block_delta")) {
            const delta = jh.getObject(inner, "delta") orelse return .unknown;
            const delta_type = jh.getString(delta, "type") orelse return .unknown;
            if (std.mem.eql(u8, delta_type, "text_delta")) {
                if (jh.getString(delta, "text")) |text| {
                    return .{ .content_delta = text };
                }
            }
        } else if (std.mem.eql(u8, inner_type, "content_block_start")) {
            const content_block = jh.getObject(inner, "content_block") orelse return .unknown;
            const block_type = jh.getString(content_block, "type") orelse return .unknown;
            if (std.mem.eql(u8, block_type, "tool_use")) {
                return .{ .tool_start = .{
                    .name = jh.getString(content_block, "name") orelse "unknown",
                } };
            }
        }
        return .unknown;
    } else if (std.mem.eql(u8, event_type, "result")) {
        return .{ .result = .{
            .result_text = jh.getString(parsed.value, "result") orelse "",
            .session_id = jh.getString(parsed.value, "session_id") orelse "",
            .is_error = getBool(parsed.value, "is_error"),
            .duration_ms = jh.getInt(parsed.value, "duration_ms") orelse 0,
            .cost_usd = getFloat(parsed.value, "total_cost_usd"),
        } };
    }

    return .unknown;
}

fn getBool(value: jh.Value, key: []const u8) bool {
    if (value != .object) return false;
    const v = value.object.get(key) orelse return false;
    return switch (v) {
        .bool => |b| b,
        else => false,
    };
}

fn getFloat(value: jh.Value, key: []const u8) f64 {
    if (value != .object) return 0;
    const v = value.object.get(key) orelse return 0;
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => 0,
    };
}

pub const Error = error{
    ProcessDead,
    EnvError,
};
