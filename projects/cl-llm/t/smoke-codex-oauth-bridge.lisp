;;;; Smoke test: :codex-oauth uses bridge transport (not api.openai chat/completions)

(require 'asdf)
(asdf:load-system :cl-llm)

(defun fail (fmt &rest args)
  (format *error-output* "FAIL: ~?~%" fmt args)
  (uiop:quit 1))

(let* ((client (cl-llm:make-codex-oauth-client :model "gpt-5-codex"))
       (base (cl-llm:client-base-url client)))
  (when (search "api.openai.com" base :test #'char-equal)
    (fail "unexpected base-url ~A" base))
  (format t "OK base-url: ~A~%" base)

  (let* ((called nil)
         (orig-codex (symbol-function 'cl-llm/codex-cli:codex-cli-chat))
         (orig-claude (symbol-function 'cl-llm/claude-cli:claude-cli-chat)))
    (unwind-protect
         (progn
           (setf (symbol-function 'cl-llm/codex-cli:codex-cli-chat)
                 (lambda (&rest _)
                   (declare (ignore _))
                   (setf called :codex)
                   (cl-llm/protocol::make-completion-response
                    :id "smoke-codex"
                    :model "gpt-5-codex"
                    :choices (list (cl-llm/protocol::make-choice
                                    :message (cl-llm:assistant-message "bridge ok")
                                    :finish-reason "stop"))
                    :usage nil)))
           (setf (symbol-function 'cl-llm/claude-cli:claude-cli-chat)
                 (lambda (&rest _)
                   (declare (ignore _))
                   (setf called :claude)
                   (cl-llm/protocol::make-completion-response
                    :id "smoke-claude"
                    :model "claude-opus-4-6"
                    :choices (list (cl-llm/protocol::make-choice
                                    :message (cl-llm:assistant-message "fallback")
                                    :finish-reason "stop"))
                    :usage nil)))

           (let ((resp (cl-llm:chat client (list (cl-llm:user-message "hi")))))
             (declare (ignore resp))
             (unless (eq called :codex)
               (fail "bridge dispatch did not call codex transport; called=~A" called))))
      (setf (symbol-function 'cl-llm/codex-cli:codex-cli-chat) orig-codex
            (symbol-function 'cl-llm/claude-cli:claude-cli-chat) orig-claude)))

  (format t "OK dispatch: :codex-oauth -> codex bridge transport~%"))

(format t "PASS smoke-codex-oauth-bridge~%")
(uiop:quit 0)
