# Pattern: OpenAI-Compatible LLM Client in Common Lisp

## Summary

Use `dexador` + `com.inuoe.jzon` to talk to any OpenAI-compatible LLM API
(Ollama, LM Studio, OpenRouter, etc.). Wrap in a struct-based client with 
sensible defaults and a clean separation of concerns.

## The Pattern

```lisp
;;; Client struct
(defstruct (client (:constructor %make-client))
  (base-url        nil :type string)
  (api-key         "not-needed" :type string)
  (model           nil :type (or null string))
  (default-options nil))

(defun make-client (&key base-url api-key model)
  (%make-client
   :base-url (string-right-trim "/" base-url)
   :api-key  (or api-key "not-needed")
   :model    model))

;;; Non-streaming POST
(defun post-json (url api-key body-string)
  (handler-case
      (dexador:post url
                    :headers `(("Content-Type"  . "application/json")
                               ("Authorization" . ,(format nil "Bearer ~a" api-key)))
                    :content body-string)
    (dexador:http-request-failed (e)
      (error 'http-error
             :status (dexador:response-status e)
             :body   (dexador:response-body e)))))

;;; Streaming POST — dexador :want-stream t returns stream as FIRST value
(defun post-json-stream (url api-key body-string callback)
  (let ((stream (dexador:post url
                              :headers `(("Content-Type"  . "application/json")
                                         ("Authorization" . ,(format nil "Bearer ~a" api-key)))
                              :content body-string
                              :want-stream t)))
    (unwind-protect
         (loop :for line := (read-line stream nil nil)
               :while line
               :do (funcall callback line))
      (close stream))))
```

## Key Points

1. **`:want-stream t` returns stream as primary value** — not as an extra value.
   `(let ((s (dexador:post ... :want-stream t))) ...)` is correct.
   
2. **Always use `unwind-protect` to close the stream** — even on errors.

3. **Bearer token format** — always `"Bearer <token>"` even for local APIs
   (Ollama accepts any string, including "ollama-local").

4. **`string-right-trim "/"` on base-url** — prevents double-slash in URLs.

## Ollama Setup

```lisp
;; Remote Ollama
(make-client :base-url "http://192.168.1.189:11434/v1"
             :api-key  "ollama-local"
             :model    "llama3.1:8b")

;; Local Ollama
(make-client :base-url "http://localhost:11434/v1"
             :api-key  "ollama-local"
             :model    "qwen2:0.5b")  ; 0.5b is the smallest model
```

## Environment (Guix systems)

Always set before running SBCL with dexador:
```bash
export LD_LIBRARY_PATH="/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH"
```

CFFI needs to find `libcrypto.so.3` which is in the system lib path, not Guix's.

## Tested

- SBCL 2.5.8
- dexador (via Quicklisp)
- Ollama local (qwen2:0.5b) — basic chat + streaming both work
- 117 streaming chunks received for "Count: 1, 2, 3" prompt
