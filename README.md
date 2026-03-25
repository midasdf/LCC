# LCC — Lightweight Claude Code

[![Zig](https://img.shields.io/badge/Zig-0.15+-f7a41d?logo=zig&logoColor=white)](https://ziglang.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Linux](https://img.shields.io/badge/Platform-Linux-yellow?logo=linux&logoColor=white)](https://kernel.org)

A lightweight CLI wrapper around Claude Code, written in Zig. Parses Claude Code's streaming JSON output to provide a minimal, fast terminal experience.

## Features

- Wraps `claude` CLI (Claude Code) — works with Pro/Max plans
- Streaming output with Markdown rendering
- Full Claude Code flag passthrough (model, tools, sessions, MCP, etc.)
- Agent mode with tool use
- Tiny static binary

## Usage

```bash
lcc "your prompt here"
lcc --model claude-sonnet-4-20250514 "explain this code"
lcc --continue  # resume last session
```

## Build

```bash
zig build -Doptimize=ReleaseSafe
```

## License

MIT
