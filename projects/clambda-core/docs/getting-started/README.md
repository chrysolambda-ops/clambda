# Getting Started

Goal: get from zero to a working Clambda agent in under 10 minutes.

## Prerequisites

| Requirement | Minimum version | Check |
|---|---|---|
| SBCL | 2.3.0+ | `sbcl --version` |
| Quicklisp | any | `ls ~/quicklisp/setup.lisp` |
| LM Studio or Ollama | any | LM Studio on your local network |

Clambda is a **local-first** platform. It works best with a local LLM server
(LM Studio, Ollama) running on your machine or home network.

Cloud LLMs (OpenRouter, Anthropic) can be added as a fallback — see the
[configuration guide](../configuration/init-lisp.html).

## 1. Install SBCL and Quicklisp

### Guix (recommended for Linux)

```bash
guix install sbcl
```

### Debian/Ubuntu

```bash
sudo apt install sbcl
```

### macOS (Homebrew)

```bash
brew install sbcl
```

### Install Quicklisp

```bash
curl -O https://beta.quicklisp.org/quicklisp.lisp
sbcl --load quicklisp.lisp \
     --eval '(quicklisp-quickstart:install)' \
     --eval '(ql:add-to-init-file)' \
     --quit
```

This installs Quicklisp to `~/quicklisp/` and adds it to `~/.sbclrc`.

## 2. Clone Clambda

```bash
cd ~/projects
git clone https://github.com/chrysolambda-ops/clambda.git
cd clambda
```

The repository contains four ASDF systems:

| System | Purpose |
|--------|---------|
| `cl-llm` | LLM API client (OpenAI-compat, streaming) |
| `cl-tui` | Terminal chat UI |
| `clambda-core` | Agent platform core |
| `clambda-gui` | McCLIM graphical frontend |

## 3. Register with ASDF

Tell ASDF where to find the systems:

```bash
mkdir -p ~/.config/common-lisp/source-registry.conf.d/
cat > ~/.config/common-lisp/source-registry.conf.d/clambda.conf << 'EOF'
(:tree "/home/YOUR-USER/projects/clambda/projects/")
EOF
```

Replace `/home/YOUR-USER/projects/clambda` with the actual path.

## 4. Create init.lisp

```bash
mkdir -p ~/.clambda
cp projects/clambda-core/example-init.lisp ~/.clambda/init.lisp
$EDITOR ~/.clambda/init.lisp
```

At minimum, set your LLM base URL:

```lisp
(in-package #:clambda-user)

;; Point to LM Studio or Ollama on your network
;; LM Studio:
(setf *default-model* "google/gemma-3-4b")  ; or whatever model you have loaded

;; Optional: start the HTTP management API
;; (setf *api-token* "your-secret-token")
;; (add-hook '*after-init-hook*
;;           (lambda () (start-server :port 7474 :address "127.0.0.1")))
```

The `example-init.lisp` file is thoroughly commented and shows every available option.

> **Security:** `~/.clambda/init.lisp` may contain API keys and bot tokens.
> Keep it out of version control. The clambda `.gitignore` excludes it by default.

## 5. Run the REPL

```bash
sbcl --eval '(ql:quickload :clambda-core)' \
     --eval '(clambda/config:load-user-config)' \
     --eval '(in-package :clambda-user)'
```

Or interactively:

```lisp
CL-USER> (ql:quickload :clambda-core)
CL-USER> (clambda/config:load-user-config)
;; → your init.lisp runs, hooks fire
CL-USER> (in-package :clambda-user)
CLAMBDA-USER> (describe-options)  ; see all config options
CLAMBDA-USER> (list-tasks)        ; see scheduled tasks
```

## 6. Chat from the terminal

```lisp
CLAMBDA-USER>
(let* ((client  (cl-llm:make-client
                  :base-url "http://192.168.1.189:1234/v1"
                  :api-key  "lmstudio"
                  :model    "google/gemma-3-4b"))
       (agent   (make-agent :name "my-agent" :client client))
       (session (make-session :agent agent)))
  (format t "~A~%" (run-agent session "Hello! What can you do?")))
```

Or launch the terminal chat UI:

```bash
sbcl --eval '(ql:quickload :cl-tui)' \
     --eval '(cl-tui:run :model "google/gemma-3-4b")' 
```

## 7. Enable Telegram (optional)

See [Telegram setup](../channels/telegram.html) for creating a bot and configuring the token.

## Next Steps

- [Configuration Guide](../configuration/init-lisp.html) — full init.lisp reference
- [Architecture Overview](../architecture/index.html) — understand the system
- [Built-in Tools](../api/tools.html) — what tools agents have by default
- [Custom Tools](../tools/custom-tools.html) — add your own tools
