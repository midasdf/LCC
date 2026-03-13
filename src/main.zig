const std = @import("std");
const terminal = @import("terminal.zig");
const agent_mod = @import("agent.zig");
const claude_cli = @import("claude_cli.zig");

// Module-level globals for signal handler (must be accessible from C callconv)
var g_interrupted: *std.atomic.Value(bool) = undefined;
var g_sigint_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var g_agent: ?*agent_mod.Agent = null;

fn sigintHandler(_: c_int) callconv(.c) void {
    const count = g_sigint_count.fetchAdd(1, .monotonic);
    if (count >= 1) {
        // Double Ctrl+C: force exit
        std.posix.exit(1);
    }
    g_interrupted.store(true, .release);

    // Kill child process to unblock stdout read
    if (g_agent) |agent| {
        const pid = agent.getChildPid();
        if (pid > 0) {
            std.posix.kill(pid, std.posix.SIG.TERM) catch {};
        }
    }
}

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

    // Setup signal handler
    var interrupted = std.atomic.Value(bool).init(false);
    g_interrupted = &interrupted;

    const sa = std.posix.Sigaction{
        .handler = .{ .handler = sigintHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &sa, null);

    // Print banner
    terminal.printBanner(alloc, config.model);

    // Initialize agent
    var agent = agent_mod.Agent.init(alloc, config, &interrupted);
    g_agent = &agent;

    // REPL loop
    while (true) {
        // Reset interrupt state for new turn
        interrupted.store(false, .release);
        g_sigint_count.store(0, .release);

        terminal.printPrompt();

        const input = terminal.readMultilineInput(alloc) catch |err| {
            terminal.printError(alloc, "Input error: {s}", .{@errorName(err)});
            continue;
        } orelse break; // EOF

        const trimmed = std.mem.trim(u8, input, " \t\n\r");
        if (trimmed.len == 0) continue;

        if (std.mem.eql(u8, trimmed, "exit") or std.mem.eql(u8, trimmed, "quit")) {
            break;
        }

        agent.processUserMessage(trimmed) catch |err| {
            terminal.printError(alloc, "Error: {s}", .{@errorName(err)});
        };
    }

    agent.shutdown();
    terminal.printStr(terminal.Color.gray ++ "  Goodbye!" ++ terminal.Color.reset ++ "\n\n");
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
        \\Input:
        \\  Type your message, then press Enter on an empty line to send.
        \\  Ctrl+C once to interrupt, twice to quit.
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
