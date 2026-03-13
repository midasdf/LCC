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
    last_message: ?[]const u8,

    pub fn init(alloc: std.mem.Allocator, config: claude_cli.Config, interrupted: *std.atomic.Value(bool)) Agent {
        return .{
            .alloc = alloc,
            .config = config,
            .process = null,
            .session_id = null,
            .interrupted = interrupted,
            .total_cost_usd = 0,
            .total_duration_ms = 0,
            .last_message = null,
        };
    }

    /// Ensure a claude process is running, restart if needed
    pub fn ensureProcess(self: *Agent) !void {
        if (self.process != null and self.process.?.alive) return;

        var config = self.config;
        if (self.session_id) |sid| {
            config.resume_session_id = sid;
            // Don't use --continue when we already have a session to resume
            config.continue_session = false;
        }

        self.process = claude_cli.Process.start(self.alloc, config) catch |err| {
            // Provide helpful error messages
            switch (err) {
                error.FileNotFound => {
                    terminal.printError("claude CLI not found. Install it: npm install -g @anthropic-ai/claude-code", .{});
                },
                error.AccessDenied => {
                    terminal.printError("Permission denied running claude CLI. Check file permissions.", .{});
                },
                else => {
                    terminal.printError("Failed to start claude: {s}", .{@errorName(err)});
                },
            }
            return err;
        };
    }

    /// Save session_id to long-lived allocator (survives arena reset)
    fn saveSessionId(self: *Agent, sid: []const u8) void {
        if (sid.len == 0) return;
        if (self.session_id) |old_sid| {
            if (old_sid.len > 0) {
                self.alloc.free(old_sid);
            }
        }
        self.session_id = self.alloc.dupe(u8, sid) catch null;
    }

    /// Save last message for /retry
    fn saveLastMessage(self: *Agent, msg: []const u8) void {
        if (self.last_message) |old| {
            self.alloc.free(old);
        }
        self.last_message = self.alloc.dupe(u8, msg) catch null;
    }

    /// Get last message (for /retry)
    pub fn getLastMessage(self: *const Agent) ?[]const u8 {
        return self.last_message;
    }

    /// Get session ID (for /session display)
    pub fn getSessionId(self: *const Agent) ?[]const u8 {
        return self.session_id;
    }

    /// Send a user message and stream the response
    pub fn processUserMessage(self: *Agent, user_input: []const u8) !void {
        self.saveLastMessage(user_input);

        try self.ensureProcess();

        var proc = &(self.process.?);

        proc.sendMessage(user_input) catch |err| {
            terminal.printError("Failed to send message: {s}", .{@errorName(err)});
            self.process = null;
            return;
        };

        terminal.printWaiting();

        var got_first_content = false;
        var current_tool: ?[]const u8 = null;

        while (true) {
            if (self.interrupted.load(.acquire)) {
                terminal.clearSpinner();
                if (current_tool) |tn| self.alloc.free(tn);
                proc.kill();
                self.process = null;
                terminal.printStr(terminal.Color.yellow ++ "\n  [interrupted]" ++ terminal.Color.reset ++ "\n");
                return;
            }

            const event = proc.readEvent() catch {
                terminal.clearSpinner();
                if (current_tool) |tn| self.alloc.free(tn);
                self.process = null;
                return;
            } orelse {
                terminal.clearSpinner();
                if (current_tool) |tn| self.alloc.free(tn);
                self.process = null;
                terminal.printStr(terminal.Color.yellow ++ "\n  [process ended unexpectedly]" ++ terminal.Color.reset ++ "\n");
                terminal.printStr(terminal.Color.gray ++ "  Will restart on next message." ++ terminal.Color.reset ++ "\n");
                return;
            };

            switch (event) {
                .content_delta => |text| {
                    if (!got_first_content) {
                        got_first_content = true;
                        terminal.clearSpinner();
                        if (current_tool) |tn| {
                            terminal.printToolDone(tn);
                            self.alloc.free(tn);
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
                    if (current_tool) |tn| {
                        terminal.printToolDone(tn);
                        self.alloc.free(tn);
                    }
                    current_tool = self.alloc.dupe(u8, data.name) catch null;
                    got_first_content = false;
                    terminal.printToolStart(data.name);
                },
                .tool_result => {
                    // tool_result events are handled implicitly via tool_start/done flow
                },
                .init => |data| {
                    self.saveSessionId(data.session_id);
                    terminal.printSessionInfo(data.session_id, data.model);
                },
                .result => |data| {
                    if (current_tool) |tn| {
                        terminal.clearSpinner();
                        terminal.printToolDone(tn);
                        self.alloc.free(tn);
                    }

                    self.saveSessionId(data.session_id);
                    self.total_cost_usd += data.cost_usd;
                    self.total_duration_ms += data.duration_ms;

                    if (data.is_error) {
                        terminal.printError("{s}", .{data.result_text});
                    }

                    terminal.printCost(data.cost_usd, data.duration_ms, self.total_cost_usd);

                    // Reset turn arena - frees all JSON parse memory from this turn
                    proc.resetTurnArena();

                    return;
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

    /// Print cost info for /cost command
    pub fn printCostSummary(self: *const Agent) void {
        if (self.total_cost_usd > 0 or self.total_duration_ms > 0) {
            const secs = @divTrunc(self.total_duration_ms, 1000);
            terminal.print("\n" ++ terminal.Color.cyan ++ "  Session Cost" ++ terminal.Color.reset ++ "\n", .{});
            terminal.print(terminal.Color.gray ++ "    total: ${d:.4} | {d}s" ++ terminal.Color.reset ++ "\n", .{ self.total_cost_usd, secs });
        } else {
            terminal.printStr("\n" ++ terminal.Color.gray ++ "  No cost data yet." ++ terminal.Color.reset ++ "\n");
        }
    }

    /// Print session info for /session command
    pub fn printSessionInfo(self: *const Agent) void {
        terminal.printStr("\n" ++ terminal.Color.cyan ++ "  Session Info" ++ terminal.Color.reset ++ "\n");
        if (self.session_id) |sid| {
            terminal.print(terminal.Color.gray ++ "    id: {s}" ++ terminal.Color.reset ++ "\n", .{sid});
        } else {
            terminal.printStr(terminal.Color.gray ++ "    No active session." ++ terminal.Color.reset ++ "\n");
        }
        if (self.config.model) |m| {
            terminal.print(terminal.Color.gray ++ "    model: {s}" ++ terminal.Color.reset ++ "\n", .{m});
        }
        if (self.process != null and self.process.?.alive) {
            terminal.printStr(terminal.Color.green ++ "    status: connected" ++ terminal.Color.reset ++ "\n");
        } else {
            terminal.printStr(terminal.Color.yellow ++ "    status: disconnected" ++ terminal.Color.reset ++ "\n");
        }
    }

    /// Graceful shutdown
    pub fn shutdown(self: *Agent) void {
        if (self.process) |*proc| {
            proc.deinit();
            self.process = null;
        }
        if (self.last_message) |lm| {
            self.alloc.free(lm);
            self.last_message = null;
        }
        terminal.printSessionSummary(self.total_cost_usd, self.total_duration_ms);
    }
};
