# Pattern: SSE (Server-Sent Events) Parsing for LLM Streaming

## Summary

OpenAI-compatible streaming endpoints send SSE data. Parse it line by line
from a Gray stream (via dexador `:want-stream t`).

## Format

```
data: {"id":"...","choices":[{"delta":{"content":"Hello"}}]}
data: {"id":"...","choices":[{"delta":{"content":" world"}}]}
data: [DONE]
```

## Parser

```lisp
(defun parse-sse-line (line callback)
  "Parse one SSE line; call CALLBACK with content delta or NIL."
  (cond
    ;; Empty line — SSE separator, ignore
    ((= (length line) 0) nil)
    ;; [DONE] sentinel
    ((string= line "data: [DONE]") nil)
    ;; data: {...}
    ((and (> (length line) 6)
          (string= line "data: " :end1 6))
     (let ((json-str (subseq line 6)))
       (handler-case
           (let* ((obj     (com.inuoe.jzon:parse json-str))
                  (choices (gethash "choices" obj))
                  (delta   (when (and choices (> (length choices) 0))
                             (gethash "delta" (aref choices 0))))
                  (content (when delta (gethash "content" delta))))
             (funcall callback content))
         (error ()
           ;; Malformed chunk — skip or signal condition
           nil))))
    (t nil)))

;;; Usage in streaming loop:
(loop :for line := (read-line stream nil nil)
      :while line
      :do (parse-sse-line line
                          (lambda (delta)
                            (when delta
                              (write-string delta)
                              (force-output)))))
```

## Integration with chat-stream

```lisp
(defun chat-stream (client messages callback &key model)
  (let* ((request-ht (build-request-ht model messages nil nil))
         (_ (setf (gethash "stream" request-ht) t))
         (body-str (com.inuoe.jzon:stringify request-ht))
         (accumulated (make-string-output-stream)))
    (declare (ignore _))
    (post-json-stream
     (chat-url client)
     (client-api-key client)
     body-str
     (lambda (line)
       (parse-sse-line line
                       (lambda (delta)
                         (when delta
                           (write-string delta accumulated)
                           (when callback
                             (funcall callback delta)))))))
    (get-output-stream-string accumulated)))
```

## Key Points

1. **Check `"data: "` prefix** — 6-char prefix, use `:end1 6` for the test
2. **`gethash "content" delta` can be NIL** — for role/tool_calls deltas
3. **`(aref choices 0)` not `(elt choices 0)`** — jzon returns JSON arrays as vectors
4. **Always guard with `(> (length choices) 0)`** — empty choices vector possible

## Tested

- 117 chunks for "Count: 1, 2, 3" with qwen2:0.5b via Ollama
- Full text accumulated correctly via `make-string-output-stream`
