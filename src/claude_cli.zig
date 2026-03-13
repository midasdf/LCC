const std = @import("std");
const jh = @import("json_helper.zig");
const terminal = @import("terminal.zig");

/// Configuration for launching the claude CLI
pub const Config = struct {
    model: ?[]const u8 = null,
    max_turns: ?u32 = null,
    session_id: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
    allowed_tools: ?[]const u8 = null,
    permission_mode: ?[]const u8 = null,
    verbose: bool = true,
};

/// A streaming event from claude CLI (stream-json format)
pub const Event = union(enum) {
    init: InitData,
    assistant_text: []const u8,
    tool_use: ToolUseData,
    result: ResultData,
    unknown: void,
};

pub const InitData = struct {
    session_id: []const u8,
    model: []const u8,
};

pub const ToolUseData = struct {
    name: []const u8,
    input_preview: []const u8,
};

pub const ResultData = struct {
    result_text: []const u8,
    session_id: []const u8,
    is_error: bool,
    duration_ms: i64,
    cost_usd: f64,
};

/// Spawn claude -p and stream output line by line
pub fn run(alloc: std.mem.Allocator, prompt: []const u8, config: Config) !ResultData {
    var argv_list: std.ArrayList([]const u8) = .empty;

    try argv_list.append(alloc, "claude");
    try argv_list.append(alloc, "-p");
    try argv_list.append(alloc, "--output-format");
    try argv_list.append(alloc, "stream-json");
    try argv_list.append(alloc, "--verbose");

    if (config.model) |m| {
        try argv_list.append(alloc, "--model");
        try argv_list.append(alloc, m);
    }
    if (config.max_turns) |mt| {
        const s = try std.fmt.allocPrint(alloc, "{d}", .{mt});
        try argv_list.append(alloc, "--max-turns");
        try argv_list.append(alloc, s);
    }
    if (config.session_id) |sid| {
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

    // The prompt goes last
    try argv_list.append(alloc, prompt);

    const argv = try argv_list.toOwnedSlice(alloc);

    // Clear CLAUDECODE env var to allow nested invocation
    var env_map = std.process.EnvMap.init(alloc);
    const env_vars = std.process.getEnvMap(alloc) catch return error.EnvError;
    var env_it = env_vars.iterator();
    while (env_it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "CLAUDECODE")) continue;
        if (std.mem.eql(u8, entry.key_ptr.*, "CLAUDE_CODE_ENTRY_POINT")) continue;
        try env_map.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    var child = std.process.Child.init(argv, alloc);
    child.env_map = &env_map;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    // Read stdout line by line, parse stream-json events
    var result_data: ResultData = .{
        .result_text = "",
        .session_id = "",
        .is_error = false,
        .duration_ms = 0,
        .cost_usd = 0,
    };

    var line_buf: std.ArrayList(u8) = .empty;
    const stdout = child.stdout.?;

    while (true) {
        var buf: [4096]u8 = undefined;
        const n = stdout.read(&buf) catch break;
        if (n == 0) break;

        for (buf[0..n]) |byte| {
            if (byte == '\n') {
                if (line_buf.items.len > 0) {
                    const event = parseLine(alloc, line_buf.items);
                    handleEvent(alloc, event, &result_data);
                    line_buf.clearRetainingCapacity();
                }
            } else {
                try line_buf.append(alloc, byte);
            }
        }
    }

    // Handle any remaining data in buffer
    if (line_buf.items.len > 0) {
        const event = parseLine(alloc, line_buf.items);
        handleEvent(alloc, event, &result_data);
    }

    // Read stderr for any error output
    const stderr = child.stderr.?;
    var stderr_buf: [4096]u8 = undefined;
    const stderr_n = stderr.read(&stderr_buf) catch 0;
    if (stderr_n > 0) {
        const stderr_text = stderr_buf[0..stderr_n];
        // Only show if it looks like a real error (not debug output)
        if (std.mem.indexOf(u8, stderr_text, "Error") != null or
            std.mem.indexOf(u8, stderr_text, "error") != null)
        {
            terminal.printError(alloc, "{s}", .{stderr_text});
        }
    }

    _ = child.wait() catch {};

    return result_data;
}

fn parseLine(alloc: std.mem.Allocator, line: []const u8) Event {
    const parsed = jh.parse(alloc, line) catch return .unknown;
    const event_type = jh.getString(parsed.value, "type") orelse return .unknown;

    if (std.mem.eql(u8, event_type, "system")) {
        return .{ .init = .{
            .session_id = jh.getString(parsed.value, "session_id") orelse "",
            .model = jh.getString(parsed.value, "model") orelse "",
        } };
    } else if (std.mem.eql(u8, event_type, "assistant")) {
        // Extract text from message content blocks
        if (jh.getObject(parsed.value, "message")) |msg| {
            if (jh.getArray(msg, "content")) |content| {
                var text_parts: std.ArrayList(u8) = .empty;
                for (content) |block| {
                    const block_type = jh.getString(block, "type") orelse continue;
                    if (std.mem.eql(u8, block_type, "text")) {
                        if (jh.getString(block, "text")) |t| {
                            text_parts.appendSlice(alloc, t) catch continue;
                        }
                    } else if (std.mem.eql(u8, block_type, "tool_use")) {
                        const name = jh.getString(block, "name") orelse "unknown";
                        // Show tool use indicator
                        return .{ .tool_use = .{
                            .name = name,
                            .input_preview = "",
                        } };
                    }
                }
                if (text_parts.items.len > 0) {
                    return .{ .assistant_text = text_parts.items };
                }
            }
        }
        return .unknown;
    } else if (std.mem.eql(u8, event_type, "result")) {
        const cost_val = jh.getObject(parsed.value, "total_cost_usd");
        var cost: f64 = 0;
        if (cost_val) |cv| {
            switch (cv) {
                .float => |f| {
                    cost = f;
                },
                .integer => |i| {
                    cost = @floatFromInt(i);
                },
                else => {},
            }
        }

        return .{ .result = .{
            .result_text = jh.getString(parsed.value, "result") orelse "",
            .session_id = jh.getString(parsed.value, "session_id") orelse "",
            .is_error = blk: {
                if (jh.getObject(parsed.value, "is_error")) |ie| {
                    switch (ie) {
                        .bool => |b| break :blk b,
                        else => break :blk false,
                    }
                }
                break :blk false;
            },
            .duration_ms = jh.getInt(parsed.value, "duration_ms") orelse 0,
            .cost_usd = cost,
        } };
    }

    return .unknown;
}

fn handleEvent(alloc: std.mem.Allocator, event: Event, result_data: *ResultData) void {
    switch (event) {
        .init => |data| {
            terminal.print(alloc, terminal.Color.gray ++ "Session: {s}" ++ terminal.Color.reset ++ "\n", .{data.session_id});
        },
        .assistant_text => |text| {
            terminal.printStr(text);
        },
        .tool_use => |data| {
            terminal.printTool(alloc, data.name, "executing...");
        },
        .result => |data| {
            result_data.* = data;
            if (data.is_error) {
                terminal.printError(alloc, "Error: {s}", .{data.result_text});
            }
            // Print cost info
            if (data.cost_usd > 0) {
                terminal.print(alloc, "\n" ++ terminal.Color.gray ++ "[{d}ms | ${d:.4}]" ++ terminal.Color.reset ++ "\n", .{ data.duration_ms, data.cost_usd });
            }
        },
        .unknown => {},
    }
}
