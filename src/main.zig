const std = @import("std");
const terminal = @import("terminal.zig");
const agent_mod = @import("agent.zig");
const claude_cli = @import("claude_cli.zig");

pub fn main() !void {
    const alloc = std.heap.smp_allocator;

    // Parse args
    var args = std.process.args();
    _ = args.next(); // skip program name

    var config: claude_cli.Config = .{};

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            config.model = args.next();
        } else if (std.mem.eql(u8, arg, "--max-turns")) {
            if (args.next()) |t| {
                config.max_turns = std.fmt.parseInt(u32, t, 10) catch null;
            }
        } else if (std.mem.eql(u8, arg, "--allowed-tools")) {
            config.allowed_tools = args.next();
        } else if (std.mem.eql(u8, arg, "--permission-mode")) {
            config.permission_mode = args.next();
        } else if (std.mem.eql(u8, arg, "--system-prompt")) {
            config.system_prompt = args.next();
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        }
    }

    // Print banner
    terminal.print(alloc, terminal.Color.bold ++ terminal.Color.cyan ++ "LCC" ++ terminal.Color.reset ++ " - Lightweight Claude Code Wrapper\n", .{});
    if (config.model) |m| {
        terminal.print(alloc, terminal.Color.gray ++ "Model: {s}" ++ terminal.Color.reset ++ "\n", .{m});
    }
    terminal.print(alloc, terminal.Color.gray ++ "Type your message. Press Enter to send. Type 'exit' to quit." ++ terminal.Color.reset ++ "\n", .{});

    // Initialize agent
    var agent = agent_mod.Agent.init(alloc, config);

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

fn printHelp() void {
    terminal.printStr(
        \\LCC - Lightweight Claude Code Wrapper
        \\
        \\A thin Zig wrapper around the `claude` CLI for low-memory environments.
        \\Requires `claude` CLI to be installed and authenticated.
        \\
        \\Usage: lcc [options]
        \\
        \\Options:
        \\  -m, --model <name>          Model to use (passed to claude CLI)
        \\  --max-turns <n>             Max agent turns per message
        \\  --allowed-tools <tools>     Comma-separated list of allowed tools
        \\  --permission-mode <mode>    Permission mode (default, plan, auto, etc.)
        \\  --system-prompt <prompt>    Append to system prompt
        \\  -h, --help                  Show this help
        \\
        \\Environment:
        \\  Requires `claude` CLI authenticated via `claude auth` or MAX subscription.
        \\
        \\Examples:
        \\  lcc
        \\  lcc --model opus
        \\  lcc --max-turns 5
        \\  lcc --permission-mode auto
        \\
    );
}
