const std = @import("std");
const terminal = @import("terminal.zig");
const claude_cli = @import("claude_cli.zig");
const markdown = @import("markdown.zig");

/// Default: recycle after 10 turns
const default_recycle_interval: u32 = 10;

pub const Agent = struct {
    alloc: std.mem.Allocator,
    config: claude_cli.Config,
    process: ?claude_cli.Process,
    session_id: ?[]const u8,
    interrupted: *std.atomic.Value(bool),
    child_pid: *std.atomic.Value(i32),
    total_cost_usd: f64,
    total_duration_ms: i64,
    last_message: ?[]const u8,
    last_response: ?[]const u8,
    got_init: bool,
    turn_count: u32,
    recycle_interval: u32,
    recycle_rss_mb: ?u32,
    compact: bool,
    md: markdown.MarkdownRenderer,
    // Tool input accumulator
    tool_input_buf: std.ArrayList(u8),
    model_owned: bool, // whether config.model was alloc'd by us

    pub fn init(alloc: std.mem.Allocator, config: claude_cli.Config, interrupted: *std.atomic.Value(bool), child_pid: *std.atomic.Value(i32)) Agent {
        return .{
            .alloc = alloc,
            .config = config,
            .process = null,
            .session_id = null,
            .interrupted = interrupted,
            .child_pid = child_pid,
            .total_cost_usd = 0,
            .total_duration_ms = 0,
            .last_message = null,
            .last_response = null,
            .got_init = false,
            .turn_count = 0,
            .recycle_interval = config.recycle_turns orelse default_recycle_interval,
            .recycle_rss_mb = config.recycle_rss_mb,
            .compact = config.compact,
            .md = markdown.MarkdownRenderer.init(alloc),
            .tool_input_buf = .empty,
            .model_owned = false,
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
        // Update atomic PID for signal handler
        if (self.process) |*p| {
            self.child_pid.store(p.child.id, .release);
        }
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

    /// Save last response for /save
    fn saveLastResponse(self: *Agent, resp: []const u8) void {
        if (self.last_response) |old| {
            self.alloc.free(old);
        }
        self.last_response = self.alloc.dupe(u8, resp) catch null;
    }

    /// Get last message (for /retry)
    pub fn getLastMessage(self: *const Agent) ?[]const u8 {
        return self.last_message;
    }

    /// Get last response (for /save)
    pub fn getLastResponse(self: *const Agent) ?[]const u8 {
        return self.last_response;
    }

    /// Extract useful context from accumulated tool input JSON
    fn extractToolContext(self: *const Agent) []const u8 {
        const input = self.tool_input_buf.items;
        if (input.len == 0) return "";
        // Return raw input, truncated — it's already informative
        return input;
    }

    /// Send a user message and stream the response
    pub fn processUserMessage(self: *Agent, user_input: []const u8) !void {
        self.saveLastMessage(user_input);

        try self.ensureProcess();

        var proc = &(self.process.?);

        proc.sendMessage(user_input) catch |err| {
            terminal.printError("Failed to send message: {s}", .{@errorName(err)});
            self.child_pid.store(0, .release);
            self.process = null;
            return;
        };

        var got_first_content = false;
        var current_tool: ?[]const u8 = null;
        var spinner_frame: usize = 0;
        var spinner_active = true;
        var response_buf: std.ArrayList(u8) = .empty;

        // Reset markdown renderer for new turn
        self.md.reset();

        // Show initial spinner
        terminal.printSpinnerFrame(0);

        while (true) {
            if (self.interrupted.load(.acquire)) {
                terminal.clearSpinner();
                if (current_tool) |tn| self.alloc.free(tn);
                self.child_pid.store(0, .release);
                proc.kill();
                self.process = null;
                terminal.printStr(terminal.Color.yellow ++ "\n  [interrupted]" ++ terminal.Color.reset ++ "\n");
                response_buf.deinit(self.alloc);
                return;
            }

            // Poll with 100ms timeout for spinner animation
            const read_result = proc.readEventTimeout(100);

            switch (read_result) {
                .timeout => {
                    spinner_frame += 1;
                    if (current_tool) |tn| {
                        // Animate tool spinner with context
                        terminal.printToolSpinnerFrame(tn, self.extractToolContext(), spinner_frame);
                    } else if (spinner_active and !got_first_content) {
                        // Animate thinking spinner
                        terminal.printSpinnerFrame(spinner_frame);
                    }
                    continue;
                },
                .eof => {
                    terminal.clearSpinner();
                    if (current_tool) |tn| self.alloc.free(tn);
                    self.child_pid.store(0, .release);
                    self.process = null;
                    terminal.printStr(terminal.Color.yellow ++ "\n  [process ended unexpectedly]" ++ terminal.Color.reset ++ "\n");
                    terminal.printStr(terminal.Color.gray ++ "  Will restart on next message." ++ terminal.Color.reset ++ "\n");
                    self.md.flush();
                    if (response_buf.items.len > 0) {
                        self.saveLastResponse(response_buf.items);
                    }
                    response_buf.deinit(self.alloc);
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
                                    if (self.compact) {
                                        terminal.printToolDoneCompact();
                                    } else {
                                        terminal.printToolDone(tn, self.extractToolContext());
                                    }
                                    self.alloc.free(tn);
                                    current_tool = null;
                                    self.tool_input_buf.clearRetainingCapacity();
                                }
                                terminal.printResponseHeader();
                            }
                            // Feed through markdown renderer
                            self.md.feed(text);
                            // Accumulate for /save
                            response_buf.appendSlice(self.alloc, text) catch {};
                        },
                        .tool_start => |data| {
                            spinner_active = false;
                            // Finish previous tool if any
                            if (current_tool) |tn| {
                                if (self.compact) {
                                    terminal.printToolDoneCompact();
                                } else {
                                    terminal.printToolDone(tn, self.extractToolContext());
                                }
                                self.alloc.free(tn);
                            }
                            current_tool = self.alloc.dupe(u8, data.name) catch null;
                            self.tool_input_buf.clearRetainingCapacity();
                            got_first_content = false;
                            spinner_frame = 0;
                            if (!self.compact) {
                                terminal.printToolSpinnerFrame(data.name, "", 0);
                            }
                        },
                        .tool_input_delta => |partial| {
                            // Accumulate tool input JSON for context display
                            if (self.tool_input_buf.items.len < 200) {
                                self.tool_input_buf.appendSlice(self.alloc, partial) catch {};
                            }
                        },
                        .tool_result => {
                            // tool_result events handled via tool_start/done flow
                        },
                        .init => |data| {
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
                                self.saveSessionId(data.session_id);
                            }
                        },
                        .result => |data| {
                            if (spinner_active) {
                                terminal.clearSpinner();
                                spinner_active = false;
                            }
                            if (current_tool) |tn| {
                                if (self.compact) {
                                    terminal.printToolDoneCompact();
                                } else {
                                    terminal.printToolDone(tn, self.extractToolContext());
                                }
                                self.alloc.free(tn);
                            }

                            // Flush markdown renderer
                            self.md.flush();

                            self.saveSessionId(data.session_id);
                            self.total_cost_usd += data.cost_usd;
                            self.total_duration_ms += data.duration_ms;
                            self.turn_count += 1;

                            // Save response for /save
                            if (response_buf.items.len > 0) {
                                self.saveLastResponse(response_buf.items);
                            }
                            response_buf.deinit(self.alloc);

                            if (data.is_error) {
                                terminal.printError("{s}", .{data.result_text});
                            }

                            terminal.printCost(data.cost_usd, data.duration_ms, self.total_cost_usd);

                            // Reset turn arena
                            proc.resetTurnArena();
                            self.tool_input_buf.clearRetainingCapacity();

                            // Auto-recycle: turn-based
                            if (self.recycle_interval > 0 and self.turn_count >= self.recycle_interval) {
                                self.recycleProcess();
                                return;
                            }

                            // Auto-recycle: RSS-based
                            if (self.recycle_rss_mb) |threshold| {
                                if (self.getChildRssKb()) |rss_kb| {
                                    if (rss_kb / 1024 >= threshold) {
                                        terminal.print(terminal.Color.gray ++ "  [RSS {d}MB >= {d}MB threshold]" ++ terminal.Color.reset ++ "\n", .{ rss_kb / 1024, threshold });
                                        self.recycleProcess();
                                    }
                                }
                            }

                            return;
                        },
                        .unknown => {},
                    }
                },
            }
        }
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
    pub fn recycleProcess(self: *Agent) void {
        self.child_pid.store(0, .release);
        if (self.process) |*proc| {
            proc.deinit();
            self.process = null;
        }
        self.turn_count = 0;
        terminal.printStr(terminal.Color.gray ++ "  [recycled: claude process restarted to free memory]" ++ terminal.Color.reset ++ "\n");
    }

    /// Switch model (for /model command)
    pub fn setModel(self: *Agent, model: []const u8) void {
        if (self.model_owned) {
            if (self.config.model) |old| {
                self.alloc.free(old);
            }
        }
        self.config.model = self.alloc.dupe(u8, model) catch return;
        self.model_owned = true;
        terminal.print(terminal.Color.cyan ++ "  Model changed to: {s}" ++ terminal.Color.reset ++ "\n", .{model});
        self.recycleProcess();
    }

    /// Toggle compact mode
    pub fn toggleCompact(self: *Agent) void {
        self.compact = !self.compact;
        if (self.compact) {
            terminal.printStr(terminal.Color.gray ++ "  Compact mode: ON (tool details hidden)" ++ terminal.Color.reset ++ "\n");
        } else {
            terminal.printStr(terminal.Color.gray ++ "  Compact mode: OFF (tool details shown)" ++ terminal.Color.reset ++ "\n");
        }
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
        terminal.print(terminal.Color.gray ++ "    compact: {s}" ++ terminal.Color.reset ++ "\n", .{if (self.compact) "on" else "off"});
    }

    /// Graceful shutdown
    pub fn shutdown(self: *Agent) void {
        self.child_pid.store(0, .release);
        if (self.process) |*proc| {
            proc.deinit();
            self.process = null;
        }
        if (self.session_id) |sid| {
            if (sid.len > 0) self.alloc.free(sid);
            self.session_id = null;
        }
        if (self.last_message) |lm| {
            self.alloc.free(lm);
            self.last_message = null;
        }
        if (self.last_response) |lr| {
            self.alloc.free(lr);
            self.last_response = null;
        }
        if (self.model_owned) {
            if (self.config.model) |m| {
                self.alloc.free(m);
                self.config.model = null;
            }
        }
        self.tool_input_buf.deinit(self.alloc);
        terminal.printSessionSummary(self.total_cost_usd, self.total_duration_ms);
    }
};
