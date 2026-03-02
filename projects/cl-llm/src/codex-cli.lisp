;;;; src/codex-cli.lisp — Codex CLI backend for cl-llm
;;;;
;;;; Calls the `codex` CLI authenticated via OAuth session.
;;;; This backend is intended for users who ran `codex login`.

(in-package #:cl-llm/codex-cli)

(defvar *codex-cli-path* "codex"
  "Path to the codex CLI binary (or command name on PATH).")

(defvar *codex-cli-default-model* "gpt-5-codex"
  "Default model to use with codex CLI.")

(defvar *codex-auth-mode* :oauth-session
  "Codex CLI auth strategy.

:OAUTH-SESSION (default): discover and use the Codex OAuth session created by
`codex login` (OpenClaw-parity behavior).")

(defun %command-exists-p (cmd)
  "Return T if CMD resolves on PATH."
  (handler-case
      (multiple-value-bind (_out _err code)
          (uiop:run-program (list "sh" "-lc" (format nil "command -v ~A >/dev/null 2>&1" cmd))
                            :ignore-error-status t
                            :output :string
                            :error-output :string)
        (declare (ignore _out _err))
        (zerop code))
    (error () nil)))

(defun %candidate-session-files ()
  "Return plausible Codex OAuth session file paths under ~/.codex/."
  (let* ((home (user-homedir-pathname))
         (codex-dir (merge-pathnames ".codex/" home)))
    (mapcar (lambda (name) (merge-pathnames name codex-dir))
            '("auth.json" "credentials.json" "token.json" "config.json"))))

(defun %existing-session-files ()
  "Return a list of existing Codex auth/session files."
  (remove nil (mapcar (lambda (p) (and (probe-file p) p))
                      (%candidate-session-files))))

(defun codex-auth-status (&key model)
  "Return a plist describing Codex OAuth readiness.

Keys:
  :CODEX-CLI-FOUND      boolean
  :LINKED-SESSION-FOUND boolean
  :ACTIVE-MODEL         string
  :SESSION-FILES        list of path strings
  :AUTH-MODE            keyword
  :REMEDIATION          list of shell commands" 
  (let* ((cli-found (%command-exists-p *codex-cli-path*))
         (session-files (%existing-session-files))
         (session-found (and session-files t))
         (active-model (or model *codex-cli-default-model*))
         (remediation
           (cond
             ((not cli-found)
              (list "Install Codex CLI, then verify with: codex --help"
                    "Link your account with: codex login"))
             ((not session-found)
              (list "Link your account with: codex login"
                    "Verify session with: ls -la ~/.codex"))
             (t
              (list "Session looks present. If requests fail/expire, refresh with: codex login")))))
    (list :codex-cli-found cli-found
          :linked-session-found session-found
          :active-model active-model
          :session-files (mapcar #'namestring session-files)
          :auth-mode *codex-auth-mode*
          :remediation remediation)))

(defun codex-auth-status-string (&key model)
  "Return a one-shot human-readable Codex auth status report string."
  (destructuring-bind (&key codex-cli-found linked-session-found active-model
                            session-files auth-mode remediation &allow-other-keys)
      (codex-auth-status :model model)
    (with-output-to-string (s)
      (format s "Codex auth status~%")
      (format s "- codex CLI: ~A~%" (if codex-cli-found "found" "NOT found"))
      (format s "- linked OAuth session: ~A~%" (if linked-session-found "found" "NOT found"))
      (format s "- auth mode: ~A~%" auth-mode)
      (format s "- active model: ~A~%" active-model)
      (when session-files
        (format s "- session files:~%")
        (dolist (f session-files)
          (format s "  - ~A~%" f)))
      (format s "- remediation:~%")
      (dolist (cmd remediation)
        (format s "  - ~A~%" cmd)))))

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

(defun %ensure-codex-oauth-ready (&key model)
  "Signal actionable error if Codex CLI or linked OAuth session is missing." 
  (destructuring-bind (&key codex-cli-found linked-session-found remediation &allow-other-keys)
      (codex-auth-status :model model)
    (flet ((render-remediation ()
             (with-output-to-string (s)
               (dolist (step remediation)
                 (format s "~%  - ~A" step)))))
      (unless codex-cli-found
        (error "Codex CLI not found on PATH.~%Recovery:~A" (render-remediation)))
      (unless linked-session-found
        (error "Codex OAuth session not found under ~~/.codex/.~%Recovery:~A" (render-remediation))))))

(defun codex-cli-chat (messages &key model system-prompt max-tokens)
  "Send MESSAGES to Codex via codex CLI and return a COMPLETION-RESPONSE."
  (declare (ignore max-tokens))
  (let* ((effective-system (or system-prompt (%messages->system-prompt messages)))
         (prompt (or (%messages->prompt messages) ""))
         (effective-model (or model *codex-cli-default-model*)))
    (%ensure-codex-oauth-ready :model effective-model)
    (let ((args (%build-cli-args prompt :model effective-model :system-prompt effective-system)))
      (multiple-value-bind (output exit-code error-output)
          (%run-cli args)
        (let ((text (%parse-cli-output output exit-code error-output)))
          (%text->completion-response text effective-model))))))

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
