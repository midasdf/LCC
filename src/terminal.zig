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
};

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
    const s = std.fmt.allocPrint(alloc, Color.red ++ fmt ++ Color.reset ++ "\n", args) catch return;
    _ = getStderr().write(s) catch {};
}

pub fn printTool(alloc: std.mem.Allocator, name: []const u8, detail: []const u8) void {
    const s = std.fmt.allocPrint(alloc, Color.dim ++ Color.cyan ++ "[tool]" ++ Color.reset ++ " " ++ Color.bold ++ "{s}" ++ Color.reset ++ ": {s}\n", .{ name, detail }) catch return;
    _ = getStdout().write(s) catch {};
}

pub fn printPrompt() void {
    printStr("\n" ++ Color.bold ++ Color.green ++ "> " ++ Color.reset);
}

pub fn printStreaming(text: []const u8) void {
    printStr(text);
}

pub fn printCost(alloc: std.mem.Allocator, turn_cost: f64, duration_ms: i64, total_cost: f64) void {
    print(alloc, "\n" ++ Color.gray ++ "[{d}ms | ${d:.4} turn | ${d:.4} session]" ++ Color.reset, .{ duration_ms, turn_cost, total_cost });
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
        printStr(Color.dim ++ ". " ++ Color.reset);
    }
}

/// Read a single line of input from stdin (kept for compatibility).
pub fn readInput(alloc: std.mem.Allocator) !?[]const u8 {
    const stdin = getStdin();
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(alloc);

    while (true) {
        var byte: [1]u8 = undefined;
        const n = stdin.read(&byte) catch |err| {
            if (err == error.BrokenPipe) return null;
            return err;
        };
        if (n == 0) {
            // EOF
            if (line.items.len > 0) return try line.toOwnedSlice(alloc);
            return null;
        }
        if (byte[0] == '\n') break;
        if (byte[0] == '\r') continue;
        try line.append(alloc, byte[0]);
    }

    if (line.items.len == 0) return try alloc.dupe(u8, "");
    return try line.toOwnedSlice(alloc);
}
