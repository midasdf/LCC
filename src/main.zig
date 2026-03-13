const std = @import("std");
const terminal = @import("terminal.zig");
const agent_mod = @import("agent.zig");

pub fn main() !void {
    const alloc = std.heap.smp_allocator;

    // Parse args first (--help doesn't need API key)
    var args = std.process.args();
    _ = args.next(); // skip program name

    var model: []const u8 = "claude-opus-4-6";
    var max_tokens: u32 = 16384;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            if (args.next()) |m| model = m;
        } else if (std.mem.eql(u8, arg, "--max-tokens") or std.mem.eql(u8, arg, "-t")) {
            if (args.next()) |t| {
                max_tokens = std.fmt.parseInt(u32, t, 10) catch 16384;
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp(alloc);
            return;
        }
    }

    // Get API key
    const api_key = std.posix.getenv("ANTHROPIC_API_KEY") orelse {
        terminal.printError(alloc, "ANTHROPIC_API_KEY environment variable not set", .{});
        return;
    };

    // Print banner
    terminal.print(alloc, terminal.Color.bold ++ terminal.Color.cyan ++ "LCC" ++ terminal.Color.reset ++ " - Lightweight Claude Code\n", .{});
    terminal.print(alloc, terminal.Color.gray ++ "Model: {s} | Max tokens: {d}" ++ terminal.Color.reset ++ "\n", .{ model, max_tokens });
    terminal.print(alloc, terminal.Color.gray ++ "Type your message. Press Enter to send. Type 'exit' to quit." ++ terminal.Color.reset ++ "\n", .{});

    // Initialize agent
    var agent = try agent_mod.Agent.init(alloc, api_key, model, max_tokens);

    // REPL loop
    while (true) {
        terminal.printPrompt();

        const input = terminal.readInput(alloc) catch |err| {
            terminal.printError(alloc, "Input error: {s}", .{@errorName(err)});
            continue;
        } orelse break; // EOF

        if (input.len == 0) continue;

        if (std.mem.eql(u8, input, "exit") or std.mem.eql(u8, input, "quit")) {
            terminal.print(alloc, terminal.Color.gray ++ "Goodbye!" ++ terminal.Color.reset ++ "\n", .{});
            break;
        }

        try agent.processUserMessage(input);
    }
}

fn printHelp(alloc: std.mem.Allocator) void {
    terminal.printStr(
        \\LCC - Lightweight Claude Code
        \\
        \\Usage: lcc [options]
        \\
        \\Options:
        \\  -m, --model <name>      Model to use (default: claude-opus-4-6)
        \\  -t, --max-tokens <n>    Max response tokens (default: 16384)
        \\  -h, --help              Show this help
        \\
        \\Environment:
        \\  ANTHROPIC_API_KEY       Required. Your Anthropic API key.
        \\
        \\Examples:
        \\  ANTHROPIC_API_KEY=sk-... lcc
        \\  lcc --model claude-sonnet-4-6
        \\  lcc --max-tokens 32768
        \\
    );
    _ = alloc;
}
