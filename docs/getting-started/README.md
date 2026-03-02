# Getting Started

Goal: get from zero to a working Clawmacs agent quickly.

## Prerequisites

| Requirement | Minimum version | Check |
|---|---|---|
| SBCL | 2.3.0+ | `sbcl --version` |
| Quicklisp | any | `ls ~/quicklisp/setup.lisp` |
| LM Studio or Ollama | any | reachable OpenAI-compatible endpoint |

Clawmacs is local-first and works well with local LLM servers (LM Studio/Ollama).

## 1. Install SBCL and Quicklisp

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

## 2. Clone Clawmacs

```bash
cd ~/projects
git clone https://github.com/chrysolambda-ops/clawmacs.git
cd clawmacs
```

## 3. Register with ASDF

```bash
mkdir -p ~/.config/common-lisp/source-registry.conf.d/
cat > ~/.config/common-lisp/source-registry.conf.d/clawmacs.conf << 'EOF'
(:tree "/home/YOUR-USER/projects/clawmacs/projects/")
EOF
```

## 4. Create init.lisp

```bash
mkdir -p ~/.clawmacs
cp projects/clambda-core/example-init.lisp ~/.clawmacs/init.lisp
$EDITOR ~/.clawmacs/init.lisp
```

At minimum, set your model/defaults in `~/.clawmacs/init.lisp`.

## 5. Run the REPL

```bash
sbcl --eval '(ql:quickload :clawmacs-core)' \
     --eval '(clawmacs/config:load-user-config)' \
     --eval '(in-package :clawmacs-user)'
```

## 6. Optional terminal UI

```bash
sbcl --eval '(ql:quickload :cl-tui)' \
     --eval '(cl-tui:run :model "google/gemma-3-4b")'
```

## Codex OAuth quick start (optional, bridge runtime)

If you want Codex via OAuth without API keys:

1. Set in `~/.clawmacs/init.lisp`:

```lisp
(setf clawmacs/telegram:*telegram-llm-api-type* :codex-oauth)
(setf cl-llm:*codex-oauth-client-id* "YOUR_OAUTH_CLIENT_ID")
```

2. In Telegram run:
- `/codex_login`
- `/codex_link <redirect-url>`
- `/codex_status`
- `/models` (see grouped model options)
- `/models set gpt-5.3-codex` (or another listed model)

You can also verify in Lisp with `(cl-llm:codex-oauth-status-string)`.
Runtime uses a subscription bridge transport (Codex CLI path) and avoids direct OpenAI Chat Completions billing path; temporary fallback to Claude CLI is explicit in output.
Full guide: [Codex OAuth](../auth/codex-oauth.md)

## Next Steps

- [Installation](installation.md)
- [Configuration Guide](../configuration/init-lisp.md)
- [Codex OAuth](../auth/codex-oauth.md)
- [Architecture Overview](../architecture/index.md)
