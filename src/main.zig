const std = @import("std");
const terminal = @import("terminal.zig");
const agent_mod = @import("agent.zig");
const claude_cli = @import("claude_cli.zig");
const settings = @import("settings.zig");
const history_mod = @import("history.zig");

const version = "0.3.0";

// Module-level globals for signal handler (must be accessible from C callconv)
var g_interrupted: *std.atomic.Value(bool) = undefined;
var g_sigint_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
// Atomic PID for signal-safe child process termination (avoids data race on Agent struct)
var g_child_pid: std.atomic.Value(i32) = std.atomic.Value(i32).init(0);

fn sigintHandler(_: c_int) callconv(.c) void {
    const count = g_sigint_count.fetchAdd(1, .monotonic);
    if (count >= 1) {
        std.posix.exit(1);
    }
    g_interrupted.store(true, .release);

    // Kill child process using atomic PID (signal-safe)
    const pid = g_child_pid.load(.acquire);
    if (pid > 0) {
        std.posix.kill(pid, std.posix.SIG.TERM) catch {};
    }
}

pub fn main() !void {
    const alloc = std.heap.smp_allocator;

    // Parse args — collect into slice for index-based access
    var raw_args = std.process.args();
    _ = raw_args.next(); // skip program name

    var arg_list: std.ArrayList([]const u8) = .empty;
    while (raw_args.next()) |a| {
        try arg_list.append(alloc, a);
    }
    const argv = arg_list.items;

    var config: claude_cli.Config = .{};
    var extra_args_list: std.ArrayList([]const u8) = .empty;
    var add_dirs_list: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;

    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
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
            if (next_val) |d| {
                try add_dirs_list.append(alloc, d);
                i += 1;
            }
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
            if (next_val) |next| {
                if (std.mem.startsWith(u8, next, "-")) {
                    config.worktree = "";
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
        } else if (std.mem.eql(u8, arg, "--recycle-rss-mb")) {
            if (next_val) |t| {
                config.recycle_rss_mb = std.fmt.parseInt(u32, t, 10) catch null;
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--compact")) {
            config.compact = true;
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
            if (next_val) |next| {
                if (!std.mem.startsWith(u8, next, "-")) {
                    try extra_args_list.append(alloc, next);
                    i += 1;
                }
            }
        }
    }

    // Store accumulated lists
    if (extra_args_list.items.len > 0) {
        config.extra_args = try extra_args_list.toOwnedSlice(alloc);
    }
    if (add_dirs_list.items.len > 0) {
        config.add_dirs = try add_dirs_list.toOwnedSlice(alloc);
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
    var agent = agent_mod.Agent.init(alloc, config, &interrupted, &g_child_pid);

    // Load input history
    var history_path_buf: [256]u8 = undefined;
    var history_path: ?[]const u8 = null;
    if (std.posix.getenv("HOME")) |home| {
        history_path = std.fmt.bufPrint(&history_path_buf, "{s}/.lcc_history", .{home}) catch null;
    }
    var hist = history_mod.History.init(alloc);
    defer hist.deinit();
    if (history_path) |hp| hist.load(hp);

    // Check if stdin is piped (non-interactive)
    if (!terminal.isInteractive()) {
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
        interrupted.store(false, .release);
        g_sigint_count.store(0, .release);

        terminal.printPrompt();

        const input = terminal.readMultilineInput(alloc, &hist) catch |err| {
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
        } else if (std.mem.eql(u8, trimmed, "/compact")) {
            agent.toggleCompact();
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
        } else if (std.mem.startsWith(u8, trimmed, "/model")) {
            // /model <name>
            const rest = std.mem.trim(u8, trimmed[6..], " ");
            if (rest.len > 0) {
                agent.setModel(rest);
            } else {
                if (agent.config.model) |m| {
                    terminal.print(terminal.Color.gray ++ "  Current model: {s}" ++ terminal.Color.reset ++ "\n", .{m});
                } else {
                    terminal.printStr(terminal.Color.gray ++ "  No model set (using default)." ++ terminal.Color.reset ++ "\n");
                }
                terminal.printStr(terminal.Color.gray ++ "  Usage: /model <name>  (e.g. /model opus)" ++ terminal.Color.reset ++ "\n");
            }
            continue;
        } else if (std.mem.startsWith(u8, trimmed, "/save")) {
            // /save [filename]
            if (agent.getLastResponse()) |resp| {
                const rest = std.mem.trim(u8, trimmed[5..], " ");
                const filename = if (rest.len > 0) rest else "lcc-response.md";

                // Resolve to absolute path
                var cwd_buf: [512]u8 = undefined;
                var path_buf: [1024]u8 = undefined;
                const save_path = if (std.fs.path.isAbsolute(filename))
                    filename
                else blk: {
                    const cwd = std.process.getCwd(&cwd_buf) catch {
                        terminal.printError("Could not get cwd", .{});
                        continue;
                    };
                    break :blk std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ cwd, filename }) catch {
                        terminal.printError("Path too long", .{});
                        continue;
                    };
                };

                terminal.writeFile(save_path, resp) catch |err| {
                    terminal.printError("Failed to save: {s}", .{@errorName(err)});
                    continue;
                };
                terminal.print(terminal.Color.green ++ "  Saved to: {s}" ++ terminal.Color.reset ++ "\n", .{save_path});
            } else {
                terminal.printStr(terminal.Color.gray ++ "  No response to save yet." ++ terminal.Color.reset ++ "\n");
            }
            continue;
        }

        // Add to history and send
        hist.add(trimmed);
        agent.processUserMessage(trimmed) catch |err| {
            terminal.printError("Error: {s}", .{@errorName(err)});
        };
    }

    // Save history
    if (history_path) |hp| hist.save(hp);

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
        \\  --add-dir <dir>             Additional directory (can be repeated)
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
        \\  --recycle-turns <n>         Restart process every N turns (default: 10)
        \\  --recycle-rss-mb <mb>       Restart when RSS exceeds threshold (MB)
        \\  --compact                   Hide tool execution details
        \\  --debug                     Show claude CLI stderr output
        \\  -q, --quiet                 Suppress startup banner
        \\  -v, --version               Show LCC version
        \\  -h, --help                  Show this help
        \\
        \\  Unknown flags are passed through to claude CLI directly.
        \\
        \\REPL Commands:
        \\  /help, ?            Show REPL help
        \\  /cost               Show session cost summary
        \\  /session            Show session info (+ RSS, compact status)
        \\  /model <name>       Switch model (restarts process)
        \\  /save [file]        Save last response to file
        \\  /compact            Toggle compact mode (hide tool details)
        \\  /clear              Clear screen
        \\  /retry              Retry last message
        \\  /recycle            Restart claude process (frees memory)
        \\  /version            Show LCC version
        \\  exit, quit          Exit LCC
        \\
        \\  Up/Down arrows browse input history (~/.lcc_history).
        \\
        \\Pipe Mode:
        \\  echo "explain this code" | lcc
        \\  cat file.py | lcc --system-prompt "review this code"
        \\
        \\Examples:
        \\  lcc                                    Interactive mode
        \\  lcc --model opus                       Use Opus model
        \\  lcc --continue                         Resume last session
        \\  lcc --add-dir ../lib --add-dir ../api  Multiple directories
        \\  lcc --compact --recycle-rss-mb 512     Low-memory mode
        \\  lcc --agent reviewer -n "code review"  Named agent session
        \\
    );
}
