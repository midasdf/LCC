const std = @import("std");
const jh = @import("json_helper.zig");
const terminal = @import("terminal.zig");
const tools_mod = @import("tools.zig");
const client_mod = @import("client.zig");

const Value = jh.Value;

const SYSTEM_PROMPT =
    \\You are a coding agent running in a terminal. You help users with software engineering tasks.
    \\
    \\You have access to tools for reading files, writing files, editing files, running bash commands,
    \\searching files with glob patterns, searching file contents with grep, and listing directories.
    \\
    \\Guidelines:
    \\- Read files before modifying them to understand existing code
    \\- Use bash for running tests, builds, git commands, and other shell operations
    \\- Use edit_file for precise string replacements in existing files
    \\- Use write_file only for creating new files or complete rewrites
    \\- Use glob and grep to explore the codebase
    \\- Be concise in your responses
    \\- When you make changes, verify them by reading back or running tests
    \\- The working directory is the user's project root
;

const MAX_HISTORY: usize = 100;

pub const Agent = struct {
    alloc: std.mem.Allocator,
    client: client_mod.Client,
    messages: jh.Array,
    tool_defs: Value,

    pub fn init(alloc: std.mem.Allocator, api_key: []const u8, model: []const u8, max_tokens: u32) !Agent {
        return .{
            .alloc = alloc,
            .client = client_mod.Client.init(alloc, api_key, model, max_tokens),
            .messages = jh.array(alloc),
            .tool_defs = try tools_mod.getToolDefinitions(alloc),
        };
    }

    pub fn processUserMessage(self: *Agent, user_input: []const u8) !void {
        const alloc = self.alloc;

        // Add user message to history
        try self.addUserMessage(user_input);

        // Agent loop: keep going until no more tool calls
        while (true) {
            // Trim history if needed
            self.trimHistory();

            // Send to API
            const messages_val = Value{ .array = self.messages };
            const response = self.client.sendRequest(
                SYSTEM_PROMPT,
                messages_val,
                self.tool_defs,
            ) catch |err| {
                terminal.printError(alloc, "API request failed: {s}", .{@errorName(err)});
                return;
            };

            // Process response blocks
            var has_tool_use = false;
            var assistant_content = jh.array(alloc);
            var tool_results = jh.array(alloc);

            for (response.blocks) |block| {
                switch (block.block_type) {
                    .text => {
                        var text_block = jh.object(alloc);
                        try text_block.put("type", jh.string("text"));
                        try text_block.put("text", jh.string(block.text));
                        try assistant_content.append(.{ .object = text_block });
                    },
                    .tool_use => {
                        has_tool_use = true;
                        terminal.printStr("\n");

                        // Parse tool input
                        const tool_input = if (block.tool_input.len > 0) blk: {
                            const parsed = jh.parse(alloc, block.tool_input) catch {
                                break :blk Value{ .object = jh.object(alloc) };
                            };
                            break :blk parsed.value;
                        } else Value{ .object = jh.object(alloc) };

                        // Add tool_use to assistant content
                        var tool_use_block = jh.object(alloc);
                        try tool_use_block.put("type", jh.string("tool_use"));
                        try tool_use_block.put("id", jh.string(block.tool_id));
                        try tool_use_block.put("name", jh.string(block.tool_name));
                        try tool_use_block.put("input", tool_input);
                        try assistant_content.append(.{ .object = tool_use_block });

                        // Execute tool
                        const result = try tools_mod.execute(alloc, block.tool_name, tool_input);

                        // Show truncated result
                        if (result.len > 500) {
                            terminal.print(alloc, "{s}{s}...({d} bytes total){s}\n", .{
                                terminal.Color.gray, result[0..500], result.len, terminal.Color.reset,
                            });
                        }

                        // Build tool_result
                        var tool_result = jh.object(alloc);
                        try tool_result.put("type", jh.string("tool_result"));
                        try tool_result.put("tool_use_id", jh.string(block.tool_id));
                        try tool_result.put("content", jh.string(result));
                        try tool_results.append(.{ .object = tool_result });
                    },
                }
            }

            // Add assistant message to history
            var assistant_msg = jh.object(alloc);
            try assistant_msg.put("role", jh.string("assistant"));
            try assistant_msg.put("content", .{ .array = assistant_content });
            try self.messages.append(.{ .object = assistant_msg });

            if (has_tool_use) {
                // Add tool results as user message
                var tool_msg = jh.object(alloc);
                try tool_msg.put("role", jh.string("user"));
                try tool_msg.put("content", .{ .array = tool_results });
                try self.messages.append(.{ .object = tool_msg });
            } else {
                terminal.printStr("\n");
                break;
            }
        }
    }

    fn addUserMessage(self: *Agent, text: []const u8) !void {
        var msg = jh.object(self.alloc);
        try msg.put("role", jh.string("user"));
        try msg.put("content", jh.string(text));
        try self.messages.append(.{ .object = msg });
    }

    fn trimHistory(self: *Agent) void {
        while (self.messages.items.len > MAX_HISTORY) {
            _ = self.messages.orderedRemove(0);
        }
    }
};
