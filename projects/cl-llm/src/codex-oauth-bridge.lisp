;;;; src/codex-oauth-bridge.lisp — Runtime bridge for :codex-oauth
;;;;
;;;; IMPORTANT:
;;;; - Does NOT call https://api.openai.com/v1/chat/completions
;;;; - Primary path: codex CLI transport (subscription-compatible)
;;;; - Interim fallback: Claude CLI with explicit warning in assistant text

(in-package #:cl-llm/codex-oauth-bridge)

(defvar *codex-oauth-fallback-enabled* t
  "When true, :codex-oauth runtime falls back to Claude CLI if Codex bridge fails.")

(defun %prepend-warning-to-response (response warning)
  (let* ((choice (first (cl-llm/protocol:response-choices response)))
         (msg (and choice (cl-llm/protocol:choice-message choice)))
         (text (or (and msg (cl-llm/protocol:message-content msg)) ""))
         (merged (format nil "⚠️ ~A~%~%~A" warning text)))
    (when msg
      (setf (cl-llm/protocol:message-content msg) merged))
    response))

(defun codex-oauth-bridge-chat (messages &key model system-prompt max-tokens)
  "Runtime transport for :CODEX-OAUTH.

Attempts Codex subscription-compatible transport via CODEX CLI first.
If unavailable and *CODEX-OAUTH-FALLBACK-ENABLED* is true, falls back to
Claude CLI and prepends an explicit warning to the assistant response."
  (handler-case
      (cl-llm/codex-cli:codex-cli-chat messages
                                       :model model
                                       :system-prompt system-prompt
                                       :max-tokens max-tokens)
    (error (e)
      (if (not *codex-oauth-fallback-enabled*)
          (error "Codex OAuth bridge failed: ~A" e)
          (let* ((warning (format nil
                                  "Codex OAuth subscription transport unavailable (~A). Using Claude CLI fallback for this response. To restore Codex, run /codex_login + /codex_link, ensure `codex login` completed on host, then retry."
                                  e))
                 (fallback (cl-llm/claude-cli:claude-cli-chat messages
                                                               :model model
                                                               :system-prompt system-prompt
                                                               :max-tokens max-tokens)))
            (%prepend-warning-to-response fallback warning))))))

(defun codex-oauth-bridge-chat-stream (messages callback &key model system-prompt max-tokens)
  "Streaming variant for :CODEX-OAUTH bridge.

Currently bridges through non-streaming call then emits once."
  (let* ((response (codex-oauth-bridge-chat messages
                                            :model model
                                            :system-prompt system-prompt
                                            :max-tokens max-tokens))
         (choice (first (cl-llm/protocol:response-choices response)))
         (msg (and choice (cl-llm/protocol:choice-message choice)))
         (text (or (and msg (cl-llm/protocol:message-content msg)) "")))
    (when callback
      (funcall callback text))
    text))
