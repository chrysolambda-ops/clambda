# Built-in Tools

Clambda ships with a set of built-in tools available to all agents.
These are registered by `clambda/builtins:register-builtins` and cover
the most common agent needs: filesystem, shell, web, and I/O.

## Tool List

| Tool name | Function | Description |
|-----------|---------|-------------|
| `exec` | Shell execution | Run shell commands, capture stdout/stderr |
| `read_file` | File reading | Read a file's contents |
| `write_file` | File writing | Write or overwrite a file |
| `list_dir` | Directory listing | List directory contents |
| `web_fetch` | HTTP fetch | Fetch and extract content from a URL |
| `tts` | Text-to-speech | Speak text aloud via system TTS |
| `browser_navigate` | Browser | Navigate to a URL |
| `browser_snapshot` | Browser | Get the ARIA accessibility tree |
| `browser_screenshot` | Browser | Capture a screenshot |
| `browser_click` | Browser | Click an element by CSS selector |
| `browser_type` | Browser | Fill an input field |
| `browser_evaluate` | Browser | Execute JavaScript |

---

## exec — Shell Execution

Runs a shell command and returns combined stdout + stderr.

**Parameters:**

| Name | Type | Required | Description |
|------|------|---------|-------------|
| `command` | string | yes | Shell command to execute |
| `timeout` | integer | no | Timeout in seconds (default: 30) |
| `workdir` | string | no | Working directory (default: current dir) |

**Example LLM usage:**

```
Tool: exec
Arguments: {"command": "ls -la /home/user/projects/"}
Result: total 48\ndrwxr-xr-x 12 user user 4096 Feb 27 ...\n...
```

**Security note:** `exec` gives agents full shell access. Trust only agents you control.
For untrusted agents, consider creating a restricted tool registry without `exec`.

---

## read_file — File Reading

Reads a file and returns its contents as a string.

**Parameters:**

| Name | Type | Required | Description |
|------|------|---------|-------------|
| `path` | string | yes | File path (absolute or relative) |
| `offset` | integer | no | Line number to start reading from (1-indexed) |
| `limit` | integer | no | Maximum number of lines to read |

**Example:**

```
Tool: read_file
Arguments: {"path": "/home/user/project/README.md"}
Result: # My Project\n\nA brief description...\n
```

---

## write_file — File Writing

Writes content to a file. Creates parent directories if needed.
Overwrites the file if it exists.

**Parameters:**

| Name | Type | Required | Description |
|------|------|---------|-------------|
| `path` | string | yes | File path to write |
| `content` | string | yes | File content |

**Example:**

```
Tool: write_file
Arguments: {"path": "/tmp/hello.lisp", "content": "(format t \"Hello~%\")"}
Result: Wrote 22 bytes to /tmp/hello.lisp
```

---

## list_dir — Directory Listing

Lists files and directories at a given path.

**Parameters:**

| Name | Type | Required | Description |
|------|------|---------|-------------|
| `path` | string | yes | Directory path to list |

**Example:**

```
Tool: list_dir
Arguments: {"path": "/home/user/projects"}
Result: clambda/\ngaurix/\ntodo.org\nREADME.md\n
```

---

## web_fetch — HTTP Content Fetch

Fetches a URL and returns its readable content (HTML stripped to text).

**Parameters:**

| Name | Type | Required | Description |
|------|------|---------|-------------|
| `url` | string | yes | HTTP or HTTPS URL to fetch |
| `max_chars` | integer | no | Maximum characters to return |

**Example:**

```
Tool: web_fetch
Arguments: {"url": "https://www.gnu.org/philosophy/free-sw.html"}
Result: What is Free Software?\n\nFree software means the users have...\n
```

Implementation: uses `dexador` for HTTP, `cl-ppcre` for HTML tag stripping.

---

## tts — Text-to-Speech

Speaks text aloud using the system's TTS engine. Graceful no-op if no
TTS engine is available.

**Parameters:**

| Name | Type | Required | Description |
|------|------|---------|-------------|
| `text` | string | yes | Text to speak |

**Supported TTS engines (checked in order):**

1. `piper` — high quality neural TTS
2. `espeak-ng` — lightweight, widely available
3. `espeak` — older espeak
4. `say` — macOS built-in

Install on Debian/Ubuntu:

```bash
sudo apt install espeak-ng
```

Install on Guix:

```bash
guix install espeak-ng
```

---

## Browser Tools

Browser tools require the Playwright bridge to be set up. See
[Installation — Browser Automation](../getting-started/installation.md#browser-automation-optional).

### browser_navigate

Navigate to a URL and wait for DOM content to load.

```
Tool: browser_navigate
Arguments: {"url": "https://duckduckgo.com"}
Result: Navigated to https://duckduckgo.com
```

### browser_snapshot

Get the ARIA accessibility tree of the current page as YAML. Useful for
understanding page structure without rendering.

```
Tool: browser_snapshot
Arguments: {}
Result: - document:\n  - heading "DuckDuckGo"\n  - textbox "Search the web"\n  ...
```

### browser_screenshot

Capture the current page as a screenshot.

```
Tool: browser_screenshot
Arguments: {"path": "/tmp/screenshot.png"}
Result: Screenshot saved to /tmp/screenshot.png
```

If `path` is omitted, returns a base64-encoded PNG string.

### browser_click

Click an element matching a CSS selector.

```
Tool: browser_click
Arguments: {"selector": "input[name='q']"}
Result: Clicked input[name='q']
```

### browser_type

Fill an input field (clears existing content first).

```
Tool: browser_type
Arguments: {"selector": "input[name='q']", "text": "Common Lisp"}
Result: Typed into input[name='q']
```

### browser_evaluate

Execute arbitrary JavaScript in the page and return the result.

```
Tool: browser_evaluate
Arguments: {"js": "document.title"}
Result: DuckDuckGo — Privacy Protected Search Engine
```

---

## Registering Built-in Tools

Built-in tools are not automatically added to every registry. Use:

```lisp
;; Create a registry with all built-ins
(let ((registry (clambda:make-tool-registry)))
  (clambda/builtins:register-builtins registry)
  ;; Add browser tools (requires browser to be launched)
  (clambda/browser:register-browser-tools registry)
  ;; Add user-defined tools from init.lisp
  (clambda/config:merge-user-tools! registry)
  ;; Use the registry
  (make-agent :name "my-agent" :client client :tool-registry registry))
```

Or create a browser-only registry:

```lisp
(clambda/browser:make-browser-registry)  ; just the 6 browser tools
```

---

## Custom Tool Schema

Tools use a JSON Schema-like parameter spec:

```lisp
;; Parameters plist format:
'((:name "param-name"
   :type "string"        ; "string" | "integer" | "number" | "boolean" | "array" | "object"
   :description "..."    ; shown to the LLM
   :required t)          ; optional, default T
  (:name "optional-param"
   :type "integer"
   :description "..."
   :required nil))       ; explicitly optional
```

See [Custom Tools](../tools/custom-tools.md) for full documentation on defining
and registering your own tools.
