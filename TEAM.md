# TEAM.md — Gensym Team Operations Manual

> The definitive reference for how this team works. Updated after Layer 4
> (post cl-llm, cl-tui, clambda-core, clambda-gui). Read this before starting
> any new project.

---

## 1. Team Roles

### Implementer
**When to use:** Any non-trivial coding task — new files, new systems, non-obvious bugs.
- Writes production CL code
- Responsible for package design up front (defpackage before any code)
- Must check knowledge base before starting
- Must compile and test locally before reporting done

### Verifier
**When to use:** After any Implementer produces code; before any commit goes to main.
- Loads the system in a fresh SBCL image
- Runs tests (`(asdf:test-system :foo)`)
- Checks for compiler notes and warnings
- Verifies the happy path manually if tests don't exist yet

### Reviewer
**When to use:** After Verifier passes; before architectural decisions are locked.
- Critiques idiom, CL style, performance
- Checks for anti-patterns from `knowledge/mistakes/recent.md`
- Ensures patterns from `knowledge/patterns/` are applied
- Does NOT rewrite — files issues for Implementer

### Researcher
**When to use:** Before Implementer starts any library integration; when something fails in an unknown domain.
- Looks up HyperSpec, Quicklisp docs, library source
- Produces a short summary + code sketch — not production code
- Documents findings in `knowledge/reference/`

### General Manager (Gensym) — direct implementation
**When to use:** Small fixes (1–5 lines), documentation tasks, config files.
- Don't spin up a sub-agent for trivial edits
- Do spin up for anything requiring exploration or > 50 lines

---

## 2. Standard CL Project Template

### Directory Layout

```
projects/my-system/
├── my-system.asd          ; ASDF system definition
├── src/
│   ├── packages.lisp      ; ALL defpackage forms — first file loaded
│   ├── conditions.lisp    ; define-condition forms
│   ├── protocol.lisp      ; struct definitions, generics (if CLOS)
│   ├── <module>.lisp      ; implementation files
│   └── main.lisp          ; entry point / top-level runners
└── t/
    ├── packages.lisp       ; test package defpackage
    └── test-<suite>.lisp   ; tests using parachute
```

### Canonical .asd

```lisp
(defsystem "my-system"
  :description "..."
  :version "0.1.0"
  :author "Gensym <gensym@cl-team>"
  :license "MIT"
  :depends-on ("dexador" "com.inuoe.jzon" "alexandria" "uiop")
  :serial t
  :components ((:file "src/packages")
               (:file "src/conditions")
               (:file "src/protocol")
               (:file "src/core")
               (:file "src/main"))
  :in-order-to ((test-op (test-op "my-system/tests"))))

(defsystem "my-system/tests"
  :depends-on ("my-system" "parachute")
  :serial t
  :components ((:file "t/packages")
               (:file "t/test-basic")))
```

### Package Conventions

```lisp
;;; In src/packages.lisp — define ALL packages here
(defpackage #:my-system/protocol
  (:use #:cl)
  (:export #:thing #:make-thing #:thing-name #:thing-value))

(defpackage #:my-system/core
  (:use #:cl)
  (:import-from #:my-system/protocol
                #:thing #:make-thing #:thing-name))

;;; Top-level convenience package — re-exports the public surface
(defpackage #:my-system
  (:use #:cl)
  (:import-from #:my-system/protocol
                #:thing #:make-thing #:thing-name #:thing-value)
  (:import-from #:my-system/core
                #:do-the-thing #:run)
  (:export
   #:thing #:make-thing #:thing-name #:thing-value
   #:do-the-thing #:run))
```

### Test Setup (parachute)

```lisp
;;; t/packages.lisp
(defpackage #:my-system/tests
  (:use #:cl #:parachute)
  (:import-from #:my-system #:do-the-thing))

;;; t/test-basic.lisp
(in-package #:my-system/tests)

(define-test "smoke"
  (is eq t t))

(define-test "basic-behavior"
  (let ((result (do-the-thing "input")))
    (is string= "expected" result)))
```

---

## 3. Pre-Implementation Checklist

Before an Implementer writes a single line:

- [ ] **Read `knowledge/mistakes/recent.md`** — don't repeat known mistakes
- [ ] **Read relevant patterns** from `knowledge/patterns/`
- [ ] **Plan packages first** — sketch all `defpackage` forms; decide what each exports
- [ ] **Decide struct vs CLOS** — see `knowledge/cl-style-guide.md`
- [ ] **Map struct accessor names to export names** — use `:conc-name` to match
- [ ] **Check Quicklisp availability** of all needed deps: `(ql:system-apropos "name")`
- [ ] **Verify ASDF registry** — ensure `~/.config/common-lisp/source-registry.conf` covers `projects/`
- [ ] **Set environment variables** — `LD_LIBRARY_PATH` for CFFI/dexador (see §5)
- [ ] **Design the public API surface** before internal implementation
- [ ] **Document the spec** as a comment at the top of the main source file

---

## 4. Post-Implementation Checklist

After an Implementer finishes:

- [ ] **Compile clean** — zero warnings, zero errors in a fresh SBCL image
- [ ] **Run tests** — `(asdf:test-system :my-system)`
- [ ] **Verify manually** — run the actual binary / REPL session
- [ ] **Log any mistakes encountered** → `knowledge/mistakes/recent.md`
- [ ] **Log any good patterns discovered** → `knowledge/patterns/<name>.md`
- [ ] **Update README** in the project dir (or create one) with usage examples
- [ ] **Commit** with a descriptive message: `git add -A && git commit -m "..."`
- [ ] **Push**: `git push`
- [ ] **Report to CEO** with concrete artifacts (not status text)

---

## 5. Environment Setup

### Required Environment Variables

```bash
# Required for dexador (CFFI → libcrypto)
export LD_LIBRARY_PATH="/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH"
```

Add to `~/.bashrc` or your shell profile. Without this, `(ql:quickload :dexador)`
succeeds but any HTTPS request will fail with a CFFI foreign library error.

### SBCL Invocation Pattern

```bash
# Standard: load quicklisp, then your system
sbcl --load ~/quicklisp/setup.lisp \
     --eval '(asdf:clear-source-registry)' \
     --eval '(asdf:initialize-source-registry)' \
     --eval '(ql:quickload :my-system)' \
     --eval '(my-system:run)'
```

For multi-form scripts, use `--load <file>` instead of multiple `--eval`.
SBCL's `--eval` accepts exactly **one form** per flag.

### Quicklisp

```bash
# Load Quicklisp in SBCL
(load "~/quicklisp/setup.lisp")

# Install a new library
(ql:quickload "library-name")

# Search for libraries
(ql:system-apropos "keyword")

# Update Quicklisp dist
(ql:update-dist "quicklisp")
```

### ASDF Source Registry

`~/.config/common-lisp/source-registry.conf`:

```lisp
(:source-registry
  (:tree "/home/slime/.openclaw/workspace-gensym/projects/")
  :inherit-configuration)
```

After editing the config or adding new projects:
```lisp
(asdf:clear-source-registry)
(asdf:initialize-source-registry)
```

---

## 6. LM Studio Endpoint & Models

**This machine has NO GPU and NO local inference server.**
Use the remote LM Studio instance only.

**Remote Base URL:** `http://192.168.1.189:1234/v1`

**Available models (check LM Studio UI on remote host for current loaded model):**
- `google/gemma-3-4b` — smallest/fastest, good for smoke tests
- *(others depend on what's loaded on the remote)*

**Client setup:**

```lisp
(cl-llm:make-client
  :base-url "http://192.168.1.189:1234/v1"
  :api-key  "lm-studio"   ; any string accepted
  :model    "google/gemma-3-4b")
```

**No Ollama instance is currently running.** Do not attempt localhost inference.

---

## 7. Git Workflow

```bash
cd /home/slime/.openclaw/workspace-gensym

# After completing a layer or significant task
git add -A
git commit -m "Layer N: brief description"
git push

# Check status
git status
git log --oneline -10
```

All work lives in the workspace repo. Commit early and often.

---

## 8. Knowledge Base Conventions

| Path | Purpose |
|------|---------|
| `knowledge/mistakes/recent.md` | Running mistake log — append, never delete |
| `knowledge/patterns/*.md` | Named reusable patterns — one file per pattern |
| `knowledge/reference/` | Cached docs, snippets, API notes |
| `knowledge/cl-style-guide.md` | CL coding standards |
| `knowledge/architecture.md` | Clambda system architecture |

**Always check before implementing.** The knowledge base exists so we don't
repeat mistakes. If you find a new pattern or make a new mistake, document it
before closing the task.
