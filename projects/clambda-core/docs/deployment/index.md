# Deployment Guide

Running Clawmacs as a persistent service — surviving reboots, auto-reconnecting,
logging everything.

## Basic: Run in Screen/tmux

The simplest approach: start Clawmacs in a persistent terminal session.

```bash
# Start a named tmux session
tmux new-session -d -s clawmacs

# In the session, load Clawmacs
tmux send-keys -t clawmacs \
  "sbcl --eval '(ql:quickload :clawmacs-core)' --eval '(clawmacs/config:load-user-config)'" \
  Enter

# Attach to watch logs
tmux attach -t clawmacs

# Detach (keep running)
Ctrl+B, D
```

---

## Recommended: systemd Service

Create a systemd unit to start Clawmacs automatically on boot.

### 1. Create a startup script

```bash
cat > ~/bin/clawmacs-start.sh << 'EOF'
#!/bin/bash
# Clawmacs startup script
set -euo pipefail

# Load API keys from environment file
if [ -f "$HOME/.clawmacs/env" ]; then
  set -a
  source "$HOME/.clawmacs/env"
  set +a
fi

# Guix library path (if applicable)
if [ -d "$HOME/.guix-profile/lib" ]; then
  export LD_LIBRARY_PATH="$HOME/.guix-profile/lib:${LD_LIBRARY_PATH:-}"
fi

exec sbcl \
  --eval '(ql:quickload :clawmacs-core :silent t)' \
  --eval '(clawmacs/config:load-user-config)' \
  --eval '(loop (sleep 3600))'   # keep SBCL alive
EOF

chmod +x ~/bin/clawmacs-start.sh
```

### 2. Create the environment file

Store secrets outside the code:

```bash
cat > ~/.clawmacs/env << 'EOF'
OPENROUTER_API_KEY=sk-or-v1-your-key-here
ANTHROPIC_API_KEY=sk-ant-your-key-here
EOF
chmod 600 ~/.clawmacs/env
```

### 3. Create the systemd unit

```bash
mkdir -p ~/.config/systemd/user/

cat > ~/.config/systemd/user/clawmacs.service << EOF
[Unit]
Description=Clawmacs AI Agent Platform
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=%h
ExecStart=%h/bin/clawmacs-start.sh
Restart=on-failure
RestartSec=30
StandardOutput=append:%h/logs/clawmacs.log
StandardError=append:%h/logs/clawmacs.log
Environment=HOME=%h

[Install]
WantedBy=default.target
EOF
```

### 4. Enable and start

```bash
mkdir -p ~/logs

# Enable systemd user linger (service starts on boot, not just login)
loginctl enable-linger $USER

# Reload systemd and start
systemctl --user daemon-reload
systemctl --user enable clawmacs
systemctl --user start clawmacs

# Check status
systemctl --user status clawmacs

# Follow logs
journalctl --user -u clawmacs -f
```

---

## Log Management

Clawmacs emits two kinds of logs:

### 1. JSONL structured log (agent activity)

Configured in init.lisp:

```lisp
(add-hook '*after-init-hook*
  (lambda ()
    (start-server :port 18789
                  :address "127.0.0.1"
                  :log-file (merge-pathnames "logs/clawmacs.jsonl"
                                             (user-homedir-pathname)))))
```

Query with `jq`:

```bash
# All LLM requests today
cat ~/logs/clawmacs.jsonl | jq 'select(.event == "llm_request")'

# Tool calls in last 100 lines
tail -100 ~/logs/clawmacs.jsonl | jq 'select(.event == "tool_call")'
```

### 2. Console log (startup, errors, debug output)

Captured by systemd in `~/logs/clawmacs.log`:

```bash
tail -f ~/logs/clawmacs.log
```

### Log rotation (logrotate)

```bash
cat > ~/.config/logrotate/clawmacs << 'EOF'
/home/YOUR_USER/logs/clawmacs.log
/home/YOUR_USER/logs/clawmacs.jsonl {
  daily
  rotate 7
  compress
  delaycompress
  missingok
  notifempty
  copytruncate
}
EOF

# Run manually to test
logrotate --state ~/.config/logrotate/clawmacs.state \
          ~/.config/logrotate/clawmacs
```

---

## Health Monitoring

Use the HTTP `/health` endpoint as a health probe:

```bash
# Basic health check (no auth required)
curl -sf http://localhost:18789/health && echo "OK" || echo "DOWN"
```

### Watchdog cron (via Clawmacs's own scheduler)

```lisp
;; In init.lisp: watchdog for critical subsystems
(defvar *last-healthy-t* 0)

(defun %health-watchdog ()
  (setf *last-healthy-t* (get-universal-time))
  ;; Check IRC connection
  (when (and (clawmacs/irc:irc-connected-p) (not (clawmacs/irc:irc-running-p)))
    (format t "[watchdog] IRC not running — restarting...~%")
    (clawmacs/irc:start-irc))
  ;; Check Telegram
  (unless (clawmacs/telegram:telegram-running-p)
    (format t "[watchdog] Telegram not running — restarting...~%")
    (clawmacs/telegram:start-telegram)))

(add-hook '*after-init-hook*
  (lambda ()
    (schedule-task "health-watchdog" :every 60 #'%health-watchdog
                   :description "Restart failed subsystems")))
```

---

## Resource Usage

Clawmacs's idle resource footprint is modest:

| Resource | Typical idle usage |
|---|---|
| Memory (RSS) | 200–400 MB (SBCL + loaded systems) |
| CPU | ~0% (sleeping threads) |
| Threads | ~5–8 (polling, IRC, flood, cron, HTTP) |
| Disk | Minimal (logs only) |

The bulk of memory is SBCL's compiled image + loaded Quicklisp libraries.
LLM inference happens on the remote LM Studio/Ollama server.

---

## Saving a Core Image (fast startup)

For faster startup, save a preloaded SBCL core:

```bash
sbcl --eval '(ql:quickload :clawmacs-core)' \
     --eval '(save-lisp-and-die "/home/user/clawmacs.core" :executable t :purify t)'
```

Then start with:

```bash
/home/user/clawmacs.core \
  --eval '(clawmacs/config:load-user-config)' \
  --eval '(loop (sleep 3600))'
```

Startup time goes from ~30 seconds to ~1 second.

---

## Multiple Instances

To run multiple Clawmacs instances (e.g., different agents on different ports):

```bash
# Instance 1: ceo-chryso on port 18789
CLAWMACS_HOME=~/.clawmacs-ceo sbcl --load ceo-startup.lisp &

# Instance 2: researcher on port 18790
CLAWMACS_HOME=~/.clawmacs-researcher sbcl --load researcher-startup.lisp &
```

Each instance has its own `CLAWMACS_HOME`, `init.lisp`, and port.

---

## Security Checklist

- [ ] `init.lisp` has `chmod 600` (secrets inside)
- [ ] `~/.clawmacs/env` has `chmod 600`
- [ ] HTTP API uses a strong random bearer token (`openssl rand -hex 24`)
- [ ] HTTP API bound to `127.0.0.1` (not `0.0.0.0`) unless behind a reverse proxy
- [ ] Telegram bot has an allowlist configured (not open to all)
- [ ] IRC `allowed-users` is set appropriately
- [ ] SBCL process runs as a non-root user
- [ ] Logs are not world-readable (`chmod 750 ~/logs/`)
