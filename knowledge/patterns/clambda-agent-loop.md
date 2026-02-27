# Pattern: clawmacs-core Agent Loop

## What it is

The canonical CL agent loop: receive user message → call LLM with tools → if tool calls, execute them → feed results back → loop until final text.

## Core structure

```lisp
(defun run-agent (session user-message &key options)
  (session-add-message session (user-message user-message))
  (loop :for turn :from 1 :to max-turns
        :do (multiple-value-bind (text tool-calls response)
                (agent-turn session :options opts)
              (when (or (null tool-calls) (endp tool-calls))
                (return text))
              ;; else: tool results already added to session, loop continues
             )))
```

## Tool dispatch pattern

```lisp
;; register-tool! with direct lambdas (for inline handlers)
(register-tool! registry "exec"
  (lambda (args)
    (let ((cmd (gethash "command" args)))
      (if cmd
          (tool-result-ok (run-shell-command cmd))
          (tool-result-error "No command"))))
  :description "..."
  :parameters '(...schema plist...))

;; define-tool macro (auto-wraps body in tool-result-ok)
(define-tool registry "greet" "Greet by name."
  (("name" "string" "Person's name"))
  (format nil "Hello, ~a!" name))
```

## JSON Schema plist format

Parameters use a nested plist structure processed by `schema-plist->ht`:

```lisp
'(:|type| "object"
  :|properties|
  (:|command| (:|type| "string" :|description| "Shell command to run")
   :|workdir|  (:|type| "string" :|description| "Optional working dir"))
  :|required| #("command"))
```

`schema-plist->ht` recursively converts this to nested hash-tables.
`plist->object` (from cl-llm) is SHALLOW — don't use it for schemas.

## Session = conversation context

```lisp
(let* ((agent   (make-agent :name "bot" :client client :tool-registry registry))
       (session (make-session :agent agent)))
  (run-agent session "Hello!" :options (make-loop-options :verbose t)))
```

Session holds the full message history. Each `run-agent` call continues
the existing conversation.

## Hook pattern for observability

```lisp
(setf clawmacs:*on-tool-call*
      (lambda (name tc) (format t "Calling ~a~%" name)))
(setf clawmacs:*on-llm-response*
      (lambda (text) (format t "Final: ~a~%" text)))
```

## When to use define-tool vs register-tool!

- `define-tool` — simple cases where args are named and the body returns a value
- `register-tool!` — when you need full control over arg parsing, or the schema
  is complex/conditional

## Error handling in tools

```lisp
(handler-case
    (progn ... (tool-result-ok result))
  (error (e)
    (tool-result-error (format nil "Failed: ~a" e))))
```

Never let tool errors propagate unhandled — return `tool-result-error`.
The agent loop will feed the error string back to the LLM which can
recover gracefully.

## See also

- `projects/clawmacs-core/src/loop.lisp` — agent-turn and run-agent
- `projects/clawmacs-core/src/tools.lisp` — tool-registry and define-tool
- `projects/clawmacs-core/src/builtins.lisp` — exec, read_file, write_file
