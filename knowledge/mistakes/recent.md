# Mistakes Log

> Running log of things that went wrong and what fixed them.
> **Always read this before starting implementation.**
> Append new mistakes — never delete old ones.

---

## Index

| # | Date | Category | Summary |
|---|------|---------|---------|
| 1 | 2026-02-26 | runtime/mcclim | `redisplay-frame-pane` before `run-frame-top-level` → NIL crash |
| 2 | 2026-02-26 | idiom/streams | `get-output-stream-string` clears the stream on every call |
| 3 | 2026-02-26 | packages | `*on-stream-delta*` not re-exported by top-level `clambda` package |
| 15 | 2026-02-26 | idiom/uiop | `uiop:parse-native-namestring` wrapping the result of `uiop:ensure-directory-pathname` → type error |
| 4 | 2026-02-26 | runtime/http | `dexador :want-stream t` returns stream as FIRST value, not extra |
| 5 | 2026-02-26 | asdf/packaging | `parse-sse-line` used before being exported |
| 6 | 2026-02-26 | asdf/packaging | `completion-response` missing `:conc-name` → wrong accessor names |
| 7 | 2026-02-26 | asdf/packaging | `make-tool-definition` constructor not exported |
| 8 | 2026-02-26 | runtime/env | `LD_LIBRARY_PATH` not set → CFFI can't find `libcrypto.so.3` |
| 9 | 2026-02-26 | idiom/sbcl | `--eval` with multiple top-level forms |
| 10 | 2026-02-26 | idiom/format | Literal `~` in format string → "Unknown directive" |
| 11 | 2026-02-26 | idiom/control | `return-from NAME` inside a lambda → "unknown block" |
| 12 | 2026-02-26 | packages | `clambda/loop` missing accessor imports for CLOS class |
| 13 | 2026-02-26 | idiom/assert | `(assert cond "message")` → "value not of type LIST" |
| 14 | 2026-02-26 | runtime/json | Nested plist → JSON array not object (shallow `plist->object`) |

---

## Category: runtime/mcclim

### #1 — 2026-02-26
**What:** Calling `clim:redisplay-frame-pane` before `clim:run-frame-top-level` causes "no applicable method for `pane-needs-redisplay` when called with NIL".
**Why:** `find-pane-named` returns NIL for panes that haven't been adopted/realized yet. Panes are only live after `run-frame-top-level` starts.
**Fix:** Add a `safe-redisplay` helper that calls `find-pane-named` first and only redisplays if the pane is non-NIL. For pre-launch setup, use `append-chat-message` (just sets the slot, no redisplay).
**Lesson:** Never call `redisplay-frame-pane` on a frame before its top-level is running. McCLIM panes are live only after `run-frame-top-level`.
**Tags:** #mcclim #redisplay #frames #initialization

---

## Category: idiom/streams

### #2 — 2026-02-26
**What:** `get-output-stream-string` **clears** the string-output-stream on every call. Using it in a streaming delta callback to update a display buffer produced a buffer showing only the LAST token, not the accumulated text.
**Why:** Per CL spec, `get-output-stream-string` returns all accumulated chars AND resets the internal buffer. So each call discards previous content.
**Fix:** Accumulate into an adjustable char array with fill-pointer: `(vector-push-extend ch buf)`. Snapshot with `(coerce buf 'string)` which does NOT clear the array.
**Lesson:** For streaming accumulation, use adjustable arrays or `with-output-to-string`. Never use `make-string-output-stream` + `get-output-stream-string` in a hot loop where you need the full history on each call.
**Tags:** #streams #mcclim #streaming #idiom

---

## Category: packages

### #3 — 2026-02-26
**What:** `*on-stream-delta*` is exported from `clambda/loop` but NOT re-exported by the top-level `clambda` package.
**Why:** The `clambda` package only `:import-from`s `#:*on-tool-call*`, `#:*on-tool-result*`, `#:*on-llm-response*` from `clambda/loop` — omits `*on-stream-delta*`.
**Fix:** `:import-from #:clambda/loop #:*on-stream-delta*` directly in the downstream package.
**Lesson:** The `clambda` convenience package is incomplete. Always check which symbols are re-exported when using convenience packages. Prefer `#:clambda/loop` when you need the full loop API.
**Tags:** #packages #exports #clambda

### #12 — 2026-02-26
**What:** `clambda/loop` package couldn't find `session-agent`, `agent-client`, etc. at runtime — "function undefined" errors.
**Why:** The package only imported the *class names* (`#:agent`, `#:session`) but not the accessor functions. Since `(:use #:cl)` doesn't pull in other packages, all external symbols must be explicitly imported.
**Fix:** Added all needed accessors to `(:import-from ...)` in the `defpackage` form for `clambda/loop`.
**Lesson:** When a package uses `(:use #:cl)` only (not other packages), every external function must be explicitly `:import-from`'d or used as a package-qualified name. The class name import does NOT automatically import its accessors.
**Tags:** #packages #clos #imports

---

## Category: runtime/http

### #4 — 2026-02-26
**What:** `post-json-stream` bound `stream` as the 5th return value from `dexador:post`, but dexador with `:want-stream t` returns the stream as the *first* value (the body IS the stream).
**Why:** Misread the dexador API — assumed `:want-stream` added an extra return value, but it replaces the body with the stream.
**Fix:** `(let ((stream (dexador:post ... :want-stream t))) ...)` — just bind the single primary return value.
**Lesson:** Read dexador docs carefully. `:want-stream t` means: return the response body as a Gray stream (first value). It doesn't change the arity — it replaces the bytes with a stream.
**Tags:** #dexador #http #streaming

---

## Category: asdf/packaging

### #5 — 2026-02-26
**What:** `parse-sse-line` used in `client.lisp` via `cl-llm/streaming:parse-sse-line` but not exported from the `cl-llm/streaming` package.
**Why:** Wrote the package defpackage exports before the implementation, missed adding the internal helper.
**Fix:** Added `#:parse-sse-line` to `cl-llm/streaming`'s `:export` list.
**Lesson:** When packages have serial dependencies, compile early and check export errors before writing downstream code.
**Tags:** #packages #exports

### #6 — 2026-02-26
**What:** `completion-response` struct had no `:conc-name` so it generated `completion-response-id`, `completion-response-model` etc., but the packages exported `response-id`, `response-model` etc. which didn't exist.
**Why:** Forgot to set `(:conc-name response-)` on the struct to match the intended export names.
**Fix:** `(defstruct (completion-response (:conc-name response-)) ...)`.
**Lesson:** When designing a struct, decide on the public accessor prefix *before* writing the package exports, and use `:conc-name` explicitly.
**Tags:** #clos #packages #structs

### #7 — 2026-02-26
**What:** `make-tool-definition` was used in `tools.lisp` but wasn't exported from `cl-llm/protocol`, causing a package import error.
**Why:** Only exported `tool-definition` (the type name) but not the constructor `make-tool-definition`.
**Fix:** Added `#:make-tool-definition` to the protocol package's export list.
**Lesson:** For each struct in a public package, export both the type name and the constructor `make-*`. Accessors as needed.
**Tags:** #packages #structs #exports

---

## Category: runtime/env

### #8 — 2026-02-26
**What:** LD_LIBRARY_PATH not set in the environment, so dexador/CFFI couldn't find `libcrypto.so.3` even though it's at `/lib/x86_64-linux-gnu/libcrypto.so.3`.
**Why:** Guix profile has its own isolated paths; system libcrypto is there but not on CFFI's search path.
**Fix:** `export LD_LIBRARY_PATH="/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH"` before running SBCL.
**Lesson:** When using CFFI on Guix systems, always ensure `LD_LIBRARY_PATH` includes system library paths. Consider adding this to a wrapper script.
**Tags:** #cffi #ffi #guix #environment

---

## Category: idiom/sbcl

### #9 — 2026-02-26
**What:** Put multiline code in `--eval` options; SBCL rejects `--eval` with multiple top-level forms.
**Why:** Forgot SBCL's `--eval` restriction: one form per `--eval` option.
**Fix:** Either use multiple `--eval` flags, or write to a temp file and use `--load`.
**Lesson:** Use `--load` for anything more than a one-liner. Or write a wrapper `.lisp` script.
**Tags:** #sbcl #shell #repl

---

## Category: idiom/format

### #10 — 2026-02-26
**What:** Used `~` literally in a `format` string (as `"  ~ Streaming..."`) causing "Unknown directive" compile error.
**Why:** `~` is the FORMAT directive prefix in CL. A literal tilde must be doubled as `~~`.
**Fix:** Either use `~~` for a literal tilde, or rephrase to avoid the character.
**Lesson:** Any `~` in a format string is a directive. Use `~~` for literal tilde.
**Tags:** #format #idiom #cl

---

## Category: idiom/control

### #11 — 2026-02-26
**What:** Used `(return-from clambda/tools:register-tool! ...)` inside a lambda inside `register-tool!`. SBCL rejected it: "return for unknown block".
**Why:** `return-from` jumps to a named block. Functions defined with `defun` create a block with the function's name. But `register-tool!` is a function, and the lambda is a *different* function — so there's no block named `clambda/tools:register-tool!` in scope inside the lambda.
**Fix:** Use regular conditional logic (`cond`, `if`, `when`) instead of `return-from` inside lambdas.
**Lesson:** `return-from NAME` only works if you're lexically inside a `(block NAME ...)` or `(defun NAME ...)` form. Never use it to escape from a lambda — use `return` (from a `(block nil ...)`) or just restructure with `cond`.
**Tags:** #idiom #control-flow #lambdas

---

## Category: idiom/assert

### #13 — 2026-02-26
**What:** `(assert value "error message")` caused compile error: "value is not of type LIST".
**Why:** CL's `assert` syntax is `(assert test [places [datum args...]])`. The second argument is `places` (a list of generalized references). A string is not a valid places list.
**Fix:** `(assert test () "error message")` — pass empty list `()` for places, then the string datum.
**Lesson:** CL `assert` is NOT like `assert(condition, message)` from other languages. Always write `(assert test () "message ~a" arg)`.
**Tags:** #idiom #assert #cl

---

## Category: runtime/json

### #14 — 2026-02-26
**What:** Tool parameters with nested `properties` were serialized as JSON arrays instead of objects, causing HTTP 400 from LM Studio.
**Why:** `cl-llm/json:plist->object` only converts the top-level plist to a hash-table. Nested plists (like the `properties` value) are left as CL lists, which jzon serializes as JSON arrays.
**Fix:** Wrote `schema-plist->ht` in `clambda/tools` — a recursive converter that specially handles the `"properties"` key by iterating its plist and recursively converting each property schema.
**Lesson:** `plist->object` is shallow. For nested JSON schemas, write a recursive converter. The `"properties"` field in JSON Schema is a JSON object (keyed by property name), not an array.
**Tags:** #json #schema #tools #runtime

---

## Category: idiom/uiop

### #15 — 2026-02-26
**What:** Wrapped `uiop:ensure-directory-pathname` result inside `uiop:parse-native-namestring`, causing `SIMPLE-TYPE-ERROR`: "value #P\"/some/path/\" is not of type (OR STRING NULL)".
**Why:** `uiop:ensure-directory-pathname` returns a PATHNAME object. `uiop:parse-native-namestring` expects a string. Nesting them creates a type mismatch.
**Fix:** Accept string or pathname defensively:
  ```lisp
  (uiop:ensure-directory-pathname
   (if (stringp path)
       (uiop:parse-native-namestring path)
       path))
  ```
  Or just use `uiop:ensure-directory-pathname` directly — it accepts both strings and pathnames.
**Lesson:** `uiop:ensure-directory-pathname` already handles strings. Don't wrap its output in `parse-native-namestring`. When writing functions that accept workspace paths, accept both strings and pathnames with an `(if (stringp p) ...)` guard.
**Tags:** #uiop #pathnames #idiom #runtime
