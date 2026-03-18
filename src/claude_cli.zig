const std = @import("std");
const jh = @import("json_helper.zig");
const terminal = @import("terminal.zig");

/// Configuration for the claude CLI process.
/// Maps 1:1 to claude CLI flags where applicable.
pub const Config = struct {
    // --- Model & behavior ---
    model: ?[]const u8 = null,
    fallback_model: ?[]const u8 = null,
    effort: ?[]const u8 = null,
    max_turns: ?u32 = null,
    max_budget_usd: ?[]const u8 = null,
    permission_mode: ?[]const u8 = null,
    json_schema: ?[]const u8 = null,

    // --- Session management ---
    continue_session: bool = false,
    resume_session_id: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    fork_session: bool = false,
    session_name: ?[]const u8 = null,
    no_session_persistence: bool = false,

    // --- System prompt ---
    system_prompt: ?[]const u8 = null,
    append_system_prompt: ?[]const u8 = null,

    // --- Tools ---
    tools: ?[]const u8 = null,
    allowed_tools: ?[]const u8 = null,
    disallowed_tools: ?[]const u8 = null,

    // --- Directories & files ---
    add_dirs: ?[]const []const u8 = null, // multiple --add-dir support
    cwd: ?[]const u8 = null,
    file: ?[]const u8 = null,

    // --- Agents ---
    agent: ?[]const u8 = null,
    agents: ?[]const u8 = null,

    // --- MCP ---
    mcp_config: ?[]const u8 = null,
    strict_mcp_config: bool = false,

    // --- Plugins & settings ---
    plugin_dir: ?[]const u8 = null,
    settings: ?[]const u8 = null,
    setting_sources: ?[]const u8 = null,

    // --- Permissions ---
    dangerously_skip_permissions: bool = false,
    allow_dangerously_skip_permissions: bool = false,

    // --- Beta & debug ---
    betas: ?[]const u8 = null,
    verbose: bool = true, // LCC defaults to verbose for stream-json
    debug: bool = false,

    // --- Worktree ---
    worktree: ?[]const u8 = null, // null = disabled, "" = auto-name, "name" = named

    // --- LCC-specific ---
    quiet: bool = false,
    recycle_turns: ?u32 = null,
    recycle_rss_mb: ?u32 = null,
    compact: bool = false,

    // --- Passthrough: unknown flags forwarded directly to claude CLI ---
    extra_args: ?[]const []const u8 = null,
};

/// Events parsed from claude CLI stream-json output
pub const Event = union(enum) {
    init: InitData,
    content_delta: []const u8,
    tool_start: ToolStartData,
    tool_input_delta: []const u8,
    tool_result: ToolResultData,
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

pub const ToolResultData = struct {
    name: []const u8,
    output: []const u8,
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

    /// Helper to append a flag + value pair
    fn appendFlag(argv_list: *std.ArrayList([]const u8), alloc: std.mem.Allocator, flag: []const u8, value: []const u8) !void {
        try argv_list.append(alloc, flag);
        try argv_list.append(alloc, value);
    }

    pub fn start(parent_alloc: std.mem.Allocator, config: Config) !Process {
        var argv_list: std.ArrayList([]const u8) = .empty;

        // Base flags: always present
        try argv_list.append(parent_alloc, "claude");
        try argv_list.append(parent_alloc, "-p");
        try appendFlag(&argv_list, parent_alloc, "--output-format", "stream-json");
        try appendFlag(&argv_list, parent_alloc, "--input-format", "stream-json");
        try argv_list.append(parent_alloc, "--include-partial-messages");

        if (config.verbose) {
            try argv_list.append(parent_alloc, "--verbose");
        }

        // --- Model & behavior ---
        if (config.model) |v| try appendFlag(&argv_list, parent_alloc, "--model", v);
        if (config.fallback_model) |v| try appendFlag(&argv_list, parent_alloc, "--fallback-model", v);
        if (config.effort) |v| try appendFlag(&argv_list, parent_alloc, "--effort", v);
        if (config.max_turns) |mt| {
            const s = try std.fmt.allocPrint(parent_alloc, "{d}", .{mt});
            try appendFlag(&argv_list, parent_alloc, "--max-turns", s);
        }
        if (config.max_budget_usd) |v| try appendFlag(&argv_list, parent_alloc, "--max-budget-usd", v);
        if (config.permission_mode) |v| try appendFlag(&argv_list, parent_alloc, "--permission-mode", v);
        if (config.json_schema) |v| try appendFlag(&argv_list, parent_alloc, "--json-schema", v);

        // --- Session management ---
        if (config.continue_session) {
            try argv_list.append(parent_alloc, "--continue");
        }
        if (config.resume_session_id) |v| try appendFlag(&argv_list, parent_alloc, "--resume", v);
        if (config.session_id) |v| try appendFlag(&argv_list, parent_alloc, "--session-id", v);
        if (config.fork_session) {
            try argv_list.append(parent_alloc, "--fork-session");
        }
        if (config.session_name) |v| try appendFlag(&argv_list, parent_alloc, "--name", v);
        if (config.no_session_persistence) {
            try argv_list.append(parent_alloc, "--no-session-persistence");
        }

        // --- System prompt ---
        // --system-prompt replaces default; --append-system-prompt appends
        if (config.system_prompt) |v| try appendFlag(&argv_list, parent_alloc, "--system-prompt", v);
        if (config.append_system_prompt) |v| try appendFlag(&argv_list, parent_alloc, "--append-system-prompt", v);

        // --- Tools ---
        if (config.tools) |v| try appendFlag(&argv_list, parent_alloc, "--tools", v);
        if (config.allowed_tools) |v| try appendFlag(&argv_list, parent_alloc, "--allowedTools", v);
        if (config.disallowed_tools) |v| try appendFlag(&argv_list, parent_alloc, "--disallowed-tools", v);

        // --- Directories & files ---
        if (config.add_dirs) |dirs| {
            for (dirs) |d| {
                try appendFlag(&argv_list, parent_alloc, "--add-dir", d);
            }
        }
        if (config.cwd) |v| try appendFlag(&argv_list, parent_alloc, "--cwd", v);
        if (config.file) |v| try appendFlag(&argv_list, parent_alloc, "--file", v);

        // --- Agents ---
        if (config.agent) |v| try appendFlag(&argv_list, parent_alloc, "--agent", v);
        if (config.agents) |v| try appendFlag(&argv_list, parent_alloc, "--agents", v);

        // --- MCP ---
        if (config.mcp_config) |v| try appendFlag(&argv_list, parent_alloc, "--mcp-config", v);
        if (config.strict_mcp_config) {
            try argv_list.append(parent_alloc, "--strict-mcp-config");
        }

        // --- Plugins & settings ---
        if (config.plugin_dir) |v| try appendFlag(&argv_list, parent_alloc, "--plugin-dir", v);
        if (config.settings) |v| try appendFlag(&argv_list, parent_alloc, "--settings", v);
        if (config.setting_sources) |v| try appendFlag(&argv_list, parent_alloc, "--setting-sources", v);

        // --- Permissions ---
        if (config.dangerously_skip_permissions) {
            try argv_list.append(parent_alloc, "--dangerously-skip-permissions");
        }
        if (config.allow_dangerously_skip_permissions) {
            try argv_list.append(parent_alloc, "--allow-dangerously-skip-permissions");
        }

        // --- Beta ---
        if (config.betas) |v| try appendFlag(&argv_list, parent_alloc, "--betas", v);

        // --- Worktree ---
        if (config.worktree) |v| {
            if (v.len > 0) {
                try appendFlag(&argv_list, parent_alloc, "--worktree", v);
            } else {
                try argv_list.append(parent_alloc, "--worktree");
            }
        }

        // --- Passthrough extra args ---
        if (config.extra_args) |extras| {
            for (extras) |arg| {
                try argv_list.append(parent_alloc, arg);
            }
        }

        // Initial prompt required by -p; use empty string since we send via stdin
        try argv_list.append(parent_alloc, "");

        const argv = try argv_list.toOwnedSlice(parent_alloc);

        // Build env without CLAUDECODE to allow nested invocation
        var env_map = std.process.EnvMap.init(parent_alloc);
        var env_vars = std.process.getEnvMap(parent_alloc) catch return error.EnvError;
        defer env_vars.deinit();
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
        self.child.stderr_behavior = if (config.debug) .Inherit else .Ignore;

        try self.child.spawn();
        self.alive = true;

        return self;
    }

    /// Send a user message via stdin (NDJSON). Buffered write to minimize syscalls.
    pub fn sendMessage(self: *Process, content: []const u8) !void {
        if (!self.alive) return error.ProcessDead;

        const stdin = self.child.stdin orelse return error.ProcessDead;

        // Use a stack buffer to batch the write
        var buf: [4096]u8 = undefined;
        var pos: usize = 0;
        const prefix = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"";
        const suffix = "\"}}\n";

        @memcpy(buf[0..prefix.len], prefix);
        pos = prefix.len;

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
                if (pos + esc.len > buf.len - suffix.len) {
                    // Flush buffer
                    _ = stdin.write(buf[0..pos]) catch |err| {
                        self.alive = false;
                        return err;
                    };
                    pos = 0;
                }
                @memcpy(buf[pos..][0..esc.len], esc);
                pos += esc.len;
            } else {
                if (pos + 1 > buf.len - suffix.len) {
                    _ = stdin.write(buf[0..pos]) catch |err| {
                        self.alive = false;
                        return err;
                    };
                    pos = 0;
                }
                buf[pos] = c;
                pos += 1;
            }
        }

        @memcpy(buf[pos..][0..suffix.len], suffix);
        pos += suffix.len;

        _ = stdin.write(buf[0..pos]) catch |err| {
            self.alive = false;
            return err;
        };
    }

    /// Read the next event with a timeout in milliseconds.
    /// Returns .timeout if no data within the timeout period.
    /// Returns null on EOF. Negative timeout means block forever.
    pub const ReadResult = union(enum) {
        event: Event,
        timeout: void,
        eof: void,
    };

    pub fn readEventTimeout(self: *Process, timeout_ms: i32) ReadResult {
        if (!self.alive) return .eof;

        const stdout = self.child.stdout orelse return .eof;
        const alloc = self.turnAlloc();

        // Check if we already have a complete line in the buffer
        if (self.tryParseLine(alloc)) |event| {
            return .{ .event = event };
        }

        // Need more data - use poll if timeout requested
        const fd = stdout.handle;
        var poll_fds = [1]std.posix.pollfd{
            .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 },
        };

        const poll_result = std.posix.poll(&poll_fds, timeout_ms) catch 0;
        if (poll_result == 0) {
            return .timeout;
        }

        // Data available, read it
        var read_buf: [4096]u8 = undefined;
        const n = stdout.read(&read_buf) catch |err| {
            if (err == error.Unexpected) return .eof;
            self.alive = false;
            return .eof;
        };
        if (n == 0) {
            self.alive = false;
            return .eof;
        }

        self.line_buf.appendSlice(self.parent_alloc, read_buf[0..n]) catch return .eof;

        // Try to parse a line from the updated buffer
        if (self.tryParseLine(alloc)) |event| {
            return .{ .event = event };
        }

        // Got data but no complete line yet
        return .timeout;
    }

    /// Try to extract and parse one complete line from line_buf
    fn tryParseLine(self: *Process, alloc: std.mem.Allocator) ?Event {
        while (true) {
            const nl_pos = std.mem.indexOf(u8, self.line_buf.items, "\n") orelse return null;
            const line = self.line_buf.items[0..nl_pos];

            if (line.len > 0) {
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
        }
    }

    /// Reset the per-turn arena, freeing all JSON parse/stringify memory.
    pub fn resetTurnArena(self: *Process) void {
        _ = self.arena.reset(.retain_capacity);
    }

    /// Kill the subprocess
    pub fn kill(self: *Process) void {
        if (!self.alive) return;
        self.alive = false;

        const pid = self.child.id;
        std.posix.kill(pid, std.posix.SIG.TERM) catch {};
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
    if (std.mem.indexOf(u8, line, "\"text_delta\"")) |_| {
        if (std.mem.indexOf(u8, line, "\"text\":\"")) |text_start| {
            const start = text_start + 8;
            if (start < line.len) {
                var i = start;
                while (i < line.len) : (i += 1) {
                    if (line[i] == '\\') {
                        if (i + 1 < line.len) i += 1;
                        continue;
                    }
                    if (line[i] == '"') break;
                }
                if (i <= line.len) {
                    const raw = line[start..i];
                    if (std.mem.indexOf(u8, raw, "\\") == null) {
                        return .{ .content_delta = raw };
                    }
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
            } else if (std.mem.eql(u8, delta_type, "input_json_delta")) {
                if (jh.getString(delta, "partial_json")) |pj| {
                    return .{ .tool_input_delta = pj };
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
        } else if (std.mem.eql(u8, inner_type, "content_block_stop")) {
            return .unknown;
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
