# Codex OAuth in Clawmacs

Use this when you want Clawmacs to talk to Codex through an OAuth-linked CLI session instead of storing an API key in `init.lisp`.

## 1) Prerequisites

- `codex` CLI installed and available on `PATH`
- Clawmacs checkout + SBCL/Quicklisp working
- A model compatible with your Codex account (example: `gpt-5-codex`)

Check CLI availability:

```bash
codex --help
```

## 2) Link/login flow

Authenticate the CLI with OAuth:

```bash
codex login
```

Follow the browser/device prompts until the CLI reports success.

## 3) Where session credentials are stored

The OAuth session is stored by the Codex CLI in its own local config/state directory (managed by the CLI, not by Clawmacs).

To inspect where your CLI keeps config on your machine, run:

```bash
codex --help
```

and check the config/state section for your platform.

## 4) Required `init.lisp` config

Set Clawmacs to use the Codex CLI backend explicitly:

```lisp
(in-package #:clawmacs-user)

(setf clawmacs/telegram:*telegram-llm-api-type* :codex-cli)
(setf *default-model* "gpt-5-codex")
```

If you build clients directly, use:

```lisp
(cl-llm:make-codex-cli-client :model "gpt-5-codex")
```

## 5) Verification

First verify CLI auth outside Clawmacs:

```bash
codex exec --json --model gpt-5-codex "Reply with: oauth-ok"
```

Then verify Clawmacs loads with your config:

```bash
sbcl --eval '(ql:quickload :clawmacs-core)' \
     --eval '(clawmacs/config:load-user-config)' \
     --eval '(format t "Loaded config with api-type=~A~%" clawmacs/telegram:*telegram-llm-api-type*)' \
     --quit
```

Expected: api type prints `CODEX-CLI` (or `:CODEX-CLI` depending on printer settings).

## 6) Troubleshooting

### "Codex CLI failed" / no output

- Ensure `codex` is installed and on `PATH`
- Re-run `codex login`
- Retry the standalone verification command above

### Expired or invalid OAuth session

Re-authenticate:

```bash
codex login
```

### Wrong auth mode in Clawmacs

If Clawmacs still tries HTTP provider auth, ensure:

```lisp
(setf clawmacs/telegram:*telegram-llm-api-type* :codex-cli)
```

and restart the running channel/session.
