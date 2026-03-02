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

## Codex OAuth quick start (optional)

If you want to use Codex via OAuth (no API key in init):

```bash
codex login
```

Then set Telegram/client API type to `:codex-cli` in init.lisp (see config guide).
Full guide: [Codex OAuth](../auth/codex-oauth.md)

## Next Steps

- [Installation](installation.md)
- [Configuration Guide](../configuration/init-lisp.md)
- [Codex OAuth](../auth/codex-oauth.md)
- [Architecture Overview](../architecture/index.md)
