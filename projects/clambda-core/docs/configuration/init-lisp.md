# Configuration Guide — init.lisp

Clawmacs is configured in **Common Lisp**, not JSON or YAML. Your configuration file
is `~/.clawmacs/init.lisp` — a regular Lisp source file loaded at startup.

This is the Emacs model: configuration *is* code. You have the full power of Common
Lisp available: conditionals, loops, file I/O, string manipulation, anything.

## How it works

1. You start Clawmacs (SBCL + quickload)
2. `(clawmacs/config:load-user-config)` finds `~/.clawmacs/init.lisp`
3. The file is loaded with `*package*` bound to `clawmacs-user`
4. All public Clawmacs symbols are available without package qualification
5. After the file loads, `*after-init-hook*` fires (starts channels, etc.)

## File location

```
~/.clawmacs/init.lisp          # default
$CLAWMACS_HOME/init.lisp       # override with env var
```

Create the directory if needed:

```bash
mkdir -p ~/.clawmacs
cp /path/to/clawmacs/projects/clawmacs-core/example-init.lisp ~/.clawmacs/init.lisp
```

**Security:** `init.lisp` may contain API keys and bot tokens. Do **not** commit
it to version control. The Clawmacs `.gitignore` excludes it by default.

---

## § 1. Options

Options are variables declared with `defoption`. Set them with `setf`:

```lisp
(in-package #:clawmacs-user)

;; LLM model (used when no per-agent model is set)
(setf *default-model* "google/gemma-3-4b")

;; Maximum tool-calling turns per agent loop (prevents infinite loops)
(setf *default-max-turns* 30)

;; Enable streaming responses
(setf *default-stream* t)

;; Log verbosity: :debug :info :warn :error
(setf *log-level* :info)

;; Message printed to stdout on startup
(setf *startup-message* "Clawmacs ready. λ")
```

See all options at the REPL:

```lisp
CLAMBDA-USER> (describe-options)
```

### Defining custom options

```lisp
(defoption *my-workspace* "~/projects/"
  :type string
  :doc "Workspace directory for the coding agent.")
```

`defoption` is like Emacs' `defcustom`: it defines a variable, registers it in the
option registry, and makes it visible to `describe-options`.

---

## § 2. LLM Clients

Clawmacs uses `cl-llm` to talk to any OpenAI-compatible API.

```lisp
;; LM Studio (local, free)
(defun make-local-client (&optional (model *default-model*))
  (cl-llm:make-client
    :base-url "http://192.168.1.189:1234/v1"  ; your LM Studio host
    :api-key  "lmstudio"                       ; any non-empty string
    :model    model))

;; OpenRouter (cloud, paid)
(defun make-cloud-client (&optional (model "anthropic/claude-3.5-sonnet"))
  (cl-llm:make-client
    :base-url "https://openrouter.ai/api/v1"
    :api-key  (uiop:getenv "OPENROUTER_API_KEY")
    :model    model))
```

For Ollama, use the `/v1` OpenAI-compatibility endpoint:

```lisp
(cl-llm:make-client
  :base-url "http://localhost:11434/v1"
  :api-key  "ollama"
  :model    "llama3.1:8b")
```

---

## § 3. Channel Registration

Channels are how Clawmacs receives and sends messages. Register them with
`register-channel`:

### Telegram

```lisp
(register-channel :telegram
  :token         "YOUR_BOT_TOKEN_HERE"      ; from @BotFather
  :allowed-users '(123456789)               ; Telegram user IDs (integers)
  :streaming     t)                         ; stream tokens as they arrive
```

See [Telegram setup](../channels/telegram.html) for getting your bot token and user ID.

### IRC

```lisp
(register-channel :irc
  :server            "irc.libera.chat"
  :port              6697
  :tls               t
  :nick              "my-clawmacs-bot"
  :realname          "Clawmacs AI"
  :channels          '("#clawmacs" "#lisp")
  :nickserv-password "YOUR_NICKSERV_PASSWORD"  ; omit if not registered
  :allowed-users     nil                        ; nil = all users; list nicks to restrict
  :dm-allowed-users  '("alice" "bob")           ; DM-specific allowlist
  :channel-policies  '(("#clawmacs" :allowed-users nil)   ; all welcome
                       ("#priv"    :allowed-users ("alice"))))
```

See [IRC setup](../channels/irc.html) for complete IRC configuration.

### Browser

```lisp
(register-channel :browser :headless t)
(add-hook '*after-init-hook* #'clawmacs/browser:browser-launch)
```

### HTTP Management API

The HTTP API is started via `start-server`, not `register-channel`:

```lisp
(setf *api-token* "YOUR_SECRET_TOKEN")
(add-hook '*after-init-hook*
          (lambda () (start-server :port 7474 :address "127.0.0.1")))
```

---

## § 4. Agent Definitions

Pre-define named agents with `define-agent`:

```lisp
(define-agent :coder
  :model "google/gemma-3-4b"
  :system-prompt
  "You are an expert Common Lisp programmer.
Use exec, read_file, and write_file to work with code.
Always explain your reasoning.")

(define-agent :researcher
  :model "deepseek/deepseek-r1:8b"
  :system-prompt
  "You are a research assistant. Fetch and summarise web content.
Be concise and always cite your sources.")
```

Retrieve a defined agent:

```lisp
(find-agent :coder)    ; => agent struct or NIL
```

Channel plugins (Telegram, IRC) use a default agent if no specific one is requested.
To wire a named agent to a channel, start it in a hook:

```lisp
(add-hook '*after-init-hook*
  (lambda ()
    (let* ((agent   (find-agent :coder))
           (session (make-session :agent agent)))
      ;; store session for use by channel handler
      (setf my-coding-session session))))
```

---

## § 5. Custom Tools

Define tools that agents can call with `define-user-tool`:

```lisp
;;; Simple tool: get current time
(define-user-tool get-current-time
  :description "Returns the current date and time as a string."
  :parameters  nil
  :function    (lambda (args)
                 (declare (ignore args))
                 (multiple-value-bind (s min h d mo y)
                     (decode-universal-time (get-universal-time))
                   (format nil "~4,'0D-~2,'0D-~2,'0D ~2,'0D:~2,'0D:~2,'0D"
                           y mo d h min s))))

;;; Tool with parameters
(define-user-tool translate
  :description "Translate text to a target language."
  :parameters  '((:name "text"     :type "string"  :description "Text to translate.")
                 (:name "language" :type "string"  :description "Target language code (e.g. 'fr', 'de')."))
  :function    (lambda (args)
                 (let ((text (gethash "text" args))
                       (lang (gethash "language" args)))
                   ;; call your translation API here
                   (format nil "[Translation to ~A]: ~A" lang text))))
```

Tools defined with `define-user-tool` go into `*user-tool-registry*`. To include
them when creating an agent manually:

```lisp
(let ((registry (clawmacs:make-tool-registry)))
  (clawmacs/builtins:register-builtins registry)
  (clawmacs/config:merge-user-tools! registry)
  ;; registry now has both built-in and user tools
  (make-agent :name "my-agent" :client client :tool-registry registry))
```

See [Custom Tools](../tools/custom-tools.html) for the full tool API.

---

## § 6. Hooks

Hooks let you plug into Clawmacs's lifecycle without modifying core code.

```lisp
;;; After init: called after all of init.lisp loads
(add-hook '*after-init-hook* #'my-startup-fn)

;;; Before each agent turn: (session user-message)
(add-hook '*before-agent-turn-hook*
  (lambda (session msg)
    (format t "[hook] New turn: ~A~%" (subseq msg 0 (min 40 (length msg))))))

;;; After each tool call: (tool-name result-string)
(add-hook '*after-tool-call-hook*
  (lambda (name result)
    (format t "[hook] Tool ~A → ~A chars~%" name (length result))))

;;; On inbound channel message: (channel-keyword message-plist)
(add-hook '*channel-message-hook*
  (lambda (channel msg)
    (format t "[hook] Channel ~A: ~A~%" channel msg)))
```

Remove a hook:

```lisp
(remove-hook '*after-init-hook* #'my-startup-fn)
```

---

## § 7. Cron / Scheduled Tasks

```lisp
;;; Periodic task: every 30 minutes
(defun my-check ()
  (format t "[cron] Checking...~%"))

(add-hook '*after-init-hook*
  (lambda ()
    (schedule-task "my-check" :every 1800 #'my-check
                   :description "Check every 30 minutes")))

;;; One-shot task: fires 10 seconds after startup
(add-hook '*after-init-hook*
  (lambda ()
    (schedule-once "startup-ping" :after 10
      (lambda () (format t "[cron] Clawmacs is up!~%"))
      :description "Startup notification")))

;;; Cancel and inspect tasks
(list-tasks)            ; => list of scheduled-task objects
(describe-tasks)        ; => human-readable output to stdout
(cancel-task "my-check")
(clear-tasks)           ; cancel all
```

---

## § 8. Full Lisp is the Config

Because init.lisp is real Lisp, you can do anything:

```lisp
;;; Conditional config by hostname
(let ((host (machine-instance)))
  (cond
    ((string= host "home-server")
     (setf *default-model* "google/gemma-3-12b"))
    ((string= host "laptop")
     (setf *default-model* "google/gemma-3-4b"))
    (t nil)))

;;; Read API keys from a separate secrets file
(let ((secrets (merge-pathnames "secrets.lisp" *clawmacs-home*)))
  (when (probe-file secrets)
    (load secrets)))

;;; Load additional config fragments
(dolist (f (directory (merge-pathnames "conf.d/*.lisp" *clawmacs-home*)))
  (load f))
```

---

## § 9. Remote Management API

```lisp
;;; Set bearer token (required for auth)
(setf *api-token* "YOUR_SECRET_TOKEN")

;;; Start API server on startup
(add-hook '*after-init-hook*
  (lambda ()
    (start-server :port 18789 :address "127.0.0.1")))
```

Management endpoints:

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/health` | — | Health check |
| GET | `/api/system` | ✓ | Version, uptime, counts |
| GET | `/api/agents` | ✓ | List registered agents |
| POST | `/api/agents/:name/start` | ✓ | Create session |
| POST | `/api/agents/:name/message` | ✓ | Send message, get reply |
| GET | `/api/agents/:name/history` | ✓ | Session history |
| DELETE | `/api/agents/:name/stop` | ✓ | Terminate session |
| GET | `/api/sessions` | ✓ | All sessions |
| GET | `/api/channels` | ✓ | Registered channels |
| GET | `/api/tasks` | ✓ | Cron task list |

See [HTTP API Reference](../api/index.html) for full details.

---

## Complete Example

See [`example-init.lisp`](../../projects/clawmacs-core/example-init.lisp) for a fully
commented example covering all features.
