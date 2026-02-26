# ROADMAP.md — Clambda / OpenClaw Rewrite

> What's been built, what's needed, and in what order.
> Updated after Layer 4 (team codification complete).

---

## Completed Layers

### ✅ Layer 1: `cl-llm` — LLM API Client
**Status:** Shipping. Tested with LM Studio and Ollama.

Delivers:
- OpenAI-compatible HTTP client (non-streaming and streaming)
- SSE parsing for streaming responses
- Tool definition structs and JSON serialization
- Conditions for HTTP and parse errors

Gaps/TODOs:
- No Anthropic-native API support (only OpenAI-compat)
- No retry/backoff on transient errors
- No response caching

---

### ✅ Layer 2a: `cl-tui` — Terminal Chat Interface
**Status:** Shipping. Single-threaded, streaming, slash commands.

Delivers:
- ANSI color output without dependencies
- Streaming token display (`force-output` per token)
- Slash command dispatch (`/model`, `/system`, `/clear`, `/quit`)
- Clean app state struct

Gaps/TODOs:
- No tool use (talks directly to cl-llm, not clambda-core)
- No conversation history persistence
- No multi-model routing

---

### ✅ Layer 2b: `clambda-core` — Agent Platform Core
**Status:** Shipping. Multi-turn tool-using agent loop.

Delivers:
- `agent` + `session` structs
- Tool registry with `register-tool!` + `define-tool`
- `schema-plist->ht` recursive JSON schema converter
- Built-in tools: `exec`, `read_file`, `write_file`, `list_dir`, `web_fetch`
- Hook system: `*on-tool-call*`, `*on-tool-result*`, `*on-llm-response*`, `*on-stream-delta*`
- Agent loop with configurable max-turns
- Session persistence: `save-session` / `load-session` (JSON)
- Structured logging: `clambda/logging` module, JSONL output
- Workspace memory: `clambda/memory` module, priority .md loading, context injection

Gaps/TODOs:
- No tool schema validation
- No sub-agent spawning

---

### ✅ Layer 3: `clambda-gui` — McCLIM GUI Frontend
**Status:** Shipping. Windowed chat with streaming and threading.

Delivers:
- Application frame with chat log, sidebar, status bar, command input
- Background LLM worker thread (bordeaux-threads)
- Streaming token display via hooks and `safe-redisplay`
- Command table (Send, Clear, Quit)

Gaps/TODOs:
- Single session only (no session switching)
- No sidebar model/tools info
- No font configuration (uses CLIM defaults)
- Thread safety is best-effort (`safe-redisplay`)

---

### ✅ Layer 4: Team Codification
**Status:** Complete (this commit).

Delivers:
- `TEAM.md` — operations manual
- `knowledge/cl-style-guide.md` — CL coding standards
- `knowledge/architecture.md` — system architecture doc
- `knowledge/mistakes/recent.md` — reorganized and indexed
- `ROADMAP.md` — this file
- Updated `AGENTS.md`

---

## What OpenClaw Has That Clambda Needs

Listed in priority order for the full rewrite:

### Priority 1 — Core Agent Infrastructure

#### ✅ 1.1 Session Persistence
**What:** Save/load conversation history as JSON files (one per session).
**Status:** Done. `save-session` / `load-session` in `clambda/session`.

#### ✅ 1.2 Memory System
**What:** Daily notes, knowledge base, project state — loaded at startup.
**Status:** Done. `clambda/memory` — `load-workspace-memory`, `memory-context-string`, `search-memory`.
Priority files (SOUL.md, AGENTS.md, etc.) loaded first.

#### 1.3 Skills System
**What:** Load SKILL.md files, inject tool definitions and instructions.
**Why:** OpenClaw's skill system allows capability extension without code changes.
**Approach:** `clambda/skills` — scans skills dir, loads SKILL.md, registers described tools.
**Effort:** Medium-Large (3–5 days)

---

### Priority 2 — Multi-Agent / Orchestration

#### 2.1 Sub-agent Spawning
**What:** Spawn a child agent in a new thread/process, get result back.
**Why:** OpenClaw uses subagents for delegation (coding tasks, research, etc.).
**Approach:** `clambda/subagents` — wrap `bt:make-thread` + new session + result callback.
**Effort:** Medium (2–3 days)

#### 2.2 Agent Registry
**What:** Named agents with defined capabilities and system prompts.
**Why:** Multi-agent orchestration needs a way to route tasks to the right agent.
**Approach:** Global `*agent-registry*` alist; `(find-agent :researcher)` etc.
**Effort:** Small (1 day)

---

### Priority 3 — I/O Channels

#### 3.1 Structured Output / Message Routing
**What:** Route agent output to different channels (file, socket, HTTP endpoint).
**Why:** OpenClaw has channel plugins for Discord, Telegram, webchat, etc.
**Approach:** `clambda/channels` protocol — `send-message`, `recv-message` generics.
**Effort:** Medium (2–3 days)

#### 3.2 REST API / Webhook Receiver
**What:** HTTP server that accepts inbound messages and dispatches to agent.
**Why:** Needed for channel integrations, webhooks, external triggers.
**Approach:** Use `hunchentoot` or `woo` for HTTP; route to session dispatcher.
**Effort:** Medium (2–4 days)

---

### Priority 4 — Extended Tools

#### ✅ 4.1 Web Fetch Tool
**What:** Built-in tool to fetch and extract readable content from a URL.
**Status:** Done. `web_fetch` in `clambda/builtins`. Uses dexador + cl-ppcre HTML stripping.

#### 4.2 Browser Control
**What:** Drive a headless browser (screenshots, clicks, form fills).
**Why:** OpenClaw has browser automation for web tasks.
**Approach:** Wrap `cl-selenium` or call `playwright` via shell.
**Effort:** Large (1–2 weeks)

#### 4.3 TTS Output
**What:** Text-to-speech for voice output.
**Why:** OpenClaw supports audio output channels.
**Approach:** Shell out to `espeak`/`piper`/`say`; or use a TTS API.
**Effort:** Small (1 day)

---

### Priority 5 — Production Hardening

#### 5.1 Retry / Backoff
**What:** Retry transient HTTP errors with exponential backoff.
**Approach:** Wrap `post-json` / `post-json-stream` with retry loop.
**Effort:** Small (hours)

#### 5.2 Token Budget / Turn Limits
**What:** Hard limits on tokens and turns per session.
**Approach:** Track token counts in `session`; add budget to `loop-options`.
**Effort:** Small (1 day)

#### ✅ 5.3 Structured Logging
**What:** JSON logs of all agent activity (requests, tool calls, results).
**Status:** Done. `clambda/logging` module — JSONL output, `with-logging` macro, configurable path.

---

## Known Gaps and Risks

| Gap | Risk | Mitigation |
|-----|------|-----------|
| ~~No session persistence~~ | ~~Agent loses state on restart~~ | ✅ Done: `save-session`/`load-session` |
| McCLIM thread safety | Possible redisplay race conditions | Use event queue; move to CLIM's redisplay queue |
| Tool schema not validated | LLM may call tools with wrong types | Add schema validator in tool dispatch |
| ~~`*on-stream-delta*` not re-exported~~| ~~Downstream packages break subtly~~ | ✅ Done: now exported from `clambda` |
| No error recovery in agent loop | One bad tool call can break session | Add condition-based restart in `agent-turn` |
| LM Studio models change | Hardcoded model names go stale | Store model config in workspace file |
| Guix LD_LIBRARY_PATH | Fresh shells break dexador | Add to workspace startup script |

---

## Next Immediate Tasks (Layer 5)

Suggested starting point for the full OpenClaw rewrite:

1. ✅ **Fix `*on-stream-delta*` re-export** in `clambda` package — was already done in Layer 4
2. ✅ **Session persistence** — `save-session` / `load-session` (JSON, one file per session)
3. ✅ **Memory loading** — `clambda/memory` module, `load-workspace-memory`, `memory-context-string`
4. ✅ **Web fetch builtin** — `web_fetch` in `clambda/builtins` (dexador + cl-ppcre HTML stripping)
5. ✅ **Structured logging** — `clambda/logging` module, JSONL to configurable file, `with-logging` macro
6. **Sub-agent spawning** — first cut (2 days) ← NEXT

Completing these would make Clambda functionally comparable to the core of OpenClaw,
minus channel plugins and browser control.
