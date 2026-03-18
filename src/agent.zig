const std = @import("std");
const terminal = @import("terminal.zig");
const claude_cli = @import("claude_cli.zig");

/// Default: recycle after 10 turns
const default_recycle_interval: u32 = 10;

pub const Agent = struct {
    alloc: std.mem.Allocator,
    config: claude_cli.Config,
    process: ?claude_cli.Process,
    session_id: ?[]const u8,
    interrupted: *std.atomic.Value(bool),
    total_cost_usd: f64,
    total_duration_ms: i64,
    last_message: ?[]const u8,
    got_init: bool,
    turn_count: u32,
    recycle_interval: u32,

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
            .got_init = false,
            .turn_count = 0,
            .recycle_interval = config.recycle_turns orelse default_recycle_interval,
        };
    }

    /// Ensure a claude process is running, restart if needed
    pub fn ensureProcess(self: *Agent) !void {
        if (self.process != null and self.process.?.alive) return;

        // Reset init flag when starting a new process
        self.got_init = false;

        var config = self.config;
        if (self.session_id) |sid| {
            config.resume_session_id = sid;
            config.continue_session = false;
        }

        self.process = claude_cli.Process.start(self.alloc, config) catch |err| {
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

        var got_first_content = false;
        var current_tool: ?[]const u8 = null;
        var spinner_frame: usize = 0;
        var spinner_active = true;

        // Show initial spinner
        terminal.printSpinnerFrame(0);

        while (true) {
            if (self.interrupted.load(.acquire)) {
                terminal.clearSpinner();
                if (current_tool) |tn| self.alloc.free(tn);
                proc.kill();
                self.process = null;
                terminal.printStr(terminal.Color.yellow ++ "\n  [interrupted]" ++ terminal.Color.reset ++ "\n");
                return;
            }

            // Poll with 100ms timeout for spinner animation
            const read_result = proc.readEventTimeout(100);

            switch (read_result) {
                .timeout => {
                    spinner_frame += 1;
                    if (current_tool) |tn| {
                        // Animate tool spinner
                        terminal.printToolSpinnerFrame(tn, spinner_frame);
                    } else if (spinner_active and !got_first_content) {
                        // Animate thinking spinner
                        terminal.printSpinnerFrame(spinner_frame);
                    }
                    continue;
                },
                .eof => {
                    terminal.clearSpinner();
                    if (current_tool) |tn| self.alloc.free(tn);
                    self.process = null;
                    terminal.printStr(terminal.Color.yellow ++ "\n  [process ended unexpectedly]" ++ terminal.Color.reset ++ "\n");
                    terminal.printStr(terminal.Color.gray ++ "  Will restart on next message." ++ terminal.Color.reset ++ "\n");
                    return;
                },
                .event => |event| {
                    switch (event) {
                        .content_delta => |text| {
                            if (!got_first_content) {
                                got_first_content = true;
                                spinner_active = false;
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
                            spinner_active = false;
                            if (current_tool) |tn| {
                                self.alloc.free(tn);
                            }
                            current_tool = self.alloc.dupe(u8, data.name) catch null;
                            got_first_content = false;
                            spinner_frame = 0;
                            terminal.printToolSpinnerFrame(data.name, 0);
                        },
                        .tool_result => {
                            // tool_result events handled via tool_start/done flow
                        },
                        .init => |data| {
                            // Only show session info on first init event
                            // Clear spinner before showing session info
                            if (spinner_active) {
                                terminal.clearSpinner();
                                spinner_active = false;
                            }
                            if (!self.got_init) {
                                self.got_init = true;
                                self.saveSessionId(data.session_id);
                                if (data.model.len > 0) {
                                    terminal.printSessionInfo(data.session_id, data.model);
                                }
                            } else {
                                // Still save session_id for subsequent inits
                                self.saveSessionId(data.session_id);
                            }
                        },
                        .result => |data| {
                            if (spinner_active) {
                                terminal.clearSpinner();
                                spinner_active = false;
                            }
                            if (current_tool) |tn| {
                                terminal.printToolDone(tn);
                                self.alloc.free(tn);
                            }

                            self.saveSessionId(data.session_id);
                            self.total_cost_usd += data.cost_usd;
                            self.total_duration_ms += data.duration_ms;
                            self.turn_count += 1;

                            if (data.is_error) {
                                terminal.printError("{s}", .{data.result_text});
                            }

                            terminal.printCost(data.cost_usd, data.duration_ms, self.total_cost_usd);

                            // Reset turn arena
                            proc.resetTurnArena();

                            // Auto-recycle process to prevent memory bloat
                            if (self.recycle_interval > 0 and self.turn_count >= self.recycle_interval) {
                                self.recycleProcess();
                            }

                            return;
                        },
                        .unknown => {},
                    }
                },
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

    /// Recycle the claude CLI process to free Node.js memory.
    /// Session is preserved via session_id — ensureProcess() handles restart.
    pub fn recycleProcess(self: *Agent) void {
        if (self.process) |*proc| {
            proc.deinit();
            self.process = null;
        }
        self.turn_count = 0;
        terminal.printStr(terminal.Color.gray ++ "  [recycled: claude process restarted to free memory]" ++ terminal.Color.reset ++ "\n");
    }

    /// Get RSS of the child process in KB (Linux /proc/pid/statm)
    fn getChildRssKb(self: *const Agent) ?u64 {
        if (self.process == null or !self.process.?.alive) return null;
        const pid = self.process.?.child.id;

        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/statm", .{pid}) catch return null;

        const file = std.fs.openFileAbsolute(path, .{}) catch return null;
        defer file.close();

        var buf: [128]u8 = undefined;
        const n = file.read(&buf) catch return null;
        const content = buf[0..n];

        // statm format: "size resident shared ..."
        // We want the 2nd field (resident) in pages
        var it = std.mem.splitScalar(u8, content, ' ');
        _ = it.next(); // skip size
        const rss_str = it.next() orelse return null;
        const rss_pages = std.fmt.parseInt(u64, rss_str, 10) catch return null;

        const page_size_bytes: u64 = std.heap.page_size_min;
        return (rss_pages * page_size_bytes) / 1024;
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
            if (self.getChildRssKb()) |rss_kb| {
                if (rss_kb >= 1024) {
                    terminal.print(terminal.Color.gray ++ "    claude RSS: {d}MB" ++ terminal.Color.reset ++ "\n", .{rss_kb / 1024});
                } else {
                    terminal.print(terminal.Color.gray ++ "    claude RSS: {d}KB" ++ terminal.Color.reset ++ "\n", .{rss_kb});
                }
            }
        } else {
            terminal.printStr(terminal.Color.yellow ++ "    status: disconnected" ++ terminal.Color.reset ++ "\n");
        }
        terminal.print(terminal.Color.gray ++ "    turns: {d}/{d} (next recycle)" ++ terminal.Color.reset ++ "\n", .{ self.turn_count, self.recycle_interval });
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
