# Clambda

**Common Lisp agent platform — OpenClaw rewrite in pure CL**

> ⚠️ Work in progress. Layers 1–6a complete; full feature parity with OpenClaw is ongoing.

Clambda is an experimental rewrite of the [OpenClaw](https://openclaw.ai) AI agent framework entirely in Common Lisp. The goal is a libre, self-hosting, hackable agent platform with no Node.js dependency.

---

## Layer Architecture

| Layer | Package | Description |
|-------|---------|-------------|
| 1 | **`cl-llm`** | LLM API client — OpenAI-compatible HTTP, SSE streaming, tool-call structs |
| 2a | **`cl-tui`** | ANSI terminal chat interface — streaming output, slash commands |
| 2b | **`clambda-core`** | Agent platform core — session management, memory, tool dispatch, multi-agent orchestration, HTTP API, IRC/Telegram channels |
| 3 | **`clambda-gui`** | McCLIM GUI frontend — graphical chat interface built on top of clambda-core |

---

## Sub-projects

```
projects/
  cl-llm/          # Layer 1: LLM HTTP client
  cl-tui/          # Layer 2a: Terminal UI
  clambda-core/    # Layer 2b–6+: Agent core platform
  clambda-gui/     # Layer 3: McCLIM GUI
```

Each sub-project is an ASDF system with its own `.asd` file and `src/` / `t/` tree.

---

## Status

- ✅ Layer 1 — `cl-llm`: LLM API client (OpenAI-compat, streaming, tool defs)
- ✅ Layer 2a — `cl-tui`: Terminal chat interface
- ✅ Layer 2b–5 — `clambda-core`: Agent architecture, memory, tools, HTTP API, multi-agent, IRC/Telegram
- ✅ Layer 6a — Emacs-style configuration system
- 🔧 Anthropic-native API support (pending)
- 🔧 Full OpenClaw feature parity (ongoing)

---

## Requirements

- SBCL (recommended) or another CL implementation
- Quicklisp
- For `clambda-gui`: McCLIM + CLX

---

## License

This program is free software: you can redistribute it and/or modify it under
the terms of the **GNU Affero General Public License** as published by the Free
Software Foundation, either version 3 of the License, or (at your option) any
later version. See [LICENSE](LICENSE) for the full text.
