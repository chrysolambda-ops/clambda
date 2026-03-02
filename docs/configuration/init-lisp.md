# Configuration Guide — init.lisp

Clawmacs is configured in Common Lisp via `~/.clawmacs/init.lisp`.

## How it works

1. Start SBCL and load `clawmacs-core`
2. Run `(clawmacs/config:load-user-config)`
3. `~/.clawmacs/init.lisp` is loaded in `clawmacs-user`
4. Hooks fire after initialization

## File location

```text
~/.clawmacs/init.lisp
$CLAWMACS_HOME/init.lisp
```

Bootstrap from the example file:

```bash
mkdir -p ~/.clawmacs
cp /path/to/clawmacs/projects/clambda-core/example-init.lisp ~/.clawmacs/init.lisp
```

> The source directory is currently `projects/clambda-core/`; the ASDF system name remains `clawmacs-core`.

## Basic options

```lisp
(in-package #:clawmacs-user)

(setf *default-model* "google/gemma-3-4b")
(setf *default-max-turns* 30)
(setf *default-stream* t)
(setf *log-level* :info)
```

Inspect options:

```lisp
(describe-options)
```

## LLM client example

```lisp
(defun make-local-client (&optional (model *default-model*))
  (cl-llm:make-client
    :base-url "http://localhost:1234/v1"
    :api-key  "lmstudio"
    :model    model))
```

## Channel registration example (Telegram)

```lisp
(register-channel :telegram
  :token         "YOUR_BOT_TOKEN"
  :allowed-users '(123456789)
  :streaming     t)
```

## Codex OAuth mode (CLI-backed)

```lisp
(in-package #:clawmacs-user)

;; Use codex CLI (OAuth session from `codex login`)
(setf clawmacs/telegram:*telegram-llm-api-type* :codex-cli)
(setf *default-model* "gpt-5-codex")
```

You can also construct a client directly:

```lisp
(cl-llm:make-codex-cli-client :model "gpt-5-codex")
```

See full setup/link flow: [Codex OAuth](../auth/codex-oauth.md)

## Start HTTP API on boot

```lisp
(setf *api-token* "YOUR_SECRET_TOKEN")
(add-hook '*after-init-hook*
          (lambda () (start-server :port 7474 :address "127.0.0.1")))
```

## Full example

See:

- `projects/clambda-core/example-init.lisp`
- [Architecture](../architecture/index.md)
