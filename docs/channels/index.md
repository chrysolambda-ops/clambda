# Channels Overview

Channels are how Clawmacs connects to the outside world. Each channel receives
messages, routes them to the agent loop, and sends responses back.

## Available Channels

| Channel | Status | Description |
|---------|--------|-------------|
| [Telegram](telegram.md) | ✅ Production | Bot API long polling, streaming responses |
| [IRC](irc.md) | ✅ Production | Raw IRC with TLS, NickServ, flood protection |
| Browser | ✅ Production | Playwright headless browser (not a messaging channel) |
| REPL | ✅ Built-in | Interactive REPL for development |
| Discord | 🔧 Planned | Gateway WebSocket — on the roadmap |
| WhatsApp | 🔧 Planned | Requires bridge — on the roadmap |

## How Channels Work

1. A channel plugin starts a background thread (or polling loop)
2. Incoming messages are dispatched to `find-or-create-session` (per user/chat)
3. The session feeds the message to `run-agent`
4. The agent loop calls the LLM and executes tools
5. The response is sent back via the channel's send function

Each user/chat gets its own session so conversations are isolated.
A user who DMs the Telegram bot has a different session than the same user in an IRC channel.

## Registering Channels

All channels are registered with `register-channel` in `init.lisp`:

```lisp
;; Telegram
(register-channel :telegram :token "TOKEN" :allowed-users '(123456))

;; IRC
(register-channel :irc :server "irc.libera.chat" :nick "mybot" :channels '("#lisp"))

;; Browser (not a messaging channel — enables browser tools for agents)
(register-channel :browser :headless t)
```

## Starting Channels

Registration doesn't start channels. You must explicitly start them, typically
in `*after-init-hook*`:

```lisp
(add-hook '*after-init-hook*
  (lambda ()
    (clawmacs/telegram:start-telegram)
    (clawmacs/irc:start-irc)
    (clawmacs/browser:browser-launch)))
```

Or use `start-all-channels` (starts all registered Telegram channels):

```lisp
(add-hook '*after-init-hook* #'clawmacs/telegram:start-all-channels)
```

## Inspect Registered Channels

```lisp
;; In the REPL:
clawmacs/config:*registered-channels*
;; => ((:telegram :token "..." :allowed-users (123456))
;;     (:irc :server "irc.libera.chat" ...))

;; Via HTTP API:
;; GET /api/channels
```

## Per-Channel Agent Assignment

Currently, all channels use whichever agent is configured in the channel's
LLM settings (`*telegram-llm-base-url*`, etc.). More granular routing
(different agents per channel or per user) can be implemented via hooks:

```lisp
(add-hook '*channel-message-hook*
  (lambda (channel msg)
    ;; Log inbound messages
    (format t "[channel ~A] ~A~%" channel (getf msg :text))))
```

## See Also

- [Telegram](telegram.md) — complete Telegram setup and configuration
- [IRC](irc.md) — complete IRC setup and configuration
- [Configuration Guide](../configuration/init-lisp.md) — full init.lisp reference
