;;;; start-headless.lisp — Headless Clawmacs daemon startup
;;;;
;;;; Loads clawmacs-core, reads init.lisp, starts Telegram channel,
;;;; then sleeps forever until SIGTERM/SIGINT.

(require :asdf)
(pushnew #P"/home/slime/.openclaw/workspace-gensym/projects/clambda-core/" asdf:*central-registry* :test #'equal)
(pushnew #P"/home/slime/.openclaw/workspace-gensym/projects/cl-llm/" asdf:*central-registry* :test #'equal)

(let ((ql-setup (or (probe-file #P"/home/slime/.quicklisp/setup.lisp")
                    (probe-file #P"/home/slime/quicklisp/setup.lisp"))))
  (when ql-setup (load ql-setup)))

(asdf:load-system :clawmacs-core)

(format t "~&[headless] Clawmacs loaded. Reading init.lisp...~%")
(clawmacs/config:load-user-config)
(format t "~&[headless] init.lisp loaded.~%")

;; Start Telegram channel
(format t "~&[headless] Starting Telegram channel...~%")
(clawmacs/telegram:start-all-channels)
(format t "~&[headless] Telegram running: ~s~%" (clawmacs/telegram:telegram-running-p))

;; IRC is already started by start-all-channels above — don't double-start
;; (Double-starting causes SIGSEGV: closing SSL stream while reader thread is
;; blocked in SSL_read is undefined behavior in OpenSSL)
(format t "~&[headless] IRC running: ~S~%" (clawmacs/irc:irc-connected-p))

;; Also start SWANK for live debugging
(ignore-errors
 (clawmacs/swank:start-swank :port 4006)
 (format t "~&[headless] SWANK started on port 4006.~%"))

(format t "~&[headless] Daemon running. Ctrl-C or SIGTERM to stop.~%")

;; Sleep forever, waking every 30s to check channels are still alive
(loop
  (sleep 30)
  (unless (clawmacs/telegram:telegram-running-p)
    (format t "~&[headless] Telegram stopped unexpectedly — restarting...~%")
    (ignore-errors (clawmacs/telegram:start-telegram))))
