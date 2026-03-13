const std = @import("std");
const terminal = @import("terminal.zig");
const agent_mod = @import("agent.zig");
const claude_cli = @import("claude_cli.zig");
const settings = @import("settings.zig");

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
        } else if (std.mem.eql(u8, arg, "--disallowed-tools")) {
            config.disallowed_tools = args.next();
        } else if (std.mem.eql(u8, arg, "--permission-mode")) {
            config.permission_mode = args.next();
        } else if (std.mem.eql(u8, arg, "--system-prompt")) {
            config.system_prompt = args.next();
        } else if (std.mem.eql(u8, arg, "--continue") or std.mem.eql(u8, arg, "-c")) {
            config.continue_session = true;
        } else if (std.mem.eql(u8, arg, "--effort")) {
            config.effort = args.next();
        } else if (std.mem.eql(u8, arg, "--max-budget-usd")) {
            config.max_budget_usd = args.next();
        } else if (std.mem.eql(u8, arg, "--tools")) {
            config.tools = args.next();
        } else if (std.mem.eql(u8, arg, "--add-dir")) {
            config.add_dir = args.next();
        } else if (std.mem.eql(u8, arg, "--cwd")) {
            config.cwd = args.next();
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            config.quiet = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        }
    }

    // Apply preferredLanguage from ~/.claude/settings.json
    if (config.system_prompt == null) {
        if (settings.readPreferredLanguage(alloc)) |lang| {
            config.system_prompt = std.fmt.allocPrint(alloc, "IMPORTANT: You must respond in {s}.", .{lang}) catch null;
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

    // Initialize agent
    var agent = agent_mod.Agent.init(alloc, config, &interrupted);
    g_agent = &agent;

    // Check if stdin is piped (non-interactive)
    if (!terminal.isInteractive()) {
        // Pipe mode: read all stdin, send as single message
        const input = terminal.readPipedInput(alloc) catch |err| {
            terminal.printError("Input error: {s}", .{@errorName(err)});
            return;
        } orelse {
            terminal.printError("No input received from pipe.", .{});
            return;
        };
        defer alloc.free(input);

        const trimmed = std.mem.trim(u8, input, " \t\n\r");
        if (trimmed.len == 0) return;

        agent.processUserMessage(trimmed) catch |err| {
            terminal.printError("Error: {s}", .{@errorName(err)});
        };
        agent.shutdown();
        return;
    }

    // Interactive mode
    if (!config.quiet) {
        terminal.printBanner(config.model);
    }

    // REPL loop
    while (true) {
        // Reset interrupt state for new turn
        interrupted.store(false, .release);
        g_sigint_count.store(0, .release);

        terminal.printPrompt();

        const input = terminal.readMultilineInput(alloc) catch |err| {
            terminal.printError("Input error: {s}", .{@errorName(err)});
            continue;
        } orelse break; // EOF

        defer alloc.free(input);
        const trimmed = std.mem.trim(u8, input, " \t\n\r");
        if (trimmed.len == 0) continue;

        // Built-in commands
        if (std.mem.eql(u8, trimmed, "exit") or std.mem.eql(u8, trimmed, "quit")) {
            break;
        } else if (std.mem.eql(u8, trimmed, "/help") or std.mem.eql(u8, trimmed, "?")) {
            terminal.printReplHelp();
            continue;
        } else if (std.mem.eql(u8, trimmed, "/cost")) {
            agent.printCostSummary();
            continue;
        } else if (std.mem.eql(u8, trimmed, "/session")) {
            agent.printSessionInfo();
            continue;
        } else if (std.mem.eql(u8, trimmed, "/clear")) {
            terminal.clearScreen();
            continue;
        } else if (std.mem.eql(u8, trimmed, "/retry")) {
            if (agent.getLastMessage()) |last| {
                terminal.printStr(terminal.Color.gray ++ "  Retrying last message..." ++ terminal.Color.reset ++ "\n");
                agent.processUserMessage(last) catch |err| {
                    terminal.printError("Error: {s}", .{@errorName(err)});
                };
            } else {
                terminal.printStr(terminal.Color.gray ++ "  No previous message to retry." ++ terminal.Color.reset ++ "\n");
            }
            continue;
        }

        agent.processUserMessage(trimmed) catch |err| {
            terminal.printError("Error: {s}", .{@errorName(err)});
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
        \\       echo "prompt" | lcc [options]
        \\
        \\Options:
        \\  -m, --model <name>          Model to use (passed to claude CLI)
        \\  -c, --continue              Resume most recent conversation
        \\  -q, --quiet                 Suppress startup banner
        \\  --max-turns <n>             Max agent turns per message
        \\  --effort <level>            Effort level (low, medium, high, max)
        \\  --max-budget-usd <amount>   Maximum cost limit for session
        \\  --tools <tools>             Explicitly enable tools (e.g. Bash,Edit,Read)
        \\  --allowed-tools <tools>     Comma-separated list of allowed tools
        \\  --disallowed-tools <tools>  Deny specific tools
        \\  --add-dir <dir>             Additional directory for tool access
        \\  --cwd <dir>                 Working directory for file operations
        \\  --permission-mode <mode>    Permission mode (default, plan, auto, etc.)
        \\  --system-prompt <prompt>    Append to system prompt
        \\  -h, --help                  Show this help
        \\
        \\REPL Commands:
        \\  /help, ?     Show REPL help
        \\  /cost        Show session cost summary
        \\  /session     Show session info
        \\  /clear       Clear screen
        \\  /retry       Retry last message
        \\  exit, quit   Exit LCC
        \\
        \\Pipe Mode:
        \\  Reads all stdin and sends as a single message when piped.
        \\  Example: echo "explain this code" | lcc
        \\  Example: cat file.py | lcc --system-prompt "review this code"
        \\
        \\Environment:
        \\  Requires `claude` CLI authenticated via `claude auth` or MAX subscription.
        \\
        \\Examples:
        \\  lcc
        \\  lcc --model opus
        \\  lcc --continue
        \\  lcc --effort low --max-budget-usd 1.00
        \\  lcc --max-turns 5 --permission-mode auto
        \\
    );
}
