# LCC — Lightweight Claude Code

[![Zig](https://img.shields.io/badge/Zig-0.15+-f7a41d?logo=zig&logoColor=white)](https://ziglang.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Linux](https://img.shields.io/badge/Platform-Linux-yellow?logo=linux&logoColor=white)](https://kernel.org)

A minimal Claude API client written in Zig. Lightweight alternative to the official Claude Code CLI.

## Features

- Direct Claude API integration (streaming)
- Agent mode with tool use
- Model selection (`--model`)
- Configurable system prompts
- Tiny static binary

## Usage

```bash
export ANTHROPIC_API_KEY=sk-...
lcc "your prompt here"
lcc --model claude-sonnet-4-20250514 "explain this code"
```

## Build

```bash
zig build -Doptimize=ReleaseSafe
```

## License

MIT
