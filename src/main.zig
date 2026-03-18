const std = @import("std");
const terminal = @import("terminal.zig");
const agent_mod = @import("agent.zig");
const claude_cli = @import("claude_cli.zig");
const settings = @import("settings.zig");

const version = "0.2.0";

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

    // Parse args — collect into slice first for index-based access (needed for peek/lookahead)
    var raw_args = std.process.args();
    _ = raw_args.next(); // skip program name

    var arg_list: std.ArrayList([]const u8) = .empty;
    while (raw_args.next()) |a| {
        try arg_list.append(alloc, a);
    }
    const argv = arg_list.items;

    var config: claude_cli.Config = .{};
    var extra_args_list: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;

    while (i < argv.len) : (i += 1) {
        const arg = argv[i];

        // Helper: consume next arg as value
        const next_val: ?[]const u8 = if (i + 1 < argv.len) argv[i + 1] else null;

        // --- Model & behavior ---
        if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            config.model = next_val;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--fallback-model")) {
            config.fallback_model = next_val;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--effort")) {
            config.effort = next_val;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--max-turns")) {
            if (next_val) |t| {
                config.max_turns = std.fmt.parseInt(u32, t, 10) catch null;
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--max-budget-usd")) {
            config.max_budget_usd = next_val;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--permission-mode")) {
            config.permission_mode = next_val;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--json-schema")) {
            config.json_schema = next_val;
            i += 1;

            // --- Session management ---
        } else if (std.mem.eql(u8, arg, "--continue") or std.mem.eql(u8, arg, "-c")) {
            config.continue_session = true;
        } else if (std.mem.eql(u8, arg, "--resume") or std.mem.eql(u8, arg, "-r")) {
            config.resume_session_id = next_val;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--session-id")) {
            config.session_id = next_val;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--fork-session")) {
            config.fork_session = true;
        } else if (std.mem.eql(u8, arg, "--name") or std.mem.eql(u8, arg, "-n")) {
            config.session_name = next_val;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--no-session-persistence")) {
            config.no_session_persistence = true;

            // --- System prompt ---
        } else if (std.mem.eql(u8, arg, "--system-prompt")) {
            config.system_prompt = next_val;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--append-system-prompt")) {
            config.append_system_prompt = next_val;
            i += 1;

            // --- Tools ---
        } else if (std.mem.eql(u8, arg, "--tools")) {
            config.tools = next_val;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--allowed-tools") or std.mem.eql(u8, arg, "--allowedTools")) {
            config.allowed_tools = next_val;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--disallowed-tools") or std.mem.eql(u8, arg, "--disallowedTools")) {
            config.disallowed_tools = next_val;
            i += 1;

            // --- Directories & files ---
        } else if (std.mem.eql(u8, arg, "--add-dir")) {
            config.add_dir = next_val;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--cwd")) {
            config.cwd = next_val;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--file")) {
            config.file = next_val;
            i += 1;

            // --- Agents ---
        } else if (std.mem.eql(u8, arg, "--agent")) {
            config.agent = next_val;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--agents")) {
            config.agents = next_val;
            i += 1;

            // --- MCP ---
        } else if (std.mem.eql(u8, arg, "--mcp-config")) {
            config.mcp_config = next_val;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--strict-mcp-config")) {
            config.strict_mcp_config = true;

            // --- Plugins & settings ---
        } else if (std.mem.eql(u8, arg, "--plugin-dir")) {
            config.plugin_dir = next_val;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--settings")) {
            config.settings = next_val;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--setting-sources")) {
            config.setting_sources = next_val;
            i += 1;

            // --- Permissions ---
        } else if (std.mem.eql(u8, arg, "--dangerously-skip-permissions")) {
            config.dangerously_skip_permissions = true;
        } else if (std.mem.eql(u8, arg, "--allow-dangerously-skip-permissions")) {
            config.allow_dangerously_skip_permissions = true;

            // --- Beta & debug ---
        } else if (std.mem.eql(u8, arg, "--betas")) {
            config.betas = next_val;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--no-verbose")) {
            config.verbose = false;

            // --- Worktree ---
        } else if (std.mem.eql(u8, arg, "--worktree") or std.mem.eql(u8, arg, "-w")) {
            // Optional value: peek at next arg without consuming if it's a flag
            if (next_val) |next| {
                if (std.mem.startsWith(u8, next, "-")) {
                    config.worktree = ""; // auto-name
                } else {
                    config.worktree = next;
                    i += 1;
                }
            } else {
                config.worktree = "";
            }

            // --- LCC-specific ---
        } else if (std.mem.eql(u8, arg, "--recycle-turns")) {
            if (next_val) |t| {
                config.recycle_turns = std.fmt.parseInt(u32, t, 10) catch null;
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            config.quiet = true;
        } else if (std.mem.eql(u8, arg, "--debug")) {
            config.debug = true;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            terminal.print("lcc {s}\n", .{version});
            return;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            // Unknown flag: pass through to claude CLI
            try extra_args_list.append(alloc, arg);
            // Peek: if next arg exists and doesn't look like a flag, treat as value
            if (next_val) |next| {
                if (!std.mem.startsWith(u8, next, "-")) {
                    try extra_args_list.append(alloc, next);
                    i += 1;
                }
                // If next starts with -, don't consume it — loop will handle it
            }
        }
    }

    // Store extra args if any
    if (extra_args_list.items.len > 0) {
        config.extra_args = try extra_args_list.toOwnedSlice(alloc);
    }

    // Apply preferredLanguage from ~/.claude/settings.json
    if (config.system_prompt == null and config.append_system_prompt == null) {
        if (settings.readPreferredLanguage(alloc)) |lang| {
            config.append_system_prompt = std.fmt.allocPrint(alloc, "IMPORTANT: You must respond in {s}.", .{lang}) catch null;
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
        terminal.printBanner(config.model, config.session_name);
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
        } else if (std.mem.eql(u8, trimmed, "/recycle")) {
            if (agent.session_id != null) {
                agent.recycleProcess();
            } else {
                terminal.printStr(terminal.Color.gray ++ "  No active session to recycle." ++ terminal.Color.reset ++ "\n");
            }
            continue;
        } else if (std.mem.eql(u8, trimmed, "/version")) {
            terminal.print(terminal.Color.gray ++ "  lcc {s}" ++ terminal.Color.reset ++ "\n", .{version});
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
        \\Model & Behavior:
        \\  -m, --model <name>          Model to use (e.g. opus, sonnet, haiku)
        \\  --fallback-model <name>     Fallback model when default is overloaded
        \\  --effort <level>            Effort level (low, medium, high, max)
        \\  --max-turns <n>             Max agent turns per message
        \\  --max-budget-usd <amount>   Maximum cost limit for session
        \\  --permission-mode <mode>    Permission mode (default, plan, auto, etc.)
        \\  --json-schema <schema>      JSON Schema for structured output
        \\
        \\Session:
        \\  -c, --continue              Resume most recent conversation
        \\  -r, --resume <id>           Resume conversation by session ID
        \\  --session-id <uuid>         Use a specific session UUID
        \\  --fork-session              Create new session ID when resuming
        \\  -n, --name <name>           Set session display name
        \\  --no-session-persistence    Don't save session to disk
        \\
        \\System Prompt:
        \\  --system-prompt <prompt>    Replace default system prompt
        \\  --append-system-prompt <p>  Append to default system prompt
        \\
        \\Tools:
        \\  --tools <tools>             Set available tools (e.g. Bash,Edit,Read)
        \\  --allowed-tools <tools>     Allow specific tools (e.g. "Bash(git:*) Edit")
        \\  --disallowed-tools <tools>  Deny specific tools
        \\
        \\Directories & Files:
        \\  --add-dir <dir>             Additional directory for tool access
        \\  --cwd <dir>                 Working directory for file operations
        \\  --file <spec>               File resource (format: file_id:path)
        \\
        \\Agents:
        \\  --agent <agent>             Agent for the session
        \\  --agents <json>             JSON defining custom agents
        \\
        \\MCP:
        \\  --mcp-config <config>       Load MCP servers from JSON file/string
        \\  --strict-mcp-config         Only use MCP servers from --mcp-config
        \\
        \\Plugins & Settings:
        \\  --plugin-dir <path>         Load plugins from directory
        \\  --settings <file-or-json>   Additional settings file/JSON
        \\  --setting-sources <sources> Setting sources to load (user,project,local)
        \\
        \\Permissions:
        \\  --dangerously-skip-permissions  Bypass all permission checks
        \\  --allow-dangerously-skip-permissions  Enable bypass as option
        \\
        \\Advanced:
        \\  --betas <betas>             Beta headers for API requests
        \\  --no-verbose                Disable verbose mode (default: on)
        \\  -w, --worktree [name]       Create git worktree for session
        \\
        \\LCC-specific:
        \\  --recycle-turns <n>         Restart claude process every N turns (default: 10)
        \\  --debug                     Show claude CLI stderr output
        \\  -q, --quiet                 Suppress startup banner
        \\  -v, --version               Show LCC version
        \\  -h, --help                  Show this help
        \\
        \\  Unknown flags are passed through to claude CLI directly.
        \\
        \\REPL Commands:
        \\  /help, ?       Show REPL help
        \\  /cost          Show session cost summary
        \\  /session       Show session info (+ claude RSS memory)
        \\  /clear         Clear screen
        \\  /retry         Retry last message
        \\  /recycle       Restart claude process (frees memory)
        \\  /version       Show LCC version
        \\  exit, quit     Exit LCC
        \\
        \\Pipe Mode:
        \\  Reads all stdin and sends as a single message when piped.
        \\  Example: echo "explain this code" | lcc
        \\  Example: cat file.py | lcc --system-prompt "review this code"
        \\  Example: echo "fix bugs" | lcc --json-schema '{"type":"object"}'
        \\
        \\Environment:
        \\  Requires `claude` CLI authenticated via `claude auth` or MAX subscription.
        \\
        \\Examples:
        \\  lcc                                    Interactive mode
        \\  lcc --model opus                       Use Opus model
        \\  lcc --continue                         Resume last session
        \\  lcc -r abc123                          Resume specific session
        \\  lcc -n "refactor"                      Named session
        \\  lcc --agent reviewer                   Use specific agent
        \\  lcc --mcp-config servers.json          With MCP servers
        \\  lcc --effort max --recycle-turns 5     High effort, frequent recycle
        \\  lcc --permission-mode auto             Auto-approve permissions
        \\
    );
}
