# Codex OAuth (Bridge Runtime)

Clawmacs keeps `/codex_login` + `/codex_link` browser OAuth UX, but runtime no longer uses direct `api.openai.com/v1/chat/completions` for `:codex-oauth`.

## Runtime transport (important)

For `:codex-oauth` requests:
1. Primary: Codex subscription-compatible CLI transport (`codex exec`)
2. Interim fallback: Claude CLI transport with explicit warning in the model reply

This avoids the API-key billing/quota path that caused `insufficient_quota` with subscription-only accounts.

## init.lisp configuration

```lisp
(in-package #:clawmacs-user)

(setf clawmacs/telegram:*telegram-llm-api-type* :codex-oauth)
(setf cl-llm:*codex-oauth-client-id* "YOUR_OAUTH_CLIENT_ID")
(setf *default-model* "gpt-5-codex")
```

Optional: disable interim fallback (strict mode)

```lisp
(setf cl-llm:*codex-oauth-fallback-enabled* nil)
```

## Telegram login flow

1. Send `/codex_login`
2. Open the returned URL and approve access
3. Copy the full redirect URL
4. Send `/codex_link <redirect-url>`
5. Verify with `/codex_status`

## Known interim limitations

- Full OpenClaw parity transport via `@mariozechner/pi-ai` is not wired yet.
- Streaming for `:codex-oauth` bridge currently emits final text as one chunk.
- If Codex bridge runtime is unavailable, fallback response is prefixed with a warning.

## Troubleshooting

### Codex runtime unavailable
- Run `codex login` on the host machine
- Verify session files under `~/.codex/`
- Retry message or run `/status`

### OAuth state mismatch
Run `/codex_login` again and use the latest redirect URL.

### Missing/expired OAuth
Relink via `/codex_login` + `/codex_link`.

## Security notes

- OAuth session file: `~/.clawmacs/auth/codex-oauth.json` (`0600`)
- Tokens are not printed in status output
