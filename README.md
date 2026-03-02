# Clawmacs

**Common Lisp agent platform — OpenClaw rewrite in pure CL**

> ⚠️ Work in progress. Core platform is running; docs are being actively refreshed as naming and packaging evolve.

Clawmacs is an experimental rewrite of the [OpenClaw](https://openclaw.ai) AI agent framework entirely in Common Lisp. The goal is a libre, self-hosting, hackable agent platform with no Node.js dependency in the core runtime.

---

## Layer Architecture

| Layer | Package/System | Description |
|-------|----------------|-------------|
| 1 | **`cl-llm`** | LLM API client — OpenAI-compatible HTTP, SSE streaming, tool-call structs |
| 2a | **`cl-tui`** | ANSI terminal chat interface |
| 2b | **`clawmacs-core`** | Agent platform core — sessions, memory, tool dispatch, channels, HTTP API |
| 3 | **`clawmacs-gui`** | McCLIM GUI frontend |

---

## Repository Layout

```text
projects/
  cl-llm/         # Layer 1: LLM HTTP client
  cl-tui/         # Layer 2a: terminal chat interface
  clambda-core/   # Layer 2b+: core platform source tree
  clambda-gui/    # Layer 3: GUI source tree
  cl-term/        # terminal emulator component (separate system)
```

Notes:
- The core and GUI source directories are currently `clambda-core/` and `clambda-gui/`.
- ASDF system names remain `clawmacs-core` and `clawmacs-gui` for compatibility.

---

## Status Snapshot

- ✅ `cl-llm` running (OpenAI-compat, streaming, tool schema support)
- ✅ `clawmacs-core` loads and runs (agent loop, tools, channels, API)
- ✅ `cl-tui` loads and runs
- ✅ `clawmacs-gui` available as optional frontend
- 🔧 Ongoing refinement for docs and feature parity details

---

## Requirements

- SBCL (recommended)
- Quicklisp
- For GUI: McCLIM + CLX
- Optional browser tooling: Node.js + Playwright (used by browser integration)
- Optional OAuth CLI backends: `claude` CLI and `codex` CLI (recommended for Codex subscription bridge runtime)

## Codex OAuth (browser-link + bridge runtime)

Clawmacs supports OpenClaw-style browser-link OAuth for Codex. Runtime uses a subscription bridge path (Codex CLI transport) instead of direct OpenAI Chat Completions API billing; if unavailable, it temporarily falls back to Claude CLI with an explicit warning.
Use Telegram commands:
- `/codex_login`
- `/codex_link <redirect-url|code#state>`
- `/codex_status`
- `/models` (list grouped model options + current active model)
- `/models set <model-id>` (validated + persisted)

Stored credentials path: `~/.clawmacs/auth/codex-oauth.json` (permission `0600`).
See [Codex OAuth setup](docs/auth/codex-oauth.md) for full flow and troubleshooting.

---

## License

This program is free software: you can redistribute it and/or modify it under
the terms of the **GNU Affero General Public License** as published by the Free
Software Foundation, either version 3 of the License, or (at your option) any
later version. See [LICENSE](LICENSE) for the full text.
