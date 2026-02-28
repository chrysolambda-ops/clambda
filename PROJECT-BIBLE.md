# Clawmacs Project Bible

> Canonical rebuild document for Clawmacs.
> Goal: enough detail to rebuild the system from scratch without original source.

---

## 1) Project Overview

Clawmacs is a Common Lisp, OpenClaw-inspired agent platform with an Emacs-style philosophy:

- **Emacs-style**: full programmable runtime, not fixed configuration.
- **Lisp-native**: CLOS, conditions/restarts, macros, image-based workflows.
- **Local-first**: workspace memory injection, file tools, local channels, local config (`~/.clawmacs/init.lisp`).

### Why it exists

OpenClaw proved strong architecture in Node. Clawmacs ports that architecture into Lisp and adds Lisp-exclusive capabilities:

1. Condition-based live recovery (restart tool calls without process restart).
2. Live runtime patching via SWANK/SLIME.
3. Save/restore entire runtime image.
4. Declarative `define-agent` DSL.

### Design philosophy

- **Protocol-first modules** (tools, channels, registry).
- **Composable layers** (client → loop/core → channels/UIs).
- **Explicit package boundaries** in `src/packages.lisp`.
- **Operational robustness**: retries, budgets, structured logs, persistence.

---

## 2) Architecture

## 2.1 System graph

```text
cl-llm  ─┐
         ├── clawmacs-core ─── clawmacs-gui
cl-tui  ─┘
```

- `cl-llm`: OpenAI-compatible LLM protocol client.
- `cl-tui`: standalone terminal chat app (directly on cl-llm).
- `clawmacs-core`: agent runtime, tools, channels, HTTP API, scheduler.
- `clawmacs-gui`: McCLIM frontend over clawmacs-core.

## 2.2 cl-llm

Purpose: normalize OpenAI-compatible chat/tool APIs.

API surface (major):

- `make-client`, `make-ollama-client`, `make-openrouter-client`, `make-lm-studio-client`
- `chat`, `chat-stream`, `simple-chat`
- Protocol structs: `message`, `tool-definition`, `tool-call`, `completion-response`, `choice`, `usage`
- SSE parser: `parse-sse-line`
- HTTP helpers: `post-json`, `post-json-stream` with retry/backoff on transient statuses

Streaming protocol:

- Reads SSE lines: `data: {...}` and `data: [DONE]`
- Extracts `choices[0].delta.content`
- Invokes token callback per chunk
- Aggregates full text for final return

## 2.3 cl-tui

Terminal architecture:

- `ansi.lisp`: escape constants, color helpers
- `state.lisp`: `app` struct (`client`, `messages`, `model`, `system-prompt`, `running-p`, `stream`)
- `display.lisp`: role-colored rendering + streaming output
- `commands.lisp`: slash command parse/dispatch
- `loop.lisp`: main read-eval-chat loop

Important behavior:

- Streaming uses `force-output` on each token.
- Commands: model/system/clear/quit flow through central dispatcher.

## 2.4 clawmacs-core

Main runtime. 20 modules:

1. agent
2. browser
3. builtins
4. channels
5. conditions
6. config
7. cron
8. http-server
9. image
10. irc
11. logging
12. loop
13. memory
14. packages
15. registry
16. session
17. subagents
18. swank
19. telegram
20. tools

Composition flow:

- `run-agent` calls cl-llm with session history and tools.
- Tool calls dispatched through registry.
- Channels (Telegram/IRC/HTTP) map external messages to per-channel sessions.
- Registry handles named agents and inter-agent messages.
- Cron executes background jobs; HTTP server exposes management API.

## 2.5 clawmacs-gui

Current state:

- McCLIM frame with panes (chat/sidebar/status/input)
- Background worker thread for LLM loop calls
- Hook-driven streaming UI updates
- Safe redisplay pattern used to avoid pane NIL crashes

Status: functional single-window chat frontend; not full multi-activity environment yet.

---

## 3) Module Deep Dives (clawmacs-core)

## 3.1 `clawmacs/agent`

Purpose: agent identity + model/client/tool wiring.

Key type:

```lisp
(defclass agent ()
  ((name display-name emoji theme role model workspace
    system-prompt client tool-registry
    workspace-injected-context workspace-injected-at)))
```

Public API:

- `make-agent (&key name display-name emoji theme role model workspace workspace-path system-prompt client tool-registry)`
- accessors: `agent-name`, `agent-role`, `agent-model`, `agent-client`, `agent-tool-registry`, ...
- `agent-effective-system-prompt`
- `agent-with-tools`
- `default-agent-workspace`, `agent-workspace-path`

Design decisions:

- class (not struct) for future extensibility
- cached workspace injection with refresh interval from config options

## 3.2 `clawmacs/browser`

Purpose: Playwright automation via Node bridge subprocess.

API:

- lifecycle: `browser-launch`, `browser-close`, `browser-running-p`
- actions: `browser-navigate`, `browser-snapshot`, `browser-screenshot`, `browser-click`, `browser-type`, `browser-evaluate`
- tool wiring: `register-browser-tools`, `make-browser-registry`

Protocol:

- line-delimited JSON over stdin/stdout
- request: `{id, command, params}`
- response: `{id, ok, result|error}`

Design:

- mutex-protected synchronous command channel (`*browser-lock*`)
- fallback to config options `*browser-headless*`, `*browser-playwright-path*`, `*browser-bridge-script*`

## 3.3 `clawmacs/builtins`

Purpose: canonical built-in tools.

Tools registered:

- `exec`
- `read_file`
- `write_file`
- `list_directory`
- `web_fetch`
- `tts`
- `memory_search`
- `image_analyze` (vision stub)
- `send_message` (inter-agent)

Public API:

- `register-builtin-tools`
- `make-builtin-registry`

Design:

- handlers always return `tool-result` objects
- graceful degraded behavior for optional deps (e.g., TTS unavailable)

## 3.4 `clawmacs/channels`

Purpose: abstract channel protocol + in-memory/testing implementations.

Core protocol:

```lisp
(defgeneric channel-send (channel message))
(defgeneric channel-receive (channel &key timeout))
(defgeneric channel-poll (channel))
(defgeneric channel-close (channel))
```

Types:

- `channel` base class
- `repl-channel`
- `queue-channel`

Conditions:

- `channel-closed-error`
- `channel-timeout-error`

Design:

- lock+condition-variable queue channel for thread-safe integration tests

## 3.5 `clawmacs/conditions`

Purpose: condition hierarchy + canonical restart symbols.

Conditions:

- base: `clawmacs-error`
- agent/session: `agent-error`, `session-error`
- tools: `tool-not-found`, `tool-execution-error` (includes failing `:input`)
- loop: `agent-loop-error`, `agent-turn-error`
- budgets: `budget-exceeded`

Restart names standardized in this package:

- `retry-with-fixed-input`
- `skip-tool-call`
- `retry-tool-call`
- `abort-agent-loop`

Design:

- shared restart symbol identity avoids cross-package mismatch

## 3.6 `clawmacs/config`

Purpose: Emacs-style `init.lisp` configuration runtime.

Core API:

- home/load: `*clawmacs-home*`, `clawmacs-home`, `load-user-config`, `user-config-loaded-p`
- options: `defoption`, `*option-registry*`, `describe-options`
- hooks: `add-hook`, `remove-hook`, `run-hook`, `run-hook-with-args`
- channel registration generic: `register-channel`
- user tools: `define-user-tool`, `register-user-tool!`, `merge-user-tools!`, `*user-tool-registry*`

Key options include model defaults, compaction thresholds, fallback models, workspace injection settings, vision support flag.

Design:

- full CL in config package `clawmacs-user`
- no sandbox
- startup is resilient to init errors (error reported; runtime continues)

## 3.7 `clawmacs/cron`

Purpose: thread-based scheduled task system.

Type:

```lisp
(defstruct (scheduled-task (:conc-name task-))
  name kind interval fire-at function thread active-p
  description last-run last-error run-count)
```

API:

- `schedule-task` (periodic)
- `schedule-once`
- `cancel-task`, `find-task`, `list-tasks`, `clear-tasks`
- `task-info`, `describe-tasks`

Design:

- cooperative cancel via active flag and short sleep interval (`*cron-sleep-interval*`)
- each task isolated in its own thread

## 3.8 `clawmacs/http-server`

Purpose: Hunchentoot HTTP API for chat and remote management.

State/API:

- lifecycle: `start-server`, `stop-server`, `restart-server`, `server-running-p`
- sessions: `*http-sessions*`, `http-session-get/create/delete`, `list-http-sessions`
- auth: `*api-token*`, `check-auth`
- telemetry: `*server-start-time*`, `uptime-seconds`

Endpoints (high level):

- legacy: `/chat`, `/chat/stream`, `/agents`, `/sessions`
- management: `/health`, `/api/system`, `/api/agents`, `/api/agents/:name/...`, `/api/channels`, `/api/tasks`

Design:

- per-agent management sessions keyed by `mgmt:<agent-name>`
- JSON in/out with auth guard for protected routes

## 3.9 `clawmacs/image`

Purpose: save whole runtime image and restore entrypoint.

API:

- `save-clawmacs-image`
- `clawmacs-main`

Design:

- wraps `sb-ext:save-lisp-and-die`
- restored toplevel restarts SWANK/channels/hooks best-effort

## 3.10 `clawmacs/irc`

Purpose: raw IRC channel integration (TLS capable).

Type: `irc-connection` struct with config + runtime + session state.

API:

- lifecycle: `start-irc`, `stop-irc`, `irc-connected-p`
- send/control: `irc-send-privmsg`, `irc-join`, `irc-part`
- protocol helpers: `parse-irc-line`, `irc-build-line`, `prefix-nick`

Design:

- dedicated flood queue thread (`*irc-send-interval*` throttling)
- reader thread with reconnect backoff
- per-target session routing and trigger parsing

## 3.11 `clawmacs/logging`

Purpose: JSONL structured logging.

API:

- config vars: `*log-file*`, `*log-enabled*`
- events: `log-event`, `log-llm-request`, `log-tool-call`, `log-tool-result`, `log-error-event`
- scope macro: `with-logging`

Design:

- logging failures never crash runtime (errors swallowed with stderr notice)

## 3.12 `clawmacs/loop`

Purpose: core multi-turn agent loop.

Hooks:

- `*on-tool-call*`
- `*on-tool-result*`
- `*on-llm-response*`
- `*on-stream-delta*`

Options:

```lisp
(defstruct loop-options
  max-turns max-tokens stream verbose)
```

Main API:

- `agent-turn`
- `run-agent`

Key behavior:

- builds system prompt + memory + history
- model fallback routing on retryable errors
- context compaction with summary when near token window threshold
- tool call dispatch and message insertion
- budget enforcement via `budget-exceeded`
- auto-repair failed tool calls by asking LLM for corrected JSON and invoking `retry-with-fixed-input`

## 3.13 `clawmacs/memory`

Purpose: workspace markdown ingestion/search/context injection.

Types:

- `memory-entry` (name/path/content)
- `workspace-memory` (path/entries)

API:

- `load-workspace-memory`
- `search-memory`
- `memory-search`
- `memory-context-string`

Design:

- priority files loaded first (SOUL, AGENTS, TEAM, etc.)
- entry/total truncation caps

## 3.14 `src/packages.lisp`

Purpose: package topology and exports.

Design rules:

- single source of package truth
- dependency order in defpackage declarations matters
- top-level convenience package `clawmacs` re-exports public surface

## 3.15 `clawmacs/registry`

Purpose: named agent-spec registry + inter-agent queueing + DSL.

Type:

```lisp
(defstruct (agent-spec (:conc-name agent-spec-))
  name role display-name emoji theme model workspace system-prompt
  tools max-turns client)
```

API:

- registry ops: `register-agent`, `find-agent`, `list-agents`, `unregister-agent`, `clear-registry`
- inter-agent: `send-to-agent`, `consume-agent-messages`
- DSL: `define-agent`
- instantiation: `instantiate-agent-spec`

Design:

- thread-safe hash table with lock
- tool symbol → `snake_case` conversion in DSL

## 3.16 `clawmacs/session`

Purpose: conversation/session object + persistence.

Type: `session` class with id, agent, messages, metadata, created-at, total-tokens.

API:

- constructor: `make-session`
- mutation: `session-add-message`, `session-clear-messages`
- query: `session-message-count`, `session-last-message`
- persistence: `save-session`, `load-session`

Design:

- persistence stores role/content and optional `tool_call_id`

## 3.17 `clawmacs/subagents`

Purpose: spawn asynchronous child agent runs.

Type: `subagent-handle` with status/result/error + sync lock/cvar.

API:

- `spawn-subagent`
- `subagent-wait`
- `subagent-status`
- `subagent-kill`

Design:

- status states `:running/:done/:failed/:killed`
- callback executes in child thread

## 3.18 `clawmacs/swank`

Purpose: runtime SLIME/Sly integration.

API:

- `start-swank`, `stop-swank`, `swank-running-p`
- config option `*swank-port*`

Design:

- startup nonfatal; double start safe; enables live debugging/hot patching

## 3.19 `clawmacs/telegram`

Purpose: Telegram Bot API long-polling channel.

Type: `telegram-channel` struct with token, allowlist, polling state, sessions.

API:

- bot operations: `telegram-api-url`, `telegram-get-me`, `telegram-get-updates`, `telegram-send-message`, `telegram-edit-message`
- channel control: `start-telegram`, `stop-telegram`, `telegram-running-p`, `start-all-channels`
- routing helpers: `allowed-user-p`, `find-or-create-session`, `process-update`

Design:

- polling thread + per-chat session map
- streaming reply path with debounced message edits

## 3.20 `clawmacs/tools`

Purpose: tool registry/protocol, schema conversion, dispatch/restarts.

Types:

- `tool-registry` class
- internal `tool-entry`
- `tool-result` struct (`tr-ok`, `tr-value`)

API:

- registry: `make-tool-registry`, `register-tool!`, `find-tool`, `list-tools`, `copy-tools-to-registry`
- schema: `schema-plist->ht`
- llm: `tool-definitions-for-llm`
- dispatch: `dispatch-tool-call`
- macro: `define-tool`
- result helpers: `tool-result-ok`, `tool-result-error`, `tool-result-value`, `format-tool-result`

Design:

- recursive schema conversion for nested JSON Schema properties
- dispatch installs restarts for repair/skip semantics

---

## 4) Data Formats

## 4.1 LLM JSON wire protocol

Request (OpenAI-compatible):

```json
{
  "model": "google/gemma-3-4b",
  "messages": [
    {"role": "system", "content": "..."},
    {"role": "user", "content": "..."}
  ],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "read_file",
        "description": "Read file",
        "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}
      }
    }
  ],
  "stream": true
}
```

Response parsed to protocol structs; tool calls read from `message.tool_calls[*].function.{name,arguments}`.

## 4.2 Session persistence format

Saved JSON:

```json
{
  "id": "session-...",
  "created_at": 3912345678,
  "total_tokens": 1422,
  "messages": [
    {"role": "user", "content": "Hello"},
    {"role": "assistant", "content": "Hi"},
    {"role": "tool", "tool_call_id": "call_1", "content": "..."}
  ]
}
```

## 4.3 Structured log format

JSONL entries (one per line):

```json
{"timestamp":"2026-02-27T12:00:00Z","event_type":"llm_request","agent":"researcher","model":"...","message_count":8,"tools_count":6}
```

Common event types: `llm_request`, `tool_call`, `tool_result`, `http_request`, `http_response`, `error`, `cron`.

## 4.4 IRC line protocol

Parser supports canonical form:

```text
[:prefix] COMMAND [params ...] [:trailing]
```

Examples:

- `PING :server`
- `:nick!user@host PRIVMSG #chan :hello`

## 4.5 Telegram Bot API usage

Methods used:

- `getMe`
- `getUpdates` (long poll with timeout)
- `sendMessage`
- `editMessageText`

Update extraction focuses on `message.chat.id`, `message.from.id`, `message.text`, update-id tracking.

## 4.6 Playwright bridge JSON protocol

Request/response lines:

```json
{"id":"br-1","command":"navigate","params":{"url":"https://example.com"}}
{"id":"br-1","ok":true,"result":null}
```

Error form:

```json
{"id":"br-1","ok":false,"error":"timeout"}
```

---

## 5) Configuration System

Config file: `~/.clawmacs/init.lisp` (or `$CLAWMACS_HOME/init.lisp`).

Loaded with `*package*` bound to `clawmacs-user`.

### `defoption`

Registers option metadata and defines setf-able special var.

```lisp
(defoption *default-model* "google/gemma-3-4b" :type string :doc "...")
```

### Hooks

- add: `(add-hook '*after-init-hook* #'fn)`
- run: `(run-hook '*after-init-hook*)`
- arg hooks: `(run-hook-with-args '*channel-message-hook* ch msg)`

### Channels

Generic `register-channel`; plugins specialize on eql keywords (`:telegram`, `:irc`, `:browser`).

### User tools

`define-user-tool` macro populates `*user-tool-registry*`; `merge-user-tools!` copies into runtime registry.

---

## 6) Agent Lifecycle

1. Boot system (`quickload clawmacs-core`)
2. `load-user-config`
3. register agents/tools/channels in init
4. start channels (`start-telegram`, `start-irc`, `start-server` etc.)
5. inbound message received by channel adapter
6. find/create session for channel conversation key
7. `run-agent`:
   - append user message
   - loop `agent-turn` up to `max-turns`
   - call LLM with messages + tools
   - execute tool calls if present
   - append tool results and continue
8. return final assistant output
9. channel sends response
10. optional session save/logging/telemetry updates

Shutdown:

- stop channels
- stop HTTP server
- cancel cron tasks
- optional `save-session` and/or `save-clawmacs-image`

---

## 7) Tool Protocol

Definition path:

1. register handler (`register-tool!` or `define-tool`)
2. provide description + JSON schema
3. convert registry entries to LLM tool definitions
4. receive tool call from LLM
5. parse args JSON string → hash table
6. dispatch to handler
7. normalize result into `tool-result`
8. append tool message to session using tool-call-id

Error path:

- unknown tool → `tool-not-found` (with skip restart)
- handler error → `tool-execution-error` (with retry-with-fixed-input/skip restarts)
- loop handler may auto-repair by asking model for corrected args

---

## 8) Channel Protocol

CLOS protocol from `clawmacs/channels`:

- send
- receive (blocking, optional timeout)
- poll (nonblocking)
- close

Telegram implementation:

- long-polling thread
- JSON API transport
- per-chat sessions
- optional streaming via edit-message debounce

IRC implementation:

- socket+TLS connection
- flood-protected outgoing queue
- parser/dispatcher for PRIVMSG, PING, numerics
- per-target sessions

---

## 9) Error Handling

Three layers:

1. **Condition taxonomy** in `clawmacs/conditions`
2. **Restart-driven local recovery** in tools/loop
3. **Operational guards** in channels/http/logging (catch + continue)

Important restarts:

- `retry-with-fixed-input`: recover tool calls in-place
- `skip-tool-call`: continue loop after failure
- `abort-agent-loop`: controlled stop for budgets/max-turn and unrecoverable flow

---

## 10) Lisp Superpowers

Implemented:

- SWANK runtime server (`clawmacs/swank`)
- image save/restore (`clawmacs/image`)
- richer agent DSL (`define-agent`)
- condition/restart auto-repair flow in tool dispatch

Hot-reload pattern:

- connect SLIME
- redefine function/method
- existing runtime continues without restart

---

## 11) Testing

Framework: **Parachute**.

Systems:

- `cl-llm/tests`
- `clawmacs-core/tests`
- `clawmacs-gui/tests`

Core test files (`projects/clambda-core/t`):

- `smoke-test.lisp`
- `test-config.lisp`
- `test-telegram.lisp`
- `test-irc.lisp`
- `test-browser.lisp`
- `test-cron.lisp`
- `test-remote-api.lisp`
- `test-superpowers.lisp`
- `live-telegram-irc-test.lisp`

Run:

```lisp
(asdf:test-system :clawmacs-core)
```

---

## 12) Deployment

### Quicklisp / ASDF

- ensure source-registry includes `projects/`
- quickload system(s)

### Required env

```bash
export LD_LIBRARY_PATH="/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH"
```

Needed for CFFI/OpenSSL users (dexador/cl+ssl paths).

### Service model

- long-running daemon typically boots clawmacs-core, loads init, starts selected channels and HTTP server
- recommended: systemd unit wrapping SBCL invocation + restart policy

### Browser prereq

```bash
cd projects/clambda-core/browser
npm install
npx playwright install chromium
```

---

## 13) Lessons Learned (from `knowledge/mistakes/recent.md`)

Condensed actionable lessons:

1. McCLIM redisplay only after frame realization; use safe pane checks.
2. `get-output-stream-string` clears stream; do not use for rolling accumulation.
3. Convenience package exports are incomplete; import from concrete subpackage when needed.
4. Dexador `:want-stream t` returns stream as primary value.
5. Export symbols early; packaging errors dominate CL integration failures.
6. Set `:conc-name` intentionally before exporting accessors.
7. Export constructors for public structs.
8. Ensure LD_LIBRARY_PATH for crypto libs.
9. Prefer `--load` scripts over complex `--eval` forms.
10. Escape literal `~` in format strings.
11. Don’t `return-from` outer function inside nested lambda.
12. Import accessors explicitly, not just class names.
13. `assert` syntax is `(assert test () "message")`.
14. Shallow plist→JSON conversion breaks nested schemas.
15. Avoid pathname double-conversion mistakes (`ensure-directory-pathname` etc.).
16. Bordeaux-threads has `condition-notify`, not broadcast API variant used elsewhere.
17. Avoid defstruct accessor name collisions with custom functions.
18. Update all package export layers whenever adding public function.
19. Use MOP eql specializer helpers, not `find-class` on `(eql ...)`.
20. `defpackage` load order must respect dependency imports.
21. Load parachute before test package definitions.
22. Playwright API changes: use `ariaSnapshot`, not removed accessibility API.
23. `asdf:system-relative-pathname` already resolves full path; don’t merge duplicate segments.
24. Parachute `skip-on` DSL isn’t generic runtime boolean evaluator.
25. Deep nested Lisp code: compile early to catch paren mismatches.
26. Ensure log directories exist before first write.

---

## 14) Patterns Summary (`knowledge/patterns/*`)

- **asdf-local-registry**: register local project tree for ASDF discovery.
- **clambda-agent-loop**: canonical tool-capable loop architecture.
- **emacs-style-config**: `init.lisp` + hooks + defoption model.
- **mcclim-chat-app**: frame/pane layout + safe redisplay + threaded workers.
- **openai-compat-client**: dexador+jzon client pattern with stream handling.
- **queue-channel-clos**: lock/cvar FIFO channel abstraction.
- **sse-streaming-parsing**: robust SSE line parsing for token callbacks.
- **structured-jsonl-logging**: nonfatal append-only event logs.
- **subagent-handle**: thread + status/result handle synchronization pattern.
- **tui-ansi-streaming**: force-output token rendering and slash command loop.
- **workspace-memory-injection**: priority markdown loading + prompt injection.

---

## 15) Dependencies (Quicklisp systems and role)

From ASDF manifests:

- `alexandria` — utility helpers/macros
- `com.inuoe.jzon` — JSON parse/stringify
- `dexador` — HTTP client
- `cl-ppcre` — regex parsing/cleanup (SSE, HTML stripping)
- `uiop` — path/process/filesystem utilities
- `bordeaux-threads` — cross-impl threading primitives
- `hunchentoot` — HTTP server framework
- `usocket` — IRC TCP sockets
- `cl+ssl` — TLS for IRC
- `swank` — SLIME runtime bridge
- `mcclim` — GUI toolkit (clawmacs-gui)
- `parachute` — tests

---

## 16) File Inventory (source-centric)

### cl-llm

- `projects/cl-llm/src/packages.lisp` — package/export definitions
- `.../conditions.lisp` — LLM/client conditions
- `.../json.lisp` — JSON adapter helpers
- `.../http.lisp` — HTTP request + retry/backoff
- `.../protocol.lisp` — protocol structs and converters
- `.../client.lisp` — high-level chat APIs
- `.../streaming.lisp` — SSE parsing/stream accumulation
- `.../tools.lisp` — lightweight tool registry helpers

### cl-tui

- `projects/cl-tui/src/packages.lisp` — packages
- `.../ansi.lisp` — escape and color helpers
- `.../state.lisp` — app state model
- `.../display.lisp` — rendering functions
- `.../commands.lisp` — slash commands
- `.../loop.lisp` — TUI run loop entrypoint

### clawmacs-core (`projects/clambda-core/src`)

- `packages.lisp` — all package boundaries and exports
- `conditions.lisp` — clawmacs condition hierarchy
- `agent.lisp` — agent class + prompt/workspace logic
- `session.lisp` — sessions + persistence
- `tools.lisp` — tool registry/protocol/dispatch
- `logging.lisp` — JSONL structured logging
- `memory.lisp` — workspace memory ingest/search/render
- `builtins.lisp` — built-in tools implementations
- `loop.lisp` — core multi-turn runtime loop
- `registry.lisp` — named agent specs + DSL + inter-agent queue
- `subagents.lisp` — asynchronous child agent execution
- `channels.lisp` — abstract channel protocol + REPL/queue channels
- `cron.lisp` — scheduler subsystem
- `http-server.lisp` — HTTP API + management endpoints
- `config.lisp` — init.lisp configuration runtime
- `telegram.lisp` — Telegram channel adapter
- `irc.lisp` — IRC channel adapter
- `browser.lisp` — Playwright bridge client + browser tools
- `swank.lisp` — runtime SWANK management
- `image.lisp` — image save/restore entrypoints

### clawmacs-core browser bridge

- `projects/clambda-core/browser/playwright-bridge.js` — Node Playwright command bridge
- `.../package.json` — bridge dependency manifest

### clawmacs-gui

- `projects/clambda-gui/src/packages.lisp` — packages
- `.../colors.lisp` — palette/ink constants
- `.../chat-record.lisp` — GUI message record type
- `.../frame.lisp` — McCLIM frame and panes
- `.../display.lisp` — pane display logic
- `.../commands.lisp` — GUI command table actions
- `.../main.lisp` — run/launch entrypoints

### ASDF roots

- `projects/cl-llm/cl-llm.asd`
- `projects/cl-tui/cl-tui.asd`
- `projects/clambda-core/clawmacs-core.asd`
- `projects/clambda-gui/clambda-gui.asd`

---

## Rebuild Blueprint (practical sequence)

1. Create ASDF systems and package files first.
2. Implement `cl-llm` protocol + HTTP + streaming.
3. Build clawmacs-core nucleus: conditions, agent, session, tools, loop.
4. Add builtins + logging + memory + persistence.
5. Add registry + subagents + channels abstraction.
6. Add transport adapters: telegram, irc, browser.
7. Add cron + HTTP management API.
8. Add config system (`init.lisp`) and `clawmacs-user` package.
9. Add superpowers: swank + image.
10. Add tests in each phase; run `asdf:test-system` continuously.

---

## Appendix: Key code snippets

### Define and run an agent

```lisp
(let* ((client (cl-llm:make-client :base-url "http://host:1234/v1"
                                   :api-key "not-needed"
                                   :model "google/gemma-3-4b"))
       (registry (clawmacs:make-builtin-registry))
       (agent (clawmacs:make-agent :name "assistant" :client client :tool-registry registry))
       (session (clawmacs:make-session :agent agent)))
  (clawmacs:run-agent session "Hello"))
```

### Define a custom tool

```lisp
(clawmacs:define-tool registry "greet" "Greet a person"
  (("name" "string" "Person name"))
  (format nil "Hello, ~a" name))
```

### Register channels in init.lisp

```lisp
(register-channel :telegram :token "..." :allowed-users '(12345))
(register-channel :irc :server "irc.libera.chat" :port 6697 :tls t :nick "clawmacs" :channels '("#clawmacs"))
(start-all-channels)
```

### Start management API

```lisp
(setf clawmacs:*api-token* "secret")
(clawmacs:start-server :port 7474)
```

---

This document is the canonical architecture and rebuild reference for Clawmacs.
