# LCC — Lightweight Claude Code

[![Zig](https://img.shields.io/badge/Zig-0.15+-f7a41d?logo=zig&logoColor=white)](https://ziglang.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Linux](https://img.shields.io/badge/Platform-Linux-yellow?logo=linux&logoColor=white)](https://kernel.org)

A lightweight CLI wrapper around [Claude Code](https://docs.anthropic.com/en/docs/claude-code), written in Zig. Wraps the `claude` CLI and parses its streaming JSON output to provide a minimal, fast terminal experience. Works with Pro and Max plans.

## Why?

Claude Code's Node.js runtime uses 300-500MB+ RSS. LCC wraps it in a tiny Zig binary, auto-recycling the underlying process to keep memory in check — ideal for low-memory environments like a Raspberry Pi or small VPS.

## Features

- Wraps `claude` CLI — works with any plan (Pro/Max)
- Streaming Markdown rendering in terminal
- Full Claude Code flag passthrough (model, tools, sessions, MCP, agents, etc.)
- Auto process recycling on turn count or RSS threshold (memory management)
- Compact mode to hide tool execution details
- Input history with arrow key navigation
- Pipe mode for non-interactive use
- REPL commands (`/cost`, `/model`, `/save`, `/retry`, `/compact`, `/recycle`)
- Reads `preferredLanguage` from `~/.claude/settings.json`
- Tiny static binary (~1MB)

## Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated (`claude` in PATH)

## Build

```bash
zig build -Doptimize=ReleaseSafe
# Binary at ./zig-out/bin/lcc
```

## Usage

```bash
# Interactive REPL
lcc

# With model selection (short aliases work)
lcc --model opus
lcc -m sonnet

# Resume last session
lcc --continue

# Low-memory mode: compact output + recycle at 512MB RSS
lcc --compact --recycle-rss-mb 512

# Pipe mode
echo "explain this function" | lcc
cat main.zig | lcc --system-prompt "review this code"

# Multiple directories
lcc --add-dir ../lib --add-dir ../api

# Git worktree isolation
lcc --worktree feature-name
```

## REPL Commands

| Command | Description |
|---------|-------------|
| `/help`, `?` | Show help |
| `/cost` | Session cost summary |
| `/session` | Session info (RSS, compact status) |
| `/model <name>` | Switch model (restarts process) |
| `/save [file]` | Save last response to file |
| `/compact` | Toggle compact mode |
| `/retry` | Retry last message |
| `/recycle` | Restart claude process (frees memory) |
| `/clear` | Clear screen |
| `/version` | Show LCC version |
| `exit`, `quit` | Exit |

## LCC-specific Flags

| Flag | Description |
|------|-------------|
| `--recycle-turns <n>` | Restart claude process every N turns (default: 10) |
| `--recycle-rss-mb <mb>` | Restart when RSS exceeds threshold |
| `--compact` | Hide tool execution details |
| `--debug` | Show claude CLI stderr |
| `-q`, `--quiet` | Suppress startup banner |

All other flags are passed through to `claude` CLI directly.

## License

MIT
