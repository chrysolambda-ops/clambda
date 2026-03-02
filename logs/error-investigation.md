# Clawmacs Error Investigation

## 2026-03-01 ~22:00Z — HTTP 400 "No models loaded" (LM Studio routing)

**Log line:** `[2026-03-01T22:00:29Z] [llm] ERROR: HTTP 400 on model anthropic/claude-sonnet-4-6`
```
"No models loaded. Please load a model in the developer page or use the 'lms load' command."
```

**Analysis:**
This error message originates from LM Studio's local server, not OpenRouter. Clawmacs sent a request
intended for OpenRouter (`anthropic/claude-sonnet-4-6`) but it landed on a local LM Studio instance
(typically `http://localhost:1234`). This means the LLM backend URL was pointing at LM Studio at
the time of the request.

**Likely cause:** Either:
1. The LLM base URL config switched to `localhost:1234` (LM Studio default) instead of the OpenRouter URL.
2. A fallback/retry logic tried a local endpoint after the string of OpenRouter 402 failures.
3. Config was manually changed or a different config profile was loaded.

**Recommended fix:**
- Check Clawmacs LLM config for the base URL; ensure it points to OpenRouter for cloud models.
- If local fallback is intentional, the model name `anthropic/claude-sonnet-4-6` won't exist locally —
  fallback should use a locally-loaded model name, or skip gracefully if none loaded.
- Review retry/fallback logic to prevent sending cloud model names to local endpoints.

**Severity:** Medium — routing misconfiguration that could cause silent failures.

---

## 2026-03-01 ~22:00Z — HTTP 400 deepseek model crash

**Log line:** `[2026-03-01T22:00:29Z] [llm] ERROR: HTTP 400 on model deepseek/deepseek-r1-0528-qwen3-8b`
```
"The model has crashed without additional information. (Exit code: null)"
```

**Analysis:** Remote model crash on OpenRouter's infrastructure. Not a Clawmacs code issue.

**Recommended action:** No code fix needed. Consider retry with exponential backoff or a fallback
model for this error code if this model is used regularly.

---

## Ongoing — HTTP 402 credit exhaustion (lines 1–61)

**Pattern:** `claude-opus-4-6` and `claude-sonnet-4-6` requests failing with 402 due to low weekly
credit balance on OpenRouter key. Credits declined from ~61k to ~27k tokens over ~29 minutes.

**Not a code issue.** Requires OpenRouter account top-up or weekly limit increase at:
https://openrouter.ai/settings/keys

---

_Last updated: 2026-03-01T22:20Z by error-patrol cron_
## 2026-03-01 18:50 EST (error patrol)

Observed new errors in `clawmacs-errors.log` (lines 1-63):
- Repeated OpenRouter HTTP 402 for `anthropic/claude-opus-4-6` and `anthropic/claude-sonnet-4-6` due to insufficient credits vs `max_tokens=65536`.
- One HTTP 400 for `deepseek/deepseek-r1-0528-qwen3-8b` indicating model crash.
- One HTTP 400 for `anthropic/claude-sonnet-4-6`: "No models loaded ... use lms load".

Assessment:
- These are runtime/provider/configuration issues, not clambda-core source-code exceptions.
- No safe/simple source fix under `projects/clambda-core/src/` would resolve provider credit exhaustion or unloaded model state.

Recommended ops fixes:
1. Reduce requested `max_tokens` for failing requests (well below current available credit ceiling).
2. Increase OpenRouter key weekly limit / credits.
3. Ensure local model is loaded before request path that targets local runtime (`lms load ...`).
4. Add guard/fallback model selection when provider returns 402/400.

## 2026-03-01 23:20 ET — clawmacs-error-patrol

Checked `/logs/clawmacs-errors.log` for new entries since `error-patrol-state.json` (`lastLine: 63`).

### New lines observed
- Lines 64-82: model access failures for `claude-sonnet-4-6` (`404 model_not_found`) with fallback attempts logged.
- Lines 84-118: provider quota failures (`429 insufficient_quota`).

### Source review
Reviewed:
- `src/config.lisp` (default token/model fallback settings)
- `src/loop.lisp` (`%chat-with-fallbacks`, `%retryable-http-error-p`)

Current behavior:
- Fallback routing is implemented and already active.
- 429 is treated as retryable.
- 404/402 are not in `%retryable-http-error-p`, but non-retryable branch still attempts fallback when additional models exist.

### Assessment
This looks primarily operational (provider/model availability + quota exhaustion), not a straightforward local code defect.
No safe “simple fix” identified that would actually resolve these specific errors without changing model/provider configuration.

### Suggested follow-up
- Ensure configured primary model exists/is accessible.
- Adjust provider billing/quota.
- Optionally set a reliably available local/default model as primary to reduce telegram-facing failures.
## 2026-03-01 23:50 EST — clawmacs-error-patrol

### New error(s) detected
- Log advanced from line 119 to 123.
- New multiline error at 2026-03-02T04:29:05Z:
  - `[telegram] Agent error ... Codex OAuth runtime failed`
  - Root exception text:
    - `The file #P"/home/slime/.openclaw/workspace-gensym/projects/clambda-core/{\"nil\":false}" does not exist`

### Triage performed
- Checked Telegram runtime path in:
  - `/home/slime/.openclaw/workspace-gensym/projects/clambda-core/src/telegram.lisp`
- Located codex-oauth bridge implementation in:
  - `/home/slime/.openclaw/workspace-gensym/projects/cl-llm/src/codex-oauth-bridge.lisp`
  - `/home/slime/.openclaw/workspace-gensym/projects/cl-llm/node/codex_oauth_helper.mjs`

### Preliminary diagnosis
- Failure is likely in the codex-oauth helper invocation path (`uiop:run-program` or related path handling) rather than application business logic.
- The injected path segment `{"nil":false}` strongly suggests a JSON false sentinel leaking into a pathname/cwd argument.
- Not a safe "simple fix" from current evidence; needs targeted repro with backtrace around `%run-node-helper` and/or caller context capturing cwd/directory argument values at failure time.

### Recommended next step
- Add temporary diagnostic logging around `uiop:run-program` call in `codex-oauth-bridge.lisp` (cwd, helper path, payload shape) and reproduce once.

## 2026-03-02T06:50 UTC — HTTP 401 invalid x-api-key

**New errors (lines 136–137):**
- `[2026-03-02T06:22:29Z] [llm] HTTP 401 on model claude-opus-4-6: invalid x-api-key`
- `[2026-03-02T06:22:29Z] [telegram] Agent error: HTTP error 401: invalid x-api-key`

**Assessment:** The Anthropic direct API key configured in Clawmacs is invalid or expired. This is a credential issue — no source code fix possible. The key needs to be rotated/updated in Clawmacs config.

**Historical context visible in log:**
- Lines before 136: Many HTTP 402 (OpenRouter out of credits), HTTP 429 (OpenAI quota exceeded), Codex OAuth runtime failures (`{"nil":false}` path bug — source fix already committed, but running process may need restart to pick it up)
- The `{"nil":false}` Codex OAuth bug: caused by wrong `remove nil ... :key #'null` idiom in `%messages->bridge-payload` producing a malformed plist. Fix (`%payload-input-stream`) is already in `codex-oauth-bridge.lisp` source; restart will apply it.

**Action needed by human:**
1. Rotate/update Anthropic direct API key in Clawmacs config
2. Consider restarting headless process to pick up Codex OAuth stream fix

## 2026-03-02 04:20 AM — Error Patrol Summary

### Issues Identified (pre-existing, no new lines since last patrol)

1. **OpenRouter 402 credit exhaustion** (~2026-03-01 21:50–22:00Z)
   - Models: claude-opus-4-6, claude-sonnet-4-6
   - Cause: weekly token limit exceeded on OpenRouter key
   - Fix: top up OpenRouter credits or lower max_tokens config

2. **Model 404 / bad model names** (~2026-03-02 03:55Z)
   - `claude-sonnet-4-6` not found; fallback `gpt-5.3-codex` also failed
   - Fix: verify model name strings in clawmacs config

3. **Codex OAuth runtime: file-not-found with JSON blob as path** (~04:29–06:05Z)
   - Error: `#P"/home/slime/.openclaw/workspace-gensym/projects/clambda-core/{\"nil\":false}"` does not exist
   - Likely cause: JSON value `{"nil": false}` being coerced to a pathname string somewhere in startup/OAuth config parsing
   - Investigate: `start-headless.lisp` and OAuth config reader for cl-json or similar returning nil as a structure that gets stringified into a path
   - Priority: HIGH — blocks runtime startup

4. **HTTP 401 invalid Anthropic API key** (~06:22Z)
   - Direct Anthropic calls failing auth
   - Fix: rotate/re-enter Anthropic API key

