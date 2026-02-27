;;;; src/packages.lisp — Package definitions for clawmacs-core

;;; ── Conditions ───────────────────────────────────────────────────────────────

(defpackage #:clawmacs/conditions
  (:use #:cl)
  (:export
   ;; Base
   #:clawmacs-error
   ;; Agent errors
   #:agent-error
   #:agent-error-agent
   ;; Session errors
   #:session-error
   #:session-error-session
   ;; Tool errors
   #:tool-not-found
   #:tool-not-found-name
   #:tool-execution-error
   #:tool-execution-error-tool-name
   #:tool-execution-error-cause
   #:tool-execution-error-input      ; new: the failing args
   ;; Loop control
   #:agent-loop-error
   #:agent-turn-error                ; new: LLM-level turn failure
   #:agent-turn-error-session
   #:agent-turn-error-cause
   ;; Budget
   #:budget-exceeded
   #:budget-exceeded-kind
   #:budget-exceeded-limit
   #:budget-exceeded-current
   ;; Restart name symbols (use the same symbol across packages)
   #:retry-with-fixed-input          ; new: retry tool with LLM-repaired args
   #:skip-tool-call
   #:retry-tool-call
   #:abort-agent-loop))

;;; ── Agent ────────────────────────────────────────────────────────────────────

(defpackage #:clawmacs/agent
  (:use #:cl)
  (:import-from #:clawmacs/conditions
                #:clawmacs-error #:agent-error)
  (:export
   ;; CLOS class
   #:agent
   #:make-agent
   ;; Accessors
   #:agent-name
   #:agent-role
   #:agent-model
   #:agent-workspace
   #:agent-workspace-path
   #:default-agent-workspace
   #:agent-system-prompt
   #:agent-client
   #:agent-tool-registry
   ;; Operations
   #:agent-effective-system-prompt
   #:agent-with-tools))

;;; ── Session ──────────────────────────────────────────────────────────────────

(defpackage #:clawmacs/session
  (:use #:cl)
  (:import-from #:clawmacs/agent #:agent)
  (:import-from #:clawmacs/conditions
                #:session-error)
  (:export
   ;; CLOS class
   #:session
   #:make-session
   ;; Accessors
   #:session-id
   #:session-agent
   #:session-messages
   #:session-metadata
   #:session-created-at
   ;; Operations
   #:session-add-message
   #:session-clear-messages
   #:session-message-count
   #:session-last-message
   ;; Token tracking
   #:session-total-tokens
   ;; Persistence (basic)
   #:save-session
   #:load-session))

;;; ── Tools ────────────────────────────────────────────────────────────────────

(defpackage #:clawmacs/tools
  (:use #:cl)
  (:import-from #:cl-llm/protocol
                #:tool-definition #:make-tool-definition
                #:tool-call #:tool-call-id
                #:tool-call-function-name
                #:tool-call-function-arguments)
  (:import-from #:clawmacs/conditions
                #:tool-not-found #:tool-execution-error
                #:retry-with-fixed-input
                #:skip-tool-call #:retry-tool-call)
  (:export
   ;; Registry
   #:tool-registry
   #:make-tool-registry
   #:register-tool!
   #:find-tool
   #:list-tools
   ;; Macro
   #:define-tool
   ;; Schema helpers
   #:schema-plist->ht
   ;; Dispatch
   #:dispatch-tool-call
   #:tool-definitions-for-llm
   ;; Registry operations
   #:copy-tools-to-registry
   ;; Result
   #:tool-result
   #:tool-result-ok
   #:tool-result-error
   #:tool-result-value
   #:format-tool-result))

;;; ── Built-in tools ───────────────────────────────────────────────────────────

(defpackage #:clawmacs/builtins
  (:use #:cl)
  (:import-from #:clawmacs/tools
                #:tool-registry #:define-tool)
  (:export
   #:register-builtin-tools
   #:make-builtin-registry))

;;; ── Structured logging ───────────────────────────────────────────────────────

(defpackage #:clawmacs/logging
  (:use #:cl)
  (:export
   ;; Configuration
   #:*log-file*
   #:*log-enabled*
   ;; Log functions
   #:log-event
   #:log-llm-request
   #:log-tool-call
   #:log-tool-result
   #:log-error-event
   ;; Setup macro
   #:with-logging))

;;; ── Memory system ────────────────────────────────────────────────────────────

(defpackage #:clawmacs/memory
  (:use #:cl)
  (:export
   ;; Data types
   #:memory-entry
   #:memory-entry-name
   #:memory-entry-path
   #:memory-entry-content
   ;; Workspace memory
   #:workspace-memory
   #:workspace-memory-entries
   #:workspace-memory-path
   ;; Operations
   #:load-workspace-memory
   #:search-memory
   #:memory-search
   #:memory-context-string))

;;; ── Agent loop ───────────────────────────────────────────────────────────────

(defpackage #:clawmacs/loop
  (:use #:cl)
  (:import-from #:clawmacs/logging
                #:log-llm-request #:log-tool-call #:log-tool-result
                #:log-error-event)
  (:import-from #:clawmacs/agent
                #:agent
                #:agent-name
                #:agent-client
                #:agent-model
                #:agent-tool-registry
                #:agent-effective-system-prompt)
  (:import-from #:clawmacs/session
                #:session
                #:session-agent
                #:session-messages
                #:session-add-message)
  (:import-from #:clawmacs/tools
                #:tool-registry
                #:tool-definitions-for-llm
                #:dispatch-tool-call
                #:format-tool-result)
  (:import-from #:clawmacs/conditions
                #:agent-loop-error #:agent-turn-error #:abort-agent-loop
                #:budget-exceeded
                #:tool-execution-error
                #:tool-execution-error-tool-name
                #:tool-execution-error-cause
                #:tool-execution-error-input
                #:retry-with-fixed-input
                #:skip-tool-call)
  (:export
   ;; Main entry points
   #:agent-turn
   #:run-agent
   ;; Callbacks/hooks
   #:*on-tool-call*
   #:*on-tool-result*
   #:*on-llm-response*
   #:*on-stream-delta*
   ;; Loop options
   #:loop-options
   #:make-loop-options
   #:loop-options-max-turns
   #:loop-options-max-tokens
   #:loop-options-stream
   #:loop-options-verbose))

;;; ── Agent Registry ───────────────────────────────────────────────────────────

(defpackage #:clawmacs/registry
  (:use #:cl)
  (:import-from #:clawmacs/agent
                #:agent #:make-agent
                #:agent-name #:agent-role #:agent-model
                #:agent-workspace-path #:agent-system-prompt
                #:agent-client #:agent-tool-registry)
  (:export
   ;; Global registry
   #:*agent-registry*
   ;; Operations
   #:register-agent
   #:find-agent
   #:list-agents
   #:unregister-agent
   #:clear-registry
   ;; Declarative definition
   #:define-agent
   ;; Agent spec
   #:agent-spec
   #:agent-spec-p                     ; struct predicate
   #:make-agent-spec
   #:agent-spec-name
   #:agent-spec-model
   #:agent-spec-system-prompt
   #:agent-spec-tools
   #:agent-spec-role
   #:agent-spec-workspace
   #:agent-spec-max-turns             ; new: per-agent turn limit
   #:agent-spec-client
   ;; Instantiation
   #:instantiate-agent-spec))

;;; ── Sub-agent Spawning ───────────────────────────────────────────────────────

(defpackage #:clawmacs/subagents
  (:use #:cl)
  (:import-from #:clawmacs/agent
                #:agent #:make-agent
                #:agent-name #:agent-client #:agent-model
                #:agent-tool-registry)
  (:import-from #:clawmacs/session
                #:session #:make-session
                #:session-id)
  (:import-from #:clawmacs/loop
                #:run-agent #:make-loop-options)
  (:import-from #:clawmacs/registry
                #:agent-spec #:instantiate-agent-spec)
  (:export
   ;; Handle struct
   #:subagent-handle
   #:subagent-handle-thread
   #:subagent-handle-session
   #:subagent-handle-status
   #:subagent-handle-result
   #:subagent-handle-error
   ;; Operations
   #:spawn-subagent
   #:subagent-wait
   #:subagent-status
   #:subagent-kill))

;;; ── Channel Protocol ─────────────────────────────────────────────────────────

(defpackage #:clawmacs/channels
  (:use #:cl)
  (:export
   ;; Abstract class
   #:channel
   ;; Generic protocol
   #:channel-send
   #:channel-receive
   #:channel-poll
   #:channel-close
   #:channel-open-p
   ;; REPL channel
   #:repl-channel
   #:make-repl-channel
   #:repl-channel-input
   #:repl-channel-output
   ;; Queue channel
   #:queue-channel
   #:make-queue-channel
   #:queue-channel-queue
   #:queue-channel-lock
   #:queue-channel-cvar
   ;; Conditions
   #:channel-closed-error
   #:channel-timeout-error))

;;; ── Cron / Scheduled Task Scheduler (Layer 8a) ──────────────────────────────

(defpackage #:clawmacs/cron
  (:use #:cl)
  (:export
   ;; Task struct + constructor
   #:scheduled-task
   #:make-scheduled-task
   ;; Accessors (conc-name task-)
   #:task-name
   #:task-kind
   #:task-interval
   #:task-fire-at
   #:task-function
   #:task-thread
   #:task-active-p
   #:task-description
   #:task-last-run
   #:task-last-error
   #:task-run-count
   ;; Public API
   #:schedule-task
   #:schedule-once
   #:cancel-task
   #:find-task
   #:list-tasks
   #:clear-tasks
   ;; Introspection
   #:task-info
   #:describe-tasks
   ;; Configuration
   #:*cron-sleep-interval*
   ;; Registry (for inspection)
   #:*task-registry*))

;;; ── HTTP API Server ──────────────────────────────────────────────────────────

(defpackage #:clawmacs/http-server
  (:use #:cl)
  (:import-from #:clawmacs/logging
                #:log-event #:log-error-event #:*log-file* #:*log-enabled*)
  (:import-from #:clawmacs/session
                #:session #:make-session #:session-id #:session-messages
                #:session-total-tokens)
  (:import-from #:clawmacs/agent
                #:agent #:agent-name #:agent-role #:agent-model)
  (:import-from #:clawmacs/registry
                #:*agent-registry* #:find-agent #:list-agents
                #:instantiate-agent-spec #:agent-spec
                #:agent-spec-name #:agent-spec-role #:agent-spec-model)
  (:import-from #:clawmacs/loop
                #:run-agent #:make-loop-options)
  (:import-from #:clawmacs/channels
                #:queue-channel #:make-queue-channel
                #:channel-send #:channel-receive #:channel-poll)
  (:import-from #:clawmacs/cron
                #:list-tasks #:task-info)
  (:import-from #:cl-llm/protocol
                #:message-role #:message-content)
  (:export
   ;; Server lifecycle
   #:*default-port*
   #:start-server
   #:stop-server
   #:server-running-p
   #:restart-server
   ;; Active server instance
   #:*server*
   #:*server-start-time*
   #:uptime-seconds
   ;; Auth
   #:*api-token*
   #:check-auth
   ;; Session store
   #:*http-sessions*
   #:http-session-get
   #:http-session-create
   #:http-session-delete
   #:list-http-sessions))

;;; ── Config system ────────────────────────────────────────────────────────────
;;;
;;; Emacs-style configuration: *clawmacs-home*, load-user-config, defoption,
;;; hook system, register-channel generic.

(defpackage #:clawmacs/config
  (:use #:cl)
  (:import-from #:clawmacs/tools
                #:tool-registry #:make-tool-registry
                #:register-tool!)
  (:export
   ;; Config directory
   #:*clawmacs-home*
   #:clawmacs-home
   ;; Loading
   #:load-user-config
   #:user-config-loaded-p
   ;; Options system
   #:defoption
   #:*option-registry*
   #:describe-options
   ;; Hook system
   #:add-hook
   #:remove-hook
   #:run-hook
   #:run-hook-with-args
   ;; Standard hook variables
   #:*after-init-hook*
   #:*before-agent-turn-hook*
   #:*after-tool-call-hook*
   #:*channel-message-hook*
   ;; Channel registration
   #:register-channel
   #:*registered-channels*
   ;; User-facing tool definition (keyword-style, registers to *user-tool-registry*)
   #:define-user-tool
   #:register-user-tool!
   #:merge-user-tools!
   #:*user-tool-registry*
   ;; Built-in options (defoption-defined variables)
   #:*default-model*
   #:*default-max-turns*
   #:*default-stream*
   #:*log-level*
   #:*startup-message*
   #:*fallback-models*
   #:*heartbeat-interval*))

;;; ── Telegram Channel ─────────────────────────────────────────────────────────
;;;
;;; Telegram Bot API channel — long-polling, background thread, per-chat sessions.
;;; Specialises REGISTER-CHANNEL :TELEGRAM from clawmacs/config.
;;; Loaded after config so the register-channel generic is already defined.

(defpackage #:clawmacs/telegram
  (:use #:cl)
  ;; Only import what we need unqualified; everything else is package-qualified.
  (:import-from #:clawmacs/config
                #:register-channel
                #:*registered-channels*)
  ;; Import *on-stream-delta* for the streaming callback binding.
  (:import-from #:clawmacs/loop
                #:*on-stream-delta*)
  (:export
   ;; Channel struct
   #:telegram-channel
   #:make-telegram-channel
   #:telegram-channel-token
   #:telegram-channel-allowed-users
   #:telegram-channel-polling-interval
   #:telegram-channel-running
   #:telegram-channel-thread
   #:telegram-channel-last-update-id
   #:telegram-channel-sessions
   ;; Global state / options
   #:*telegram-channel*
   #:*telegram-llm-base-url*
   #:*telegram-llm-api-key*
   #:*telegram-system-prompt*
   #:*telegram-poll-timeout*
   ;; Streaming options (Layer 9a)
   #:*telegram-streaming*
   #:*telegram-stream-debounce-ms*
   ;; Bot API helpers
   #:telegram-api-url
   #:telegram-get-me
   #:telegram-get-updates
   #:telegram-send-message
   #:telegram-edit-message
   ;; Logic helpers (exposed for unit testing without HTTP)
   #:allowed-user-p
   #:find-or-create-session
   #:process-update
   ;; Lifecycle
   #:start-telegram
   #:stop-telegram
   #:telegram-running-p
   ;; Multi-channel startup
   #:start-all-channels))

;;; ── IRC Client Channel ───────────────────────────────────────────────────────
;;;
;;; Raw IRC protocol over TCP/TLS (usocket + cl+ssl). No external IRC library.
;;; register-channel :irc specialisation. Loaded after clawmacs/config so it can
;;; specialize register-channel.

(defpackage #:clawmacs/irc
  (:use #:cl)
  (:import-from #:clawmacs/config
                #:register-channel
                #:*default-model*)
  (:import-from #:clawmacs/agent
                #:agent #:make-agent)
  (:import-from #:clawmacs/session
                #:session #:make-session)
  (:import-from #:clawmacs/loop
                #:run-agent #:make-loop-options)
  (:import-from #:clawmacs/registry
                #:find-agent #:instantiate-agent-spec #:agent-spec)
  (:import-from #:clawmacs/builtins
                #:make-builtin-registry)
  (:export
   ;; Global variables
   #:*irc-connection*
   #:*irc-send-interval*
   #:*irc-default-system-prompt*
   ;; Struct + constructor
   #:irc-connection
   #:make-irc-connection
   ;; Config accessors
   #:irc-server
   #:irc-port
   #:irc-tls-p
   #:irc-nick
   #:irc-realname
   #:irc-channels
   #:irc-nickserv-password
   #:irc-allowed-users
   #:irc-trigger-prefix
   ;; Per-channel allowlist accessors (Layer 9b)
   #:irc-channel-policies
   #:irc-dm-allowed-users
   ;; Runtime accessors
   #:irc-socket
   #:irc-stream
   #:irc-reader-thread
   #:irc-flood-thread
   #:irc-flood-queue
   #:irc-flood-lock
   #:irc-flood-cvar
   #:irc-running-p
   #:irc-reconnect-delay
   #:irc-agent
   #:irc-sessions
   #:irc-sessions-lock
   ;; Predicates
   #:irc-connected-p
   ;; Lifecycle
   #:start-irc
   #:stop-irc
   ;; High-level commands
   #:irc-send-privmsg
   #:irc-join
   #:irc-part
   ;; Protocol helpers (exported for testing)
   #:parse-irc-line
   #:irc-build-line
   #:prefix-nick))

;;; ── Browser control (Layer 7) ────────────────────────────────────────────────

(defpackage #:clawmacs/browser
  (:use #:cl)
  (:import-from #:clawmacs/config
                #:defoption #:register-channel)
  (:import-from #:clawmacs/tools
                #:register-tool! #:schema-plist->ht #:make-tool-registry)
  (:import-from #:bordeaux-threads
                #:make-lock #:with-lock-held)
  (:export
   ;; Config options
   #:*browser-headless*
   #:*browser-playwright-path*
   #:*browser-bridge-script*
   ;; Lifecycle
   #:browser-launch
   #:browser-close
   #:browser-running-p
   ;; Navigation and content
   #:browser-navigate
   #:browser-snapshot
   #:browser-screenshot
   ;; Interaction
   #:browser-click
   #:browser-type
   #:browser-evaluate
   ;; Tool registration
   #:register-browser-tools
   #:make-browser-registry))

;;; ── SWANK/SLIME Server (Layer 9 / Lisp Superpowers P0) ──────────────────────
;;;
;;; Built-in SWANK server for live SLIME/Sly inspection, hot-reload, debugging.
;;; Loaded after clawmacs/browser. Requires the "swank" ASDF system.

(defpackage #:clawmacs/swank
  (:use #:cl)
  (:import-from #:clawmacs/config
                #:defoption)
  (:export
   ;; Config option
   #:*swank-port*
   ;; Server lifecycle
   #:start-swank
   #:stop-swank
   #:swank-running-p))

;;; ── Image Save/Restore (Layer 9 / Lisp Superpowers P1) ──────────────────────
;;;
;;; Save the entire running Clawmacs system as a SBCL core file / executable.
;;; Restore it instantly — zero dependency resolution, all config baked in.
;;; Genera-style: (save-clawmacs-image) → (./clawmacs-image)

(defpackage #:clawmacs/image
  (:use #:cl)
  (:export
   ;; Entry point for saved images
   #:clawmacs-main
   ;; Save function
   #:save-clawmacs-image))

;;; ── Top-level convenience package ────────────────────────────────────────────

(defpackage #:clawmacs
  (:use #:cl)
  ;; Re-export key symbols
  (:import-from #:clawmacs/agent
                #:agent #:make-agent
                #:agent-name #:agent-role #:agent-model
                #:agent-workspace-path #:agent-system-prompt
                #:agent-client #:agent-tool-registry)
  (:import-from #:clawmacs/session
                #:session #:make-session
                #:session-id #:session-agent #:session-messages
                #:session-add-message #:session-clear-messages
                #:session-message-count #:session-total-tokens
                #:save-session #:load-session)
  (:import-from #:clawmacs/tools
                #:tool-registry #:make-tool-registry
                #:register-tool! #:find-tool #:list-tools
                #:define-tool #:dispatch-tool-call
                #:tool-definitions-for-llm
                #:copy-tools-to-registry
                #:tool-result #:tool-result-ok #:tool-result-error
                #:tool-result-value #:format-tool-result)
  (:import-from #:clawmacs/builtins
                #:register-builtin-tools #:make-builtin-registry)
  (:import-from #:clawmacs/loop
                #:agent-turn #:run-agent
                #:*on-tool-call* #:*on-tool-result* #:*on-llm-response*
                #:*on-stream-delta*
                #:loop-options #:make-loop-options
                #:loop-options-max-turns #:loop-options-max-tokens
                #:loop-options-stream #:loop-options-verbose)
  (:import-from #:clawmacs/logging
                #:*log-file* #:*log-enabled*
                #:log-event #:log-llm-request #:log-tool-call
                #:log-tool-result #:log-error-event
                #:with-logging)
  (:import-from #:clawmacs/memory
                #:memory-entry #:memory-entry-name
                #:memory-entry-path #:memory-entry-content
                #:workspace-memory #:workspace-memory-entries
                #:workspace-memory-path
                #:load-workspace-memory #:search-memory
                #:memory-context-string)
  (:import-from #:clawmacs/conditions
                #:clawmacs-error #:agent-error #:session-error
                #:tool-not-found #:tool-execution-error
                #:agent-loop-error
                #:budget-exceeded
                #:budget-exceeded-kind #:budget-exceeded-limit
                #:budget-exceeded-current)
  (:import-from #:clawmacs/registry
                #:*agent-registry*
                #:register-agent #:find-agent #:list-agents
                #:unregister-agent #:clear-registry
                #:define-agent
                #:agent-spec #:agent-spec-p #:make-agent-spec
                #:agent-spec-name #:agent-spec-model
                #:agent-spec-system-prompt #:agent-spec-tools
                #:agent-spec-role #:agent-spec-max-turns #:agent-spec-client
                #:instantiate-agent-spec)
  (:import-from #:clawmacs/subagents
                #:subagent-handle
                #:subagent-handle-thread #:subagent-handle-session
                #:subagent-handle-status #:subagent-handle-result
                #:subagent-handle-error
                #:spawn-subagent #:subagent-wait
                #:subagent-status #:subagent-kill)
  (:import-from #:clawmacs/channels
                #:channel #:channel-send #:channel-receive
                #:channel-poll #:channel-close #:channel-open-p
                #:repl-channel #:make-repl-channel
                #:queue-channel #:make-queue-channel
                #:channel-closed-error #:channel-timeout-error)
  (:import-from #:clawmacs/cron
                #:scheduled-task #:make-scheduled-task
                #:task-name #:task-kind #:task-interval #:task-fire-at
                #:task-function #:task-thread #:task-active-p
                #:task-description #:task-last-run #:task-last-error
                #:task-run-count
                #:schedule-task #:schedule-once
                #:cancel-task #:find-task #:list-tasks #:clear-tasks
                #:task-info #:describe-tasks
                #:*cron-sleep-interval* #:*task-registry*)
  (:import-from #:clawmacs/http-server
                #:*default-port* #:start-server #:stop-server
                #:server-running-p #:restart-server
                #:*server* #:*server-start-time* #:uptime-seconds
                #:*api-token* #:check-auth
                #:*http-sessions*
                #:http-session-get #:http-session-create
                #:http-session-delete #:list-http-sessions)
  (:import-from #:clawmacs/config
                #:*clawmacs-home* #:clawmacs-home
                #:load-user-config #:user-config-loaded-p
                #:defoption #:*option-registry* #:describe-options
                #:add-hook #:remove-hook #:run-hook #:run-hook-with-args
                #:*after-init-hook* #:*before-agent-turn-hook*
                #:*after-tool-call-hook* #:*channel-message-hook*
                #:register-channel #:*registered-channels*
                #:define-user-tool #:register-user-tool!
                #:merge-user-tools! #:*user-tool-registry*
                #:*default-model* #:*default-max-turns*
                #:*default-stream* #:*log-level* #:*startup-message*)
  (:import-from #:clawmacs/telegram
                #:telegram-channel #:make-telegram-channel
                #:telegram-channel-token #:telegram-channel-allowed-users
                #:telegram-channel-polling-interval
                #:telegram-channel-running #:telegram-channel-thread
                #:*telegram-channel*
                #:*telegram-llm-base-url* #:*telegram-llm-api-key*
                #:*telegram-system-prompt* #:*telegram-poll-timeout*
                #:*telegram-streaming* #:*telegram-stream-debounce-ms*
                #:telegram-api-url #:telegram-get-me
                #:telegram-get-updates #:telegram-send-message
                #:telegram-edit-message
                #:allowed-user-p
                #:start-telegram #:stop-telegram #:telegram-running-p
                #:start-all-channels)
  (:import-from #:clawmacs/irc
                #:*irc-connection*
                #:irc-connection #:make-irc-connection
                #:irc-server #:irc-port #:irc-tls-p
                #:irc-nick #:irc-realname #:irc-channels
                #:irc-nickserv-password #:irc-allowed-users
                #:irc-trigger-prefix #:irc-running-p
                #:irc-connected-p
                #:irc-channel-policies #:irc-dm-allowed-users
                #:start-irc #:stop-irc
                #:irc-send-privmsg #:irc-join #:irc-part
                #:parse-irc-line #:irc-build-line #:prefix-nick
                #:*irc-send-interval* #:*irc-default-system-prompt*)
  ;; Layer 7: Browser control
  (:import-from #:clawmacs/browser
                #:*browser-headless*
                #:*browser-playwright-path*
                #:*browser-bridge-script*
                #:browser-launch #:browser-close #:browser-running-p
                #:browser-navigate #:browser-snapshot #:browser-screenshot
                #:browser-click #:browser-type #:browser-evaluate
                #:register-browser-tools #:make-browser-registry)
  ;; Lisp Superpowers: SWANK server
  (:import-from #:clawmacs/swank
                #:*swank-port*
                #:start-swank #:stop-swank #:swank-running-p)
  ;; Lisp Superpowers: Image save/restore
  (:import-from #:clawmacs/image
                #:clawmacs-main #:save-clawmacs-image)
  (:export
   ;; Agent
   #:agent #:make-agent
   #:agent-name #:agent-role #:agent-model
   #:agent-workspace-path #:agent-system-prompt
   #:agent-client #:agent-tool-registry
   ;; Session
   #:session #:make-session
   #:session-id #:session-agent #:session-messages
   #:session-add-message #:session-clear-messages
   #:session-message-count #:session-total-tokens
   #:save-session #:load-session
   ;; Tools
   #:tool-registry #:make-tool-registry
   #:register-tool! #:find-tool #:list-tools
   #:define-tool #:dispatch-tool-call
   #:tool-definitions-for-llm
   #:copy-tools-to-registry
   #:tool-result #:tool-result-ok #:tool-result-error
   #:tool-result-value #:format-tool-result
   ;; Builtins
   #:register-builtin-tools #:make-builtin-registry
   ;; Loop
   #:agent-turn #:run-agent
   #:*on-tool-call* #:*on-tool-result* #:*on-llm-response*
   #:*on-stream-delta*
   #:loop-options #:make-loop-options
   #:loop-options-max-turns #:loop-options-max-tokens
   #:loop-options-stream #:loop-options-verbose
   ;; Logging
   #:*log-file* #:*log-enabled*
   #:log-event #:log-llm-request #:log-tool-call
   #:log-tool-result #:log-error-event
   #:with-logging
   ;; Memory
   #:memory-entry #:memory-entry-name
   #:memory-entry-path #:memory-entry-content
   #:workspace-memory #:workspace-memory-entries
   #:workspace-memory-path
   #:load-workspace-memory #:search-memory
   #:memory-context-string
   ;; Conditions
   #:clawmacs-error #:agent-error #:session-error
   #:tool-not-found
   #:tool-execution-error
   #:tool-execution-error-tool-name #:tool-execution-error-cause
   #:tool-execution-error-input
   #:agent-loop-error
   #:agent-turn-error
   #:agent-turn-error-session #:agent-turn-error-cause
   #:budget-exceeded
   #:budget-exceeded-kind #:budget-exceeded-limit
   #:budget-exceeded-current
   ;; Restart names
   #:retry-with-fixed-input #:skip-tool-call
   #:retry-tool-call #:abort-agent-loop
   ;; Registry
   #:*agent-registry*
   #:register-agent #:find-agent #:list-agents
   #:unregister-agent #:clear-registry
   #:define-agent
   #:agent-spec #:agent-spec-p #:make-agent-spec
   #:agent-spec-name #:agent-spec-model
   #:agent-spec-system-prompt #:agent-spec-tools
   #:agent-spec-role #:agent-spec-max-turns #:agent-spec-client
   #:instantiate-agent-spec
   ;; Sub-agents
   #:subagent-handle
   #:subagent-handle-thread #:subagent-handle-session
   #:subagent-handle-status #:subagent-handle-result
   #:subagent-handle-error
   #:spawn-subagent #:subagent-wait
   #:subagent-status #:subagent-kill
   ;; Channels
   #:channel #:channel-send #:channel-receive
   #:channel-poll #:channel-close #:channel-open-p
   #:repl-channel #:make-repl-channel
   #:queue-channel #:make-queue-channel
   #:channel-closed-error #:channel-timeout-error
   ;; Cron scheduler (Layer 8a)
   #:scheduled-task #:make-scheduled-task
   #:task-name #:task-kind #:task-interval #:task-fire-at
   #:task-function #:task-thread #:task-active-p
   #:task-description #:task-last-run #:task-last-error
   #:task-run-count
   #:schedule-task #:schedule-once
   #:cancel-task #:find-task #:list-tasks #:clear-tasks
   #:task-info #:describe-tasks
   #:*cron-sleep-interval* #:*task-registry*
   ;; HTTP server (Layer 8b)
   #:*default-port* #:start-server #:stop-server
   #:server-running-p #:restart-server
   #:*server* #:*server-start-time* #:uptime-seconds
   #:*api-token* #:check-auth
   #:*http-sessions*
   #:http-session-get #:http-session-create
   #:http-session-delete #:list-http-sessions
   ;; Config system
   #:*clawmacs-home* #:clawmacs-home
   #:load-user-config #:user-config-loaded-p
   #:defoption #:*option-registry* #:describe-options
   #:add-hook #:remove-hook #:run-hook #:run-hook-with-args
   #:*after-init-hook* #:*before-agent-turn-hook*
   #:*after-tool-call-hook* #:*channel-message-hook*
   #:register-channel #:*registered-channels*
   #:define-user-tool #:register-user-tool!
   #:merge-user-tools! #:*user-tool-registry*
   #:*default-model* #:*default-max-turns*
   #:*default-stream* #:*log-level* #:*startup-message*
   ;; Telegram channel
   #:telegram-channel #:make-telegram-channel
   #:telegram-channel-token #:telegram-channel-allowed-users
   #:telegram-channel-polling-interval
   #:telegram-channel-running #:telegram-channel-thread
   #:*telegram-channel*
   #:*telegram-llm-base-url* #:*telegram-llm-api-key*
   #:*telegram-system-prompt* #:*telegram-poll-timeout*
   #:*telegram-streaming* #:*telegram-stream-debounce-ms*
   #:telegram-api-url #:telegram-get-me
   #:telegram-get-updates #:telegram-send-message
   #:telegram-edit-message
   #:allowed-user-p
   #:start-telegram #:stop-telegram #:telegram-running-p
   #:start-all-channels
   ;; IRC channel (Layer 6c)
   #:*irc-connection*
   #:irc-connection #:make-irc-connection
   #:irc-server #:irc-port #:irc-tls-p
   #:irc-nick #:irc-realname #:irc-channels
   #:irc-nickserv-password #:irc-allowed-users
   #:irc-trigger-prefix #:irc-running-p
   #:irc-connected-p
   #:irc-channel-policies #:irc-dm-allowed-users
   #:start-irc #:stop-irc
   #:irc-send-privmsg #:irc-join #:irc-part
   #:parse-irc-line #:irc-build-line #:prefix-nick
   #:*irc-send-interval* #:*irc-default-system-prompt*
   ;; Browser control (Layer 7)
   #:*browser-headless*
   #:*browser-playwright-path*
   #:*browser-bridge-script*
   #:browser-launch #:browser-close #:browser-running-p
   #:browser-navigate #:browser-snapshot #:browser-screenshot
   #:browser-click #:browser-type #:browser-evaluate
   #:register-browser-tools #:make-browser-registry
   ;; Lisp Superpowers: SWANK/SLIME server (P0)
   #:*swank-port*
   #:start-swank #:stop-swank #:swank-running-p
   ;; Lisp Superpowers: Image save/restore (P1)
   #:clawmacs-main #:save-clawmacs-image))

;;; ── User init package (for init.lisp) ────────────────────────────────────────
;;;
;;; This package is the default *package* when init.lisp is loaded.
;;; It gives users access to all public Clawmacs API without qualification.
;;; Full CL is available — no sandboxing.

(defpackage #:clawmacs-user
  (:use #:cl)
  ;; Config API — the most important things for init.lisp
  (:import-from #:clawmacs/config
                #:defoption
                #:add-hook #:remove-hook #:run-hook #:run-hook-with-args
                #:*after-init-hook* #:*before-agent-turn-hook*
                #:*after-tool-call-hook* #:*channel-message-hook*
                #:register-channel #:*registered-channels*
                #:define-user-tool #:register-user-tool!
                #:merge-user-tools! #:*user-tool-registry*
                #:*default-model* #:*default-max-turns*
                #:*default-stream* #:*log-level* #:*startup-message*
                #:describe-options #:*option-registry*
                #:*clawmacs-home* #:clawmacs-home
                #:load-user-config)
  ;; Core clawmacs API — so users can make-agent etc. from init.lisp
  (:import-from #:clawmacs/tools
                #:tool-registry #:make-tool-registry
                #:register-tool! #:find-tool #:list-tools
                #:define-tool)
  (:import-from #:clawmacs/agent
                #:agent #:make-agent
                #:agent-name #:agent-system-prompt
                #:agent-client #:agent-tool-registry)
  (:import-from #:clawmacs/session
                #:session #:make-session)
  (:import-from #:clawmacs/registry
                #:define-agent #:register-agent #:find-agent
                #:unregister-agent #:agent-spec-p
                #:agent-spec #:make-agent-spec
                #:agent-spec-name #:agent-spec-model
                #:agent-spec-tools #:agent-spec-max-turns
                #:instantiate-agent-spec)
  (:import-from #:cl-llm
                #:make-client)
  (:import-from #:clawmacs/telegram
                #:start-telegram #:stop-telegram
                #:telegram-running-p #:start-all-channels
                #:*telegram-channel*
                #:*telegram-llm-base-url* #:*telegram-llm-api-key*
                #:*telegram-system-prompt*
                #:*telegram-streaming* #:*telegram-stream-debounce-ms*)
  (:import-from #:clawmacs/irc
                #:*irc-connection*
                #:irc-connected-p
                #:irc-channel-policies #:irc-dm-allowed-users
                #:start-irc #:stop-irc
                #:irc-send-privmsg #:irc-join #:irc-part
                #:*irc-send-interval* #:*irc-default-system-prompt*)
  (:import-from #:clawmacs/browser
                #:*browser-headless*
                #:*browser-playwright-path*
                #:*browser-bridge-script*
                #:browser-launch #:browser-close #:browser-running-p
                #:browser-navigate #:browser-snapshot #:browser-screenshot
                #:browser-click #:browser-type #:browser-evaluate
                #:register-browser-tools #:make-browser-registry)
  (:import-from #:clawmacs/cron
                #:schedule-task #:schedule-once
                #:cancel-task #:find-task #:list-tasks #:clear-tasks
                #:task-info #:describe-tasks
                #:*cron-sleep-interval*)
  (:import-from #:clawmacs/http-server
                #:*api-token* #:start-server #:stop-server
                #:server-running-p #:restart-server
                #:*default-port*)
  ;; Lisp Superpowers — available from init.lisp
  (:import-from #:clawmacs/swank
                #:*swank-port* #:start-swank #:stop-swank #:swank-running-p)
  (:import-from #:clawmacs/image
                #:clawmacs-main #:save-clawmacs-image)
  (:export
   ;; Re-export everything imported so users can (use-package :clawmacs-user)
   ;; from a downstream package if desired.
   #:defoption
   #:add-hook #:remove-hook #:run-hook #:run-hook-with-args
   #:*after-init-hook* #:*before-agent-turn-hook*
   #:*after-tool-call-hook* #:*channel-message-hook*
   #:register-channel #:*registered-channels*
   #:define-user-tool #:register-user-tool!
   #:merge-user-tools! #:*user-tool-registry*
   #:*default-model* #:*default-max-turns*
   #:*default-stream* #:*log-level* #:*startup-message*
   #:describe-options #:*option-registry*
   #:*clawmacs-home* #:clawmacs-home
   #:tool-registry #:make-tool-registry
   #:register-tool! #:find-tool #:list-tools
   #:define-tool
   #:agent #:make-agent
   #:agent-name #:agent-system-prompt
   #:agent-client #:agent-tool-registry
   #:session #:make-session
   #:define-agent #:register-agent #:find-agent
   #:unregister-agent #:agent-spec-p
   #:agent-spec #:make-agent-spec
   #:agent-spec-name #:agent-spec-model
   #:agent-spec-tools #:agent-spec-max-turns
   #:instantiate-agent-spec
   #:make-client
   ;; Telegram channel lifecycle (most useful from init.lisp)
   #:start-telegram #:stop-telegram
   #:telegram-running-p #:start-all-channels
   #:*telegram-channel*
   #:*telegram-llm-base-url* #:*telegram-llm-api-key*
   #:*telegram-system-prompt*
   #:*telegram-streaming* #:*telegram-stream-debounce-ms*
   ;; IRC channel lifecycle (most useful from init.lisp)
   #:*irc-connection*
   #:irc-connected-p
   #:irc-channel-policies #:irc-dm-allowed-users
   #:start-irc #:stop-irc
   #:irc-send-privmsg #:irc-join #:irc-part
   #:*irc-send-interval* #:*irc-default-system-prompt*
   ;; Browser control (Layer 7)
   #:*browser-headless*
   #:*browser-playwright-path*
   #:*browser-bridge-script*
   #:browser-launch #:browser-close #:browser-running-p
   #:browser-navigate #:browser-snapshot #:browser-screenshot
   #:browser-click #:browser-type #:browser-evaluate
   #:register-browser-tools #:make-browser-registry
   ;; Cron scheduler (Layer 8a)
   #:schedule-task #:schedule-once
   #:cancel-task #:find-task #:list-tasks #:clear-tasks
   #:task-info #:describe-tasks
   #:*cron-sleep-interval*
   ;; HTTP server management (Layer 8b)
   #:*api-token* #:start-server #:stop-server
   #:server-running-p #:restart-server
   #:*default-port*
   ;; Lisp Superpowers: SWANK/SLIME server
   #:*swank-port* #:start-swank #:stop-swank #:swank-running-p
   ;; Lisp Superpowers: Image save/restore
   #:clawmacs-main #:save-clawmacs-image))
