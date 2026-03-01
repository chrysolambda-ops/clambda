;;;; src/loop.lisp — Main chat loop for cl-tui

(in-package #:cl-tui/loop)

;;; ── Default config ───────────────────────────────────────────────────────────

(defparameter *default-base-url* "https://openrouter.ai/api/v1"
  "Default LLM API base URL (OpenRouter).")

(defparameter *default-api-key*  nil
  "Default API key — NIL means try to load from clawmacs config.")

(defparameter *default-model*    "google/gemma-3-4b"
  "Default model name.")

;;; ── Config loading ───────────────────────────────────────────────────────────

(defun %load-openrouter-key ()
  "Try to read *openrouter-api-key* from the clawmacs-user package.
Returns the key string or NIL if unavailable."
  (handler-case
      (let ((sym (find-symbol "*OPENROUTER-API-KEY*" :clawmacs-user)))
        (when (and sym (boundp sym))
          (symbol-value sym)))
    (error () nil)))

(defun %effective-api-key (given-key)
  "Return GIVEN-KEY if non-NIL, else try clawmacs config, else \"not-needed\"."
  (or given-key (%load-openrouter-key) "not-needed"))

;;; ── Tool call display ────────────────────────────────────────────────────────

(defun %on-tool-call (name args stream)
  "Display a tool call notification."
  (print-system-notice
   (format nil "⚙ calling tool: ~a ~a" name
           (handler-case
               (with-output-to-string (s)
                 (let ((*print-length* 5) (*print-level* 3))
                   (prin1 args s)))
             (error () "...")))
   stream))

(defun %on-tool-result (name result stream)
  "Display a tool result notification (truncated)."
  (let* ((s (format nil "~a" result))
         (preview (if (> (length s) 120) (concatenate 'string (subseq s 0 120) "…") s)))
    (print-system-notice (format nil "✓ ~a → ~a" name preview) stream)))

;;; ── Chat round-trip via clawmacs agent loop ──────────────────────────────────

(defun do-chat (session user-input out-stream)
  "Send USER-INPUT via clawmacs run-agent (with tool support + streaming)."
  ;; Print the [AI] prefix then stream tokens inline
  (print-assistant-start out-stream)

  (handler-case
      (let ((clawmacs/loop:*on-stream-delta*
              (lambda (delta) (print-token delta out-stream)))
            (clawmacs/loop:*on-tool-call*
              (lambda (name args)
                (print-assistant-end out-stream)
                (%on-tool-call name args out-stream)))
            (clawmacs/loop:*on-tool-result*
              (lambda (name result)
                (%on-tool-result name result out-stream)
                (print-assistant-start out-stream))))
        (let ((opts (clawmacs/loop:make-loop-options :max-turns 10 :stream t)))
          (clawmacs/loop:run-agent session user-input :options opts)))
    (clawmacs/conditions:agent-loop-error (e)
      (print-assistant-end out-stream)
      (print-error-notice (format nil "Agent loop error: ~a" e) out-stream)
      nil)
    (cl-llm:llm-error (e)
      (print-assistant-end out-stream)
      (print-error-notice (format nil "LLM error: ~a" e) out-stream)
      nil)
    (error (e)
      (print-assistant-end out-stream)
      (print-error-notice (format nil "Error: ~a" e) out-stream)
      nil))

  (print-assistant-end out-stream))

;;; ── Input reader ─────────────────────────────────────────────────────────────

(defun read-input ()
  "Read a line from *standard-input*. Returns NIL on EOF."
  (handler-case
      (read-line *standard-input* nil nil)
    (end-of-file () nil)))

;;; ── Main loop ────────────────────────────────────────────────────────────────

(defun chat-loop (session app)
  "Run the main interactive chat loop until quit or EOF."
  (let ((stream (app-stream app)))
    (loop while (app-running-p app)
          do
          (print-prompt stream)
          (let ((input (read-input)))
            ;; EOF → clean exit
            (when (null input)
              (print-system-notice "EOF — exiting." stream)
              (app-stop app)
              (loop-finish))
            (let ((trimmed (string-trim " " input)))
              ;; Skip blank lines
              (unless (string= trimmed "")
                (cond
                  ;; Slash command
                  ((command-p trimmed)
                   (handle-command trimmed stream))
                  ;; Normal chat
                  (t
                   (do-chat session trimmed stream)))))))))

;;; ── Entry point ──────────────────────────────────────────────────────────────

(defun run-tui (&key (base-url *default-base-url*)
                     api-key
                     (model    *default-model*)
                     system-prompt
                     (stream   *standard-output*))
  "Start the TUI chat interface.

BASE-URL      — LLM API endpoint root (default: OpenRouter).
API-KEY       — API key (NIL → auto-load from clawmacs config).
MODEL         — model name string.
SYSTEM-PROMPT — optional system prompt string.
STREAM        — output stream (default: *standard-output*)."
  (let* ((effective-key (%effective-api-key api-key))
         (client  (make-client :base-url base-url
                               :api-key  effective-key
                               :model    model))
         (registry (clawmacs/builtins:make-builtin-registry))
         (agent   (clawmacs/agent:make-agent
                   :name          "cl-tui"
                   :client        client
                   :model         model
                   :system-prompt system-prompt
                   :tool-registry registry))
         (session (clawmacs/session:make-session :agent agent))
         (app     (make-app :client        client
                            :model         model
                            :system-prompt system-prompt
                            :stream        stream)))
    (setf *app* app)
    (print-header model system-prompt stream)
    (unwind-protect
         (chat-loop session app)
      (setf *app* nil)
      (terpri stream)
      (force-output stream)))
  (values))

;;; Alias
(defun run (&rest args)
  "Alias for RUN-TUI."
  (apply #'run-tui args))
