# CL Style Guide — Gensym Team

> Distilled from 4 projects: cl-llm, cl-tui, clawmacs-core, clawmacs-gui.
> These are our conventions, not universal law — but follow them unless you
> have a strong reason not to.

---

## 1. Package Naming

### Hierarchy with `/`

Use `system-name/module-name` for internal packages:

```lisp
#:cl-llm/protocol      ; struct/type definitions
#:cl-llm/streaming     ; SSE parsing
#:cl-llm/client        ; HTTP client impl
#:cl-llm               ; public surface re-exports
```

### Convention

- All lowercase, hyphen-separated words
- System name matches the `.asd` system name exactly
- One package per major concern
- Top-level `#:system-name` package is a **re-export aggregator** only — no implementation there

### defpackage ordering

Always define packages in `src/packages.lisp`, loaded first. Order matters:
leaf packages (no imports from siblings) first, aggregators last.

```lisp
;;; Define in dependency order
(defpackage #:cl-llm/protocol ...)    ; no imports from siblings
(defpackage #:cl-llm/json ...)        ; may import from protocol
(defpackage #:cl-llm/streaming ...)   ; imports from json, protocol
(defpackage #:cl-llm/client ...)      ; imports from protocol, streaming
(defpackage #:cl-llm ...)             ; aggregator — imports from all
```

---

## 2. Struct vs CLOS Class

### Use `defstruct` when:
- Data is simple, flat, value-like
- You need fast slot access (struct slots are often unboxed)
- No polymorphism needed
- You want automatic `make-`, `copy-`, predicate for free
- The type will be used in performance-sensitive paths

```lisp
;; Good struct: simple value object
(defstruct (client (:constructor %make-client))
  (base-url nil :type string)
  (api-key  "not-needed" :type string)
  (model    nil :type (or null string)))
```

### Use `defclass` when:
- You need inheritance (multiple types sharing an interface)
- You need `defmethod` dispatch on the type
- Slots need `:before`/`:after`/`:around` initialization
- Objects have identity semantics (mutable, shared)
- You need mixins

```lisp
;; Good class: polymorphic backend type
(defclass llm-backend ()
  ((name :reader backend-name :initarg :name)))

(defclass openai-backend (llm-backend) ...)
(defclass anthropic-backend (llm-backend) ...)
```

### The hybrid pattern: defstruct + constructors
When you want struct performance but controlled construction:

```lisp
(defstruct (thing (:constructor %make-thing))
  name
  value)

(defun make-thing (name &key (value 0))
  "Public constructor with validation."
  (assert (stringp name) () "name must be a string, got: ~s" name)
  (%make-thing :name name :value value))
```

---

## 3. Export Conventions

### What to export from a public package

| Kind | Export? | Notes |
|------|---------|-------|
| Type name (`my-thing`) | ✅ Always | The struct/class name itself |
| Constructor (`make-my-thing`) | ✅ Always | Public constructor function |
| Internal constructor (`%make-my-thing`) | ❌ Never | Internal detail |
| Accessors (`my-thing-name`) | ✅ If public | Only what callers actually need |
| Predicate (`my-thing-p`) | ✅ If public | Include if callers type-check |
| Conditions | ✅ Always | Callers need to `handler-case` |
| Special variables (`*foo*`) | ✅ If part of API | Hook variables, config |
| Internal helpers | ❌ Never | Use `%` prefix and keep private |

### `:conc-name` — match exports to struct

```lisp
;; WRONG: generates completion-response-id, completion-response-model
(defstruct completion-response
  id model)

;; Then you'd have to export #:completion-response-id — ugly long names

;; RIGHT: set conc-name to match intended export
(defstruct (completion-response (:conc-name response-))
  id model)

;; Now you export #:response-id, #:response-model — clean
```

**Rule:** Design the export names first. Then set `:conc-name` to make them match.

### Convenience re-export pattern

```lisp
(defpackage #:cl-llm
  (:use #:cl)
  (:import-from #:cl-llm/protocol
                #:completion-response
                #:make-completion-response
                #:response-id
                #:response-model)
  (:export
   ;; Re-export everything public
   #:completion-response
   #:make-completion-response
   #:response-id
   #:response-model))
```

**Warning:** The top-level convenience package may not re-export everything.
When you need the full API of a sub-package, import from it directly:
```lisp
(:import-from #:clawmacs/loop #:*on-stream-delta*)  ; NOT via #:clawmacs
```

---

## 4. Condition / Restart Patterns

### Defining conditions

```lisp
(define-condition network-error (error)
  ((status :reader error-status :initarg :status)
   (body   :reader error-body   :initarg :body))
  (:report (lambda (c s)
             (format s "HTTP ~a: ~a"
                     (error-status c)
                     (error-body c)))))
```

### Signaling with context

```lisp
;; Signal with initargs matching slots
(error 'network-error :status 400 :body response-body)

;; Wrap foreign errors
(handler-case
    (dexador:post ...)
  (dexador:http-request-failed (e)
    (error 'network-error
           :status (dexador:response-status e)
           :body   (dexador:response-body e))))
```

### Tool error handling — never let errors escape

```lisp
;; In tool implementations: always return a result, never signal
(handler-case
    (progn
      (let ((result (do-the-thing args)))
        (tool-result-ok result)))
  (error (e)
    (tool-result-error (format nil "Error: ~a" e))))
```

### assert — CL syntax is different from other languages

```lisp
;; WRONG (string is treated as `places` arg → error)
(assert condition "My error message")

;; RIGHT
(assert condition () "My error message: ~a" extra-info)
;;              ^^
;;              empty `places` list (no generalized references to retry)
```

---

## 5. `define-tool` Macro Usage

```lisp
;; Simple tool — define-tool handles wrapping in tool-result-ok
(define-tool registry "get-time" "Return current UTC time."
  ()                              ; no parameters
  (multiple-value-bind (s m h) (get-decoded-time)
    (format nil "~2,'0d:~2,'0d:~2,'0d UTC" h m s)))

;; Tool with parameters — positional from JSON object
(define-tool registry "greet" "Greet a person."
  (("name" "string" "Person's name to greet")
   ("formal" "boolean" "Use formal greeting" :required nil))
  (if formal
      (format nil "Good day, ~a." name)
      (format nil "Hey ~a!" name)))

;; When NOT to use define-tool — use register-tool! directly
;; - When you need to inspect the full args hash-table
;; - When schema is complex (nested objects, arrays)
;; - When you need full error handling control

(register-tool! registry "exec"
  (lambda (args)
    (let ((cmd (gethash "command" args))
          (dir (gethash "workdir" args)))
      (if cmd
          (handler-case
              (tool-result-ok (run-shell-command cmd :dir dir))
            (error (e)
              (tool-result-error (format nil "Failed: ~a" e))))
          (tool-result-error "No command provided"))))
  :description "Run a shell command"
  :parameters '(:|type| "object"
                :|properties|
                (:|command| (:|type| "string" :|description| "Command to run"))
                :|required| #("command")))
```

### JSON Schema plist format

```lisp
;; IMPORTANT: plist->object is SHALLOW
;; For nested schemas (like tool parameters), use schema-plist->ht
;; which recursively converts the "properties" sub-object

;; The :|keyword| style (with colon-pipe) produces string keys in hash-tables
;; Don't mix string keys and keyword keys in the same hash-table
```

---

## 6. `format` Directives — Common Pitfalls

```lisp
;; Literal tilde — use ~~
(format t "Status: ~~ processing")   ; prints "Status: ~ processing"

;; NOT:
(format t "Status: ~ processing")    ; ERROR: Unknown directive

;; Common useful directives:
;; ~a  — print arg (no quotes)
;; ~s  — print arg (with quotes, read-back form)
;; ~%  — newline
;; ~&  — fresh-line (newline if not already at column 0)
;; ~d  — decimal integer
;; ~f  — floating point
;; ~2,'0d — decimal, width 2, padded with '0'
;; ~~  — literal tilde
```

---

## 7. Common Pitfalls (from Mistakes Log)

### 7.1 Package imports don't include accessors

```lisp
;; Importing a class name does NOT import its accessors
(:import-from #:my-system/agent #:agent)   ; imports the class

;; Still need to import each accessor separately:
(:import-from #:my-system/agent
              #:agent #:agent-client #:agent-name #:agent-tool-registry)
```

### 7.2 `get-output-stream-string` clears the stream

```lisp
;; WRONG for streaming accumulation:
(let ((s (make-string-output-stream)))
  (lambda (delta)
    (write-string delta s)
    (get-output-stream-string s)))  ; clears on every call!

;; RIGHT:
(let ((buf (make-array 0 :element-type 'character
                         :fill-pointer 0
                         :adjustable t)))
  (lambda (delta)
    (loop for ch across delta do (vector-push-extend ch buf))
    (coerce buf 'string)))  ; snapshot, doesn't clear
```

### 7.3 McCLIM panes are NIL before run-frame-top-level

```lisp
;; WRONG — crashes if frame isn't live yet
(clim:redisplay-frame-pane frame (clim:find-pane-named frame 'chat))

;; RIGHT — safe helper
(defun safe-redisplay (frame pane-name)
  (let ((pane (clim:find-pane-named frame pane-name)))
    (when pane
      (clim:redisplay-frame-pane frame pane))))
```

### 7.4 dexador :want-stream returns stream as FIRST value

```lisp
;; WRONG — stream is NOT an extra return value
(multiple-value-bind (body status headers stream)
    (dexador:post url :want-stream t)
  ...)

;; RIGHT — stream replaces body as the first value
(let ((stream (dexador:post url :want-stream t)))
  (unwind-protect
       (loop for line = (read-line stream nil nil) while line ...)
    (close stream)))
```

### 7.5 return-from inside lambdas

```lisp
;; WRONG — no block named foo inside the lambda
(defun foo (x)
  (mapcar (lambda (item)
            (when (bad-p item)
              (return-from foo nil)))   ; ERROR: unknown block
          x))

;; RIGHT — use conditional logic or block nil
(defun foo (x)
  (block foo
    (mapcar (lambda (item)
              (when (bad-p item)
                (return-from foo nil)))
            x)))

;; Or just restructure:
(defun foo (x)
  (unless (some #'bad-p x)
    (mapcar #'process x)))
```

### 7.6 SBCL --eval accepts only ONE form

```lisp
;; WRONG
sbcl --eval "(progn (load ...) (run))"   ; ok actually, one form
sbcl --eval "(load ...)"  "(run)"        ; TWO separate --eval, fine

;; WRONG for complex scripts
sbcl --eval "(defun f () ...)(f)"        ; two top-level forms in one --eval

;; RIGHT for anything complex
echo "(progn ...)" > /tmp/run.lisp && sbcl --load /tmp/run.lisp
```

### 7.7 plist->object is shallow (JSON schemas)

```lisp
;; WRONG for nested schemas
(plist->object '(:|type| "object" :|properties| (:|name| (:|type| "string"))))
;; properties value stays as a list → serializes as JSON array

;; RIGHT — use a recursive converter
(defun schema-plist->ht (plist)
  (let ((ht (make-hash-table :test #'equal)))
    (loop for (k v) on plist by #'cddr
          do (let ((key (if (keywordp k) (symbol-name k) k)))
               (setf (gethash key ht)
                     (if (and (string= key "properties") (listp v))
                         (properties-plist->ht v)
                         (if (listp v) (schema-plist->ht v) v)))))
    ht))
```

### 7.8 Struct exports: always include constructor

For every struct in a public package:
- Export: type name, `make-*` constructor, any public accessors, predicate if needed
- Use `:conc-name` to control accessor names before writing exports

---

## 8. LOOP vs ITERATE

We use `loop` (built-in) by default. `iterate` is available via Quicklisp
for more complex cases. Prefer `loop` unless you need `iterate`'s named blocks
or its more readable syntax.

```lisp
;; Standard idioms
(loop for x in list collect (f x))
(loop for x across vector do (process x))
(loop repeat 10 do (print "hi"))
(loop for i from 0 below n sum i)
(loop while (running-p) do (step))
(loop for line = (read-line s nil nil) while line do (process line))
```

---

## 9. File Load Order (ASDF :serial t)

With `:serial t` in the `.asd`, files load in listed order. Dependencies:
- `packages.lisp` must be first — it defines all package names
- `conditions.lisp` before anything that signals conditions
- `protocol.lisp` (structs, generics) before implementations
- `main.lisp` or `loop.lisp` last — depends on everything

Never have circular file dependencies. If you find yourself needing a circular
dependency, split the code differently.
