;;;; t/packages.lisp — Test packages for clambda-core
;;;; Updated in Layer 8: added clambda-core/tests/cron and clambda-core/tests/remote-api

(defpackage #:clambda-core/tests
  (:use #:cl #:clambda)
  (:export #:run-smoke-test))

(defpackage #:clambda-core/tests/telegram
  (:use #:cl #:parachute)
  ;; Import public API symbols
  (:import-from #:clambda/telegram
                #:telegram-channel
                #:make-telegram-channel
                #:telegram-channel-token
                #:telegram-channel-allowed-users
                #:telegram-channel-polling-interval
                #:telegram-channel-running
                #:telegram-channel-last-update-id
                #:telegram-api-url
                #:allowed-user-p
                #:process-update)
  ;; Internal helpers accessed via :: for white-box testing
  ;; (clambda/telegram::%extract-message-fields ...)
  ;; (clambda/telegram::%plist->ht ...)
  )

(defpackage #:clambda-core/tests/browser
  (:use #:cl #:parachute)
  (:import-from #:clambda/browser
                #:*browser-headless*
                #:*browser-playwright-path*
                #:*browser-bridge-script*
                #:browser-running-p
                #:browser-launch
                #:browser-close
                #:browser-navigate
                #:browser-snapshot
                #:browser-screenshot
                #:browser-click
                #:browser-type
                #:browser-evaluate
                #:register-browser-tools
                #:make-browser-registry))

(defpackage #:clambda-core/tests/irc
  (:use #:cl #:parachute)
  ;; Public API
  (:import-from #:clambda/irc
                #:parse-irc-line
                #:irc-build-line
                #:prefix-nick
                #:irc-connection
                #:make-irc-connection
                #:irc-server #:irc-port #:irc-tls-p
                #:irc-nick #:irc-realname #:irc-channels
                #:irc-allowed-users #:irc-trigger-prefix
                #:irc-running-p #:irc-connected-p
                #:irc-flood-queue #:irc-flood-lock #:irc-flood-cvar
                #:*irc-send-interval*)
  ;; Internal helpers for white-box testing
  ;; clambda/irc::%strip-cr, clambda/irc::%extract-message-body, etc.
  )

;;; ── Layer 8a: Cron scheduler tests ──────────────────────────────────────────

(defpackage #:clambda-core/tests/cron
  (:use #:cl #:parachute)
  (:import-from #:clambda/cron
                #:scheduled-task
                #:make-scheduled-task
                #:task-name #:task-kind #:task-interval #:task-fire-at
                #:task-active-p #:task-description
                #:task-last-run #:task-last-error #:task-run-count
                #:schedule-task #:schedule-once
                #:cancel-task #:find-task #:list-tasks #:clear-tasks
                #:task-info #:describe-tasks
                #:*cron-sleep-interval*
                #:*task-registry*))

;;; ── Layer 8b: Remote Management API tests ────────────────────────────────────

(defpackage #:clambda-core/tests/remote-api
  (:use #:cl #:parachute)
  (:import-from #:clambda/http-server
                #:*api-token*
                #:check-auth
                #:*default-port*
                #:*http-sessions*
                #:http-session-get
                #:http-session-create
                #:http-session-delete
                #:list-http-sessions
                #:*server-start-time*
                #:uptime-seconds)
  (:import-from #:clambda/cron
                #:schedule-task #:cancel-task #:find-task
                #:list-tasks #:clear-tasks #:task-info
                #:*cron-sleep-interval*))
