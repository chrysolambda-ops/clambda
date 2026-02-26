;;;; src/packages.lisp — Package definitions for clambda-core

;;; ── Conditions ───────────────────────────────────────────────────────────────

(defpackage #:clambda/conditions
  (:use #:cl)
  (:export
   ;; Base
   #:clambda-error
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
   ;; Loop control
   #:agent-loop-error
   ;; Restarts
   #:skip-tool-call
   #:retry-tool-call
   #:abort-agent-loop))

;;; ── Agent ────────────────────────────────────────────────────────────────────

(defpackage #:clambda/agent
  (:use #:cl)
  (:import-from #:clambda/conditions
                #:clambda-error #:agent-error)
  (:export
   ;; CLOS class
   #:agent
   #:make-agent
   ;; Accessors
   #:agent-name
   #:agent-role
   #:agent-model
   #:agent-workspace-path
   #:agent-system-prompt
   #:agent-client
   #:agent-tool-registry
   ;; Operations
   #:agent-effective-system-prompt
   #:agent-with-tools))

;;; ── Session ──────────────────────────────────────────────────────────────────

(defpackage #:clambda/session
  (:use #:cl)
  (:import-from #:clambda/agent #:agent)
  (:import-from #:clambda/conditions
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
   ;; Persistence (basic)
   #:save-session
   #:load-session))

;;; ── Tools ────────────────────────────────────────────────────────────────────

(defpackage #:clambda/tools
  (:use #:cl)
  (:import-from #:cl-llm/protocol
                #:tool-definition #:make-tool-definition
                #:tool-call #:tool-call-id
                #:tool-call-function-name
                #:tool-call-function-arguments)
  (:import-from #:clambda/conditions
                #:tool-not-found #:tool-execution-error
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
   ;; Dispatch
   #:dispatch-tool-call
   #:tool-definitions-for-llm
   ;; Result
   #:tool-result
   #:tool-result-ok
   #:tool-result-error
   #:tool-result-value
   #:format-tool-result))

;;; ── Built-in tools ───────────────────────────────────────────────────────────

(defpackage #:clambda/builtins
  (:use #:cl)
  (:import-from #:clambda/tools
                #:tool-registry #:define-tool)
  (:export
   #:register-builtin-tools
   #:make-builtin-registry))

;;; ── Structured logging ───────────────────────────────────────────────────────

(defpackage #:clambda/logging
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

(defpackage #:clambda/memory
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
   #:memory-context-string))

;;; ── Agent loop ───────────────────────────────────────────────────────────────

(defpackage #:clambda/loop
  (:use #:cl)
  (:import-from #:clambda/agent
                #:agent
                #:agent-name
                #:agent-client
                #:agent-model
                #:agent-tool-registry
                #:agent-effective-system-prompt)
  (:import-from #:clambda/session
                #:session
                #:session-agent
                #:session-messages
                #:session-add-message)
  (:import-from #:clambda/tools
                #:tool-registry
                #:tool-definitions-for-llm
                #:dispatch-tool-call
                #:format-tool-result)
  (:import-from #:clambda/conditions
                #:agent-loop-error #:abort-agent-loop)
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
   #:loop-options-stream
   #:loop-options-verbose))

;;; ── Top-level convenience package ────────────────────────────────────────────

(defpackage #:clambda
  (:use #:cl)
  ;; Re-export key symbols
  (:import-from #:clambda/agent
                #:agent #:make-agent
                #:agent-name #:agent-role #:agent-model
                #:agent-workspace-path #:agent-system-prompt
                #:agent-client #:agent-tool-registry)
  (:import-from #:clambda/session
                #:session #:make-session
                #:session-id #:session-agent #:session-messages
                #:session-add-message #:session-clear-messages
                #:session-message-count
                #:save-session #:load-session)
  (:import-from #:clambda/tools
                #:tool-registry #:make-tool-registry
                #:register-tool! #:find-tool #:list-tools
                #:define-tool #:dispatch-tool-call
                #:tool-definitions-for-llm
                #:tool-result #:tool-result-ok #:tool-result-error
                #:tool-result-value #:format-tool-result)
  (:import-from #:clambda/builtins
                #:register-builtin-tools #:make-builtin-registry)
  (:import-from #:clambda/loop
                #:agent-turn #:run-agent
                #:*on-tool-call* #:*on-tool-result* #:*on-llm-response*
                #:*on-stream-delta*
                #:loop-options #:make-loop-options)
  (:import-from #:clambda/logging
                #:*log-file* #:*log-enabled*
                #:log-event #:log-llm-request #:log-tool-call
                #:log-tool-result #:log-error-event
                #:with-logging)
  (:import-from #:clambda/memory
                #:memory-entry #:memory-entry-name
                #:memory-entry-path #:memory-entry-content
                #:workspace-memory #:workspace-memory-entries
                #:workspace-memory-path
                #:load-workspace-memory #:search-memory
                #:memory-context-string)
  (:import-from #:clambda/conditions
                #:clambda-error #:agent-error #:session-error
                #:tool-not-found #:tool-execution-error
                #:agent-loop-error)
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
   #:session-message-count
   #:save-session #:load-session
   ;; Tools
   #:tool-registry #:make-tool-registry
   #:register-tool! #:find-tool #:list-tools
   #:define-tool #:dispatch-tool-call
   #:tool-definitions-for-llm
   #:tool-result #:tool-result-ok #:tool-result-error
   #:tool-result-value #:format-tool-result
   ;; Builtins
   #:register-builtin-tools #:make-builtin-registry
   ;; Loop
   #:agent-turn #:run-agent
   #:*on-tool-call* #:*on-tool-result* #:*on-llm-response*
   #:*on-stream-delta*
   #:loop-options #:make-loop-options
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
   #:clambda-error #:agent-error #:session-error
   #:tool-not-found #:tool-execution-error
   #:agent-loop-error))
