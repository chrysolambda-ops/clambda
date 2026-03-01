;;;; src/streaming.lisp — SSE (Server-Sent Events) parsing for streaming

(in-package #:cl-llm/streaming)

;;; OpenAI-compatible streaming sends SSE events like:
;;;
;;;   data: {"id":"...","choices":[{"delta":{"content":"Hello"}}]}
;;;   data: [DONE]
;;;
;;; We parse each line, extract the content delta, and call the callback.

(defun parse-sse-line (line callback)
  "Parse a single SSE line and call CALLBACK with the text delta (or NIL).

LINE — a raw string from the HTTP response stream.
CALLBACK — called with the extracted content string, or NIL for no-op lines."
  (cond
    ;; Empty line → ignore (SSE separator)
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
         (error (e)
           ;; Malformed chunk — signal restartable condition
           (restart-case
               (signal 'stream-error* :chunk json-str)
             (skip-chunk ()
               :report "Skip this malformed SSE chunk and continue"
               nil))))))
    ;; Other lines (event:, id:, retry:, comments) → ignore
    (t nil)))

(defun make-chunk-collector ()
  "Return a callback suitable for CHAT-STREAM that accumulates text.
Also returns a thunk to retrieve the accumulated string.

  (multiple-value-bind (cb get-text) (make-chunk-collector)
    (chat-stream client messages cb)
    (get-text))"
  (let ((stream (make-string-output-stream)))
    (values
     (lambda (chunk)
       (when chunk (write-string chunk stream)))
     (lambda () (get-output-stream-string stream)))))

(defun stream-to-string (client messages &key model options tools)
  "Synchronous streaming: send request, collect all chunks, return full string."
  (cl-llm/client:chat-stream
   client messages nil
   :model model
   :options options
   :tools tools))

;;; ── Anthropic SSE parsing ─────────────────────────────────────────────────

(defun parse-anthropic-sse-line (line callback)
  "Parse a single Anthropic SSE line and call CALLBACK with text delta or NIL.

Anthropic SSE events we care about:
  event: content_block_delta
  data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"...\"}}

  event: message_stop
  data: {\"type\":\"message_stop\"}

We ignore event: lines and only process data: lines."
  (cond
    ;; Empty line → SSE separator
    ((= (length line) 0) nil)
    ;; event: lines → ignore (we parse data: lines instead)
    ((and (>= (length line) 6)
          (string= line "event:" :end1 6))
     nil)
    ;; data: lines
    ((and (> (length line) 6)
          (string= line "data: " :end1 6))
     (let ((json-str (subseq line 6)))
       (handler-case
           (let* ((obj   (com.inuoe.jzon:parse json-str))
                  (etype (gethash "type" obj)))
             (cond
               ;; Text delta
               ((string= etype "content_block_delta")
                (let* ((delta (gethash "delta" obj))
                       (dtype (when delta (gethash "type" delta)))
                       (text  (when (and delta (string= dtype "text_delta"))
                                (gethash "text" delta))))
                  (funcall callback text)))
               ;; message_stop — signal end (call with nil)
               ((string= etype "message_stop")
                (funcall callback nil))
               ;; All other event types → ignore
               (t nil)))
         (error ()
           ;; Malformed chunk — ignore silently
           nil))))
    ;; Other lines → ignore
    (t nil)))
