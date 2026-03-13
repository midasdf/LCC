const std = @import("std");

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

fn getStdout() std.fs.File {
    return .{ .handle = std.posix.STDOUT_FILENO };
}

fn getStderr() std.fs.File {
    return .{ .handle = std.posix.STDERR_FILENO };
}

fn getStdin() std.fs.File {
    return .{ .handle = std.posix.STDIN_FILENO };
}

/// Print formatted text to stdout using a stack buffer (no heap allocation)
pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch {
        // Fallback: just write what we can
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

/// Print tool activity
pub fn printToolStart(name: []const u8) void {
    printStr(CLEAR_LINE ++ Color.cyan ++ "  > " ++ Color.bold);
    printStr(name);
    printStr(Color.reset ++ Color.gray ++ " ..." ++ Color.reset);
}

/// Print tool completion
pub fn printToolDone(name: []const u8) void {
    printStr(CLEAR_LINE ++ Color.green ++ "  > " ++ Color.reset ++ Color.dim);
    printStr(name);
    printStr(Color.reset ++ "\n");
}

/// Print the user input prompt
pub fn printPrompt() void {
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

/// Show waiting indicator
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
pub fn printBanner(model: ?[]const u8) void {
    printStr("\n");
    printStr(Color.bold ++ Color.cyan ++ "  LCC" ++ Color.reset ++ " - Lightweight Claude Code\n");
    printSeparator();
    if (model) |m| {
        print(Color.gray ++ "  model: {s}" ++ Color.reset ++ "\n", .{m});
    }
    printStr(Color.gray ++ "  Enter to send | empty line = submit | Ctrl+C = stop | exit = quit" ++ Color.reset ++ "\n");
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

/// Read multiline input. Empty line sends. Returns null on EOF.
pub fn readMultilineInput(alloc: std.mem.Allocator) !?[]const u8 {
    const stdin = getStdin();
    var lines: std.ArrayList(u8) = .empty;

    while (true) {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(alloc);

        while (true) {
            var byte: [1]u8 = undefined;
            const n = stdin.read(&byte) catch |err| {
                if (err == error.BrokenPipe) return null;
                return err;
            };
            if (n == 0) {
                if (lines.items.len > 0) return try lines.toOwnedSlice(alloc);
                return null;
            }
            if (byte[0] == '\n') break;
            if (byte[0] == '\r') continue;
            try line.append(alloc, byte[0]);
        }

        if (line.items.len == 0) {
            if (lines.items.len > 0) return try lines.toOwnedSlice(alloc);
            return try alloc.dupe(u8, "");
        }

        if (lines.items.len > 0) try lines.append(alloc, '\n');
        try lines.appendSlice(alloc, line.items);

        printContinuation();
    }
}
