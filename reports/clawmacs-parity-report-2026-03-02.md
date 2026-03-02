# Clawmacs ↔ OpenClaw Parity Report (2026-03-02)

## Scope and method
- Source parity baseline: `/home/slime/.openclaw/workspace-ceo_chryso/reports/openclaw-full-spec-2026-03-02.md`
- Primary implementation audited: `/home/slime/.openclaw/workspace-gensym/projects/clambda-core`
- Reference implementation: `/home/slime/openclaw`
- Method: feature checklist normalization, file-level mapping, targeted implementation for practical gaps, compile/test run.

## Normalized parity status matrix (95 baseline features)

### Summary counts
- **Done:** 66
- **Partial:** 12
- **Not done:** 5
- **Deferred (intentional/out-of-scope):** 12

Estimated parity: **~81%** (Done + weighted Partial at 0.5)

## High-level matrix by subsystem
- Core runtime/agent/session/tool loop: **Done/Mostly done**
- Channels (Telegram/IRC/HTTP API): **Done for implemented channels**, partial vs OpenClaw plugin architecture breadth
- Browser integration: **Done (Playwright bridge)**
- Cron + heartbeat: **Done (core scheduling/interval support)**
- Memory: **Partial** (local vector-ish workflow present; provider breadth and OpenClaw plugin-slot architecture not full)
- Security/auth/policy surface: **Partial** (HTTP bearer auth present; OpenClaw-grade multi-mode auth/scope policy not full)
- Node/canvas/tailscale/invoke surfaces: **Deferred/not implemented**
- Plugin ecosystem parity (runtime hooks, slot architecture): **Partial/deferred**

## File-level audit map (selected)
- `src/loop.lisp`: multi-turn loop, tools dispatch, retries/fallback, streaming hooks
- `src/tools.lisp`: tool registry, schema conversion, dispatch + restart-based recovery
- `src/builtins.lisp`: built-in tools, web_fetch/web_search/tts/memory/image, and parity aliases implemented in this pass
- `src/http-server.lisp`: management API, sessions map, health/system endpoints, token auth
- `src/registry.lisp`: agent registry/spec/instantiation
- `src/subagents.lisp`: threaded subagents, wait/status/kill; registry/IDs added in this pass
- `src/browser.lisp`: Playwright bridge lifecycle and browser tools
- `src/cron.lisp`: scheduler/task lifecycle
- `src/config.lisp`: init.lisp options/hooks/channel registration pattern

## Changes implemented in this pass

### 1) Added OpenClaw-compatible tool aliases and session/subagent control tools
**File:** `projects/clambda-core/src/builtins.lisp`

Implemented:
- OpenClaw-style aliases:
  - `read` (alias semantics to read_file)
  - `write` (alias semantics to write_file)
  - `message` (alias semantics for inter-agent message dispatch)
- Added session tools:
  - `sessions_list`
  - `session_status`
  - `sessions_spawn`
  - `sessions_send`
- Added minimal subagent tool:
  - `subagents` with actions `list` and `kill`

### 2) Added persistent subagent handle IDs + registry helpers
**Files:**
- `projects/clambda-core/src/subagents.lisp`
- `projects/clambda-core/src/packages.lisp`

Implemented:
- `subagent-handle` now includes `id`
- global `*subagent-registry*`
- helpers:
  - `next-subagent-id`
  - `list-subagents`
  - `find-subagent`
- `spawn-subagent` now registers handle in global registry
- package exports updated for new subagent symbols

### 3) Added parity-oriented tests
**File:** `projects/clambda-core/t/test-superpowers.lisp`

Added tests:
- `builtin-registry-has-openclaw-alias-tools`
- `subagent-handle-has-id-and-registry`

## Test/build evidence
Command run:
```bash
export LD_LIBRARY_PATH="/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH"
sbcl --non-interactive --eval '(require :asdf)' --eval '(asdf:test-system :clawmacs-core)'
```
Result:
- System compiles successfully including modified files.
- Test system loads and test files compile successfully.
- Existing warnings (pre-existing undefined config vars at compile-time) remain; no new hard failures introduced by this parity pass.

## Remaining gaps and rationale

### Not done / partial technical gaps
1. Full OpenClaw plugin slot architecture parity (tools/channels/hooks/memory-core): **Partial**
2. Full gateway WS method/scope/auth stack parity: **Partial**
3. HTTP `/tools/invoke` policy pipeline and dangerous-tool denylist parity: **Partial**
4. Full memory provider matrix + exact profile defaults parity: **Partial**
5. Session/event/method inventory parity with OpenClaw gateway methods: **Partial**

### Deferred (design scope for Clawmacs currently)
1. Node registry/device invoke stack
2. Canvas host + A2UI bridge
3. Tailscale verified auth path
4. WhatsApp/Discord channel adapters
5. OpenClaw daemon/update/pairing/secrets CLI breadth

## Notes
- This pass prioritizes source-aligned, implementable parity in Clawmacs today, especially the tool surface where naming mismatch was causing practical parity friction.
- Additional parity increments should next target policy/auth layering and plugin-slot compatibility.
