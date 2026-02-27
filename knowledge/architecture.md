# Clambda Architecture Overview

> How the 4 completed projects fit together and form the foundation for the
> full OpenClaw rewrite. Updated after Layer 4.

---

## 1. System Dependency Graph

```
                    clambda-gui
                       │
                       │ :depends-on
                       ▼
              ┌── clambda-core ──┐
              │                  │
              │ :depends-on      │ :depends-on
              ▼                  │
           cl-llm             cl-tui (standalone TUI)
              │
              │ :depends-on
              ▼
       (Quicklisp libs)
       dexador, jzon,
       alexandria, cl-ppcre
```

**Leaf → root order:** `cl-llm` → `cl-tui` | `clambda-core` → `clambda-gui`

### Direct dependency table

| System | Depends On |
|--------|-----------|
| `cl-llm` | `dexador`, `com.inuoe.jzon`, `alexandria`, `cl-ppcre` |
| `cl-tui` | `cl-llm`, `alexandria`, `cl-ppcre` |
| `clambda-core` | `cl-llm`, `alexandria`, `com.inuoe.jzon`, `uiop` |
| `clambda-gui` | `clambda-core`, `cl-llm`, `mcclim`, `bordeaux-threads` |

---

## 2. Layer Descriptions

### Layer 1: `cl-llm` — LLM API Client

**Purpose:** Talk to any OpenAI-compatible API (LM Studio, Ollama, OpenRouter).

**Packages:**
- `cl-llm/protocol` — structs: `client`, `completion-response`, `tool-definition`, `tool-call`, `chat-message`
- `cl-llm/conditions` — `network-error`, `parse-error`
- `cl-llm/json` — `plist->object` (shallow), `object->plist`
- `cl-llm/http` — `post-json`, `post-json-stream` (wraps dexador)
- `cl-llm/streaming` — `parse-sse-line`, `chat-stream`
- `cl-llm/client` — `make-client`, `chat`, `chat-stream`
- `cl-llm/tools` — `make-tool-definition`
- `cl-llm` — public re-export surface

**Key interfaces:**
```lisp
;; Create a client
(cl-llm:make-client :base-url "..." :api-key "..." :model "...")

;; Non-streaming chat → returns string
(cl-llm:chat client messages)

;; Streaming chat → calls callback with each delta, returns full string
(cl-llm:chat-stream client messages callback)

;; Tool definitions for the API
(cl-llm:make-tool-definition :name "..." :description "..." :parameters ht)
```

---

### Layer 2a: `cl-tui` — Terminal UI Chat

**Purpose:** ANSI terminal chat interface using `cl-llm`. Standalone.

**Packages:**
- `cl-tui/ansi` — ANSI escape code constants and helpers
- `cl-tui/state` — `app` struct, global `*app*`
- `cl-tui/display` — print functions, streaming token display
- `cl-tui/commands` — slash command dispatch
- `cl-tui/loop` — main REPL loop
- `cl-tui` — public surface

**Key interfaces:**
```lisp
;; Entry point
(cl-tui:run &key model system-prompt)
```

**Architecture notes:**
- Single-threaded (no background threads)
- Streaming via `cl-llm:chat-stream` + `force-output` per token
- State in `*app*` global (mutable, but single-threaded so safe)
- Slash commands: `/model`, `/system`, `/clear`, `/quit`

---

### Layer 2b: `clambda-core` — Agent Platform

**Purpose:** Multi-turn agent loop with tool execution. Powers both TUI and GUI agents.

**Packages:**
- `clambda/agent` — `agent` struct: name, client, tool-registry, system-prompt
- `clambda/session` — `session` struct: agent + message history
- `clambda/tools` — `tool-registry`, `register-tool!`, `define-tool` macro, `schema-plist->ht`
- `clambda/builtins` — pre-built tools: `exec`, `read_file`, `write_file`, `list_dir`
- `clambda/loop` — `run-agent`, `agent-turn`; hook variables `*on-tool-call*`, `*on-tool-result*`, `*on-llm-response*`, `*on-stream-delta*`
- `clambda/conditions` — `tool-error`, `agent-error`
- `clambda` — public surface

**Key interfaces:**
```lisp
;; Build an agent
(clambda:make-agent :name "bot" :client client :tool-registry registry)

;; Create a session (holds conversation history)
(clambda:make-session :agent agent)

;; Register tools
(clambda:register-tool! registry "name" handler-fn :description "..." :parameters schema)
(clambda:define-tool registry "name" "desc" ((param-specs)) body...)

;; Run the agent loop
(clambda:run-agent session user-message :options opts)

;; Hook variables (setf before run-agent)
clambda/loop:*on-stream-delta*   ; lambda (delta) — called per streaming token
clambda:*on-tool-call*           ; lambda (name tc) — called when tool invoked
clambda:*on-tool-result*         ; lambda (name result) — called after tool runs
clambda:*on-llm-response*        ; lambda (text) — called with final LLM text
```

**Agent loop flow:**
```
run-agent
  │
  ├── add user message to session history
  │
  └── loop (up to max-turns):
        agent-turn
          │
          ├── call cl-llm:chat (with tools)
          │     └── returns (text tool-calls response)
          │
          ├── if no tool-calls → return text (done)
          │
          └── for each tool-call:
                execute tool from registry
                add tool-result to session
                → loop again
```

---

### Layer 3: `clambda-gui` — McCLIM GUI Frontend

**Purpose:** Windowed chat UI using McCLIM, threaded LLM calls, streaming display.

**Packages:**
- `clambda-gui/colors` — ink constants and role→color mapping
- `clambda-gui/chat-record` — `chat-message` struct (role, content, timestamp)
- `clambda-gui/frame` — `clambda-frame` definition, pane layout, slots
- `clambda-gui/display` — display functions for each pane
- `clambda-gui/commands` — CLIM command table (Send, Clear, Quit)
- `clambda-gui/main` — `run-gui` entry point

**Key interfaces:**
```lisp
;; Launch the GUI (blocks until window closes)
(clambda-gui:run-gui &key session width height)

;; Inside the frame, messages pushed via:
(push-chat-message frame :user "Hello")
(push-chat-message frame :assistant "Hi there")
(push-chat-message frame :system "Tool result: ...")
```

**Threading model:**
- Main thread: McCLIM event loop (`run-frame-top-level`)
- LLM calls: `bordeaux-threads` worker thread per request
- Streaming tokens: worker thread calls `safe-redisplay` to update display pane
- Only one worker at a time (guarded by `frame-worker` slot check)

---

## 3. Key Interfaces Between Layers

### cl-llm → clambda-core

`clambda-core` uses `cl-llm` for all LLM communication:
- `cl-llm:make-client` → stored in `agent` struct
- `cl-llm:chat` / `cl-llm:chat-stream` → called by `agent-turn`
- `cl-llm:make-tool-definition` → used when serializing registry to API
- `cl-llm/protocol` structs: `chat-message`, `tool-call`, `completion-response`

### clambda-core → clambda-gui

`clambda-gui` embeds a `clambda-core` session:
- `clambda:make-session` stored in frame slot
- `clambda:run-agent` called from worker thread
- Hook variables set before run:
  - `*on-stream-delta*` → `push-streaming-token frame delta` → `safe-redisplay`
  - `*on-tool-call*` → `push-chat-message frame :system ...`
  - `*on-llm-response*` → `push-chat-message frame :assistant text`

### cl-llm → cl-tui

`cl-tui` uses `cl-llm` directly (no clambda-core):
- `cl-llm:make-client` → stored in `app` struct
- `cl-llm:chat-stream` → called in main loop, token callback → `print-token`

---

## 4. Data Flow: User Message to Response

### In cl-tui (simple, single-threaded)

```
User types text
  │
  └── cl-tui/loop:handle-message
        │
        └── cl-llm:chat-stream client messages
              │ (calls callback per SSE chunk)
              └── print-token → write-string + force-output
                  (streaming display)
```

### In clambda-gui + clambda-core (multi-turn, threaded)

```
User enters command "Send <text>"
  │
  └── climbda-gui/commands:com-send
        │
        └── run-llm-async frame text
              │
              └── bt:make-thread
                    │
                    └── run-agent session text
                          │
                          ├── *on-stream-delta* → safe-redisplay (streaming tokens)
                          ├── tool-call → execute → *on-tool-call* + *on-tool-result*
                          └── final text → *on-llm-response* → push-chat-message
```

---

---

## Layer 6a: Emacs-Style Configuration System (`clambda/config`)

**File:** `src/config.lisp`  
**Package:** `clambda/config`  
**Loaded:** last in `clambda-core.asd` (depends on `clambda/tools` being loaded first)

The configuration model: users write Common Lisp in `~/.clambda/init.lisp`, which is
loaded at startup. No JSON, no YAML, no DSL. Full CL. Trust the user.

### Key APIs

```lisp
;;; Config directory
*clambda-home*           ; pathname variable; resolved from $CLAMBDA_HOME or ~/.clambda/
(clambda-home)           ; function accessor

;;; Loading
(load-user-config)       ; finds init.lisp, loads in clambda-user package, runs hooks
(user-config-loaded-p)   ; T after successful load

;;; Options (Emacs defcustom analog)
(defoption *default-model* "google/gemma-3-4b"
  :type string :doc "Default LLM model.")
(describe-options)       ; print all known options to stdout
*option-registry*        ; alist of (sym :default val :type T :doc "...")

;;; Hook system
(add-hook '*after-init-hook* #'my-fn)      ; appends fn
(remove-hook '*after-init-hook* #'my-fn)   ; removes fn
(run-hook '*after-init-hook*)              ; calls all fns, catches errors
(run-hook-with-args '*channel-message-hook* ch msg)

;;; Standard hooks
*after-init-hook*         ; () — after init.lisp loads
*before-agent-turn-hook*  ; (session user-msg) — before each agent-turn
*after-tool-call-hook*    ; (tool-name result) — after each tool call
*channel-message-hook*    ; (channel message) — on inbound channel messages

;;; Channel registration
(register-channel :telegram :token "..." :allowed-users '(12345))
*registered-channels*    ; alist of (keyword . args-plist)

;;; User tool registration (init.lisp syntax)
(define-user-tool my-tool
  :description "..." 
  :parameters '((:name "x" :type "string" :description "..."))
  :function #'my-handler)
*user-tool-registry*           ; tool-registry populated by define-user-tool
(merge-user-tools! registry)   ; copy user tools into another registry
```

### `clambda-user` package

init.lisp is loaded with `*package*` bound to `clambda-user`. This package:
- `:use #:cl` (full CL available, no sandboxing)
- Imports all config API symbols (defoption, add-hook, register-channel, etc.)
- Imports core clambda API (make-agent, make-client, define-tool, etc.)
- Users can call any clambda function without package qualification

### Sequence: startup with config

```
1. System loads (ql:quickload :clambda-core)
2. Caller invokes (clambda/config:load-user-config)
3.   → finds ~/.clambda/init.lisp
4.   → binds *package* to clambda-user
5.   → (load init.lisp)
6.      init.lisp runs: sets options, registers channels, defines tools, adds hooks
7.   → runs *after-init-hook* functions
8. Caller creates agent/session using *default-model* and *user-tool-registry*
```

### register-channel: plugin pattern

Channel plugins (telegram, irc, etc.) specialise `register-channel`:

```lisp
;; In clambda/channels/telegram.lisp:
(defmethod clambda/config:register-channel ((type (eql :telegram)) &rest args
                                            &key token allowed-users &allow-other-keys)
  (let ((chan (make-telegram-channel :token token :allowed-users allowed-users)))
    (setf *telegram-channel* chan)
    (start-polling chan))
  ;; Store config in *registered-channels* via default method:
  (call-next-method))
```

Users just write `(register-channel :telegram :token "...")` in init.lisp.

---

---

## Layer 6c: IRC Client Channel (`clambda/irc`)

**File:** `src/irc.lisp`
**Package:** `clambda/irc`
**Loaded:** after `clambda/config` (specialises `register-channel`)
**New deps:** `usocket` (TCP), `cl+ssl` (TLS)

Raw IRC protocol implementation — no external IRC library, no DCC, no CTCP beyond VERSION.

### Key Data: `irc-connection` struct (`:conc-name irc-`)

```
server, port, tls-p, nick, realname    — connection config
channels, nickserv-password            — channel config
allowed-users, trigger-prefix          — routing config
socket, stream                         — live connection state
reader-thread, flood-thread            — background threads
flood-queue, flood-lock, flood-cvar   — rate-limited send queue
running-p, reconnect-delay             — lifecycle state
agent, sessions, sessions-lock         — per-target session routing
```

### Connection & Protocol

```lisp
;; IRC line format: [:prefix] COMMAND [params...] [:trailing]
(parse-irc-line ":nick!u@h PRIVMSG #chan :hello")
;; => (:prefix "nick!u@h" :command "PRIVMSG" :params ("#chan") :trailing "hello")

(irc-build-line "PRIVMSG" '("#chan") "hello")
;; => "PRIVMSG #chan :hello"

(prefix-nick "alice!alice@libera.chat")
;; => "alice"
```

### Threading Model

```
start-irc
  ├── bt:make-thread → %flood-sender-loop
  │     Dequeues raw lines at *IRC-SEND-INTERVAL* (0.5s = 2/sec max)
  │     Writes line\r\n, force-output, sleeps
  │
  └── bt:make-thread → %reader-loop
        CONNECT (usocket:socket-connect + cl+ssl:make-ssl-client-stream for TLS)
        %register (NICK + USER, sent immediately bypassing flood queue)
        %read-loop (read-line loop, %dispatch-line per line)
        ON DISCONNECT:
          if running-p: sleep reconnect-delay (5→10→20…→300s), reconnect
          else: exit

Per inbound PRIVMSG that triggers:
  bt:make-thread → %route-message
    %find-or-create-session (per reply-target: channel or nick)
    run-agent session message
    irc-send-privmsg (splits long responses, queues via flood queue)
```

### Message Routing

- **Channel message**: trigger = nick mentioned OR starts with `nick:` (configurable)
- **DM (PRIVMSG to bot nick)**: always triggers
- **allowed-users**: if set, only nicks in list can trigger
- **CTCP VERSION**: replied with version notice, not routed to agent

### Reconnection

```
On disconnect → check running-p → sleep reconnect-delay → reconnect
reconnect-delay: 5s initial, doubles each attempt, caps at 300s (5 min)
Reset to 5s on successful RPL_WELCOME (001)
```

### User API

```lisp
;; In init.lisp:
(register-channel :irc
  :server "irc.libera.chat" :port 6697 :tls t
  :nick "clambda" :channels '("#clambda")
  :nickserv-password "s3cr3t"
  :allowed-users '("alice" "bob"))

(add-hook '*after-init-hook* #'start-irc)

;; Direct:
(start-irc :server "irc.libera.chat" :nick "clambda" :channels '("#test"))
(stop-irc)
(irc-connected-p)
(irc-send-privmsg "#test" "Hello channel!")
(irc-join "#another-channel")
```

---

## Layer 7: Browser Control (`clambda/browser`)

**File:** `src/browser.lisp`
**Package:** `clambda/browser`
**Loaded:** after `clambda/irc` (depends on `clambda/config` for `defoption`)
**New file:** `browser/playwright-bridge.js` (Node.js subprocess)
**New dir:** `browser/` with `package.json` + `node_modules/playwright`

Browser automation via a Playwright Node.js subprocess. Synchronous JSON-over-stdin/stdout protocol.

### Config Options

```lisp
*browser-headless*        ; bool, default T — run without visible window
*browser-playwright-path* ; string, default "node" — Node.js executable
*browser-bridge-script*   ; string — path to playwright-bridge.js (auto-resolved)
```

### Key APIs

```lisp
;;; Lifecycle
(browser-launch &key headless)  ; starts subprocess + Chromium
(browser-close)                 ; clean shutdown (safe if not running)
(browser-running-p)             ; T if subprocess is alive

;;; Navigation & content
(browser-navigate url)          ; go to URL (waits for DOMContentLoaded)
(browser-snapshot)              ; ARIA tree as YAML text (ariaSnapshot API)
(browser-screenshot &optional path)  ; base64 PNG string or saved file

;;; Interaction
(browser-click selector)        ; click by CSS selector
(browser-type selector text)    ; fill input (clears first)
(browser-evaluate js)           ; eval JS, return serialized result

;;; Tool registration
(register-browser-tools registry)  ; add 6 browser tools to any registry
(make-browser-registry)            ; new registry with just browser tools
```

### Subprocess Protocol

```
CL side                          Node.js bridge
--------                         --------------
write JSON line to stdin  ─────► parse JSON command
wait for stdout line      ◄───── write JSON response line

Request:  { "id": "br1", "command": "navigate", "params": { "url": "..." } }
Response: { "id": "br1", "ok": true, "result": null }
Error:    { "id": "br1", "ok": false, "error": "message" }
```

All commands are synchronous (one in-flight at a time, guarded by `*browser-lock*` mutex).

### Agent Tool Names

| Tool name | CL function |
|-----------|-------------|
| `browser_navigate` | `browser-navigate` |
| `browser_snapshot` | `browser-snapshot` |
| `browser_screenshot` | `browser-screenshot` |
| `browser_click` | `browser-click` |
| `browser_type` | `browser-type` |
| `browser_evaluate` | `browser-evaluate` |

### Setup

```bash
# One-time setup (in projects/clambda-core/browser/):
npm install
npx playwright install chromium   # ~200MB

# In init.lisp:
(register-channel :browser :headless t)
;; Then at startup:
(browser-launch)
```

---

---

## Layer 8: Cron Scheduler + Remote Management API

### Layer 8a: `clambda/cron`

**File:** `src/cron.lisp`
**Package:** `clambda/cron`
**Loaded:** before `clambda/http-server` (http-server imports `list-tasks`, `task-info`)

Thread-based task scheduler with two task kinds: `:periodic` (repeating) and `:once` (one-shot).
Cooperative cancellation via sleep-interval granularity. Error isolation in task functions.

#### `scheduled-task` struct (`:conc-name task-`)

```
name, kind, interval, fire-at    — task identity and timing
function                          — (lambda ()) to call
thread                            — bt:thread running the task
active-p                          — NIL → thread exits after current sleep
description, last-run, last-error, run-count — metadata
```

#### Threading Model

```
schedule-task / schedule-once
  └── bt:make-thread → %periodic-task-loop / %once-task-body
        loop:
          %sleep-until target-time in *cron-sleep-interval* chunks
            (checks active-p on each wake)
          %run-task-function — catches errors, stores in last-error
          update fire-at (periodic only)
          :once → %unregister-task, exit
```

#### Public API

```lisp
(schedule-task "name" :every 30 #'fn &key description)   ; periodic
(schedule-once "name" :after 300 #'fn &key description)  ; one-shot
(cancel-task "name")         ; → T / NIL; cooperative (up to *cron-sleep-interval*)
(find-task "name")           ; → scheduled-task or NIL
(list-tasks)                 ; → list of all active tasks
(clear-tasks)                ; → count cancelled
(task-info task)             ; → hash-table (JSON-serializable)
(describe-tasks &optional stream) ; → human-readable output
```

### Layer 8b: `clambda/http-server` (updated)

**All Layer 5 endpoints unchanged.** Layer 8b adds:

#### Management Endpoints

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/health` | none | Server alive, uptime |
| GET | `/api/system` | ✓ | Version, uptime, log file, counts |
| GET | `/api/agents` | ✓ | List registered agents |
| POST | `/api/agents/:name/start` | ✓ | Create/get management session |
| POST | `/api/agents/:name/message` | ✓ | Send message, get response |
| GET | `/api/agents/:name/history` | ✓ | Session message history |
| DELETE | `/api/agents/:name/stop` | ✓ | Delete session |
| GET | `/api/sessions` | ✓ | All active sessions |
| GET | `/api/channels` | ✓ | Registered channel configs |
| GET | `/api/tasks` | ✓ | Cron task list |

#### Auth

`*api-token*` (default NIL = disabled). When set, all protected endpoints require:
`Authorization: Bearer <token>`

`check-auth` returns NIL on pass, JSON-error string on fail — callers use `return-from` on fail.

#### Session Key Convention

Management API uses session keys `"mgmt:<agent-name>"` in `*http-sessions*`.
`get-or-create-agent-session` resolves agent from registry and creates session if missing.

---

## 5. Extension Points for OpenClaw Rewrite

### What's already implemented (as of Layer 5 Phase 3)

| OpenClaw Feature | CL Equivalent | Status |
|-----------------|---------------|--------|
| LLM API client | `cl-llm` | ✅ Complete |
| Streaming SSE | `cl-llm/streaming` | ✅ Complete |
| HTTP retry/backoff | `cl-llm/http` | ✅ Complete |
| Tool protocol | `clambda/tools` | ✅ Complete |
| Agent loop | `clambda/loop` | ✅ Complete |
| Token budget / turn limits | `clambda/loop`, `clambda/session` | ✅ Complete |
| Built-in tools (exec, file ops, web, tts) | `clambda/builtins` | ✅ Complete |
| Structured logging (JSONL) | `clambda/logging` | ✅ Complete (wired in) |
| Session persistence | `clambda/session` | ✅ Complete |
| Workspace memory | `clambda/memory` | ✅ Complete |
| Agent registry | `clambda/registry` | ✅ Complete |
| Sub-agent spawning | `clambda/subagents` | ✅ Complete |
| Channel protocol (abstract) | `clambda/channels` | ✅ Complete |
| HTTP API server | `clambda/http-server` | ✅ Complete |
| TUI chat | `cl-tui` | ✅ Complete |
| GUI chat | `clambda-gui` | ✅ Complete |

### What OpenClaw has that Clambda still needs

| OpenClaw Feature | CL Gap | Priority |
|-----------------|--------|---------|
| Emacs-style config (init.lisp) | ✅ Done: `clambda/config` Layer 6a | — |
| Telegram channel plugin | ✅ Done: `clambda/telegram` Layer 6b | — |
| IRC channel plugin | ✅ Done: `clambda/irc` Layer 6c | — |
| Web browser control | ✅ Done: `clambda/browser` Layer 7 | — |
| Cron / scheduled tasks | ✅ Done: `clambda/cron` Layer 8a | — |
| Remote management API | ✅ Done: `clambda/http-server` Layer 8b | — |
| Skills system (SKILL.md loading) | Not implemented | High |
| Discord channel plugin | Not implemented | Medium |
| Canvas / UI presentation | Not implemented | Low |
| Node pairing (mobile/devices) | Not implemented | Low |
| Multi-model routing | Not implemented | Low |

### Natural extension points

1. **New tools** → `(clambda:register-tool! registry ...)` in `clambda/builtins.lisp`
2. **New backends** → implement `cl-llm:make-client` pattern for Anthropic, etc.
3. **New frontends** → create new ASDF system, depend on `clambda-core`, use hooks
4. **Skills** → load SKILL.md, inject instructions into system prompt, register tools
5. **Sub-agents** → `clambda-core` already models session isolation; spawn via `bt:make-thread`

---

## 6. Known Architectural Gaps

1. ~~**No persistence**~~ — ✅ Done: `save-session` / `load-session`
2. **No multi-agent coordination** — no structured message passing between agent instances;
   sub-agents share nothing except the parent's tool registry passed at spawn time
3. **Tool schema validation** — parameters accepted but not validated against schema
4. **No streaming tool calls** — tool calls are only parsed from complete responses
5. **Thread safety** — McCLIM redisplay from worker threads needs care; `safe-redisplay` is a workaround not a solution
6. ~~**No retry/backoff**~~ — ✅ Done: exponential backoff in `cl-llm/http` for 429/5xx
7. **`tool-result-ok` naming collision** — the `defun tool-result-ok` overrides the struct accessor
   of the same name, so `format-tool-result` always returns the value without the `ERROR:` prefix
   (see tools.lisp). Low severity (error results still carry the message), but confusing.
   Fix: rename the slot to `:success` or the constructor to `make-ok-result`.

## 7. Layer 5 Phase 3 Additions

### New in `cl-llm/http` (retry/backoff)

```
cl-llm/conditions:retryable-error  — transient HTTP error (429, 5xx)
cl-llm/http:*max-retries*          — default 3
cl-llm/http:*retry-base-delay-seconds* — default 1 (exponential: 1s, 2s, 4s)
```

`post-json` and `post-json-stream` both retry automatically. The `retry` restart
is established before each retry so callers can override (skip retry, abort, etc.).

### New in `clambda/conditions`

```
clambda/conditions:budget-exceeded  — token or turn budget exceeded
  :kind    — :tokens or :turns
  :limit   — the configured maximum
  :current — the value that exceeded it
```

### New in `clambda/session`

```
session-total-tokens  — cumulative token count; updated by agent-turn from usage data
```

### New in `clambda/loop`

```
loop-options :max-tokens — optional token budget; signals budget-exceeded when exceeded
```

Agent loop now also calls `log-llm-request` before each LLM call, `log-tool-call` and
`log-tool-result` for each tool dispatch.

### New in `clambda/builtins`

```
tts   — text-to-speech; shells out to espeak-ng/espeak/piper/say (whichever is on PATH)
        graceful no-op if none available
```

### Updated in `clambda/http-server`

- `start-server` now auto-configures `*log-file*` (defaults to `logs/clambda.jsonl`)
- `/chat` and `/chat/stream` handlers emit `http_request` and `http_response` log entries
