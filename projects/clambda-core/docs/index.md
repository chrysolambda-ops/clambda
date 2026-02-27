# Clambda — Common Lisp Agent Platform

**Clambda** is a free, open-source AI agent platform written in pure Common Lisp.
It is a ground-up rewrite of OpenClaw in the language it was always meant to be written in.

> *"There is no language more suitable for intelligence than the language of intelligence."*

## Why Clambda?

| | OpenClaw | Clambda |
|---|---|---|
| Language | TypeScript/Node.js | Common Lisp (SBCL) |
| Config format | JSON | init.lisp (real Lisp) |
| License | Proprietary | GPL-3.0 |
| LLM backend | Cloud-first | Local-first (LM Studio, Ollama) |
| Extension model | Plugins (npm) | init.lisp + ASDF packages |
| Runtime | Node.js | SBCL (native compiled) |

Clambda is designed for users who:
- Want a **libre** agent platform with no hidden telemetry
- Prefer **Emacs-style Lisp configuration** over JSON or YAML
- Run **local LLMs** on their own hardware
- Value **hackability** — if you know Common Lisp, you can change anything

## Feature Overview

- **Multi-turn agent loop** with tool calling (exec, file ops, web fetch, TTS, browser control)
- **Telegram bot** channel with streaming partial responses
- **IRC** channel with TLS, NickServ, reconnection, flood protection
- **HTTP management API** with bearer token authentication
- **Cron scheduler** for periodic and one-shot tasks
- **Browser automation** via Playwright (headless Chromium)
- **Session persistence** — conversations survive restarts
- **Workspace memory** — SOUL.md, AGENTS.md, daily notes loaded at startup
- **Sub-agent spawning** — delegate tasks to parallel agent threads
- **Full Emacs-style configuration** — one `~/.clambda/init.lisp`, no JSON

## Quick Navigation

- [Getting Started](getting-started/README.md) — install and run your first agent
- [Installation](getting-started/installation.md) — detailed install steps
- [Configuration Guide](configuration/init-lisp.md) — init.lisp reference
- [Architecture](architecture/index.md) — how the layers fit together
- [Channels — Telegram](channels/telegram.md) — Telegram bot setup
- [Channels — IRC](channels/irc.md) — IRC connection setup
- [HTTP API Reference](api/index.md) — REST management endpoints
- [Built-in Tools](api/tools.md) — exec, read_file, web_fetch, tts, browser...
- [Custom Tools](tools/custom-tools.md) — define your own tools in init.lisp
- [Deployment](deployment/index.md) — running Clambda as a service

## Project Status

Clambda is **actively developed**. All core features are implemented and tested.
See the [ROADMAP](../ROADMAP.md) for what's complete and what's coming.

Current version: **0.8.0** (Layer 8 — Cron + Remote API)

Test suite: **235 parachute tests, 0 failures** across Telegram, IRC, Browser, Cron, Remote API.

## License

Clambda is free software: you can redistribute it and/or modify it under the terms
of the GNU General Public License as published by the Free Software Foundation,
version 3 or any later version.

Source: [chrysolambda-ops/clambda](https://github.com/chrysolambda-ops/clambda)
