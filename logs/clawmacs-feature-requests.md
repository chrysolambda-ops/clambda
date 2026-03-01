
## [2026-03-01] BUG: TYPE-ERROR in %MAYBE-COMPACT-SESSION-CONTEXT (CRITICAL)

**Reported by:** ceo-chryso (cl-term project session)
**Severity:** Critical — causes daemon crash

**Error:**
```
TYPE-ERROR when setting slot CL-LLM/PROTOCOL::CONTENT of structure CL-LLM/PROTOCOL:MESSAGE
Value: #S(CL-LLM/PROTOCOL:COMPLETION-RESPONSE ...)
```

**Stack trace location:** `CLAWMACS/LOOP::%MAYBE-COMPACT-SESSION-CONTEXT`

**What happens:** When the session history grows and context compaction triggers, `%MAYBE-COMPACT-SESSION-CONTEXT` attempts to create a summary message but passes a raw COMPLETION-RESPONSE struct as the :CONTENT slot instead of a string. This causes a TYPE-ERROR that cascades.

**Secondary issue:** Combined with heap exhaustion (SBCL heap hit 1GB limit), daemon is killed.

**Fix needed:**
1. In `%MAYBE-COMPACT-SESSION-CONTEXT`, ensure the content passed to `make-message` or equivalent is a string, not a struct.
2. Consider increasing SBCL heap size or using `--dynamic-space-size` flag (e.g., 2048MB).

**Workaround:** Use fresh sessions with no compaction; keep sessions short.

## [2026-03-01] BUG: write_file tool mangles newlines

**Reported by:** ceo-chryso (cl-term project)
**Severity:** High — files written with literal \n instead of real newlines

**What happens:** When Gensym calls write_file with multi-line content, the content contains
literal backslash-n sequences instead of actual newlines. The file ends up as one long line
with `n` characters between what should be separate lines.

**Root cause:** Likely the model outputs `\n` in its JSON tool_call arguments, and the
write_file tool implementation does not unescape them before writing to disk.

**Fix needed:** In the write_file tool implementation, call `(cl:substitute #\Newline #\n content)`
or use `(cl:read-from-string (format nil "\"~a\"" content))` to process escape sequences.
Or better: ensure the JSON argument parser properly converts \\n → newline.

**Workaround:** Use exec tool with printf/heredoc to write files.

## [2026-03-01] CRITICAL: Heap exhaustion even with 4GB dynamic-space-size

**Reported by:** ceo-chryso (cl-term project)
**Severity:** Critical — makes Clawmacs unusable for multi-turn agent sessions

**What happens:** SBCL exhausts 4GB heap during agent turns. The system prompt builder
loads all workspace files + tool schemas, and LLM responses are kept in session history.
Combined, this causes rapid heap growth.

**Stack of fixes needed:**
1. The system-prompt builder should be lazy/cached, not rebuilding every turn
2. Session messages should not keep full raw response structs in memory — only the text
3. GC should be triggered more aggressively between tool calls
4. The LLM client should not cache full response objects

**Workaround attempted:** --dynamic-space-size 4096 — still runs out.

**Suggested fix:** Add `(sb-ext:gc :full t)` calls between agent turns, and ensure
old completion-response structs are not retained in session history (only the text/role).

**Impact:** Cannot run sustained multi-turn sessions through SWANK. Every 2-3 turns crashes.

---
## SUMMARY: Critical bugs blocking cl-term project (2026-03-01, from ceo-chryso)

These three bugs are **blocking** active development. Please fix urgently:

### BUG-1 (CRITICAL): write_file tool mangles newlines
- Tool writes literal `\n` characters instead of real newlines
- Every file created by the agent is one long line with `n` chars between logical lines
- Fix: in write_file handler, unescape `\n` → newline, `\t` → tab, `\\` → backslash in content arg
- Location: likely `src/tools.lisp` or `src/builtins.lisp` in write_file tool definition

### BUG-2 (CRITICAL): %MAYBE-COMPACT-SESSION-CONTEXT TYPE-ERROR
- Condition: `TYPE-ERROR when setting CONTENT of MESSAGE to COMPLETION-RESPONSE struct`
- Stack: `CLAWMACS/LOOP::%MAYBE-COMPACT-SESSION-CONTEXT` → crash
- Fix: ensure compaction summary is written as a string, not a raw response struct
- Workaround in place: disabled *compaction-enabled* via SWANK

### BUG-3 (CRITICAL): Heap exhaustion after 2-3 agent turns
- SBCL runs out of heap even at 4GB dynamic-space-size
- System prompt builder loads full workspace + all tool schemas every turn
- Old COMPLETION-RESPONSE structs may be retained in session history
- Fix: (a) cache system prompt, (b) strip raw structs from session after each turn, (c) add `(sb-ext:gc :full t)` between turns

### BUG-4 (MEDIUM): Agent loop hits max-turns when model doesn't terminate
- With local models (gemma-3-4b), the model calls tools repeatedly without reaching `stop`
- Fix: detect repeated identical tool calls and break; or increase stop_sequences
- Not critical now that we use Claude Opus

## [2026-03-01] BUG: DeepSeek-R1 <think> tags break tool dispatch

**Reported by:** ceo-chryso (cl-term project)
**Severity:** High

**What happens:** DeepSeek-R1 (deepseek/deepseek-r1-0528-qwen3-8b) returns `<think>...</think>` 
reasoning blocks in the response content. When extracting tool calls, Clawmacs' cl-llm 
parser dispatches a tool named "tool_name" instead of the actual function name.

**Likely cause:** The response content field contains the think block, and the tool-call 
extraction code gets confused by the mixed content/tool-call response structure.

**Fix:** Strip `<think>...</think>` blocks from content before tool-call extraction, OR 
check the OpenAI-compatible `tool_calls` field directly (which is separate from content).

## [2026-03-01] BUG: max_tokens set too high (65536) — causes OpenRouter 402

**Reported by:** ceo-chryso
**Severity:** High — consumes OpenRouter credits rapidly

**What happens:** The LLM client sends requests with max_tokens=65536 (OpenAI default context).
OpenRouter rejects these with HTTP 402 when account balance is insufficient.

**Fix:** Set a reasonable default max_tokens (e.g., 4096 for coding tasks).
Reduce *default-context-window* in init.lisp from 32768 or add :max-tokens option to run-agent.
