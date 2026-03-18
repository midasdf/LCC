const std = @import("std");
const history_mod = @import("history.zig");

pub const Color = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const red = "\x1b[31m";
    pub const green = "\x1b[32m";
    pub const yellow = "\x1b[33m";
    pub const blue = "\x1b[34m";
    pub const magenta = "\x1b[35m";
    pub const cyan = "\x1b[36m";
    pub const gray = "\x1b[90m";
    pub const white = "\x1b[97m";
};

// ANSI escape sequences
const CLEAR_LINE = "\x1b[2K\r";
const CLEAR_SCREEN = "\x1b[2J\x1b[H";

fn getStdout() std.fs.File {
    return .{ .handle = std.posix.STDOUT_FILENO };
}

fn getStderr() std.fs.File {
    return .{ .handle = std.posix.STDERR_FILENO };
}

fn getStdin() std.fs.File {
    return .{ .handle = std.posix.STDIN_FILENO };
}

/// Check if stdin is a TTY (interactive terminal)
pub fn isInteractive() bool {
    return std.posix.isatty(std.posix.STDIN_FILENO);
}

/// Print formatted text to stdout using a stack buffer (no heap allocation)
pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch {
        return;
    };
    _ = getStdout().write(s) catch {};
}

pub fn printStr(s: []const u8) void {
    _ = getStdout().write(s) catch {};
}

/// Print error to stderr using stack buffer
pub fn printError(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, Color.red ++ "  " ++ fmt ++ Color.reset ++ "\n", args) catch return;
    _ = getStderr().write(s) catch {};
}

/// Print a horizontal separator line
pub fn printSeparator() void {
    printStr(Color.dim ++ "─────────────────────────────────────────────────" ++ Color.reset ++ "\n");
}

/// Spinner frames for animated waiting indicator
pub const spinner_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

/// Show animated spinner frame (overwrites current line)
pub fn printSpinnerFrame(frame: usize) void {
    const f = spinner_frames[frame % spinner_frames.len];
    printStr(CLEAR_LINE ++ Color.cyan);
    printStr("  ");
    printStr(f);
    printStr(" " ++ Color.dim ++ "thinking..." ++ Color.reset);
}

/// Show animated tool spinner frame with optional context
pub fn printToolSpinnerFrame(name: []const u8, context: []const u8, frame: usize) void {
    const f = spinner_frames[frame % spinner_frames.len];
    printStr(CLEAR_LINE ++ Color.cyan ++ "  ");
    printStr(f);
    printStr(" " ++ Color.bold);
    printStr(name);
    if (context.len > 0) {
        printStr(Color.reset ++ Color.dim ++ " ");
        // Truncate context to ~60 chars
        if (context.len > 60) {
            printStr(context[0..60]);
            printStr("...");
        } else {
            printStr(context);
        }
    }
    printStr(Color.reset);
}

/// Clear tool display (tool finished)
pub fn printToolDone(name: []const u8, context: []const u8) void {
    // Show brief completion line instead of just clearing
    printStr(CLEAR_LINE ++ Color.dim ++ "  ✓ ");
    printStr(name);
    if (context.len > 0) {
        printStr(" ");
        if (context.len > 70) {
            printStr(context[0..70]);
            printStr("...");
        } else {
            printStr(context);
        }
    }
    printStr(Color.reset ++ "\n");
}

/// Clear tool display silently (for compact mode)
pub fn printToolDoneCompact() void {
    printStr(CLEAR_LINE);
}

/// Print the user input prompt with command hints
pub fn printPrompt() void {
    printStr("\n" ++ Color.dim ++ "  /help /cost /model /save /compact /recycle | exit" ++ Color.reset);
    printStr("\n" ++ Color.bold ++ Color.green ++ " > " ++ Color.reset);
}

/// Print continuation prompt for multiline input
fn printContinuation() void {
    printStr(Color.dim ++ " . " ++ Color.reset);
}

/// Print response header before streaming starts
pub fn printResponseHeader() void {
    printStr("\n" ++ Color.bold ++ Color.cyan ++ " Claude" ++ Color.reset ++ "\n");
}

/// Stream text output (called for each text delta)
pub fn printStreaming(text: []const u8) void {
    printStr(text);
}

/// Clear the spinner/waiting indicator
pub fn clearSpinner() void {
    printStr(CLEAR_LINE);
}

/// Clear screen
pub fn clearScreen() void {
    printStr(CLEAR_SCREEN);
}

/// Show waiting indicator (static, used as fallback for non-interactive)
pub fn printWaiting() void {
    printStr(Color.dim ++ "  thinking..." ++ Color.reset);
}

/// Print cost summary for a turn
pub fn printCost(turn_cost: f64, duration_ms: i64, total_cost: f64) void {
    const secs = @divTrunc(duration_ms, 1000);
    const ms_rem = @mod(duration_ms, 1000);
    if (total_cost > 0) {
        print("\n" ++ Color.gray ++ "  [{d}.{d:0>3}s | ${d:.4} / ${d:.4}]" ++ Color.reset ++ "\n", .{ secs, ms_rem, turn_cost, total_cost });
    } else {
        print("\n" ++ Color.gray ++ "  [{d}.{d:0>3}s]" ++ Color.reset ++ "\n", .{ secs, ms_rem });
    }
}

/// Print the startup banner
pub fn printBanner(model: ?[]const u8, name: ?[]const u8) void {
    printStr("\n");
    printStr(Color.bold ++ Color.cyan ++ "  LCC" ++ Color.reset ++ " - Lightweight Claude Code\n");
    printSeparator();
    if (name) |n| {
        print(Color.gray ++ "  session: {s}" ++ Color.reset ++ "\n", .{n});
    }
    if (model) |m| {
        print(Color.gray ++ "  model: {s}" ++ Color.reset ++ "\n", .{m});
    }
    printStr(Color.gray ++ "  Type /help for commands | empty line = submit | Ctrl+C = stop" ++ Color.reset ++ "\n");
    printSeparator();
}

/// Print session info when claude process starts
pub fn printSessionInfo(session_id: []const u8, model: []const u8) void {
    const short_id = if (session_id.len > 8) session_id[0..8] else session_id;
    print(Color.gray ++ "  session: {s}... | model: {s}" ++ Color.reset ++ "\n", .{ short_id, model });
}

/// Print session summary on exit
pub fn printSessionSummary(total_cost: f64, total_duration_ms: i64) void {
    if (total_cost > 0 or total_duration_ms > 0) {
        const secs = @divTrunc(total_duration_ms, 1000);
        printSeparator();
        print(Color.gray ++ "  total: ${d:.4} | {d}s" ++ Color.reset ++ "\n", .{ total_cost, secs });
    }
}

/// Print REPL help
pub fn printReplHelp() void {
    printStr("\n" ++ Color.bold ++ "  Commands:" ++ Color.reset ++ "\n");
    printStr(Color.gray ++ "    /help              Show this help\n" ++ Color.reset);
    printStr(Color.gray ++ "    /cost              Show session cost summary\n" ++ Color.reset);
    printStr(Color.gray ++ "    /session           Show session info\n" ++ Color.reset);
    printStr(Color.gray ++ "    /model <name>      Switch model (restarts process)\n" ++ Color.reset);
    printStr(Color.gray ++ "    /save [file]       Save last response to file\n" ++ Color.reset);
    printStr(Color.gray ++ "    /compact           Toggle compact mode (hide tool details)\n" ++ Color.reset);
    printStr(Color.gray ++ "    /clear             Clear screen\n" ++ Color.reset);
    printStr(Color.gray ++ "    /retry             Retry last message\n" ++ Color.reset);
    printStr(Color.gray ++ "    /recycle           Restart claude process (frees memory)\n" ++ Color.reset);
    printStr(Color.gray ++ "    /version           Show LCC version\n" ++ Color.reset);
    printStr(Color.gray ++ "    exit, quit         Exit LCC\n" ++ Color.reset);
    printStr("\n" ++ Color.gray ++ "  Input: type message, press Enter on empty line to send.\n" ++ Color.reset);
    printStr(Color.gray ++ "  Up/Down arrows browse input history.\n" ++ Color.reset);
    printStr(Color.gray ++ "  Ctrl+C once to interrupt, twice to quit.\n" ++ Color.reset);
}

// --- Raw terminal mode for input history ---

const RawTerminal = struct {
    orig: std.posix.termios,

    fn enable() ?RawTerminal {
        const orig = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch return null;
        var raw = orig;
        // Disable canonical mode and echo; keep signal handling
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        // Read returns after 1 byte
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw) catch return null;
        return .{ .orig = orig };
    }

    fn disable(self: *const RawTerminal) void {
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.orig) catch {};
    }
};

/// Read a single line with history support using raw terminal mode.
/// Returns the line content, or null on EOF.
fn readLineRaw(alloc: std.mem.Allocator, hist: *history_mod.History) !?[]const u8 {
    const raw = RawTerminal.enable() orelse {
        // Fallback to simple line reading
        return readSimpleLine(alloc);
    };
    defer raw.disable();

    const stdin = getStdin();
    var line: std.ArrayList(u8) = .empty;
    var cursor: usize = 0;

    while (true) {
        var byte: [1]u8 = undefined;
        const n = stdin.read(&byte) catch |err| {
            if (err == error.BrokenPipe) return null;
            return err;
        };
        if (n == 0) {
            if (line.items.len > 0) {
                return try line.toOwnedSlice(alloc);
            }
            return null;
        }

        switch (byte[0]) {
            '\n', '\r' => {
                printStr("\n");
                return try line.toOwnedSlice(alloc);
            },
            // Ctrl+D: EOF
            4 => {
                if (line.items.len == 0) return null;
            },
            // Backspace / Ctrl+H
            127, 8 => {
                if (cursor > 0) {
                    _ = line.orderedRemove(cursor - 1);
                    cursor -= 1;
                    // Redraw from cursor position
                    redrawLine(line.items, cursor);
                }
            },
            // Escape sequence
            '\x1b' => {
                var seq: [2]u8 = undefined;
                const sn = stdin.read(&seq) catch continue;
                if (sn < 2 or seq[0] != '[') continue;

                switch (seq[1]) {
                    // Up arrow
                    'A' => {
                        if (hist.prev()) |entry| {
                            replaceLine(&line, alloc, entry, &cursor);
                        }
                    },
                    // Down arrow
                    'B' => {
                        if (hist.next()) |entry| {
                            replaceLine(&line, alloc, entry, &cursor);
                        } else {
                            replaceLine(&line, alloc, "", &cursor);
                        }
                    },
                    // Right arrow
                    'C' => {
                        if (cursor < line.items.len) {
                            cursor += 1;
                            printStr("\x1b[C");
                        }
                    },
                    // Left arrow
                    'D' => {
                        if (cursor > 0) {
                            cursor -= 1;
                            printStr("\x1b[D");
                        }
                    },
                    // Home
                    'H' => {
                        if (cursor > 0) {
                            print("\x1b[{d}D", .{cursor});
                            cursor = 0;
                        }
                    },
                    // End
                    'F' => {
                        if (cursor < line.items.len) {
                            print("\x1b[{d}C", .{line.items.len - cursor});
                            cursor = line.items.len;
                        }
                    },
                    // Delete key: ESC [ 3 ~
                    '3' => {
                        var tilde: [1]u8 = undefined;
                        _ = stdin.read(&tilde) catch {};
                        if (cursor < line.items.len) {
                            _ = line.orderedRemove(cursor);
                            redrawLine(line.items, cursor);
                        }
                    },
                    else => {},
                }
            },
            // Ctrl+A: Home
            1 => {
                if (cursor > 0) {
                    print("\x1b[{d}D", .{cursor});
                    cursor = 0;
                }
            },
            // Ctrl+E: End
            5 => {
                if (cursor < line.items.len) {
                    print("\x1b[{d}C", .{line.items.len - cursor});
                    cursor = line.items.len;
                }
            },
            // Ctrl+U: Clear line
            21 => {
                replaceLine(&line, alloc, "", &cursor);
            },
            // Ctrl+K: Kill to end of line
            11 => {
                if (cursor < line.items.len) {
                    line.items.len = cursor;
                    // Clear from cursor to end
                    printStr("\x1b[K");
                }
            },
            // Ctrl+W: Delete word backwards
            23 => {
                if (cursor > 0) {
                    var end = cursor;
                    // Skip spaces
                    while (end > 0 and line.items[end - 1] == ' ') : (end -= 1) {}
                    // Skip word
                    while (end > 0 and line.items[end - 1] != ' ') : (end -= 1) {}
                    const removed = cursor - end;
                    var j: usize = 0;
                    while (j < removed) : (j += 1) {
                        _ = line.orderedRemove(end);
                    }
                    cursor = end;
                    redrawLine(line.items, cursor);
                }
            },
            else => |c| {
                // Printable characters
                if (c >= 32 and c < 127) {
                    line.insert(alloc, cursor, c) catch continue;
                    cursor += 1;
                    if (cursor == line.items.len) {
                        // Simple append: just echo the char
                        var buf: [1]u8 = .{c};
                        printStr(&buf);
                    } else {
                        // Insert: need to redraw
                        redrawLine(line.items, cursor);
                    }
                } else if (c >= 0xC0) {
                    // UTF-8 multi-byte: read remaining bytes and insert all
                    const utf8_len: usize = if (c < 0xE0) 2 else if (c < 0xF0) 3 else 4;
                    var utf8_buf: [4]u8 = .{ c, 0, 0, 0 };
                    const remaining = utf8_buf[1..utf8_len];
                    const rn = stdin.read(remaining) catch continue;
                    if (rn == utf8_len - 1) {
                        var insert_ok = true;
                        for (utf8_buf[0..utf8_len]) |ub| {
                            line.insert(alloc, cursor, ub) catch {
                                insert_ok = false;
                                break;
                            };
                            cursor += 1;
                        }
                        if (insert_ok) {
                            redrawLine(line.items, cursor);
                        }
                    }
                }
            },
        }
    }
}

fn replaceLine(line: *std.ArrayList(u8), alloc: std.mem.Allocator, new: []const u8, cursor: *usize) void {
    // Move to start of input
    if (cursor.* > 0) {
        print("\x1b[{d}D", .{cursor.*});
    }
    // Clear from cursor to end
    printStr("\x1b[K");
    // Replace content
    line.clearRetainingCapacity();
    line.appendSlice(alloc, new) catch {};
    cursor.* = new.len;
    printStr(new);
}

fn redrawLine(line: []const u8, cursor: usize) void {
    // Move to start of input
    printStr("\r" ++ Color.bold ++ Color.green ++ " > " ++ Color.reset);
    printStr(line);
    printStr("\x1b[K"); // Clear rest of line
    // Move cursor to correct position
    const chars_after = line.len - cursor;
    if (chars_after > 0) {
        print("\x1b[{d}D", .{chars_after});
    }
}

fn readSimpleLine(alloc: std.mem.Allocator) !?[]const u8 {
    const stdin = getStdin();
    var line: std.ArrayList(u8) = .empty;
    var read_buf: [256]u8 = undefined;

    while (true) {
        const n = stdin.read(&read_buf) catch |err| {
            if (err == error.BrokenPipe) return null;
            return err;
        };
        if (n == 0) {
            if (line.items.len > 0) return try line.toOwnedSlice(alloc);
            return null;
        }
        for (read_buf[0..n]) |c| {
            if (c == '\n') {
                return try line.toOwnedSlice(alloc);
            }
            if (c != '\r') {
                try line.append(alloc, c);
            }
        }
    }
}

/// Read multiline input with history support.
/// First line uses raw mode with arrow key history.
/// Empty line sends. Returns null on EOF.
pub fn readMultilineInput(alloc: std.mem.Allocator, hist: *history_mod.History) !?[]const u8 {
    // Read first line with history support
    const first_line = try readLineRaw(alloc, hist) orelse return null;

    if (first_line.len == 0) {
        alloc.free(first_line);
        return try alloc.dupe(u8, "");
    }

    var lines: std.ArrayList(u8) = .empty;
    try lines.appendSlice(alloc, first_line);
    alloc.free(first_line);

    // Read continuation lines (cooked mode, simpler)
    printContinuation();
    const stdin = getStdin();
    var read_buf: [256]u8 = undefined;
    var read_pos: usize = 0;
    var read_len: usize = 0;

    while (true) {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(alloc);

        while (true) {
            if (read_pos >= read_len) {
                read_len = stdin.read(&read_buf) catch |err| {
                    if (err == error.BrokenPipe) return try lines.toOwnedSlice(alloc);
                    return err;
                };
                read_pos = 0;
                if (read_len == 0) {
                    return try lines.toOwnedSlice(alloc);
                }
            }

            const byte = read_buf[read_pos];
            read_pos += 1;

            if (byte == '\n') break;
            if (byte == '\r') continue;
            try line.append(alloc, byte);
        }

        if (line.items.len == 0) {
            // Empty line: submit
            return try lines.toOwnedSlice(alloc);
        }

        try lines.append(alloc, '\n');
        try lines.appendSlice(alloc, line.items);
        printContinuation();
    }
}

/// Read piped input until EOF. Returns null on empty.
pub fn readPipedInput(alloc: std.mem.Allocator) !?[]const u8 {
    const stdin = getStdin();
    var buf: std.ArrayList(u8) = .empty;

    var read_buf: [4096]u8 = undefined;
    while (true) {
        const n = stdin.read(&read_buf) catch |err| {
            if (err == error.BrokenPipe) break;
            return err;
        };
        if (n == 0) break;
        try buf.appendSlice(alloc, read_buf[0..n]);
    }

    if (buf.items.len == 0) return null;
    return try buf.toOwnedSlice(alloc);
}

/// Write content to a file (for /save command)
pub fn writeFile(path: []const u8, content: []const u8) !void {
    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(content);
}
