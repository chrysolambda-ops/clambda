;;;; src/codex-cli.lisp — Codex CLI backend for cl-llm
;;;;
;;;; Calls the `codex` CLI authenticated via OAuth session.
;;;; This backend is intended for users who ran `codex login`.

(in-package #:cl-llm/codex-cli)

(defvar *codex-cli-path* "codex"
  "Path to the codex CLI binary (or command name on PATH).")

(defvar *codex-cli-default-model* "gpt-5-codex"
  "Default model to use with codex CLI.")

(defun %messages->system-prompt (messages)
  "Extract and return the system message content from MESSAGES, or NIL."
  (let ((sys (find :system messages :key #'cl-llm/protocol:message-role)))
    (when sys
      (cl-llm/protocol:message-content sys))))

(defun %messages->prompt (messages)
  "Convert non-system MESSAGES to a conversation string for codex CLI."
  (let ((non-system (remove :system messages :key #'cl-llm/protocol:message-role)))
    (if (= (length non-system) 1)
        (or (cl-llm/protocol:message-content (first non-system)) "")
        (with-output-to-string (s)
          (dolist (msg non-system)
            (let* ((role (cl-llm/protocol:message-role msg))
                   (content (or (cl-llm/protocol:message-content msg) ""))
                   (label (ecase role
                            (:user "User")
                            (:assistant "Assistant")
                            (:tool "Tool"))))
              (format s "~A: ~A~%~%" label content)))))))

(defun %build-cli-args (prompt &key model system-prompt)
  "Build the argument list for invoking codex CLI.

The default invocation is:
  codex exec --json --model MODEL PROMPT [--system SYSTEM-PROMPT]"
  (let ((args (list *codex-cli-path*
                    "exec"
                    "--json"
                    "--model" (or model *codex-cli-default-model*)
                    prompt)))
    (if (and system-prompt (not (string= system-prompt "")))
        (append args (list "--system" system-prompt))
        args)))

(defun %run-cli (args)
  "Run codex CLI with ARGS.
Returns (values output-string exit-code error-string)."
  (handler-case
      (multiple-value-bind (output error-output exit-code)
          (uiop:run-program args
                            :output :string
                            :error-output :string
                            :ignore-error-status t)
        (values output exit-code error-output))
    (error (e)
      (error "Unable to execute codex CLI (~A). Ensure `codex` is installed and on PATH, then run `codex login`." e))))

(defun %parse-json-result (line)
  "Parse one JSON LINE and extract a response text string when present."
  (handler-case
      (let* ((parsed (com.inuoe.jzon:parse line))
             (output-text (gethash "output_text" parsed))
             (result (gethash "result" parsed))
             (choices (gethash "choices" parsed)))
        (cond
          ((and output-text (stringp output-text)) output-text)
          ((and result (stringp result)) result)
          ((and choices (vectorp choices) (> (length choices) 0))
           (let* ((choice (aref choices 0))
                  (message (and (hash-table-p choice) (gethash "message" choice)))
                  (content (and (hash-table-p message) (gethash "content" message))))
             (and content (stringp content) content)))
          (t nil)))
    (error () nil)))

(defun %parse-cli-output (output exit-code error-output)
  "Parse codex CLI output and return response text.
Signals an error with guidance when the OAuth session is missing/expired."
  (when (and (not (zerop exit-code))
             (or (null output) (string= (string-trim '(#\Space #\Newline #\Tab) output) "")))
    (error
     (concatenate
      'string
      "Codex CLI failed (exit " (princ-to-string exit-code) "): " error-output
      "\nIf you are not logged in, run: codex login")))
  (let ((result-text nil))
    (dolist (line (cl-ppcre:split "\\n" (or output "")))
      (let ((trimmed (string-trim '(#\Space #\Newline #\Tab) line)))
        (when (and (> (length trimmed) 0)
                   (char= (char trimmed 0) #\{))
          (let ((parsed-text (%parse-json-result trimmed)))
            (when parsed-text
              (setf result-text parsed-text))))))
    (unless result-text
      (let ((trimmed (string-trim '(#\Space #\Newline #\Tab) (or output ""))))
        (if (> (length trimmed) 0)
            (setf result-text trimmed)
            (error
             (concatenate
              'string
              "Codex CLI returned no result. Error: " (or error-output "")
              "\nTry refreshing your OAuth session: codex login")))))
    result-text))

(defun %text->completion-response (text model)
  "Wrap TEXT string in a COMPLETION-RESPONSE struct."
  (cl-llm/protocol::make-completion-response
   :id (format nil "codex-cli-~A" (get-universal-time))
   :model (or model *codex-cli-default-model*)
   :choices (list (cl-llm/protocol::make-choice
                   :message (cl-llm/protocol:assistant-message text)
                   :finish-reason "stop"))
   :usage nil))

(defun codex-cli-chat (messages &key model system-prompt max-tokens)
  "Send MESSAGES to Codex via codex CLI and return a COMPLETION-RESPONSE."
  (declare (ignore max-tokens))
  (let* ((effective-system (or system-prompt (%messages->system-prompt messages)))
         (prompt (or (%messages->prompt messages) ""))
         (effective-model (or model *codex-cli-default-model*))
         (args (%build-cli-args prompt :model effective-model :system-prompt effective-system)))
    (multiple-value-bind (output exit-code error-output)
        (%run-cli args)
      (let ((text (%parse-cli-output output exit-code error-output)))
        (%text->completion-response text effective-model)))))

(defun codex-cli-chat-stream (messages callback &key model system-prompt max-tokens)
  "Like CODEX-CLI-CHAT but calls CALLBACK once with full text."
  (declare (ignore max-tokens))
  (let* ((response (codex-cli-chat messages :model model :system-prompt system-prompt))
         (choice (first (cl-llm/protocol:response-choices response)))
         (msg (when choice (cl-llm/protocol:choice-message choice)))
         (text (when msg (cl-llm/protocol:message-content msg))))
    (when (and callback text)
      (funcall callback text))
    (or text "")))
