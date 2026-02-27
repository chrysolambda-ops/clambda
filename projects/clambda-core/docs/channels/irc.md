# IRC Channel

Clambda includes a full IRC client implemented from scratch in Common Lisp — no
external IRC library needed. Supports TLS, NickServ registration, flood protection,
automatic reconnection, and per-channel access policies.

## Quick Setup

### Step 1: Configure init.lisp

```lisp
(in-package #:clambda-user)

(register-channel :irc
  :server            "irc.libera.chat"   ; IRC server hostname
  :port              6697                ; port (6667 = plaintext, 6697 = TLS)
  :tls               t                  ; use TLS (recommended)
  :nick              "my-clambda-bot"   ; bot's IRC nick
  :realname          "Clambda AI"       ; IRC GECOS/realname field
  :channels          '("#clambda")      ; channels to join on connect
  :nickserv-password "YOUR_PASSWORD"    ; omit if not registered with NickServ
  :allowed-users     nil)               ; nil = all users; list to restrict
```

### Step 2: Start the connection

```lisp
(add-hook '*after-init-hook* #'clambda/irc:start-irc)
```

### Step 3: Trigger the bot

In a channel the bot has joined:

```
<alice> my-clambda-bot: what is 2 + 2?
<my-clambda-bot> 2 + 2 = 4
```

In a direct message (DM):

```
/msg my-clambda-bot hello there
```

---

## Configuration Reference

```lisp
(register-channel :irc
  :server            "irc.libera.chat"  ; Required
  :port              6697               ; Default: 6697
  :tls               t                  ; Default: t
  :nick              "clambda"          ; Required
  :realname          "Clambda AI"       ; Default: nick value
  :channels          '("#clambda")      ; Channels to auto-join
  :nickserv-password "secret"           ; Optional
  :allowed-users     nil                ; Global nick allowlist (nil = all)
  :dm-allowed-users  '("alice" "bob")  ; DM-specific allowlist
  :channel-policies  '(("#priv" :allowed-users ("alice")))  ; Per-channel policy
  :trigger-prefix    nil)               ; Custom trigger prefix (default: nick mention
```

### Parameters

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `:server` | string | required | IRC server hostname |
| `:port` | integer | `6697` | IRC server port |
| `:tls` | boolean | `t` | Use TLS encryption |
| `:nick` | string | required | Bot's IRC nickname |
| `:realname` | string | nick | IRC realname/GECOS |
| `:channels` | list | `nil` | Channels to auto-join after connect |
| `:nickserv-password` | string | `nil` | NickServ IDENTIFY password |
| `:allowed-users` | list/nil | `nil` | Global nick allowlist (`nil` = all allowed) |
| `:dm-allowed-users` | list/nil | `nil` | DM-specific nick allowlist (falls back to `:allowed-users`) |
| `:channel-policies` | alist | `nil` | Per-channel policies (see below) |
| `:trigger-prefix` | string | `nil` | Custom trigger string (default: nick mention) |

---

## Access Control

### Global allowlist

```lisp
;; Only "alice" and "bob" can use the bot anywhere (channels + DMs):
(register-channel :irc
  :nick          "mybot"
  :allowed-users '("alice" "bob"))
```

### Per-channel policies

Control access per channel independently of the global setting:

```lisp
(register-channel :irc
  :nick             "mybot"
  :channels         '("#public" "#private")
  :allowed-users    nil                  ; global: all allowed
  :dm-allowed-users '("alice")          ; DMs: alice only
  :channel-policies
    '(("#public"  :allowed-users nil)       ; all welcome in #public
      ("#private" :allowed-users ("alice" "bob"))))  ; restricted
```

Policy resolution order:
1. For channel messages: look up channel-specific policy → fall back to global `:allowed-users`
2. For DMs: use `:dm-allowed-users` if set → fall back to global `:allowed-users`

### Nick collision handling

If the configured nick is taken, Clambda appends `_` and retries (e.g., `chryso_`, `chryso__`).

---

## Trigger Detection

The bot only responds when triggered. In channels:

- **Nick mention:** `mybot: question` or `mybot, question` or `mybot question`
- **Custom prefix:** set `:trigger-prefix "!"` to respond to `!question`

In DMs (PRIVMSG directly to the bot):
- **Always triggered** — any message starts the agent

```lisp
;; Example: trigger with "!" prefix instead of nick mention
(register-channel :irc
  :nick           "mybot"
  :trigger-prefix "!")
;; In channel: "!what time is it?"
```

---

## Flood Protection

Clambda uses a background flood-sender thread to rate-limit outgoing messages.

- Maximum: **2 messages per second** (configurable via `*irc-send-interval*`)
- Long responses are split into multiple PRIVMSGs at word boundaries (max 400 chars)
- The flood queue handles bursts gracefully

```lisp
;; Adjust send rate (default 0.5 = 2/sec)
(setf clambda/irc:*irc-send-interval* 1.0)  ; 1/sec = slower
```

---

## Reconnection

Clambda automatically reconnects after disconnection with exponential backoff:

- First retry: 5 seconds
- Second retry: 10 seconds
- Third retry: 20 seconds
- Maximum delay: 300 seconds (5 minutes)
- Resets to 5 seconds after successful reconnect

The NickServ IDENTIFY is re-sent after each successful reconnect.

---

## Lifecycle API

```lisp
;; Start IRC connection (background thread)
(clambda/irc:start-irc)

;; Stop IRC connection (sends QUIT, exits threads)
(clambda/irc:stop-irc)

;; Check connection status
(clambda/irc:irc-connected-p)

;; Send a message directly (bypasses agent loop)
(clambda/irc:irc-send-privmsg "#clambda" "Hello channel!")

;; Join a channel after connect
(clambda/irc:irc-join "#another-channel")
```

---

## NickServ Registration

To register your bot's nick with NickServ (persistent nick ownership):

1. Connect without `:nickserv-password` first
2. In the REPL, send: `(clambda/irc:irc-send-privmsg "NickServ" "REGISTER password email@example.com")`
3. Follow NickServ's instructions
4. Add `:nickserv-password "yourpassword"` to `register-channel` in init.lisp

---

## Threading Model

```
start-irc
  ├── bt:make-thread → flood-sender-loop
  │     Dequeues lines at *irc-send-interval* (0.5s = 2/sec max)
  │     Writes line\r\n to socket, force-output, sleep
  │
  └── bt:make-thread → reader-loop
        Connect (usocket + cl+ssl for TLS)
        Register (NICK + USER, bypassing flood queue)
        Loop: read-line → dispatch-line per message
        Per PRIVMSG: bt:make-thread → route-message
          find-or-create-session (per reply-target)
          run-agent session message
          irc-send-privmsg (split + flood queue)
        On disconnect: sleep reconnect-delay → reconnect
```

Each triggered message spawns its own thread so the bot stays responsive
to multiple simultaneous users.

---

## Troubleshooting

**Bot connects but doesn't respond in channel:**
- Does the message contain the bot's nick? Try `mybot: hello`
- Check `:allowed-users` (may be restricted)
- Verify the bot actually joined the channel with `/whois mybot`

**TLS errors:**
- Ensure `libssl` is installed: `apt install libssl-dev` or `guix install openssl`
- On Guix, you may need: `export LD_LIBRARY_PATH="$HOME/.guix-profile/lib:$LD_LIBRARY_PATH"`

**Nick "already in use":**
- Clambda auto-appends `_` — the bot will appear as `mybot_`
- Register the nick with NickServ to own it

**Reconnects repeatedly:**
- May be a ban, a server-side issue, or a config error
- Check SBCL output for IRC error messages (401, 433, etc.)

---

## See Also

- [Configuration Guide](../configuration/init-lisp.html)
- [Architecture — IRC threading](../architecture/index.html)
