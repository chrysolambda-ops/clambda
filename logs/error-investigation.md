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
