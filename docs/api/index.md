# HTTP API Reference

Clawmacs includes a REST management API built on Hunchentoot. It lets you inspect,
control, and send messages to agents programmatically.

## Starting the API Server

In `init.lisp`:

```lisp
(setf *api-token* "YOUR_SECRET_TOKEN")   ; required for auth

(add-hook '*after-init-hook*
  (lambda ()
    (start-server :port 18789 :address "127.0.0.1")))
```

Or start manually from the REPL:

```lisp
(clawmacs/http-server:start-server
  :port    18789
  :address "127.0.0.1"
  :api-token "YOUR_SECRET_TOKEN")
```

## Authentication

All endpoints except `/health` require a Bearer token:

```bash
curl -H "Authorization: Bearer YOUR_SECRET_TOKEN" \
     http://localhost:18789/api/system
```

Requests without a valid token get `401 Unauthorized`.

---

## Endpoints

### `GET /health` — Health Check (no auth required)

Returns server status. Suitable for load balancer probes.

**Response:**

```json
{
  "status": "ok",
  "uptime": 3600,
  "version": "0.8.0"
}
```

---

### `GET /api/system` — System Information

Returns version, uptime, log file path, and counts.

```bash
curl -H "Authorization: Bearer TOKEN" http://localhost:18789/api/system
```

**Response:**

```json
{
  "version": "0.8.0",
  "uptimeSeconds": 3600,
  "logFile": "logs/clawmacs.jsonl",
  "agents": 2,
  "sessions": 1,
  "tasks": 3,
  "auth": "enabled"
}
```

---

### `GET /api/agents` — List Agents

Lists all agents registered via `define-agent` in init.lisp.

```bash
curl -H "Authorization: Bearer TOKEN" http://localhost:18789/api/agents
```

**Response:**

```json
{
  "agents": [
    { "name": "coder",      "model": "google/gemma-3-4b" },
    { "name": "researcher", "model": "deepseek/deepseek-r1:8b" }
  ]
}
```

---

### `POST /api/agents/:name/start` — Create Agent Session

Creates (or retrieves) a management session for the named agent.

```bash
curl -X POST \
     -H "Authorization: Bearer TOKEN" \
     http://localhost:18789/api/agents/coder/start
```

**Response:**

```json
{
  "sessionKey": "mgmt:coder",
  "status": "ok"
}
```

---

### `POST /api/agents/:name/message` — Send Message to Agent

Sends a message synchronously and returns the agent's response.

```bash
curl -X POST \
     -H "Authorization: Bearer TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"message": "List the files in the current directory"}' \
     http://localhost:18789/api/agents/coder/message
```

**Request body:**

```json
{
  "message": "your message here"
}
```

**Response:**

```json
{
  "response": "Here are the files:\n- src/\n- README.md\n...",
  "turns": 3,
  "tokens": 1240
}
```

---

### `GET /api/agents/:name/history` — Session Message History

Returns the conversation history for the agent's management session.

```bash
curl -H "Authorization: Bearer TOKEN" \
     http://localhost:18789/api/agents/coder/history
```

**Response:**

```json
{
  "sessionKey": "mgmt:coder",
  "messages": [
    { "role": "user",      "content": "List the files..." },
    { "role": "assistant", "content": "Here are the files:..." }
  ]
}
```

---

### `DELETE /api/agents/:name/stop` — Terminate Agent Session

Removes the agent's management session (clears conversation history).

```bash
curl -X DELETE \
     -H "Authorization: Bearer TOKEN" \
     http://localhost:18789/api/agents/coder/stop
```

**Response:**

```json
{ "status": "ok" }
```

---

### `GET /api/sessions` — List All Sessions

Lists all active sessions (Telegram, IRC, management, etc.).

```bash
curl -H "Authorization: Bearer TOKEN" http://localhost:18789/api/sessions
```

**Response:**

```json
{
  "sessions": [
    { "key": "telegram:chat:535004273", "turns": 5, "tokens": 2100 },
    { "key": "irc:target:#bots",        "turns": 2, "tokens": 830 },
    { "key": "mgmt:coder",              "turns": 1, "tokens": 320 }
  ]
}
```

---

### `GET /api/channels` — List Registered Channels

Returns all channels registered via `register-channel`.

```bash
curl -H "Authorization: Bearer TOKEN" http://localhost:18789/api/channels
```

**Response:**

```json
{
  "channels": [
    { "type": "telegram", "token": "8533...7vc" },
    { "type": "irc",      "server": "irc.nogroup.group", "nick": "chryso" }
  ]
}
```

---

### `GET /api/tasks` — List Cron Tasks

Returns all active scheduled tasks.

```bash
curl -H "Authorization: Bearer TOKEN" http://localhost:18789/api/tasks
```

**Response:**

```json
{
  "tasks": [
    {
      "name":        "heartbeat",
      "kind":        "periodic",
      "interval":    1800,
      "description": "30-minute health check",
      "runCount":    12,
      "lastRun":     "2026-02-27T04:00:00Z",
      "lastError":   null
    }
  ]
}
```

---

## Legacy Endpoints

These endpoints from Layer 5 are unchanged and fully functional:

### `POST /chat` — Synchronous Chat

```bash
curl -X POST \
     -H "Content-Type: application/json" \
     -d '{"message": "Hello", "agent": "coder"}' \
     http://localhost:18789/chat
```

### `POST /chat/stream` — Streaming SSE Chat

Returns Server-Sent Events (SSE) stream.

```bash
curl -N -X POST \
     -H "Content-Type: application/json" \
     -d '{"message": "Tell me a story"}' \
     http://localhost:18789/chat/stream
```

---

## Server Lifecycle

```lisp
;; Start (idempotent — returns existing server if already running)
(clawmacs/http-server:start-server :port 18789 :address "127.0.0.1")

;; Stop
(clawmacs/http-server:stop-server)

;; Restart (stop + start)
(clawmacs/http-server:restart-server)

;; Check status
clawmacs/http-server:*server*            ; server object or NIL
(clawmacs/http-server:server-uptime-seconds)

;; Configure
clawmacs/http-server:*api-token*         ; bearer token string
clawmacs/http-server:*default-port*      ; default: 7474
```

---

## Example: Agent Control Script

```bash
#!/bin/bash
BASE="http://localhost:18789"
TOKEN="YOUR_SECRET_TOKEN"
AUTH="-H 'Authorization: Bearer $TOKEN'"

# Start a session
curl -sX POST "$BASE/api/agents/coder/start" $AUTH | jq .

# Send a message
curl -sX POST "$BASE/api/agents/coder/message" $AUTH \
  -H "Content-Type: application/json" \
  -d '{"message": "Write a hello world in CL"}' | jq -r .response

# Stop when done
curl -sX DELETE "$BASE/api/agents/coder/stop" $AUTH | jq .
```

---

## Structured Logging

All API requests and responses are logged in JSONL format:

```bash
tail -f logs/clawmacs.jsonl | jq .
```

Each line is a JSON object with fields:
- `timestamp` — ISO 8601
- `event` — `http_request`, `http_response`, `llm_request`, `tool_call`, `tool_result`, `heartbeat`
- `data` — event-specific payload

The log file location is configured via:

```lisp
(clawmacs/http-server:start-server :log-file "/path/to/clawmacs.jsonl")
```

Default: `logs/clawmacs.jsonl` relative to the process working directory.
