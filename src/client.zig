const std = @import("std");
const jh = @import("json_helper.zig");
const terminal = @import("terminal.zig");

const Value = jh.Value;

pub const ContentBlock = struct {
    block_type: BlockType,
    text: []const u8,
    tool_id: []const u8,
    tool_name: []const u8,
    tool_input: []const u8,

    pub const BlockType = enum { text, tool_use };
};

pub const ApiResponse = struct {
    blocks: []ContentBlock,
    stop_reason: []const u8,
};

pub const Client = struct {
    alloc: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    max_tokens: u32,

    pub fn init(alloc: std.mem.Allocator, api_key: []const u8, model: []const u8, max_tokens: u32) Client {
        return .{
            .alloc = alloc,
            .api_key = api_key,
            .model = model,
            .max_tokens = max_tokens,
        };
    }

    pub fn sendRequest(self: *Client, system_prompt: []const u8, messages: Value, tools: Value) !ApiResponse {
        const alloc = self.alloc;

        // Build request body
        var body_obj = jh.object(alloc);
        try body_obj.put("model", jh.string(self.model));
        try body_obj.put("max_tokens", jh.integer(@intCast(self.max_tokens)));
        try body_obj.put("stream", jh.boolean(true));
        try body_obj.put("system", jh.string(system_prompt));
        try body_obj.put("messages", messages);
        try body_obj.put("tools", tools);

        const body_str = try jh.stringify(alloc, .{ .object = body_obj });

        // Make HTTP request
        var http_client: std.http.Client = .{ .allocator = alloc };
        defer http_client.deinit();

        const uri = std.Uri.parse("https://api.anthropic.com/v1/messages") catch unreachable;

        var req = http_client.request(.POST, uri, .{
            .extra_headers = &.{
                .{ .name = "x-api-key", .value = self.api_key },
                .{ .name = "anthropic-version", .value = "2023-06-01" },
                .{ .name = "content-type", .value = "application/json" },
            },
        }) catch |err| {
            terminal.printError(alloc, "HTTP request error: {s}", .{@errorName(err)});
            return err;
        };
        defer req.deinit();

        // Send body
        req.transfer_encoding = .{ .content_length = body_str.len };
        req.sendBodyComplete(@constCast(body_str)) catch |err| {
            terminal.printError(alloc, "Error sending request body: {s}", .{@errorName(err)});
            return err;
        };

        // Receive response head
        var redirect_buf: [4096]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch |err| {
            terminal.printError(alloc, "Error receiving response: {s}", .{@errorName(err)});
            return err;
        };

        if (response.head.status != .ok) {
            // Read error body
            var transfer_buf: [8192]u8 = undefined;
            const body_reader = response.reader(&transfer_buf);
            const error_body = body_reader.allocRemaining(alloc, .limited(8192)) catch "";
            terminal.printError(alloc, "API error (HTTP {d}): {s}", .{ @intFromEnum(response.head.status), error_body });
            return error.HttpError;
        }

        // Parse SSE stream from response body
        return self.parseSSEStream(alloc, &response, &req);
    }

    fn parseSSEStream(self: *Client, alloc: std.mem.Allocator, response: *std.http.Client.Response, req: *std.http.Client.Request) !ApiResponse {
        _ = self;
        var blocks: std.ArrayList(ContentBlock) = .empty;
        var current_text: std.ArrayList(u8) = .empty;
        var current_tool_json: std.ArrayList(u8) = .empty;
        var current_tool_id: []const u8 = "";
        var current_tool_name: []const u8 = "";
        var stop_reason: []const u8 = "end_turn";
        var in_text_block = false;
        var in_tool_block = false;

        var line_buf: std.ArrayList(u8) = .empty;

        // Get response body reader
        var transfer_buf: [16384]u8 = undefined;
        const body_reader = response.reader(&transfer_buf);

        // Read SSE stream
        while (true) {
            const chunk = body_reader.peekGreedy(4096) catch break;
            if (chunk.len == 0) break;

            // Process bytes
            const chunk_len = chunk.len;
            for (chunk) |byte| {
                if (byte == '\n') {
                    // Process line
                    const line = line_buf.items;

                    // Remove trailing \r
                    const clean_line = if (line.len > 0 and line[line.len - 1] == '\r')
                        line[0 .. line.len - 1]
                    else
                        line;

                    if (std.mem.startsWith(u8, clean_line, "data: ")) {
                        const data = clean_line[6..];
                        if (!std.mem.eql(u8, data, "[DONE]")) {
                            processSSEData(alloc, data, &blocks, &current_text, &current_tool_json, &current_tool_id, &current_tool_name, &stop_reason, &in_text_block, &in_tool_block) catch {};
                        }
                    }

                    line_buf.clearRetainingCapacity();
                } else {
                    try line_buf.append(alloc, byte);
                }
            }
            body_reader.toss(chunk_len);
        }

        // Finalize pending blocks
        if (in_text_block and current_text.items.len > 0) {
            try blocks.append(alloc, .{
                .block_type = .text,
                .text = try current_text.toOwnedSlice(alloc),
                .tool_id = "",
                .tool_name = "",
                .tool_input = "",
            });
        }
        if (in_tool_block) {
            try blocks.append(alloc, .{
                .block_type = .tool_use,
                .text = "",
                .tool_id = current_tool_id,
                .tool_name = current_tool_name,
                .tool_input = try current_tool_json.toOwnedSlice(alloc),
            });
        }

        _ = req;

        return .{
            .blocks = try blocks.toOwnedSlice(alloc),
            .stop_reason = stop_reason,
        };
    }

    fn processSSEData(alloc: std.mem.Allocator, data: []const u8, blocks: *std.ArrayList(ContentBlock), current_text: *std.ArrayList(u8), current_tool_json: *std.ArrayList(u8), current_tool_id: *[]const u8, current_tool_name: *[]const u8, stop_reason: *[]const u8, in_text_block: *bool, in_tool_block: *bool) !void {
        const parsed = jh.parse(alloc, data) catch return;

        const event_type = jh.getString(parsed.value, "type") orelse return;

        if (std.mem.eql(u8, event_type, "content_block_start")) {
            // Finalize previous block
            if (in_text_block.* and current_text.items.len > 0) {
                try blocks.append(alloc, .{
                    .block_type = .text,
                    .text = try current_text.toOwnedSlice(alloc),
                    .tool_id = "",
                    .tool_name = "",
                    .tool_input = "",
                });
                current_text.* = .empty;
            }
            if (in_tool_block.*) {
                try blocks.append(alloc, .{
                    .block_type = .tool_use,
                    .text = "",
                    .tool_id = current_tool_id.*,
                    .tool_name = current_tool_name.*,
                    .tool_input = try current_tool_json.toOwnedSlice(alloc),
                });
                current_tool_json.* = .empty;
            }

            if (jh.getObject(parsed.value, "content_block")) |block| {
                const block_type = jh.getString(block, "type") orelse return;
                if (std.mem.eql(u8, block_type, "text")) {
                    in_text_block.* = true;
                    in_tool_block.* = false;
                } else if (std.mem.eql(u8, block_type, "tool_use")) {
                    in_text_block.* = false;
                    in_tool_block.* = true;
                    current_tool_id.* = try alloc.dupe(u8, jh.getString(block, "id") orelse "");
                    current_tool_name.* = try alloc.dupe(u8, jh.getString(block, "name") orelse "");
                }
            }
        } else if (std.mem.eql(u8, event_type, "content_block_delta")) {
            if (jh.getObject(parsed.value, "delta")) |delta| {
                const delta_type = jh.getString(delta, "type") orelse return;
                if (std.mem.eql(u8, delta_type, "text_delta")) {
                    if (jh.getString(delta, "text")) |text| {
                        terminal.printStreaming(text);
                        try current_text.appendSlice(alloc, text);
                    }
                } else if (std.mem.eql(u8, delta_type, "input_json_delta")) {
                    if (jh.getString(delta, "partial_json")) |partial| {
                        try current_tool_json.appendSlice(alloc, partial);
                    }
                }
            }
        } else if (std.mem.eql(u8, event_type, "message_delta")) {
            if (jh.getObject(parsed.value, "delta")) |delta| {
                if (jh.getString(delta, "stop_reason")) |sr| {
                    stop_reason.* = try alloc.dupe(u8, sr);
                }
            }
        }
    }
};

pub const Error = error{HttpError};
