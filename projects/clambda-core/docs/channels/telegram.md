# Telegram Channel

Clambda's Telegram channel uses the Bot API with long polling (no webhook server needed).
The bot receives messages, routes them to the agent loop, and replies — with optional
streaming delivery.

## Quick Setup

### Step 1: Create a bot

1. Open Telegram and message **[@BotFather](https://t.me/BotFather)**
2. Send `/newbot` and follow the prompts
3. Copy the bot token (format: `1234567890:AAABBBCCC...`)

### Step 2: Find your Telegram user ID

1. Message **[@userinfobot](https://t.me/userinfobot)** or **[@myidbot](https://t.me/myidbot)**
2. Copy your numeric user ID (e.g. `535004273`)

This is used for the allowlist — without it, anyone can message your bot.

### Step 3: Configure init.lisp

```lisp
(in-package #:clambda-user)

(register-channel :telegram
  :token         "YOUR_BOT_TOKEN_HERE"
  :allowed-users '(535004273)    ; your numeric Telegram user ID
  :streaming     t)              ; stream tokens as they arrive (recommended)
```

### Step 4: Start

```lisp
(add-hook '*after-init-hook* #'clambda/telegram:start-telegram)
```

Then load Clambda:

```bash
sbcl --eval '(ql:quickload :clambda-core)' \
     --eval '(clambda/config:load-user-config)' \
     --noinform
```

Your bot is now polling. Send it a message on Telegram.

---

## Configuration Reference

```lisp
(register-channel :telegram
  :token         "BOT_TOKEN"        ; Required. From @BotFather.
  :allowed-users '(123 456)         ; Optional. Numeric user IDs. nil = anyone.
  :streaming     t)                 ; Optional. Default: T. Stream tokens.
```

### Options

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `:token` | string | required | Bot API token from @BotFather |
| `:allowed-users` | list of integers | `nil` | User ID allowlist. `nil` = all users allowed. |
| `:streaming` | boolean | `t` | Send streaming partial responses (editMessageText as tokens arrive) |

### Global option variables

Set these before `register-channel` or in init.lisp:

```lisp
;; Model used by Telegram agent sessions
(setf clambda/telegram:*telegram-llm-base-url* "http://192.168.1.189:1234/v1")
(setf clambda/telegram:*telegram-llm-api-key*  "lmstudio")

;; System prompt for Telegram sessions
(setf clambda/telegram:*telegram-system-prompt*
      "You are a helpful assistant.")

;; Polling timeout in seconds (shorter = more responsive shutdown)
(setf clambda/telegram:*telegram-poll-timeout* 5)

;; Streaming options (Layer 9+)
(setf clambda/telegram:*telegram-streaming*       t)
(setf clambda/telegram:*telegram-stream-debounce-ms* 500)
```

---

## Streaming Partial Responses

When `:streaming t` is set (the default), Clambda simulates OpenClaw's
`streaming: "partial"` behaviour:

1. Clambda sends an initial `"..."` placeholder message
2. As the LLM generates tokens, the placeholder is updated via `editMessageText`
   (debounced every 500ms to avoid Telegram rate limits)
3. After the agent loop completes, a final edit shows the complete response

This gives the user real-time feedback that the bot is thinking and generating.

**Disable** streaming if you prefer clean single-message delivery:

```lisp
(register-channel :telegram :token "..." :streaming nil)
```

---

## Multiple Bot Accounts

To run multiple Telegram bots (e.g. one per agent), start multiple channels:

> **Note:** Multiple simultaneous Telegram accounts require calling `start-telegram`
> multiple times with different configurations. This is a known gap vs. OpenClaw.
> Currently, `*telegram-channel*` is a singleton. Full multi-account support is
> planned.

For now, the workaround is to run separate Clambda processes, each with its own
`init.lisp` and bot token.

---

## Allowlist and Security

Clambda's Telegram implementation **silently ignores** messages from users not in
the allowlist. No error is shown to the disallowed user.

```lisp
;; Only allow one specific user:
(register-channel :telegram
  :token         "BOT_TOKEN"
  :allowed-users '(535004273))

;; Allow anyone (dangerous — be careful):
(register-channel :telegram
  :token         "BOT_TOKEN"
  :allowed-users nil)
```

User IDs are integers. Do not use usernames (they can change).

---

## Lifecycle API

```lisp
;; Start the polling thread
(clambda/telegram:start-telegram)

;; Stop the polling thread (gracefully, up to *telegram-poll-timeout* seconds)
(clambda/telegram:stop-telegram)

;; Check if polling is active
(clambda/telegram:telegram-running-p)

;; Send a message directly (bypasses agent loop)
(clambda/telegram:send-telegram-message chat-id "Hello!")
```

---

## Error Handling

The polling loop catches and logs all errors without crashing:

- **Network errors:** logged, sleep 5s, retry
- **Parse errors (bad JSON):** logged, continue
- **Agent errors:** logged, error message sent to user
- **sendMessage failures:** logged, polling continues

---

## Troubleshooting

**Bot doesn't respond:**
- Check that the token is correct: `curl https://api.telegram.org/botYOUR_TOKEN/getMe`
- Verify your user ID is in `:allowed-users` (or set to `nil`)
- Check SBCL output for errors

**"Unauthorized" error:**
- The bot token is invalid or revoked. Re-generate from @BotFather.

**Slow responses:**
- LLM inference speed. Try a smaller model or enable streaming (`:streaming t`)
  so users see progress.

**Messages stop arriving:**
- The polling thread may have crashed. Call `(clambda/telegram:start-telegram)` again.
- Add a cron watchdog:

```lisp
(schedule-task "telegram-watchdog" :every 60
  (lambda ()
    (unless (clambda/telegram:telegram-running-p)
      (format t "[watchdog] Restarting Telegram...~%")
      (clambda/telegram:start-telegram)))
  :description "Restart Telegram if it crashes")
```

---

## See Also

- [Configuration Guide](../configuration/init-lisp.html) — full init.lisp reference
- [HTTP API](../api/index.html) — send messages programmatically
