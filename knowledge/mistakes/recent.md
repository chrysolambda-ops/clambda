# Recent Mistakes

## 2026-02-26 Category: runtime
**What:** `post-json-stream` bound `stream` as the 5th return value from `dexador:post`, but dexador with `:want-stream t` returns the stream as the *first* value (the body IS the stream).
**Why:** Misread the dexador API — assumed `:want-stream` added an extra return value, but it replaces the body with the stream.
**Fix:** `(let ((stream (dexador:post ... :want-stream t))) ...)` — just bind the single primary return value.
**Lesson:** Read dexador docs carefully. `:want-stream t` means: return the response body as a Gray stream (first value). It doesn't change the arity — it replaces the bytes with a stream.
**Tags:** #dexador #http #streaming

## 2026-02-26 Category: asdf/packaging  
**What:** `parse-sse-line` used in `client.lisp` via `cl-llm/streaming:parse-sse-line` but not exported from the `cl-llm/streaming` package.
**Why:** Wrote the package defpackage exports before the implementation, missed adding the internal helper.
**Fix:** Added `#:parse-sse-line` to `cl-llm/streaming`'s `:export` list.
**Lesson:** When packages have serial dependencies, compile early and check export errors before writing downstream code.
**Tags:** #packages #exports

## 2026-02-26 Category: asdf/packaging
**What:** `completion-response` struct had no `:conc-name` so it generated `completion-response-id`, `completion-response-model` etc., but the packages exported `response-id`, `response-model` etc. which didn't exist.
**Why:** Forgot to set `(:conc-name response-)` on the struct to match the intended export names.
**Fix:** `(defstruct (completion-response (:conc-name response-)) ...)`.
**Lesson:** When designing a struct, decide on the public accessor prefix *before* writing the package exports, and use `:conc-name` explicitly.
**Tags:** #clos #packages #structs

## 2026-02-26 Category: asdf/packaging
**What:** `make-tool-definition` was used in `tools.lisp` but wasn't exported from `cl-llm/protocol`, causing a package import error.
**Why:** Only exported `tool-definition` (the type name) but not the constructor `make-tool-definition`.
**Fix:** Added `#:make-tool-definition` to the protocol package's export list.
**Lesson:** For each struct in a public package, export both the type name and the constructor `make-*`. Accessors as needed.
**Tags:** #packages #structs #exports

## 2026-02-26 Category: runtime
**What:** LD_LIBRARY_PATH not set in the environment, so dexador/CFFI couldn't find `libcrypto.so.3` even though it's at `/lib/x86_64-linux-gnu/libcrypto.so.3`.
**Why:** Guix profile has its own isolated paths; system libcrypto is there but not on CFFI's search path.
**Fix:** `export LD_LIBRARY_PATH="/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH"` before running SBCL.
**Lesson:** When using CFFI on Guix systems, always ensure `LD_LIBRARY_PATH` includes system library paths. Consider adding this to a wrapper script.
**Tags:** #cffi #ffi #guix #environment

## 2026-02-26 Category: idiom
**What:** Put multiline code in `--eval` options; SBCL rejects `--eval` with multiple top-level forms.
**Why:** Forgot SBCL's `--eval` restriction: one form per `--eval` option.
**Fix:** Either use multiple `--eval` flags, or write to a temp file and use `--load`.
**Lesson:** Use `--load` for anything more than a one-liner. Or write a wrapper `.lisp` script.
**Tags:** #sbcl #shell #repl

## 2026-02-26 Category: idiom
**What:** Used `~` literally in a `format` string (as `"  ~ Streaming..."`) causing "Unknown directive" compile error.
**Why:** `~` is the FORMAT directive prefix in CL. A literal tilde must be doubled as `~~`.
**Fix:** Either use `~~` for a literal tilde, or rephrase to avoid the character.
**Lesson:** Any `~` in a format string is a directive. Use `~~` for literal tilde.
**Tags:** #format #idiom #cl
