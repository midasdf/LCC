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

        self.process = claude_cli.Process.start(self.alloc, config) catch |err| {
            terminal.printError(self.alloc, "Failed to start claude: {s}", .{@errorName(err)});
            return err;
        };
    }

    /// Save session_id to long-lived allocator (survives arena reset)
    fn saveSessionId(self: *Agent, sid: []const u8) void {
        if (sid.len == 0) return;
        // Free old session_id if we own it
        if (self.session_id) |old_sid| {
            if (old_sid.len > 0) {
                self.alloc.free(old_sid);
            }
        }
        self.session_id = self.alloc.dupe(u8, sid) catch null;
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

        // Show waiting indicator
        terminal.printWaiting();

        var got_first_content = false;
        var current_tool: ?[]const u8 = null;

        // Event read loop
        while (true) {
            // Check for interrupt
            if (self.interrupted.load(.acquire)) {
                terminal.clearSpinner();
                proc.kill();
                self.process = null;
                terminal.printStr(terminal.Color.yellow ++ "\n  [interrupted]" ++ terminal.Color.reset ++ "\n");
                return;
            }

            const event = proc.readEvent() catch {
                terminal.clearSpinner();
                self.process = null;
                return;
            } orelse {
                // EOF - process died
                terminal.clearSpinner();
                self.process = null;
                terminal.printStr(terminal.Color.yellow ++ "\n  [process ended]" ++ terminal.Color.reset ++ "\n");
                return;
            };

            switch (event) {
                .content_delta => |text| {
                    if (!got_first_content) {
                        got_first_content = true;
                        terminal.clearSpinner();
                        if (current_tool) |tool_name| {
                            terminal.printToolDone(self.alloc, tool_name);
                            current_tool = null;
                        }
                        terminal.printResponseHeader();
                    }
                    terminal.printStreaming(text);
                },
                .tool_start => |data| {
                    if (!got_first_content) {
                        terminal.clearSpinner();
                    }
                    if (current_tool) |tool_name| {
                        terminal.printToolDone(self.alloc, tool_name);
                    }
                    // Dupe tool name to parent alloc so it survives arena reset
                    current_tool = self.alloc.dupe(u8, data.name) catch null;
                    got_first_content = false;
                    terminal.printToolStart(self.alloc, data.name);
                },
                .init => |data| {
                    self.saveSessionId(data.session_id);
                    terminal.printSessionInfo(self.alloc, data.session_id, data.model);
                },
                .result => |data| {
                    if (current_tool) |tool_name| {
                        terminal.clearSpinner();
                        terminal.printToolDone(self.alloc, tool_name);
                        self.alloc.free(tool_name);
                    }

                    self.saveSessionId(data.session_id);
                    self.total_cost_usd += data.cost_usd;
                    self.total_duration_ms += data.duration_ms;

                    if (data.is_error) {
                        terminal.printError(self.alloc, "{s}", .{data.result_text});
                    }

                    terminal.printCost(self.alloc, data.cost_usd, data.duration_ms, self.total_cost_usd);

                    // Reset turn arena - frees all JSON parse memory from this turn
                    proc.resetTurnArena();

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
        terminal.printSessionSummary(self.alloc, self.total_cost_usd, self.total_duration_ms);
    }
};
