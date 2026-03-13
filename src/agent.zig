const std = @import("std");
const terminal = @import("terminal.zig");
const claude_cli = @import("claude_cli.zig");

pub const Agent = struct {
    alloc: std.mem.Allocator,
    config: claude_cli.Config,
    process: ?claude_cli.Process,
    session_id: ?[]const u8,
    interrupted: *std.atomic.Value(bool),
    total_cost_usd: f64,
    total_duration_ms: i64,

    pub fn init(alloc: std.mem.Allocator, config: claude_cli.Config, interrupted: *std.atomic.Value(bool)) Agent {
        return .{
            .alloc = alloc,
            .config = config,
            .process = null,
            .session_id = null,
            .interrupted = interrupted,
            .total_cost_usd = 0,
            .total_duration_ms = 0,
        };
    }

    /// Ensure a claude process is running, restart if needed
    pub fn ensureProcess(self: *Agent) !void {
        if (self.process != null and self.process.?.alive) return;

        // Set resume session_id if we have one from a previous process
        var config = self.config;
        if (self.session_id) |sid| {
            config.resume_session_id = sid;
        }

        terminal.print(self.alloc, terminal.Color.gray ++ "Starting claude..." ++ terminal.Color.reset ++ "\n", .{});

        self.process = claude_cli.Process.start(self.alloc, config) catch |err| {
            terminal.printError(self.alloc, "Failed to start claude: {s}", .{@errorName(err)});
            return err;
        };
    }

    /// Send a user message and stream the response
    pub fn processUserMessage(self: *Agent, user_input: []const u8) !void {
        try self.ensureProcess();

        var proc = &(self.process.?);

        proc.sendMessage(user_input) catch |err| {
            terminal.printError(self.alloc, "Failed to send message: {s}", .{@errorName(err)});
            self.process = null;
            return;
        };

        // Event read loop
        while (true) {
            // Check for interrupt
            if (self.interrupted.load(.acquire)) {
                proc.kill();
                self.process = null;
                terminal.printStr("\n" ++ terminal.Color.yellow ++ "[interrupted]" ++ terminal.Color.reset ++ "\n");
                return;
            }

            const event = proc.readEvent() catch {
                self.process = null;
                return;
            } orelse {
                // EOF - process died
                self.process = null;
                terminal.printStr("\n" ++ terminal.Color.yellow ++ "[process ended]" ++ terminal.Color.reset ++ "\n");
                return;
            };

            switch (event) {
                .content_delta => |text| {
                    terminal.printStreaming(text);
                },
                .tool_start => |data| {
                    terminal.printTool(self.alloc, data.name, "running...");
                },
                .init => |data| {
                    if (data.session_id.len > 0) {
                        self.session_id = data.session_id;
                    }
                    terminal.print(self.alloc, terminal.Color.gray ++ "Session: {s} | Model: {s}" ++ terminal.Color.reset ++ "\n", .{ data.session_id, data.model });
                },
                .result => |data| {
                    if (data.session_id.len > 0) {
                        self.session_id = data.session_id;
                    }
                    self.total_cost_usd += data.cost_usd;
                    self.total_duration_ms += data.duration_ms;

                    if (data.is_error) {
                        terminal.printError(self.alloc, "{s}", .{data.result_text});
                    }

                    terminal.printCost(self.alloc, data.cost_usd, data.duration_ms, self.total_cost_usd);
                    terminal.printStr("\n");
                    return; // Turn complete, back to REPL
                },
                .unknown => {},
            }
        }
    }

    /// Get PID of the running claude process (for signal handler)
    pub fn getChildPid(self: *const Agent) std.posix.pid_t {
        if (self.process) |*proc| {
            return proc.getPid();
        }
        return 0;
    }

    /// Graceful shutdown
    pub fn shutdown(self: *Agent) void {
        if (self.process) |*proc| {
            proc.deinit();
            self.process = null;
        }
        if (self.total_cost_usd > 0) {
            terminal.print(self.alloc, terminal.Color.gray ++ "Session total: ${d:.4} | {d}ms" ++ terminal.Color.reset ++ "\n", .{ self.total_cost_usd, self.total_duration_ms });
        }
    }
};
