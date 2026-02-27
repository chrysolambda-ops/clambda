;;;; t/packages.lisp — Test packages for clawmacs-core
;;;; Updated in Layer 9: added superpowers tests (condition recovery, SWANK, image, define-agent)

(defpackage #:clawmacs-core/tests
  (:use #:cl #:clawmacs)
  (:export #:run-smoke-test))

(defpackage #:clawmacs-core/tests/telegram
  (:use #:cl #:parachute)
  ;; Import public API symbols
  (:import-from #:clawmacs/telegram
                #:telegram-channel
                #:make-telegram-channel
                #:telegram-channel-token
                #:telegram-channel-allowed-users
                #:telegram-channel-polling-interval
                #:telegram-channel-running
                #:telegram-channel-last-update-id
                #:telegram-api-url
                #:allowed-user-p
                #:process-update
                ;; Streaming (Layer 9a)
                #:*telegram-streaming*
                #:*telegram-stream-debounce-ms*
                #:telegram-edit-message)
  ;; Internal helpers accessed via :: for white-box testing
  ;; (clawmacs/telegram::%extract-message-fields ...)
  ;; (clawmacs/telegram::%plist->ht ...)
  ;; (clawmacs/telegram::%split-telegram-text ...)
  ;; (clawmacs/telegram::%current-time-ms ...)
  )

(defpackage #:clawmacs-core/tests/browser
  (:use #:cl #:parachute)
  (:import-from #:clawmacs/browser
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

(defpackage #:clawmacs-core/tests/irc
  (:use #:cl #:parachute)
  ;; Public API
  (:import-from #:clawmacs/irc
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
                #:*irc-send-interval*
                ;; Per-channel allowlist (Layer 9b)
                #:irc-channel-policies
                #:irc-dm-allowed-users)
  ;; Internal helpers for white-box testing
  ;; clawmacs/irc::%strip-cr, clawmacs/irc::%extract-message-body, etc.
  ;; clawmacs/irc::%effective-channel-allowed, clawmacs/irc::%effective-dm-allowed
  )

;;; ── Layer 8a: Cron scheduler tests ──────────────────────────────────────────

(defpackage #:clawmacs-core/tests/cron
  (:use #:cl #:parachute)
  (:import-from #:clawmacs/cron
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

(defpackage #:clawmacs-core/tests/remote-api
  (:use #:cl #:parachute)
  (:import-from #:clawmacs/http-server
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
  (:import-from #:clawmacs/cron
                #:schedule-task #:cancel-task #:find-task
                #:list-tasks #:clear-tasks #:task-info
                #:*cron-sleep-interval*))

;;; ── Layer 9: Lisp Superpowers tests ──────────────────────────────────────────

(defpackage #:clawmacs-core/tests/superpowers
  (:use #:cl #:parachute)
  ;; Condition system
  (:import-from #:clawmacs/conditions
                #:tool-execution-error
                #:tool-execution-error-tool-name
                #:tool-execution-error-cause
                #:tool-execution-error-input
                #:agent-turn-error
                #:agent-turn-error-session
                #:agent-turn-error-cause
                #:retry-with-fixed-input
                #:skip-tool-call)
  ;; Tools (for dispatch-tool-call testing)
  (:import-from #:clawmacs/tools
                #:make-tool-registry
                #:register-tool!
                #:dispatch-tool-call
                #:tool-result-ok
                #:tool-result-error
                #:format-tool-result
                #:copy-tools-to-registry)
  ;; Registry + define-agent
  (:import-from #:clawmacs/registry
                #:define-agent
                #:find-agent
                #:register-agent
                #:unregister-agent
                #:clear-registry
                #:agent-spec
                #:agent-spec-p
                #:make-agent-spec
                #:agent-spec-name
                #:agent-spec-model
                #:agent-spec-system-prompt
                #:agent-spec-tools
                #:agent-spec-max-turns
                #:instantiate-agent-spec)
  ;; SWANK
  (:import-from #:clawmacs/swank
                #:*swank-port*
                #:swank-running-p
                #:start-swank
                #:stop-swank)
  ;; Image
  (:import-from #:clawmacs/image
                #:clawmacs-main
                #:save-clawmacs-image)
  ;; Protocol (for making mock tool calls)
  (:import-from #:cl-llm/protocol
                #:make-tool-call
                #:tool-call-id
                #:tool-call-function-name
                #:tool-call-function-arguments))
