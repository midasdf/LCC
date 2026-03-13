const std = @import("std");
const terminal = @import("terminal.zig");
const claude_cli = @import("claude_cli.zig");

pub const Agent = struct {
    alloc: std.mem.Allocator,
    config: claude_cli.Config,
    session_id: ?[]const u8,

    pub fn init(alloc: std.mem.Allocator, config: claude_cli.Config) Agent {
        return .{
            .alloc = alloc,
            .config = config,
            .session_id = null,
        };
    }

    pub fn processUserMessage(self: *Agent, user_input: []const u8) !void {
        // Set session_id for conversation continuity
        var config = self.config;
        if (self.session_id) |sid| {
            config.session_id = sid;
        }

        const result = claude_cli.run(self.alloc, user_input, config) catch |err| {
            terminal.printError(self.alloc, "Claude CLI error: {s}", .{@errorName(err)});
            return;
        };

        // Save session_id for resuming
        if (result.session_id.len > 0) {
            self.session_id = result.session_id;
        }
    }
};
