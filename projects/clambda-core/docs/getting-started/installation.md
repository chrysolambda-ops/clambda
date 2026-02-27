# Installation

Detailed installation instructions for all supported platforms.

## System Requirements

- **SBCL 2.3.0+** — Steel Bank Common Lisp, the reference runtime
- **Quicklisp** — the de-facto CL package manager
- **ASDF 3.3+** — build system (bundled with SBCL)
- **libssl** — for IRC TLS support (`cl+ssl` dependency)
- **Node.js 18+** — only for browser automation (optional)

### Optional LLM backends

Clambda uses any OpenAI-compatible API:

| Backend | URL format | Notes |
|---------|-----------|-------|
| LM Studio | `http://HOST:1234/v1` | Recommended for local use |
| Ollama | `http://HOST:11434/v1` | Use `/v1` OpenAI-compat endpoint |
| OpenRouter | `https://openrouter.ai/api/v1` | Cloud gateway, many models |
| LM Studio remote | `http://192.168.1.x:1234/v1` | Home server, RTX 4090 etc. |

---

## Install SBCL

### Guix (Linux — recommended)

```bash
guix install sbcl
# Verify:
sbcl --version   # SBCL 2.x.x
```

### Debian / Ubuntu

```bash
sudo apt update && sudo apt install sbcl
```

> The Debian/Ubuntu SBCL may be older. If `sbcl --version` shows < 2.3, install
> from source or use Guix.

### Fedora / RHEL

```bash
sudo dnf install sbcl
```

### Arch Linux

```bash
sudo pacman -S sbcl
```

### macOS (Homebrew)

```bash
brew install sbcl
```

### macOS (MacPorts)

```bash
sudo port install sbcl
```

### From source (any platform)

```bash
# Download from https://www.sbcl.org/platform-table.html
# e.g. for x86-64 Linux:
curl -O https://downloads.sourceforge.net/project/sbcl/sbcl/2.5.8/sbcl-2.5.8-x86-64-linux-binary.tar.bz2
tar xf sbcl-2.5.8-x86-64-linux-binary.tar.bz2
cd sbcl-2.5.8-x86-64-linux/
sudo ./install.sh
```

---

## Install Quicklisp

Quicklisp is a package manager for CL that downloads and caches library dependencies.

```bash
# Download the installer
curl -O https://beta.quicklisp.org/quicklisp.lisp

# Install to ~/quicklisp/ and add to ~/.sbclrc
sbcl --load quicklisp.lisp \
     --eval '(quicklisp-quickstart:install)' \
     --eval '(ql:add-to-init-file)' \
     --quit
```

Verify:

```bash
sbcl --eval '(ql:system-apropos "dexador")' --quit
# Should print something like: #<SYSTEM dexador ...>
```

---

## Install Clambda

### From GitHub (recommended)

```bash
cd ~/projects          # or wherever you keep code
git clone https://github.com/chrysolambda-ops/clambda.git
```

This gives you four projects under `clambda/projects/`:

```
projects/
  cl-llm/          # LLM API client
  cl-tui/          # terminal chat UI  
  clambda-core/    # agent platform (main system)
  clambda-gui/     # McCLIM GUI (optional)
```

### Register with ASDF

ASDF needs to know where to find the Clambda systems. Create a source registry config:

```bash
mkdir -p ~/.config/common-lisp/source-registry.conf.d/

cat > ~/.config/common-lisp/source-registry.conf.d/clambda.conf << 'EOF'
(:tree "/home/YOU/projects/clambda/projects/")
EOF
```

Replace `/home/YOU/projects/clambda` with your actual path. The `:tree` directive
makes ASDF recursively scan that directory for `.asd` files.

---

## Install Dependencies

Quicklisp will download most dependencies automatically. To pre-load all of them:

```bash
sbcl --eval '(ql:quickload :clambda-core)' --quit
```

This will download and compile: `dexador`, `jzon`, `alexandria`, `cl-ppcre`,
`usocket`, `cl+ssl`, `bordeaux-threads`, `hunchentoot`, `parachute`.

Expect the first load to take 2–5 minutes. Subsequent loads use compiled FASLs.

### Guix / NixOS: LD_LIBRARY_PATH

On Guix and NixOS, you may need to set `LD_LIBRARY_PATH` for `dexador` (which uses
libssl via `cl+ssl`):

```bash
# Find the libssl path:
guix package --search-paths 2>/dev/null | grep LD_LIBRARY
# Or:
ls ~/.guix-profile/lib/libssl*

# Add to your shell profile (~/.bashrc or ~/.profile):
export LD_LIBRARY_PATH="$HOME/.guix-profile/lib:$LD_LIBRARY_PATH"
```

---

## Browser Automation (optional)

Browser tools require Node.js and Playwright. From the clambda-core directory:

```bash
cd projects/clambda-core/browser/
npm install                           # install playwright npm package
npx playwright install chromium       # ~200MB Chromium download
```

Then in `init.lisp`:

```lisp
(register-channel :browser :headless t)
(add-hook '*after-init-hook* #'clambda/browser:browser-launch)
```

---

## Verify Installation

Run the test suite:

```bash
sbcl --eval '(ql:quickload :clambda-core)' \
     --eval '(asdf:test-system :clambda-core)' \
     --quit 2>&1 | tail -20
```

Expected: `235 tests, 0 failures`.

Or a quick smoke test:

```bash
sbcl --eval '(ql:quickload :clambda-core)' \
     --eval '(format t "Clambda ~A loaded OK~%" (asdf:system-version (asdf:find-system :clambda-core)))' \
     --quit
```

---

## Next Steps

- [Quick Start](README.md) — run your first agent
- [Configuration](../configuration/init-lisp.md) — write your `init.lisp`
