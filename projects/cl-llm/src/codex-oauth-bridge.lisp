;;;; src/codex-oauth-bridge.lisp — Runtime bridge for :codex-oauth

(in-package #:cl-llm/codex-oauth-bridge)

(defvar *codex-oauth-fallback-enabled* nil
  "When true, :codex-oauth runtime falls back to Claude CLI if Node OAuth bridge fails.")

(defvar *codex-oauth-last-transport* :uninitialized
  "Last transport path used by codex-oauth bridge.
One of: :helper, :fallback, :error, :uninitialized.")

(defvar *codex-oauth-last-transport-error* nil
  "String description of last codex-oauth bridge transport error (or NIL).")

(defvar *codex-oauth-node-helper*
  (merge-pathnames "node/codex_oauth_helper.mjs"
                   (asdf:system-source-directory :cl-llm))
  "Path to Node helper that executes openai-codex OAuth runtime via @mariozechner/pi-ai.")

(defun %messages->bridge-payload (messages system-prompt max-tokens)
  (let ((arr (make-array 0 :adjustable t :fill-pointer 0)))
    (dolist (m messages)
      (let ((role (string-downcase (symbol-name (cl-llm/protocol:message-role m))))
            (content (or (cl-llm/protocol:message-content m) "")))
        (vector-push-extend
         (alexandria:plist-hash-table
          (list "role" role
                "content" content)
          :test 'equal)
         arr)))
    (alexandria:plist-hash-table
     (remove nil
             (list "messages" arr
                   "system" (or system-prompt "")
                   "maxTokens" max-tokens)
             :key #'null)
     :test 'equal)))

(defun %payload-input-stream (payload)
  "Return a fresh character input stream for PAYLOAD JSON.

Important: UIOP:RUN-PROGRAM treats a raw string :INPUT as a pathname designator,
not stdin content. We must pass a stream to avoid accidental pathname coercion
(e.g. JSON like {\"nil\":false} being interpreted as a relative file path)."
  (make-string-input-stream (com.inuoe.jzon:stringify payload)))

(defun %resolve-node-helper-path ()
  (let ((helper (etypecase *codex-oauth-node-helper*
                  (pathname (namestring *codex-oauth-node-helper*))
                  (string *codex-oauth-node-helper*))))
    (unless (probe-file helper)
      (error "Codex OAuth helper not found: ~A" helper))
    helper))

(defun %run-node-helper (payload)
  (let ((helper (%resolve-node-helper-path)))
    (multiple-value-bind (out err code)
        (uiop:run-program (list "node" helper)
                          :input (%payload-input-stream payload)
                          :output :string
                          :error-output :string
                          :ignore-error-status t)
      (declare (ignore err))
      (when (or (null out) (string= (string-trim '(#\Space #\Tab #\Newline) out) ""))
        (error "Codex OAuth helper returned empty output (exit ~A)." code))
      (let ((parsed (com.inuoe.jzon:parse out)))
        (unless (gethash "ok" parsed)
          (error "Codex OAuth helper failed: ~A" (or (gethash "error" parsed) out)))
        parsed))))

(defun %helper-response->completion (parsed model)
  (let ((text (or (gethash "text" parsed) ""))
        (resolved-model (or (gethash "model" parsed) model "gpt-5.3-codex")))
    (cl-llm/protocol::make-completion-response
     :id (format nil "codex-oauth-~A" (get-universal-time))
     :model resolved-model
     :choices (list (cl-llm/protocol::make-choice
                     :message (cl-llm/protocol:assistant-message text)
                     :finish-reason "stop"))
     :usage nil)))

(defun %prepend-warning-to-response (response warning)
  (let* ((choice (first (cl-llm/protocol:response-choices response)))
         (msg (and choice (cl-llm/protocol:choice-message choice)))
         (text (or (and msg (cl-llm/protocol:message-content msg)) ""))
         (merged (format nil "⚠️ ~A~%~%~A" warning text)))
    (when msg
      (setf (cl-llm/protocol:message-content msg) merged))
    response))

(defun codex-oauth-bridge-chat (messages &key model system-prompt max-tokens)
  "Primary runtime transport for :CODEX-OAUTH.

Primary path: Node helper using @mariozechner/pi-ai openai-codex OAuth runtime.
Secondary fallback (optional): Claude CLI with explicit warning."
  (handler-case
      (let ((response (%helper-response->completion
                       (%run-node-helper (%messages->bridge-payload messages system-prompt max-tokens))
                       model)))
        (setf *codex-oauth-last-transport* :helper
              *codex-oauth-last-transport-error* nil)
        response)
    (error (e)
      (let ((err-text (princ-to-string e)))
        (setf *codex-oauth-last-transport-error* err-text)
        (if (not *codex-oauth-fallback-enabled*)
            (progn
              (setf *codex-oauth-last-transport* :error)
              (error "Codex OAuth runtime failed (~A). Runtime fallback is disabled for safety in this deployment." err-text))
            (let* ((warning (format nil
                                    "Codex OAuth primary runtime failed (~A). Using Claude CLI fallback for this response. Re-run /codex_login + /codex_link and retry."
                                    err-text))
                   (fallback (cl-llm/claude-cli:claude-cli-chat messages
                                                                 :model cl-llm/claude-cli:*claude-cli-default-model*
                                                                 :system-prompt system-prompt
                                                                 :max-tokens max-tokens)))
              (setf *codex-oauth-last-transport* :fallback)
              (%prepend-warning-to-response fallback warning)))))))

(defun codex-oauth-bridge-chat-stream (messages callback &key model system-prompt max-tokens)
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
