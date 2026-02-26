# Pattern: Structured JSONL Logging (Non-Fatal)

## Problem

Agent loops involve LLM requests, tool calls, and errors — you want an
audit trail but logging failures must never break the agent.

## Solution

Use `with-open-file :if-exists :append` to write newline-delimited JSON
(JSONL) entries. Wrap the entire write in `handler-case` so I/O errors
are silently reported to `*error-output*` and never propagate.

Key idioms:
- **Dynamic vars** for log path and enabled flag — easy to bind with `let`
- **Hash-tables** as the data structure for jzon serialization
- **`:false` keyword** for JSON `false` (jzon maps `nil` → `null`, not `false`)

## Code

```lisp
(defvar *log-file* nil)
(defvar *log-enabled* t)

(defun write-log-entry (ht)
  (when (and *log-enabled* *log-file*)
    (handler-case
        (with-open-file (out *log-file*
                             :direction :output
                             :if-exists :append
                             :if-does-not-exist :create)
          (com.inuoe.jzon:stringify ht :stream out)
          (write-char #\Newline out))
      (error (e)
        (ignore-errors
          (format *error-output* "~&[logging] write error: ~a~%" e))))))

(defmacro with-logging ((path &key (enabled t)) &body body)
  `(let ((*log-file* ,path)
         (*log-enabled* ,enabled))
     ,@body))
```

## Usage

```lisp
(with-logging ("/var/log/agent.jsonl")
  (run-agent session "Hello"))
```

## Notes

- jzon serializes:
  - `t` → `true`
  - `:false` → `false`
  - `nil` → `null`
  - strings → strings
  - numbers → numbers
- One log entry per line (JSONL) — works with `jq`, `grep`, log aggregators
- Thread safety: `with-open-file` isn't atomic, but file-level appends on
  Linux are atomic for small writes. Good enough for local agent logging.

## When To Use

- Any agent loop that needs observability
- Debugging tool call sequences
- Audit trails for automated agents
