(require :asdf)
(push #P"/home/slime/.openclaw/workspace-gensym/projects/clambda-core/" asdf:*central-registry*)
(push #P"/home/slime/.openclaw/workspace-gensym/projects/cl-llm/" asdf:*central-registry*)

(asdf:load-system :clawmacs-core)

(format t "~&[acceptance] loading user init...~%")
(clawmacs:load-user-config)

(format t "~&[acceptance] booting agent loop smoke...~%")
(let* ((client (cl-llm:make-client
                :base-url "http://192.168.1.189:1234/v1"
                :api-key "lm-studio"
                :model "google/gemma-3-4b"))
       (registry (clawmacs:make-builtin-registry))
       (agent (clawmacs:make-agent
               :name "acceptance-agent"
               :model "google/gemma-3-4b"
               :system-prompt "You are concise. Use tools when needed."
               :client client
               :tool-registry registry))
       (session (clawmacs:make-session :agent agent))
       (tool-calls '()))
  (let ((clawmacs:*on-tool-call*
          (lambda (tool-name tc)
            (declare (ignore tc))
            (push tool-name tool-calls)
            (format t "~&[acceptance] tool call: ~a~%" tool-name))))
    (let ((resp (clawmacs:run-agent
                 session
                 "Run the exec tool once with command: echo CLAWMACS_OK . Then report the output."
                 :options (clawmacs:make-loop-options :max-turns 6 :stream nil))))
      (format t "~&[acceptance] agent response: ~a~%" resp)
      (format t "~&[acceptance] tool-calls: ~s~%" (reverse tool-calls)))))

(format t "~&[acceptance] starting HTTP API...~%")
(clawmacs:start-server :port 7474 :address "127.0.0.1")
(format t "~&[acceptance] server-running-p => ~s~%" (clawmacs:server-running-p))
(clawmacs:stop-server)

(format t "~&[acceptance] starting SWANK...~%")
(let ((port (clawmacs:start-swank :port 4005)))
  (format t "~&[acceptance] swank port => ~s running => ~s~%"
          port (clawmacs:swank-running-p))
  (when (clawmacs:swank-running-p)
    (clawmacs:stop-swank)))

(format t "~&[acceptance] Telegram/IRC channel startup path...~%")
(let ((tg-token (uiop:getenv "CLAWMACS_TELEGRAM_TOKEN"))
      (irc-channel (uiop:getenv "CLAWMACS_IRC_CHANNEL")))
  (if (and tg-token (> (length tg-token) 0))
      (progn
        (clawmacs:register-channel :telegram :token tg-token :streaming nil)
        (clawmacs:start-telegram)
        (sleep 2)
        (format t "~&[acceptance] telegram-running => ~s~%" (clawmacs:telegram-running-p))
        (clawmacs:stop-telegram))
      (format t "~&[acceptance] telegram skipped (CLAWMACS_TELEGRAM_TOKEN not set).~%"))

  (if (and irc-channel (> (length irc-channel) 0))
      (progn
        (clawmacs:register-channel :irc
                                   :server "irc.libera.chat"
                                   :port 6697
                                   :tls t
                                   :nick "clawmacs-bot"
                                   :channels (list irc-channel))
        (clawmacs:start-irc)
        (sleep 3)
        (format t "~&[acceptance] irc-running => ~s~%"
                (and clawmacs::*irc-connection*
                     (clawmacs/irc::irc-running-p clawmacs::*irc-connection*)))
        (clawmacs:stop-irc))
      (format t "~&[acceptance] irc skipped (CLAWMACS_IRC_CHANNEL not set).~%")))

(format t "~&[acceptance] done.~%")
(sb-ext:exit :code 0)
