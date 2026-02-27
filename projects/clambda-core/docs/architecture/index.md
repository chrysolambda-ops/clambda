# Architecture Overview

Clambda is built in layers. Each layer builds on the one below it. You can use
any layer in isolation.

## System Dependency Graph

```
                    clambda-gui (Layer 3)
                         │
                         │ :depends-on
                         ▼
                  clambda-core (Layer 2b)
                         │
              ┌──────────┴───────────┐
              │                      │
              ▼                      │
           cl-llm (Layer 1)          cl-tui (Layer 2a, standalone)
              │
              ▼
      Quicklisp libraries:
      dexador, jzon,
      alexandria, cl-ppcre,
      usocket, cl+ssl,
      hunchentoot, parachute
```

**Build order:** `cl-llm` → `cl-tui` (standalone) | `clambda-core` → `clambda-gui`

---

## Layer 1: cl-llm — LLM API Client

**Purpose:** Talk to any OpenAI-compatible API (LM Studio, Ollama, OpenRouter).

**Key capabilities:**
- Non-streaming chat (`cl-llm:chat`)
- Streaming SSE chat (`cl-llm:chat-stream`)
- Tool definitions (JSON schema format)
- Automatic retry with exponential backoff (3 retries, 1/2/4s)
- Supports: LM Studio, Ollama (v1 endpoint), OpenRouter, any OpenAI-compat server

**Main entry points:**

```lisp
;; Create a client
(cl-llm:make-client
  :base-url "http://192.168.1.189:1234/v1"
  :api-key  "lmstudio"
  :model    "google/gemma-3-4b")

;; Non-streaming: returns full response string
(cl-llm:chat client messages)

;; Streaming: calls callback per token, returns full string
(cl-llm:chat-stream client messages
                    (lambda (delta) (write-string delta) (force-output)))
```

---

## Layer 2a: cl-tui — Terminal Chat UI

**Purpose:** A simple ANSI terminal chat interface using `cl-llm`. Standalone.

```lisp
(cl-tui:run :model "google/gemma-3-4b")
```

Slash commands: `/model`, `/system`, `/clear`, `/quit`

Single-threaded. Does not use clambda-core (direct `cl-llm` usage).

---

## Layer 2b: clambda-core — Agent Platform

**Purpose:** The core agent platform. Multi-turn tool-calling agent loop, channels,
session persistence, memory loading, sub-agents.

### Sub-modules

| Module | Purpose |
|--------|---------|
| `clambda/agent` | `agent` struct: name, client, tool-registry, system-prompt |
| `clambda/session` | `session` struct: agent + message history + token tracking |
| `clambda/tools` | Tool registry, `register-tool!`, `define-tool` macro |
| `clambda/builtins` | Built-in tools: exec, read_file, write_file, list_dir, web_fetch, tts |
| `clambda/loop` | `run-agent`, `agent-turn`, hook variables |
| `clambda/conditions` | `tool-error`, `agent-error`, `budget-exceeded` |
| `clambda/logging` | JSONL structured logging, `with-logging` macro |
| `clambda/session` | Save/load session as JSON (one file per conversation) |
| `clambda/memory` | Load workspace memory files at startup (SOUL.md, AGENTS.md, etc.) |
| `clambda/registry` | Named agent registry (`define-agent`, `find-agent`) |
| `clambda/subagents` | Spawn parallel agent threads (`spawn-subagent`, `subagent-wait`) |
| `clambda/channels` | Abstract channel protocol (repl, queue channels) |
| `clambda/http-server` | Hunchentoot HTTP management API |
| `clambda/config` | Emacs-style config system (init.lisp, defoption, hooks) |
| `clambda/telegram` | Telegram Bot API long-polling channel |
| `clambda/irc` | Raw IRC client with TLS, NickServ, flood protection, reconnect |
| `clambda/browser` | Playwright-backed browser control |
| `clambda/cron` | Thread-based periodic/one-shot task scheduler |

### Agent Loop Flow

```
run-agent session user-message
  │
  ├── add user message to session history
  │
  └── loop (up to max-turns):
        agent-turn
          │
          ├── *before-agent-turn-hook* fires
          │
          ├── cl-llm:chat (or :chat-stream) with tool definitions
          │     └── returns (text tool-calls usage-data)
          │
          ├── if no tool-calls → return text (done)
          │
          └── for each tool-call:
                *on-tool-call* hook fires
                execute tool from registry
                *on-tool-result* hook fires
                *after-tool-call-hook* fires
                add tool-result to session history
                → loop again
```

### Hook System

```lisp
;; Available hook variables:
clambda/config:*after-init-hook*         ; () → runs after init.lisp loads
clambda/config:*before-agent-turn-hook*  ; (session msg) → before each turn
clambda/config:*after-tool-call-hook*    ; (tool-name result) → after tool runs
clambda/config:*channel-message-hook*    ; (channel msg) → inbound channel message

;; Loop hooks (on the agent loop directly):
clambda/loop:*on-stream-delta*   ; (delta) → per streaming token
clambda/loop:*on-tool-call*      ; (name call) → tool invocation
clambda/loop:*on-tool-result*    ; (name result) → tool result
clambda/loop:*on-llm-response*   ; (text) → final LLM response
```

---

## Layer 3: clambda-gui — McCLIM Graphical Frontend

**Purpose:** A native windowed chat interface using McCLIM (the free Common Lisp
GUI framework). Optional — Clambda works fine without it.

```lisp
(ql:quickload :clambda-gui)
(clambda-gui:run-gui :session my-session)
```

The GUI uses a background `bordeaux-threads` worker for LLM calls so the
interface stays responsive during streaming.

---

## Data Flow: Message to Response

### In Telegram channel

```
User sends Telegram message
  │
  └── clambda/telegram: polling thread receives update
        │
        ├── check allowed-users allowlist
        │
        └── find-or-create-session (per chat-id)
              │
              └── run-agent session message-text
                    │
                    ├── [if streaming] send "..." placeholder; editMessageText per debounce
                    │
                    └── final text → sendMessage (or editMessageText)
```

### In IRC channel

```
IRC server sends PRIVMSG
  │
  └── clambda/irc: reader-thread receives line
        │
        ├── parse-irc-line → command="PRIVMSG"
        │
        ├── check trigger (nick mention in channel, or any message in DM)
        │
        ├── check allowed-users (global or per-channel policy)
        │
        └── bt:make-thread → %route-message
              │
              └── find-or-create-session (per reply-target)
                    │
                    └── run-agent session message-text
                          │
                          └── irc-send-privmsg (splits at 400 chars, flood-throttled)
```

---

## Extension Points

### Add new tools

```lisp
;; In init.lisp:
(define-user-tool my-tool
  :description "..."
  :parameters  '((:name "param" :type "string" :description "..."))
  :function    #'my-handler)
```

### Add a new channel

1. Create a new module (`src/my-channel.lisp`)
2. Define a struct for connection state
3. Implement `(defmethod clambda/config:register-channel ((type (eql :my-channel)) &rest args ...))`
4. Add a `start-my-channel` function that starts a background thread
5. Export symbols from `clambda` and `clambda-user` packages

### Add a new LLM backend

1. Implement the OpenAI-compat API on your backend, or
2. Add a new client type to `cl-llm` following the `cl-llm/protocol` contracts

---

## ASDF System Versions

| Version | Milestone |
|---------|----------|
| 0.1.0 | Layer 1: cl-llm |
| 0.2.0 | Layer 2: clambda-core + cl-tui |
| 0.3.0 | Layer 3: clambda-gui |
| 0.4.0 | Layer 6a: config system (init.lisp) |
| 0.5.0 | Layer 6b: Telegram channel |
| 0.6.0 | Layer 6c: IRC channel |
| 0.7.0 | Layer 7: Browser control |
| 0.8.0 | Layer 8: Cron + HTTP management API |

---

## Known Architectural Gaps

| Gap | Severity | Notes |
|-----|---------|-------|
| Tool schema not validated | Low | Parameters accepted but not type-checked |
| No streaming tool calls | Low | Tools only parsed from complete responses |
| McCLIM thread safety | Medium | `safe-redisplay` is a workaround |
| No Anthropic native API | Medium | Use via OpenRouter as workaround |
| No Discord channel | Medium | On the roadmap |
| `tool-result-ok` naming collision | Low | See ROADMAP known gaps |
