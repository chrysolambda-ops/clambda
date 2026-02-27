# Custom Tools

Agents learn new capabilities through tools. You can define your own tools in
`init.lisp` and they become available to all agents.

## The `define-user-tool` macro

```lisp
(define-user-tool TOOL-NAME
  :description "..."
  :parameters  PARAMETER-LIST
  :function    FUNCTION)
```

Tools are registered into `*user-tool-registry*`. When building an agent,
call `(merge-user-tools! registry)` to include them.

---

## Parameter Spec Format

Parameters are a list of plists:

```lisp
'((:name        "param-name"
   :type        "string"      ; "string" | "integer" | "number" | "boolean" | "array" | "object"
   :description "Shown to the LLM — make this descriptive"
   :required    t)            ; optional key; defaults to T

  (:name        "another-param"
   :type        "integer"
   :description "..."
   :required    nil))         ; this parameter is optional
```

Tool functions receive arguments as a **hash table** keyed by parameter name (strings):

```lisp
(gethash "param-name" args)
```

---

## Simple Tool Examples

### No-parameter tool: current time

```lisp
(define-user-tool get-time
  :description "Returns the current UTC time as an ISO 8601 string."
  :parameters  nil
  :function    (lambda (args)
                 (declare (ignore args))
                 (multiple-value-bind (sec min hour day month year)
                     (decode-universal-time (get-universal-time) 0)  ; UTC
                   (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ"
                           year month day hour min sec))))
```

### Single-parameter tool: read environment variable

```lisp
(define-user-tool get-env
  :description "Returns the value of an environment variable."
  :parameters  '((:name "name" :type "string" :description "Environment variable name."))
  :function    (lambda (args)
                 (let ((name (gethash "name" args)))
                   (or (uiop:getenv name)
                       (format nil "Environment variable ~A is not set." name)))))
```

### Multi-parameter tool: send HTTP request

```lisp
(defun %http-get (url)
  (handler-case
      (dex:get url :force-string t)
    (error (e) (format nil "HTTP error: ~A" e))))

(define-user-tool http-get
  :description "Perform an HTTP GET request and return the response body."
  :parameters  '((:name "url"      :type "string" :description "URL to fetch.")
                 (:name "max-chars" :type "integer"
                        :description "Maximum characters to return."
                        :required    nil))
  :function    (lambda (args)
                 (let* ((url  (gethash "url" args))
                        (max  (or (gethash "max-chars" args) 10000))
                        (body (%http-get url)))
                   (subseq body 0 (min max (length body))))))
```

---

## Tool Function Contract

A tool function:
- Takes one argument: `args` — a hash table (keys are strings, matching parameter names)
- Returns a string — this is shown to the LLM as the tool result
- Should handle errors gracefully — return an error string rather than signalling

```lisp
(define-user-tool safe-tool
  :description "A tool that handles errors gracefully."
  :parameters  '((:name "input" :type "string" :description "Input to process."))
  :function    (lambda (args)
                 (handler-case
                     (let ((input (gethash "input" args)))
                       ;; ... your logic ...
                       (format nil "Processed: ~A" input))
                   (error (e)
                     (format nil "Error: ~A" e)))))
```

---

## Accessing Other Tools from a Tool

Tools can call other functions freely (it's just Lisp):

```lisp
;; Use the exec tool's underlying implementation
(define-user-tool ls-json
  :description "List a directory and return results as JSON."
  :parameters  '((:name "path" :type "string" :description "Directory path."))
  :function    (lambda (args)
                 (let* ((path (gethash "path" args))
                        (cmd  (format nil "ls -la ~A" (uiop:native-namestring path)))
                        (out  (uiop:run-program cmd :output :string :ignore-error-status t)))
                   ;; Return as-is (or you could parse and return JSON)
                   out)))
```

---

## Including Tools in Agent Sessions

User tools go into `*user-tool-registry*`. You need to merge them into any agent's
registry:

```lisp
;; Approach 1: merge into a built-in registry
(let ((registry (clawmacs:make-tool-registry)))
  (clawmacs/builtins:register-builtins registry)
  (clawmacs/config:merge-user-tools! registry)       ; add user tools
  (let* ((client  (make-lmstudio-client))
         (agent   (make-agent :name "my-agent"
                              :client client
                              :tool-registry registry))
         (session (make-session :agent agent)))
    (run-agent session "Hello!")))

;; Approach 2: just user tools, no built-ins
(let ((registry (clawmacs:make-tool-registry)))
  (clawmacs/config:merge-user-tools! registry)
  ;; ...
  )
```

---

## Registering Tools at the REPL

For development, register tools directly without using `define-user-tool`:

```lisp
;; Low-level registration
(clawmacs:register-tool! registry "my-tool"
  (lambda (args) (format nil "Result: ~A" (gethash "input" args)))
  :description "A tool I'm testing."
  :parameters  '((:name "input" :type "string" :description "Input")))

;; Or use define-tool (more powerful macro)
(clawmacs:define-tool registry "my-tool"
  "Description here."
  ((input "string" "Input parameter"))
  (format nil "Got: ~A" input))
```

---

## Tool Schema to JSON Mapping

Clawmacs converts parameter specs to JSON Schema for the LLM API:

```lisp
;; CL spec:
'((:name "count" :type "integer" :description "Number of items." :required nil))

;; Sent to LLM as JSON Schema:
{
  "type": "object",
  "properties": {
    "count": {
      "type": "integer",
      "description": "Number of items."
    }
  },
  "required": []
}
```

---

## Tool Hooks

Monitor tool calls with hooks:

```lisp
;; Log all tool calls
(add-hook '*after-tool-call-hook*
  (lambda (tool-name result)
    (clawmacs/logging:log-info "tool-call"
      (format nil "Tool ~A returned ~A chars" tool-name (length result)))))

;; Per-turn hook (fires before the LLM calls, can see what session is active)
(add-hook '*before-agent-turn-hook*
  (lambda (session user-msg)
    (format t "[agent] Turn starting for session: ~A~%"
            (clawmacs/session:session-key session))))
```

---

## Tips

- **Be descriptive.** The LLM decides which tool to call based on the description.
  Make it clear when the tool should be used.

- **Return strings.** Tool results must be strings. Use `format nil` or `princ-to-string`
  to convert other types.

- **Handle nil.** When parameters are optional (`:required nil`), `gethash` may return
  `nil`. Handle it:

  ```lisp
  (let ((count (or (gethash "count" args) 10)))  ; default 10
    ...)
  ```

- **Keep tools focused.** One tool, one job. Agents compose multiple tool calls.

- **Debug with `*on-tool-call*`:**

  ```lisp
  (setf clawmacs/loop:*on-tool-call*
    (lambda (name call)
      (format t "DEBUG tool call: ~A args=~A~%" name call)))
  ```
