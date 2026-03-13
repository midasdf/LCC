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
    /// Long-lived allocator (for things that survive across turns)
    parent_alloc: std.mem.Allocator,
    /// Per-turn arena allocator (reset after each result)
    arena: std.heap.ArenaAllocator,
    session_id: []const u8,
    line_buf: std.ArrayList(u8),
    env_map: std.process.EnvMap,
    alive: bool,

    /// Get the per-turn allocator (freed on resetTurnArena)
    fn turnAlloc(self: *Process) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn start(parent_alloc: std.mem.Allocator, config: Config) !Process {
        var argv_list: std.ArrayList([]const u8) = .empty;

        try argv_list.append(parent_alloc, "claude");
        try argv_list.append(parent_alloc, "-p");
        try argv_list.append(parent_alloc, "--output-format");
        try argv_list.append(parent_alloc, "stream-json");
        try argv_list.append(parent_alloc, "--input-format");
        try argv_list.append(parent_alloc, "stream-json");
        try argv_list.append(parent_alloc, "--verbose");
        try argv_list.append(parent_alloc, "--include-partial-messages");

        if (config.model) |m| {
            try argv_list.append(parent_alloc, "--model");
            try argv_list.append(parent_alloc, m);
        }
        if (config.max_turns) |mt| {
            const s = try std.fmt.allocPrint(parent_alloc, "{d}", .{mt});
            try argv_list.append(parent_alloc, "--max-turns");
            try argv_list.append(parent_alloc, s);
        }
        if (config.resume_session_id) |sid| {
            try argv_list.append(parent_alloc, "--resume");
            try argv_list.append(parent_alloc, sid);
        }
        if (config.system_prompt) |sp| {
            try argv_list.append(parent_alloc, "--append-system-prompt");
            try argv_list.append(parent_alloc, sp);
        }
        if (config.allowed_tools) |at| {
            try argv_list.append(parent_alloc, "--allowedTools");
            try argv_list.append(parent_alloc, at);
        }
        if (config.permission_mode) |pm| {
            try argv_list.append(parent_alloc, "--permission-mode");
            try argv_list.append(parent_alloc, pm);
        }

        // Initial prompt required by -p; use empty string since we send via stdin
        try argv_list.append(parent_alloc, "");

        const argv = try argv_list.toOwnedSlice(parent_alloc);

        // Build env without CLAUDECODE to allow nested invocation
        var env_map = std.process.EnvMap.init(parent_alloc);
        const env_vars = std.process.getEnvMap(parent_alloc) catch return error.EnvError;
        var env_it = env_vars.iterator();
        while (env_it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, "CLAUDECODE")) continue;
            if (std.mem.eql(u8, entry.key_ptr.*, "CLAUDE_CODE_ENTRY_POINT")) continue;
            try env_map.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        var self = Process{
            .child = undefined,
            .parent_alloc = parent_alloc,
            .arena = std.heap.ArenaAllocator.init(parent_alloc),
            .session_id = "",
            .line_buf = .empty,
            .env_map = env_map,
            .alive = false,
        };

        self.child = std.process.Child.init(argv, parent_alloc);
        self.child.env_map = &self.env_map;
        self.child.stdin_behavior = .Pipe;
        self.child.stdout_behavior = .Pipe;
        self.child.stderr_behavior = .Pipe;

        try self.child.spawn();
        self.alive = true;

        return self;
    }

    /// Send a user message via stdin (NDJSON). Uses stack buffer + direct write.
    pub fn sendMessage(self: *Process, content: []const u8) !void {
        if (!self.alive) return error.ProcessDead;

        const stdin = self.child.stdin orelse return error.ProcessDead;

        // Write prefix
        _ = stdin.write("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"") catch |err| {
            self.alive = false;
            return err;
        };

        // Write content with JSON escaping (no heap allocation)
        for (content) |c| {
            const escaped: ?[]const u8 = switch (c) {
                '"' => "\\\"",
                '\\' => "\\\\",
                '\n' => "\\n",
                '\r' => "\\r",
                '\t' => "\\t",
                else => null,
            };
            if (escaped) |esc| {
                _ = stdin.write(esc) catch |err| {
                    self.alive = false;
                    return err;
                };
            } else {
                _ = stdin.write(&.{c}) catch |err| {
                    self.alive = false;
                    return err;
                };
            }
        }

        // Write suffix + newline
        _ = stdin.write("\"}}\n") catch |err| {
            self.alive = false;
            return err;
        };
    }

    /// Read the next event from stdout. Returns null on EOF (process died).
    /// Returned event data is valid until the next call to resetTurnArena().
    pub fn readEvent(self: *Process) !?Event {
        if (!self.alive) return null;

        const stdout = self.child.stdout orelse return null;
        const alloc = self.turnAlloc();

        while (true) {
            // Check if we already have a complete line in the buffer
            if (std.mem.indexOf(u8, self.line_buf.items, "\n")) |nl_pos| {
                const line = self.line_buf.items[0..nl_pos];

                if (line.len > 0) {
                    // Parse before modifying line_buf (line points into it)
                    const event = parseLine(alloc, line);

                    // Remove processed line from buffer
                    const remaining = self.line_buf.items.len - nl_pos - 1;
                    if (remaining > 0) {
                        std.mem.copyForwards(u8, self.line_buf.items[0..remaining], self.line_buf.items[nl_pos + 1 ..]);
                    }
                    self.line_buf.items.len = remaining;

                    return event;
                }

                // Empty line, skip it
                const remaining = self.line_buf.items.len - nl_pos - 1;
                if (remaining > 0) {
                    std.mem.copyForwards(u8, self.line_buf.items[0..remaining], self.line_buf.items[nl_pos + 1 ..]);
                }
                self.line_buf.items.len = remaining;
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

            try self.line_buf.appendSlice(self.parent_alloc, buf[0..n]);
        }
    }

    /// Reset the per-turn arena, freeing all JSON parse/stringify memory.
    /// Call after processing a complete turn (result event received).
    pub fn resetTurnArena(self: *Process) void {
        _ = self.arena.reset(.retain_capacity);
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
        self.line_buf.deinit(self.parent_alloc);
        self.arena.deinit();
    }
};

fn parseLine(alloc: std.mem.Allocator, line: []const u8) Event {
    // Fast path: content_block_delta is the most frequent event during streaming.
    // Extract text directly with string search instead of full JSON parse.
    if (std.mem.indexOf(u8, line, "\"text_delta\"")) |_| {
        if (std.mem.indexOf(u8, line, "\"text\":\"")) |text_start| {
            const start = text_start + 8; // length of "text":"
            if (start < line.len) {
                // Find closing quote (handle escaped quotes)
                var i = start;
                while (i < line.len) : (i += 1) {
                    if (line[i] == '\\') {
                        i += 1; // skip escaped char
                        continue;
                    }
                    if (line[i] == '"') break;
                }
                if (i <= line.len) {
                    const raw = line[start..i];
                    // If no escapes, return directly (common case)
                    if (std.mem.indexOf(u8, raw, "\\") == null) {
                        return .{ .content_delta = raw };
                    }
                    // Has escapes: fall through to full JSON parse
                }
            }
        }
    }

    const parsed = jh.parse(alloc, line) catch return .unknown;
    const event_type = jh.getString(parsed.value, "type") orelse return .unknown;

    if (std.mem.eql(u8, event_type, "system")) {
        return .{ .init = .{
            .session_id = jh.getString(parsed.value, "session_id") orelse "",
            .model = jh.getString(parsed.value, "model") orelse "",
        } };
    } else if (std.mem.eql(u8, event_type, "stream_event")) {
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
