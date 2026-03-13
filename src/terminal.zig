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
const HIDE_CURSOR = "\x1b[?25l";
const SHOW_CURSOR = "\x1b[?25h";

fn getStdout() std.fs.File {
    return .{ .handle = std.posix.STDOUT_FILENO };
}

fn getStderr() std.fs.File {
    return .{ .handle = std.posix.STDERR_FILENO };
}

fn getStdin() std.fs.File {
    return .{ .handle = std.posix.STDIN_FILENO };
}

pub fn print(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(alloc, fmt, args) catch return;
    _ = getStdout().write(s) catch {};
}

pub fn printStr(s: []const u8) void {
    _ = getStdout().write(s) catch {};
}

pub fn printError(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(alloc, Color.red ++ "  " ++ fmt ++ Color.reset ++ "\n", args) catch return;
    _ = getStderr().write(s) catch {};
}

/// Print a horizontal separator line
pub fn printSeparator() void {
    printStr(Color.dim ++ "─────────────────────────────────────────────────" ++ Color.reset ++ "\n");
}

/// Print tool activity with icon
pub fn printToolStart(alloc: std.mem.Allocator, name: []const u8) void {
    const s = std.fmt.allocPrint(alloc, CLEAR_LINE ++ Color.cyan ++ "  > " ++ Color.bold ++ "{s}" ++ Color.reset ++ Color.gray ++ " ..." ++ Color.reset, .{name}) catch return;
    _ = getStdout().write(s) catch {};
}

/// Print tool completion
pub fn printToolDone(alloc: std.mem.Allocator, name: []const u8) void {
    const s = std.fmt.allocPrint(alloc, CLEAR_LINE ++ Color.green ++ "  > " ++ Color.reset ++ Color.dim ++ "{s}" ++ Color.reset ++ "\n", .{name}) catch return;
    _ = getStdout().write(s) catch {};
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
pub fn printCost(alloc: std.mem.Allocator, turn_cost: f64, duration_ms: i64, total_cost: f64) void {
    const secs = @divTrunc(duration_ms, 1000);
    const ms_rem = @mod(duration_ms, 1000);
    if (total_cost > 0) {
        print(alloc, "\n" ++ Color.gray ++ "  [{d}.{d:0>3}s | ${d:.4} / ${d:.4}]" ++ Color.reset ++ "\n", .{ secs, ms_rem, turn_cost, total_cost });
    } else {
        print(alloc, "\n" ++ Color.gray ++ "  [{d}.{d:0>3}s]" ++ Color.reset ++ "\n", .{ secs, ms_rem });
    }
}

/// Print the startup banner
pub fn printBanner(alloc: std.mem.Allocator, model: ?[]const u8) void {
    printStr("\n");
    printStr(Color.bold ++ Color.cyan ++ "  LCC" ++ Color.reset ++ " - Lightweight Claude Code\n");
    printSeparator();
    if (model) |m| {
        print(alloc, Color.gray ++ "  model: {s}" ++ Color.reset ++ "\n", .{m});
    }
    printStr(Color.gray ++ "  Enter to send | empty line = submit | Ctrl+C = stop | exit = quit" ++ Color.reset ++ "\n");
    printSeparator();
}

/// Print session info when claude process starts
pub fn printSessionInfo(alloc: std.mem.Allocator, session_id: []const u8, model: []const u8) void {
    // Show abbreviated session ID
    const short_id = if (session_id.len > 8) session_id[0..8] else session_id;
    print(alloc, Color.gray ++ "  session: {s}... | model: {s}" ++ Color.reset ++ "\n", .{ short_id, model });
}

/// Print session summary on exit
pub fn printSessionSummary(alloc: std.mem.Allocator, total_cost: f64, total_duration_ms: i64) void {
    if (total_cost > 0 or total_duration_ms > 0) {
        const secs = @divTrunc(total_duration_ms, 1000);
        printSeparator();
        print(alloc, Color.gray ++ "  total: ${d:.4} | {d}s" ++ Color.reset ++ "\n", .{ total_cost, secs });
    }
}

/// Read multiline input. Empty line sends. Returns null on EOF.
pub fn readMultilineInput(alloc: std.mem.Allocator) !?[]const u8 {
    const stdin = getStdin();
    var lines: std.ArrayList(u8) = .empty;

    while (true) {
        var line: std.ArrayList(u8) = .empty;
        while (true) {
            var byte: [1]u8 = undefined;
            const n = stdin.read(&byte) catch |err| {
                if (err == error.BrokenPipe) return null;
                return err;
            };
            if (n == 0) {
                // EOF
                if (lines.items.len > 0) return try lines.toOwnedSlice(alloc);
                return null;
            }
            if (byte[0] == '\n') break;
            if (byte[0] == '\r') continue;
            try line.append(alloc, byte[0]);
        }

        if (line.items.len == 0) {
            // Empty line = send accumulated text
            if (lines.items.len > 0) return try lines.toOwnedSlice(alloc);
            return try alloc.dupe(u8, "");
        }

        // Append line
        if (lines.items.len > 0) try lines.append(alloc, '\n');
        try lines.appendSlice(alloc, line.items);

        // Show continuation prompt
        printContinuation();
    }
}
