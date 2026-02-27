;;;; t/live-telegram-irc-test.lisp
;;;; Live integration smoke test for Telegram + IRC wiring.

(load (merge-pathnames "~/quicklisp/setup.lisp"))
(asdf:load-system :clawmacs-core)

(defun env (name)
  (uiop:getenv name))

(defun required-env-present-p ()
  (and (env "CLAWMACS_TELEGRAM_TOKEN")
       (env "CLAWMACS_LM_BASE_URL")
       (env "CLAWMACS_LM_MODEL")))

(defun run-live-test ()
  (if (not (required-env-present-p))
      (format t "~&[live-test] SKIP: set CLAWMACS_TELEGRAM_TOKEN, CLAWMACS_LM_BASE_URL, CLAWMACS_LM_MODEL.~%")
      (let* ((base-url (env "CLAWMACS_LM_BASE_URL"))
             (model (env "CLAWMACS_LM_MODEL"))
             (token (env "CLAWMACS_TELEGRAM_TOKEN"))
             (client (cl-llm:make-client :base-url base-url :api-key "lm-studio" :model model))
             (registry (clawmacs/builtins:make-builtin-registry))
             (agent (clawmacs/agent:make-agent :name "live-test" :client client :tool-registry registry))
             (session (clawmacs/session:make-session :agent agent)))
        (format t "~&[live-test] Registering Telegram + IRC channels...~%")
        (clawmacs/config:register-channel :telegram :token token)
        (clawmacs/config:register-channel :irc
                                          :server "irc.nogroup.group"
                                          :port 6697
                                          :tls t
                                          :nick "chryso"
                                          :channels '("#bots"))
        (clawmacs/telegram:start-telegram)
        (clawmacs/irc:start-irc)
        (unwind-protect
             (let ((reply (clawmacs/loop:run-agent session "Reply with exactly: live-test-ok")))
               (if (and reply (search "live-test-ok" (string-downcase reply)))
                   (format t "~&[live-test] PASS: agent replied (~a chars).~%" (length reply))
                   (error "[live-test] FAIL: unexpected agent response: ~s" reply)))
          (ignore-errors (clawmacs/telegram:stop-telegram))
          (ignore-errors (clawmacs/irc:stop-irc))))))

(run-live-test)
