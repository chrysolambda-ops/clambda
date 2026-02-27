# Mistakes Log

> Running log of things that went wrong and what fixed them.
> **Always read this before starting implementation.**
> Append new mistakes — never delete old ones.

---

## Index

| # | Date | Category | Summary |
| 27 | 2026-02-27 | idiom/parachute | Used `is-true`/`is-false` (don't exist) instead of parachute's `true`/`false` predicates |
| 28 | 2026-02-27 | packages | Forgot to export new accessor `agent-spec-p` and `agent-turn-error-cause` — test import failed until added |
| 26 | 2026-02-27 | idiom/parens | Sub-agent generated one extra `)` in a deep nesting (11 instead of 10 after a streaming fallback branch); SBCL flagged "unmatched close parenthesis" at exact col — fix: count nesting levels manually |
| 22 | 2026-02-26 | asdf/packaging | `schema-plist->ht` missing from `clawmacs/tools` exports — broke `clawmacs/browser` package definition |
| 23 | 2026-02-26 | idiom/playwright | `page.accessibility.snapshot()` removed in Playwright >=1.47; use `page.locator('body').ariaSnapshot()` |
| 24 | 2026-02-26 | idiom/pathname | `merge-pathnames` on result of `asdf:system-relative-pathname` doubled the path segment — don't wrap, use directly |
| 25 | 2026-02-26 | idiom/parachute | `skip-on (not (my-fn))` fails — parachute's skip-on walks `and/or/not` combinators recursively; function calls as the innermost leaf are not supported; use `(when ...)` inside the test body instead |
| 20 | 2026-02-26 | packages | `clawmacs/irc` placed before `clawmacs/config` in packages.lisp — forward-ref error since it imports `register-channel` from config |
| 21 | 2026-02-26 | idiom/sbcl | Loading test package that uses `#:parachute` before parachute is loaded → PACKAGE-DOES-NOT-EXIST |
| 18 | 2026-02-26 | packages | `merge-user-tools!` defined in config.lisp but omitted from `clawmacs/config` exports |
| 19 | 2026-02-26 | idiom/clos | `(find-class '(eql :kw))` in `find-method` — wrong; use `sb-mop:intern-eql-specializer` |
|---|------|---------|---------|
| 1 | 2026-02-26 | runtime/mcclim | `redisplay-frame-pane` before `run-frame-top-level` → NIL crash |
| 2 | 2026-02-26 | idiom/streams | `get-output-stream-string` clears the stream on every call |
| 3 | 2026-02-26 | packages | `*on-stream-delta*` not re-exported by top-level `clawmacs` package |
| 15 | 2026-02-26 | idiom/uiop | `uiop:parse-native-namestring` wrapping the result of `uiop:ensure-directory-pathname` → type error |
| 4 | 2026-02-26 | runtime/http | `dexador :want-stream t` returns stream as FIRST value, not extra |
| 5 | 2026-02-26 | asdf/packaging | `parse-sse-line` used before being exported |
| 6 | 2026-02-26 | asdf/packaging | `completion-response` missing `:conc-name` → wrong accessor names |
| 7 | 2026-02-26 | asdf/packaging | `make-tool-definition` constructor not exported |
| 8 | 2026-02-26 | runtime/env | `LD_LIBRARY_PATH` not set → CFFI can't find `libcrypto.so.3` |
| 9 | 2026-02-26 | idiom/sbcl | `--eval` with multiple top-level forms |
| 10 | 2026-02-26 | idiom/format | Literal `~` in format string → "Unknown directive" |
| 11 | 2026-02-26 | idiom/control | `return-from NAME` inside a lambda → "unknown block" |
| 12 | 2026-02-26 | packages | `clawmacs/loop` missing accessor imports for CLOS class |
| 13 | 2026-02-26 | idiom/assert | `(assert cond "message")` → "value not of type LIST" |
| 14 | 2026-02-26 | runtime/json | Nested plist → JSON array not object (shallow `plist->object`) |
| 16 | 2026-02-26 | idiom/bordeaux-threads | `bt:condition-broadcast` doesn't exist in bordeaux-threads v0.9.4 |
| 17 | 2026-02-26 | idiom/defstruct | `defun` with same name as `defstruct` slot accessor silently replaces the accessor |

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
**What:** `*on-stream-delta*` is exported from `clawmacs/loop` but NOT re-exported by the top-level `clawmacs` package.
**Why:** The `clawmacs` package only `:import-from`s `#:*on-tool-call*`, `#:*on-tool-result*`, `#:*on-llm-response*` from `clawmacs/loop` — omits `*on-stream-delta*`.
**Fix:** `:import-from #:clawmacs/loop #:*on-stream-delta*` directly in the downstream package.
**Lesson:** The `clawmacs` convenience package is incomplete. Always check which symbols are re-exported when using convenience packages. Prefer `#:clawmacs/loop` when you need the full loop API.
**Tags:** #packages #exports #clawmacs

### #12 — 2026-02-26
**What:** `clawmacs/loop` package couldn't find `session-agent`, `agent-client`, etc. at runtime — "function undefined" errors.
**Why:** The package only imported the *class names* (`#:agent`, `#:session`) but not the accessor functions. Since `(:use #:cl)` doesn't pull in other packages, all external symbols must be explicitly imported.
**Fix:** Added all needed accessors to `(:import-from ...)` in the `defpackage` form for `clawmacs/loop`.
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
**What:** Used `(return-from clawmacs/tools:register-tool! ...)` inside a lambda inside `register-tool!`. SBCL rejected it: "return for unknown block".
**Why:** `return-from` jumps to a named block. Functions defined with `defun` create a block with the function's name. But `register-tool!` is a function, and the lambda is a *different* function — so there's no block named `clawmacs/tools:register-tool!` in scope inside the lambda.
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
**Fix:** Wrote `schema-plist->ht` in `clawmacs/tools` — a recursive converter that specially handles the `"properties"` key by iterating its plist and recursively converting each property schema.
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

---

## Category: idiom/defstruct

### #17 — 2026-02-26
**What:** `(defstruct tool-entry (ok nil :type boolean))` generates `tool-result-ok` as a slot
accessor. Then `(defun tool-result-ok (value) ...)` redefines the symbol. All code using
`(tool-result-ok result)` to check "is this result successful?" now calls the constructor
instead of the predicate — always returning a truthy struct. `format-tool-result` is broken
silently: it always returns the value string even for error results.
**Why:** In CL, `defstruct` generates accessor functions with `defun`. A subsequent `defun`
with the same name *replaces* the accessor. No warning is issued.
**Fix:** Never use the same name for a constructor and a struct accessor. Options:
  - Use `:conc-name` to give the struct a different prefix (e.g., `(:conc-name tr-)`)
  - Name the constructor differently: `make-ok-result` instead of `tool-result-ok`
  - Add a separate predicate: `(defun tool-result-success-p (r) (tr-ok r))`
**Lesson:** When you define both a struct slot and a public constructor/helper with overlapping
names, always check whether `defun` is overwriting a generated struct accessor. Best practice:
design struct slot names and public API names independently; use `:conc-name` to decouple them.
**Tags:** #defstruct #conc-name #idiom #naming

---

## Category: idiom/bordeaux-threads

### #16 — 2026-02-26
**What:** Used `bt:condition-broadcast` to wake all waiters on a condition variable when closing a `queue-channel`. SBCL/bordeaux-threads v0.9.4 raised a READ error at compile time: "Symbol CONDITION-BROADCAST not found in the BORDEAUX-THREADS package."
**Why:** bordeaux-threads v0.9.4 only exports `bt:condition-notify` (wake one waiter) and `bt:condition-wait`. There is no `condition-broadcast`.
**Fix:** Replace `bt:condition-broadcast` with `bt:condition-notify`. For the close case, a single notify is sufficient since receivers check the `open-p` slot and re-enter the wait or exit.
**Lesson:** bordeaux-threads is minimal. Check the full export list with `(loop for s being the external-symbols of :bordeaux-threads ...)` before assuming POSIX names exist. There is no `condition-broadcast`, `condition-signal`, or `thread-join` — use `bt:condition-notify` and `bt:join-thread` respectively.
**Tags:** #bordeaux-threads #threads #conditions #idiom

---

## Category: packages

### #18 — 2026-02-26
**What:** `merge-user-tools!` was defined and used in `src/config.lisp` but omitted from the `clawmacs/config` package's `:export` list in `src/packages.lisp`. Caused a compile error in the test file when it referenced `clawmacs/config:merge-user-tools!`.
**Why:** Added the function after drafting the initial export list; forgot to update the exports.
**Fix:** Added `#:merge-user-tools!` to the `:export` list of `clawmacs/config` in `packages.lisp`, and also to the `clawmacs` package's `:import-from` and `:export` sections, and to `clawmacs-user`.
**Lesson:** When adding a function to a module after initial package design, immediately update ALL three places: (1) package `:export`, (2) top-level `clawmacs` `:import-from` + `:export`, (3) `clawmacs-user` if it's user-facing. A grep for the function name across packages.lisp catches omissions.
**Tags:** #packages #exports #config

---

## Category: idiom/clos

### #19 — 2026-02-26
**What:** In a test, tried to remove a method with an EQL specializer using `(find-class '(eql :custom-plugin))`. SBCL signalled a type error: "Value of `(EQL :CUSTOM-PLUGIN)` is `(EQL :CUSTOM-PLUGIN)`, not a SYMBOL."
**Why:** `find-class` expects a symbol (class name), not an EQL specializer form. `(find-class '(eql :custom-plugin))` passes the list `(eql :custom-plugin)` as the class name, which doesn't designate a class.
**Fix:** Use `sb-mop:intern-eql-specializer :custom-plugin` to get the EQL specializer object, then pass it to `find-method`. Wrap in `ignore-errors` for cleanup code.
**Lesson:** To remove a method with an EQL specializer in SBCL: `(find-method gf '() (list (sb-mop:intern-eql-specializer val)) nil)`. The standard `find-class` is only for named classes. For EQL specializers, use the MOP.
**Tags:** #clos #mop #methods #eql-specializer

---

## Category: packages

### #20 — 2026-02-26
**What:** Initially placed `clawmacs/irc` defpackage BEFORE `clawmacs/config` in packages.lisp. Got PACKAGE-DOES-NOT-EXIST at load time: `clawmacs/irc` imports `register-channel` and `*default-model*` from `clawmacs/config`, but `clawmacs/config` wasn't defined yet.
**Why:** When working in a file with many packages, it's easy to place a new package in a "logical" position (before the config section) instead of the correct dependency-ordered position (after config).
**Fix:** Moved `clawmacs/irc` to AFTER `clawmacs/config` and the Telegram package, just before the top-level `clawmacs` convenience package.
**Lesson:** Package load order in `packages.lisp` MUST match dependency order. When a new package specialises a generic from another package (e.g., `register-channel`), it MUST be defined after that package. Draw out the dependency graph before placing the defpackage.
**Tags:** #packages #load-order #defpackage

---

## Category: idiom/sbcl

### #21 — 2026-02-26
**What:** In a test runner script, loaded test packages (which use `(:use #:parachute)`) before `parachute` was quickloaded. Got PACKAGE-DOES-NOT-EXIST: "The name PARACHUTE does not designate any package."
**Why:** The main system (`clawmacs-core`) doesn't depend on `parachute` — only `clawmacs-core/tests` does. When we manually load `t/packages.lisp` in a script that already loaded `clawmacs-core` (not `clawmacs-core/tests`), parachute is not in the image.
**Fix:** Always `(ql:quickload :parachute :silent t)` BEFORE loading any test package that `(:use #:parachute)`. Or load the full `clawmacs-core/tests` ASDF system instead of individual files.
**Lesson:** Test packages must have their dependencies explicitly loaded before `defpackage` is evaluated. Don't assume a test runner has pre-loaded all test dependencies. When writing script-driven test runners, always quickload test dependencies at the top.
**Tags:** #packages #parachute #testing #sbcl

---

## Category: asdf/packaging

### #22 — 2026-02-26
**What:** `schema-plist->ht` was defined in `clawmacs/tools` but not exported. When the new `clawmacs/browser` package tried to `(:import-from #:clawmacs/tools #:schema-plist->ht)`, SBCL raised "no symbol named SCHEMA-PLIST->HT in CLAMBDA/TOOLS".
**Why:** `schema-plist->ht` was added as a helper function but never added to the `:export` list in the package definition.
**Fix:** Added `#:schema-plist->ht` to the `:export` section of `clawmacs/tools` in `packages.lisp`.
**Lesson:** When adding a new function to an existing module that other packages will need, immediately update ALL export lists. Grep for all packages that import from the modified package to catch missed updates.
**Tags:** #packages #exports #tools

---

## Category: idiom/playwright

### #23 — 2026-02-26
**What:** Used `page.accessibility.snapshot()` in the playwright bridge. Got runtime error: "Cannot read properties of undefined (reading 'snapshot')" — `page.accessibility` is undefined.
**Why:** Playwright deprecated and removed the `page.accessibility` API in v1.31. Since we're using Playwright v1.58.2, `page.accessibility` no longer exists.
**Fix:** Use `page.locator('body').ariaSnapshot()` which is the modern Playwright API (available since v1.47). It returns a YAML string describing the ARIA accessibility tree.
**Lesson:** Playwright's API evolves. Always check the version's changelog when using accessibility/aria APIs. The `accessibility` namespace was removed; use `locator().ariaSnapshot()` instead.
**Tags:** #playwright #browser #accessibility #api-changes

---

## Category: idiom/pathname

### #24 — 2026-02-26
**What:** Used `(merge-pathnames "browser/playwright-bridge.js" (asdf:system-relative-pathname :clawmacs-core "browser/playwright-bridge.js"))` — the result had double `browser/browser/` path segment.
**Why:** `asdf:system-relative-pathname` already returns the full path including the relative component. Wrapping it in `merge-pathnames` with the same relative component appended it again.
**Fix:** Use `asdf:system-relative-pathname` directly without wrapping in `merge-pathnames`:
  ```lisp
  (asdf:system-relative-pathname :clawmacs-core "browser/playwright-bridge.js")
  ```
**Lesson:** `asdf:system-relative-pathname` returns the fully resolved path. Don't wrap it in `merge-pathnames` with the same relative component — that doubles the path.
**Tags:** #asdf #pathnames #idiom

---

## Category: idiom/parachute

### #25 — 2026-02-26
**What:** Used `(skip-on (not (my-function)) "reason")` in a parachute test. Got runtime error: "MY-FUNCTION fell through ECASE expression. Wanted one of (AND OR NOT)."
**Why:** Parachute's `skip-on` condition DSL recursively processes `and`, `or`, `not` forms to build a condition tree. When it recurses into `(not (my-function))`, the `not` is recognized, but `(my-function)` has car `my-function` which is not a recognized combinator — so it falls through the ecase.
**Fix:** Don't use `skip-on` with function calls. Instead, use a simple `(when (condition) ...)` or `(unless ...)` guard inside the test body:
  ```lisp
  (define-test "my-test"
    (when (my-function)
      (true t))
    (unless (my-function)
      (true t))) ; vacuous pass
  ```
**Lesson:** Parachute's `skip-on` is a compile-time DSL for feature flags (`and/or/not` of keywords or forms that the DSL recognizes), not a general boolean expression evaluator. For runtime conditions, use `when`/`unless` inside the test body.
**Tags:** #parachute #testing #skip-on #idiom

---

## Category: idiom/parens

### #26 — 2026-02-27
**What:** Sub-agent wrote 11 closing parens after the final body form of a deeply nested function (`%run-agent-streaming` fallback path embedded inside `process-update`). SBCL reported "unmatched close parenthesis" at the exact column.
**Why:** Manual paren-counting error in a 10-level deep nesting: `(or ...) → sendMessage → let* → if → let → (t cond-clause) → cond → when → multiple-value-bind → defun`. The sub-agent miscounted and added one extra `)`.
**Fix:** Remove the extra `)`. Reliable counting: work from the innermost form outward, incrementing by 1 for each closing `(form ...)`.
**Lesson:** When generating code with ≥8 levels of nesting, count closing parens explicitly level-by-level. SBCL's column-precise error message pinpoints the exact extra paren. For sub-agents: test compile immediately after generating deep nesting — don't batch all files before testing.
**Tags:** #idiom #parens #sbcl #nesting
