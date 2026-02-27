# Clawmacs Missing Features (vs OpenClaw)

> Identified during Phase 1 of the migration pipeline.
> Date: 2026-02-27

---

## Priority 1 — Important for ceo_chryso parity

### 1.1 Streaming Partial Telegram Responses

**OpenClaw behaviour:** Telegram messages are updated incrementally as the LLM streams
tokens. OpenClaw's `streaming: "partial"` config sends an initial placeholder message
and calls `editMessageText` repeatedly as tokens accumulate.

**Clawmacs current state:** `%handle-message` in `src/telegram.lisp` calls `run-agent`
with `:stream nil`. The full response is sent in one `sendMessage` call after the agent
loop completes.

**What's needed:**
1. Set `:stream t` in the Telegram `run-agent` call
2. Send an initial "thinking..." placeholder via `sendMessage` (capturing the `message_id`)
3. Bind `clawmacs/loop:*on-stream-delta*` to accumulate tokens into a buffer
4. Debounce `editMessageText` calls — update every ~500ms or every N chars (not every token)
5. After `run-agent` returns, do a final `editMessageText` with the complete response
6. Handle Telegram's 4096-char message limit (split if needed, editing splits separately)
7. Add `*telegram-streaming*` option (boolean, default T) to `clawmacs/telegram`
8. Expose streaming option via `register-channel :telegram :streaming t`

**Files to modify:** `src/telegram.lisp`
**New API options:** `*telegram-streaming*`, `*telegram-stream-debounce-ms*` (default 500)

---

### 1.2 Per-Channel IRC Allowlists

**OpenClaw behaviour:** IRC has separate policies for DMs and channels:
- `dmPolicy: allowlist, allowFrom: ["tay"]` — only `tay` can DM the bot
- `groups.#bots.allowFrom: ["*"]` — any user in #bots can address the bot

**Clawmacs current state:** `irc-connection` has a single `allowed-users` list for the
entire connection. Setting it to `'("tay")` blocks #bots users; setting to `nil` allows
all DMs.

**What's needed:**
1. Add a `channel-policies` slot to `irc-connection` struct: alist of `(channel-name . policy-plist)`
2. Policy plist: `(:allowed-users ("alice" "bob") :require-mention t)`
3. In `%dispatch-line`: for channel messages, look up channel-specific policy first; fall back to global
4. For DMs (PRIVMSG to bot nick): use global `allowed-users`
5. Expose via `register-channel :irc`:
   ```lisp
   :channel-policies '(("#bots" :allowed-users nil)   ; all allowed in #bots
                       ("#priv" :allowed-users ("alice")))
   ```
6. Add `:dm-allowed-users` parameter for DM-specific allowlist

**Files to modify:** `src/irc.lisp`
**New API:** `irc-channel-policy`, `:channel-policies` register-channel key, `:dm-allowed-users`

---

## Priority 2 — Useful but not blocking

### 2.1 Anthropic Native API Support in cl-llm

**OpenClaw behaviour:** Uses Anthropic's native API for Claude models directly.

**Clawmacs current state:** `cl-llm` only supports OpenAI-compatible APIs.
Anthropic can be reached via OpenRouter (OpenAI shim) but lacks:
- Prompt caching headers
- Streaming with native format
- Thinking/extended reasoning

**What's needed:**
1. New `cl-llm/anthropic` package in the `cl-llm` ASDF system
2. `make-anthropic-client` — builds a client struct with `:api :anthropic`
3. `post-anthropic-chat` — sends to `https://api.anthropic.com/v1/messages`
   with correct headers (`anthropic-version`, `x-api-key`)
4. Message format translation (OpenAI ↔ Anthropic differ in `tool_result` structure)
5. Streaming SSE format is similar but uses different event types
6. Update `cl-llm:chat` dispatch to handle `:api :anthropic` clients

**Files to create/modify:** `cl-llm/src/anthropic.lisp`, `cl-llm/cl-llm.asd`, `cl-llm/src/packages.lisp`
**Effort:** Medium-Large (3–5 days)

---

### 2.2 Skills / SKILL.md Plugin System

**OpenClaw behaviour:** Skills directories contain `SKILL.md` files describing tools
and capability instructions. Skills are loaded at startup and injected into agent prompts.

**Clawmacs current state:** No skills system. Users define tools via `define-user-tool` in
`init.lisp` (which is actually more powerful — but loses the portability of SKILL.md files).

**What's needed:**
1. `clawmacs/skills` module
2. Scan `~/.clawmacs/skills/` (and workspace-local `skills/`) for `SKILL.md` files
3. Parse SKILL.md: extract tool descriptions, parameter schemas, and prompt injection text
4. Register found tools into agent registries at startup
5. Add skill instructions to system prompt via hook

**Files to create:** `src/skills.lisp`
**Effort:** Medium (2–3 days) — already on ROADMAP as Priority 1.3

---

## Priority 3 — Lower priority gaps

### 3.1 WhatsApp Channel

Not implemented. OpenClaw has WhatsApp via a bridge.
Low priority for initial migration.

### 3.2 Agent Identity / Theme System

OpenClaw has `identity.name`, `identity.theme`, `identity.emoji` per agent.
Clawmacs has no equivalent. Could be implemented as metadata on `agent` structs.

### 3.3 Compaction / Safeguard Mode

OpenClaw has context compaction with `safeguard` mode (warns before compaction).
Clawmacs has token budget (`budget-exceeded` condition) but no automatic compaction.
Could summarise session history when approaching token limit.

### 3.4 Pairing System for DMs

OpenClaw has `dmPolicy: pairing` where new DM users must be paired first.
Clawmacs only has allowlist (must pre-configure user IDs). No pairing handshake.

### 3.5 Multiple Simultaneous Telegram Accounts

OpenClaw runs multiple bot accounts simultaneously (one per agent).
Clawmacs's current `register-channel :telegram` supports only one bot at a time.
Would require refactoring to a list of channels rather than a singleton `*telegram-channel*`.

---

## Implementation Plan

**Gensym tasks (ordered):**

1. **1.1 Telegram streaming** — modify `src/telegram.lisp`; highest user-facing value
2. **1.2 IRC per-channel allowlists** — modify `src/irc.lisp`; needed for correct DM restriction
3. **2.1 Anthropic native API** — add `cl-llm/anthropic`; needed for cloud model parity

Items 1 and 2 should unblock Phase 2 (boot and verify) for full config parity.
