;;;; src/http-server.lisp — Clawmacs Remote Management API (Layer 8b)
;;;;
;;;; A hardened REST API over the agent loop using Hunchentoot.
;;;;
;;;; BACKWARD-COMPATIBLE ENDPOINTS (unchanged from Layer 5):
;;;;   POST /chat              — send message, get response (synchronous JSON)
;;;;   POST /chat/stream       — streaming response via SSE
;;;;   GET  /agents            — list registered agents
;;;;   GET  /sessions          — list active sessions
;;;;
;;;; MANAGEMENT API (Layer 8b additions):
;;;;   GET  /health                          — health check, uptime
;;;;   GET  /api/system                      — system info (uptime, version, log file)
;;;;   GET  /api/agents                      — list registered agents (JSON)
;;;;   POST /api/agents/:name/start          — create a session for agent :name
;;;;   POST /api/agents/:name/message        — send message, get response
;;;;   GET  /api/agents/:name/history        — get session message history
;;;;   DELETE /api/agents/:name/stop         — terminate agent session
;;;;   GET  /api/sessions                    — list sessions
;;;;   GET  /api/channels                    — list registered channels
;;;;   GET  /api/tasks                       — list cron scheduled tasks
;;;;
;;;; AUTH:
;;;;   If *API-TOKEN* is non-NIL, every request must carry:
;;;;     Authorization: Bearer <token>
;;;;   Requests without the correct token get HTTP 401.
;;;;   Set *API-TOKEN* in init.lisp via (setf clawmacs/http-server:*api-token* "secret")
;;;;   or use the defoption *api-token* from config:
;;;;     (setf *api-token* "my-secret-token")

(in-package #:clawmacs/http-server)

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 1. Globals
;;;; ─────────────────────────────────────────────────────────────────────────────

(defvar *default-port* 7474
  "Default port for the Clawmacs HTTP API server.")

(defvar *server* nil
  "The running HUNCHENTOOT:EASY-ACCEPTOR instance, or NIL.")

(defvar *http-sessions* (make-hash-table :test 'equal)
  "Active sessions keyed by session-id string.")

(defvar *sessions-lock* (bt:make-lock "http-sessions-lock")
  "Protects *HTTP-SESSIONS* for concurrent access.")

(defvar *api-token* nil
  "Bearer token required for all API requests.
NIL (default) disables authentication entirely.
Set to a non-empty string to enable token auth:
  (setf clawmacs/http-server:*api-token* \"my-secret\")
Or in init.lisp:
  (setf *api-token* \"my-secret\")")

(defvar *server-start-time* nil
  "Universal-time at which start-server was most recently called.")

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 2. Session helpers
;;;; ─────────────────────────────────────────────────────────────────────────────

(defun http-session-get (session-id)
  "Return the SESSION for SESSION-ID, or NIL."
  (bt:with-lock-held (*sessions-lock*)
    (gethash session-id *http-sessions*)))

(defun http-session-create (session-id agent)
  "Create and register a new SESSION for SESSION-ID with AGENT.
Returns the new session."
  (let ((sess (clawmacs/session:make-session :id session-id :agent agent)))
    (bt:with-lock-held (*sessions-lock*)
      (setf (gethash session-id *http-sessions*) sess))
    sess))

(defun http-session-delete (session-id)
  "Remove session SESSION-ID from *HTTP-SESSIONS*. Returns T if it existed."
  (bt:with-lock-held (*sessions-lock*)
    (if (gethash session-id *http-sessions*)
        (progn (remhash session-id *http-sessions*) t)
        nil)))

(defun list-http-sessions ()
  "Return a list of all active SESSION objects."
  (bt:with-lock-held (*sessions-lock*)
    (let ((result '()))
      (maphash (lambda (k v) (declare (ignore k)) (push v result))
               *http-sessions*)
      (nreverse result))))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 3. JSON helpers
;;;; ─────────────────────────────────────────────────────────────────────────────

(defun parse-json-body ()
  "Parse the request body as JSON, returning a hash-table or NIL."
  (let ((body (hunchentoot:raw-post-data :force-text t)))
    (when (and body (> (length body) 0))
      (handler-case (com.inuoe.jzon:parse body)
        (error (c)
          (declare (ignore c))
          nil)))))

(defun json-response (data &optional (status 200))
  "Set hunchentoot response to JSON content type and return DATA as JSON string."
  (setf (hunchentoot:content-type*) "application/json; charset=utf-8"
        (hunchentoot:return-code*) status)
  (com.inuoe.jzon:stringify data))

(defun json-error (message &optional (status 400))
  "Return a JSON error response."
  (let ((ht (make-hash-table :test 'equal)))
    (setf (gethash "error" ht) message)
    (json-response ht status)))

(defun ht-get (ht key)
  "Get KEY from jzon-parsed hash-table HT."
  (gethash key ht))

(defun make-ht (&rest plist)
  "Convenience: build a hash-table from alternating key/value pairs (strings)."
  (let ((ht (make-hash-table :test 'equal)))
    (loop for (k v) on plist by #'cddr
          do (setf (gethash k ht) v))
    ht))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 4. Authentication middleware
;;;; ─────────────────────────────────────────────────────────────────────────────

(defun check-auth ()
  "Validate Bearer token if *API-TOKEN* is configured.
Returns NIL if auth passes (or is not required).
Returns a JSON error string (HTTP 401) if auth fails — call (return-from handler ...) on that.

Usage inside any handler:
  (let ((auth-fail (check-auth)))
    (when auth-fail (return-from my-handler auth-fail))
    ...)"
  (when (and *api-token* (not (string= *api-token* "")))
    (let* ((auth-header (hunchentoot:header-in* "authorization"))
           (expected    (concatenate 'string "Bearer " *api-token*)))
      (unless (and auth-header (string= auth-header expected))
        (setf (hunchentoot:header-out "WWW-Authenticate") "Bearer realm=\"clawmacs\"")
        (json-error "Unauthorized — provide Authorization: Bearer <token>" 401)))))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 5. Agent resolution
;;;; ─────────────────────────────────────────────────────────────────────────────

(defun resolve-agent (agent-name)
  "Find an agent by name (string) in the registry, instantiate if needed.
Returns an AGENT object or NIL."
  (let ((entry (clawmacs/registry:find-agent agent-name)))
    (when entry
      (typecase entry
        (clawmacs/registry:agent-spec
         (clawmacs/registry:instantiate-agent-spec entry))
        (clawmacs/agent:agent
         entry)
        (t nil)))))

(defun agent-name-from-path (pattern)
  "Extract the agent name from the current Hunchentoot request path using PATTERN regex.
PATTERN must have one capture group for the agent name."
  (let* ((path (hunchentoot:script-name*))
         (groups (nth-value 1 (cl-ppcre:scan-to-strings pattern path))))
    (when (and groups (> (length groups) 0))
      (aref groups 0))))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 6. Session key helpers
;;;; ─────────────────────────────────────────────────────────────────────────────

(defun agent-session-key (agent-name)
  "Return the session-id used by the management API for AGENT-NAME."
  (concatenate 'string "mgmt:" agent-name))

(defun get-or-create-agent-session (agent-name)
  "Return an existing management session for AGENT-NAME, or create one.
Returns (values session created-p), where CREATED-P is T if a new session was made.
Returns (values nil nil) if the agent is not found."
  (let ((session-id (agent-session-key agent-name)))
    (let ((existing (http-session-get session-id)))
      (if existing
          (values existing nil)
          (let ((agent (resolve-agent agent-name)))
            (if agent
                (values (http-session-create session-id agent) t)
                (values nil nil)))))))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 7. Message serialization
;;;; ─────────────────────────────────────────────────────────────────────────────

(defun message->ht (msg)
  "Serialize a cl-llm message to a hash-table for JSON output."
  (let ((ht (make-hash-table :test 'equal)))
    (setf (gethash "role"    ht) (string-downcase
                                   (symbol-name (cl-llm/protocol:message-role msg)))
          (gethash "content" ht) (or (cl-llm/protocol:message-content msg) ""))
    ht))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 8. Uptime helpers
;;;; ─────────────────────────────────────────────────────────────────────────────

(defun uptime-seconds ()
  "Return integer seconds since start-server was called, or 0."
  (if *server-start-time*
      (- (get-universal-time) *server-start-time*)
      0))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 9. Handlers — legacy / backward-compatible
;;;; ─────────────────────────────────────────────────────────────────────────────

;;; POST /chat

(defun handle-chat ()
  "Handle POST /chat — synchronous agent response (backward-compatible)."
  (let ((auth-fail (check-auth)))
    (when auth-fail (return-from handle-chat auth-fail)))
  (let ((body (parse-json-body)))
    (unless body
      (return-from handle-chat (json-error "Invalid or missing JSON body")))

    (let* ((message    (ht-get body "message"))
           (session-id (or (ht-get body "session_id")
                           (format nil "http-~a" (get-universal-time))))
           (agent-name (ht-get body "agent"))
           (session    (or (http-session-get session-id)
                           (let ((agent (when agent-name
                                          (resolve-agent agent-name))))
                             (if agent
                                 (http-session-create session-id agent)
                                 (return-from handle-chat
                                   (json-error
                                    (format nil "Agent not found: ~a" agent-name)
                                    404)))))))

      (unless message
        (return-from handle-chat (json-error "Missing 'message' field")))

      (clawmacs/logging:log-event "http_request"
                                  "endpoint" "/chat"
                                  "session_id" session-id
                                  "message_length" (length message))

      (let ((response
             (handler-case
                 (clawmacs/loop:run-agent session message
                                         :options (clawmacs/loop:make-loop-options
                                                   :max-turns 10))
               (error (c)
                 (clawmacs/logging:log-error-event
                  (when agent-name agent-name) "agent_error" (format nil "~a" c)
                  :context "/chat")
                 (return-from handle-chat
                   (json-error (format nil "Agent error: ~a" c) 500))))))

        (clawmacs/logging:log-event "http_response"
                                    "endpoint" "/chat"
                                    "session_id" session-id
                                    "response_length" (length (or response "")))

        (json-response (make-ht "response"   (or response "")
                                "session_id" session-id))))))

;;; POST /chat/stream

(defun handle-chat-stream ()
  "Handle POST /chat/stream — streaming SSE response (backward-compatible)."
  (let ((auth-fail (check-auth)))
    (when auth-fail (return-from handle-chat-stream auth-fail)))
  (let ((body (parse-json-body)))
    (unless body
      (return-from handle-chat-stream (json-error "Invalid JSON body")))

    (let* ((message    (ht-get body "message"))
           (session-id (or (ht-get body "session_id")
                           (format nil "http-stream-~a" (get-universal-time))))
           (agent-name (ht-get body "agent"))
           (session    (or (http-session-get session-id)
                           (let ((agent (when agent-name
                                          (resolve-agent agent-name))))
                             (if agent
                                 (http-session-create session-id agent)
                                 (return-from handle-chat-stream
                                   (json-error
                                    (format nil "Agent not found: ~a" agent-name)
                                    404)))))))

      (unless message
        (return-from handle-chat-stream (json-error "Missing 'message' field")))

      (setf (hunchentoot:content-type*) "text/event-stream; charset=utf-8")
      (setf (hunchentoot:header-out "Cache-Control") "no-cache")
      (setf (hunchentoot:header-out "Connection") "keep-alive")
      (setf (hunchentoot:header-out "Access-Control-Allow-Origin") "*")

      (let ((out-stream (hunchentoot:send-headers)))
        (let ((clawmacs/loop:*on-stream-delta*
               (lambda (delta)
                 (let ((safe-delta (cl-ppcre:regex-replace-all "\\n" delta "\\\\n")))
                   (format out-stream "data: ~a~%~%" safe-delta)
                   (finish-output out-stream)))))
          (handler-case
              (clawmacs/loop:run-agent session message
                                      :options (clawmacs/loop:make-loop-options
                                                :max-turns 10
                                                :stream t))
            (error (c)
              (format out-stream "data: [ERROR] ~a~%~%" c)
              (finish-output out-stream))))
        (format out-stream "data: [DONE]~%~%")
        (finish-output out-stream))
      "")))

;;; GET /agents  (backward-compatible)

(defun handle-list-agents ()
  "Handle GET /agents — list all registered agent specs (backward-compatible)."
  (let ((auth-fail (check-auth)))
    (when auth-fail (return-from handle-list-agents auth-fail)))
  (let* ((specs    (clawmacs/registry:list-agents))
         (out-list (mapcar #'%agent-spec->ht specs))
         (result   (make-hash-table :test 'equal)))
    (setf (gethash "agents" result) (coerce out-list 'vector))
    (json-response result)))

;;; GET /sessions  (backward-compatible)

(defun handle-list-sessions ()
  "Handle GET /sessions — list all active HTTP sessions (backward-compatible)."
  (let ((auth-fail (check-auth)))
    (when auth-fail (return-from handle-list-sessions auth-fail)))
  (let* ((sessions (list-http-sessions))
         (out-list (mapcar #'%session->ht sessions))
         (result   (make-hash-table :test 'equal)))
    (setf (gethash "sessions" result) (coerce out-list 'vector))
    (json-response result)))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 10. Serialization helpers
;;;; ─────────────────────────────────────────────────────────────────────────────

(defun %agent-spec->ht (spec)
  "Serialize an agent-spec or agent to a hash-table."
  (let ((ht (make-hash-table :test 'equal)))
    (etypecase spec
      (clawmacs/registry:agent-spec
       (setf (gethash "name"  ht) (clawmacs/registry:agent-spec-name spec)
             (gethash "role"  ht) (or (clawmacs/registry:agent-spec-role spec) "")
             (gethash "model" ht) (or (clawmacs/registry:agent-spec-model spec) "")))
      (clawmacs/agent:agent
       (setf (gethash "name"  ht) (clawmacs/agent:agent-name spec)
             (gethash "role"  ht) (or (clawmacs/agent:agent-role spec) "")
             (gethash "model" ht) (or (clawmacs/agent:agent-model spec) ""))))
    ht))

(defun %session->ht (sess)
  "Serialize a session to a hash-table."
  (let ((ht (make-hash-table :test 'equal)))
    (setf (gethash "id"            ht) (clawmacs/session:session-id sess)
          (gethash "message_count" ht) (length (clawmacs/session:session-messages sess))
          (gethash "total_tokens"  ht) (clawmacs/session:session-total-tokens sess))
    ht))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 11. Management API handlers
;;;; ─────────────────────────────────────────────────────────────────────────────

;;; GET /health

(defun handle-health ()
  "Return a health check response. No auth required (useful for load balancers)."
  (json-response
   (make-ht "status"  "ok"
            "uptime"  (uptime-seconds)
            "version" "0.8.0")))

;;; GET /api/system

(defun handle-api-system ()
  "Return detailed system information."
  (let ((auth-fail (check-auth)))
    (when auth-fail (return-from handle-api-system auth-fail)))
  (json-response
   (make-ht "version"       "0.8.0"
            "uptime"        (uptime-seconds)
            "log_file"      (or (and (boundp 'clawmacs/logging:*log-file*)
                                     clawmacs/logging:*log-file*)
                                "")
            "log_enabled"   (if (and (boundp 'clawmacs/logging:*log-enabled*)
                                     clawmacs/logging:*log-enabled*)
                                t :false)
            "agent_count"   (length (clawmacs/registry:list-agents))
            "session_count" (hash-table-count *http-sessions*)
            "task_count"    (length (clawmacs/cron:list-tasks)))))

;;; GET /api/agents

(defun handle-api-list-agents ()
  "List all registered agents."
  (let ((auth-fail (check-auth)))
    (when auth-fail (return-from handle-api-list-agents auth-fail)))
  (let* ((specs    (clawmacs/registry:list-agents))
         (out-list (mapcar #'%agent-spec->ht specs))
         (result   (make-hash-table :test 'equal)))
    (setf (gethash "agents" result) (coerce out-list 'vector))
    (json-response result)))

;;; POST /api/agents/:name/start

(defun handle-api-agent-start ()
  "Create (or return existing) a management session for an agent."
  (let ((auth-fail (check-auth)))
    (when auth-fail (return-from handle-api-agent-start auth-fail)))
  (let ((agent-name (agent-name-from-path "^/api/agents/([^/]+)/start$")))
    (unless agent-name
      (return-from handle-api-agent-start (json-error "Could not parse agent name" 400)))
    (multiple-value-bind (session created-p)
        (get-or-create-agent-session agent-name)
      (unless session
        (return-from handle-api-agent-start
          (json-error (format nil "Agent not found: ~a" agent-name) 404)))
      (json-response
       (make-ht "session_id" (clawmacs/session:session-id session)
                "agent"      agent-name
                "created"    (if created-p t :false))))))

;;; POST /api/agents/:name/message

(defun handle-api-agent-message ()
  "Send a message to an agent and return the response synchronously."
  (let ((auth-fail (check-auth)))
    (when auth-fail (return-from handle-api-agent-message auth-fail)))
  (let ((agent-name (agent-name-from-path "^/api/agents/([^/]+)/message$")))
    (unless agent-name
      (return-from handle-api-agent-message (json-error "Could not parse agent name" 400)))
    (let ((body (parse-json-body)))
      (unless body
        (return-from handle-api-agent-message (json-error "Invalid JSON body")))
      (let* ((message    (ht-get body "message"))
             (max-turns  (or (ht-get body "max_turns") 10)))
        (unless message
          (return-from handle-api-agent-message (json-error "Missing 'message' field")))
        (multiple-value-bind (session _)
            (get-or-create-agent-session agent-name)
          (declare (ignore _))
          (unless session
            (return-from handle-api-agent-message
              (json-error (format nil "Agent not found: ~a" agent-name) 404)))
          (clawmacs/logging:log-event "http_request"
                                      "endpoint" "/api/agents/:name/message"
                                      "agent"    agent-name
                                      "length"   (length message))
          (let ((response
                 (handler-case
                     (clawmacs/loop:run-agent
                      session message
                      :options (clawmacs/loop:make-loop-options
                                :max-turns (if (integerp max-turns) max-turns 10)))
                   (error (c)
                     (return-from handle-api-agent-message
                       (json-error (format nil "Agent error: ~a" c) 500))))))
            (clawmacs/logging:log-event "http_response"
                                        "endpoint" "/api/agents/:name/message"
                                        "agent"    agent-name
                                        "length"   (length (or response "")))
            (json-response
             (make-ht "response"   (or response "")
                      "agent"      agent-name
                      "session_id" (clawmacs/session:session-id session)))))))))

;;; GET /api/agents/:name/history

(defun handle-api-agent-history ()
  "Return the session message history for an agent."
  (let ((auth-fail (check-auth)))
    (when auth-fail (return-from handle-api-agent-history auth-fail)))
  (let ((agent-name (agent-name-from-path "^/api/agents/([^/]+)/history$")))
    (unless agent-name
      (return-from handle-api-agent-history (json-error "Could not parse agent name" 400)))
    (let ((session (http-session-get (agent-session-key agent-name))))
      (unless session
        ;; No session yet = empty history
        (return-from handle-api-agent-history
          (json-response
           (make-ht "agent"    agent-name
                    "messages" #()
                    "count"    0))))
      (let* ((msgs     (clawmacs/session:session-messages session))
             (out-list (mapcar #'message->ht msgs))
             (result   (make-hash-table :test 'equal)))
        (setf (gethash "agent"    result) agent-name
              (gethash "messages" result) (coerce out-list 'vector)
              (gethash "count"    result) (length msgs))
        (json-response result)))))

;;; DELETE /api/agents/:name/stop

(defun handle-api-agent-stop ()
  "Terminate (delete) the management session for an agent."
  (let ((auth-fail (check-auth)))
    (when auth-fail (return-from handle-api-agent-stop auth-fail)))
  (let ((agent-name (agent-name-from-path "^/api/agents/([^/]+)/stop$")))
    (unless agent-name
      (return-from handle-api-agent-stop (json-error "Could not parse agent name" 400)))
    (let* ((session-id (agent-session-key agent-name))
           (deleted-p  (http-session-delete session-id)))
      (json-response
       (make-ht "agent"   agent-name
                "stopped" (if deleted-p t :false))))))

;;; GET /api/sessions

(defun handle-api-list-sessions ()
  "List all active sessions."
  (let ((auth-fail (check-auth)))
    (when auth-fail (return-from handle-api-list-sessions auth-fail)))
  (let* ((sessions (list-http-sessions))
         (out-list (mapcar #'%session->ht sessions))
         (result   (make-hash-table :test 'equal)))
    (setf (gethash "sessions" result) (coerce out-list 'vector)
          (gethash "count"    result) (length sessions))
    (json-response result)))

;;; GET /api/channels

(defun handle-api-list-channels ()
  "List all registered channel configurations."
  (let ((auth-fail (check-auth)))
    (when auth-fail (return-from handle-api-list-channels auth-fail)))
  (let* ((channels (when (and (find-package '#:clawmacs/config)
                              (boundp 'clawmacs/config:*registered-channels*))
                     (symbol-value (find-symbol "*REGISTERED-CHANNELS*" '#:clawmacs/config))))
         (out-list
          (mapcar (lambda (entry)
                    (let ((ht (make-hash-table :test 'equal)))
                      (setf (gethash "type" ht)
                            (string-downcase (symbol-name (car entry))))
                      ht))
                  channels))
         (result (make-hash-table :test 'equal)))
    (setf (gethash "channels" result) (coerce out-list 'vector)
          (gethash "count"    result) (length out-list))
    (json-response result)))

;;; GET /api/tasks

(defun handle-api-list-tasks ()
  "List all cron/scheduled tasks."
  (let ((auth-fail (check-auth)))
    (when auth-fail (return-from handle-api-list-tasks auth-fail)))
  (let* ((tasks    (clawmacs/cron:list-tasks))
         (out-list (mapcar #'clawmacs/cron:task-info tasks))
         (result   (make-hash-table :test 'equal)))
    (setf (gethash "tasks" result) (coerce out-list 'vector)
          (gethash "count" result) (length tasks))
    (json-response result)))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 12. Dispatch table
;;;; ─────────────────────────────────────────────────────────────────────────────

(defun make-dispatch-table ()
  "Build the Hunchentoot dispatch table for the Clawmacs API."
  (list
   ;; ── Management API: agents ──────────────────────────────────────────────────
   (hunchentoot:create-regex-dispatcher
    "^/api/agents/[^/]+/start$"     #'handle-api-agent-start)
   (hunchentoot:create-regex-dispatcher
    "^/api/agents/[^/]+/message$"   #'handle-api-agent-message)
   (hunchentoot:create-regex-dispatcher
    "^/api/agents/[^/]+/history$"   #'handle-api-agent-history)
   (hunchentoot:create-regex-dispatcher
    "^/api/agents/[^/]+/stop$"      #'handle-api-agent-stop)
   ;; ── Management API: lists ────────────────────────────────────────────────────
   (hunchentoot:create-prefix-dispatcher "/api/agents"   #'handle-api-list-agents)
   (hunchentoot:create-prefix-dispatcher "/api/sessions" #'handle-api-list-sessions)
   (hunchentoot:create-prefix-dispatcher "/api/channels" #'handle-api-list-channels)
   (hunchentoot:create-prefix-dispatcher "/api/tasks"    #'handle-api-list-tasks)
   (hunchentoot:create-prefix-dispatcher "/api/system"   #'handle-api-system)
   ;; ── Health check (no auth) ───────────────────────────────────────────────────
   (hunchentoot:create-prefix-dispatcher "/health"       #'handle-health)
   ;; ── Legacy endpoints ─────────────────────────────────────────────────────────
   (hunchentoot:create-prefix-dispatcher "/chat/stream"  #'handle-chat-stream)
   (hunchentoot:create-prefix-dispatcher "/chat"         #'handle-chat)
   (hunchentoot:create-prefix-dispatcher "/agents"       #'handle-list-agents)
   (hunchentoot:create-prefix-dispatcher "/sessions"     #'handle-list-sessions)
   ;; ── Root ─────────────────────────────────────────────────────────────────────
   (hunchentoot:create-prefix-dispatcher "/"
     (lambda ()
       (json-response
        (make-ht "name"    "clawmacs-core API"
                 "version" "0.8.0"
                 "auth"    (if (and *api-token* (not (string= *api-token* "")))
                               "bearer" "none")
                 "paths"   (vector
                            ;; Management API
                            "/health"
                            "/api/system"
                            "/api/agents"
                            "/api/agents/:name/start"
                            "/api/agents/:name/message"
                            "/api/agents/:name/history"
                            "/api/agents/:name/stop"
                            "/api/sessions"
                            "/api/channels"
                            "/api/tasks"
                            ;; Legacy
                            "/chat"
                            "/chat/stream"
                            "/agents"
                            "/sessions")))))))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 13. Server lifecycle
;;;; ─────────────────────────────────────────────────────────────────────────────

(defun start-server (&key (port *default-port*) (address "127.0.0.1") log-file api-token)
  "Start the Clawmacs HTTP Remote Management API server on PORT (default: *DEFAULT-PORT*).

PORT      — TCP port to listen on.
ADDRESS   — bind address (default 127.0.0.1 — loopback only; use 0.0.0.0 for all interfaces).
LOG-FILE  — optional path for JSONL structured logging.
API-TOKEN — bearer token for authentication.  Overrides *API-TOKEN* when provided.

Returns the acceptor."
  (when (and *server* (hunchentoot:started-p *server*))
    (warn "Server already running on port ~a. Stop it first." port)
    (return-from start-server *server*))
  ;; Apply API token
  (when api-token
    (setf *api-token* api-token))
  ;; Configure log file
  (when (or log-file (null clawmacs/logging:*log-file*))
    (setf clawmacs/logging:*log-file*
          (or log-file
              (uiop:native-namestring
               (merge-pathnames "logs/clawmacs.jsonl" (uiop:getcwd))))))
  ;; Ensure log directory exists
  (when clawmacs/logging:*log-file*
    (ensure-directories-exist clawmacs/logging:*log-file*))
  (let ((acceptor (make-instance 'hunchentoot:easy-acceptor
                                 :port port
                                 :address address
                                 :access-log-destination nil
                                 :message-log-destination *error-output*)))
    (setf hunchentoot:*dispatch-table* (make-dispatch-table))
    (hunchentoot:start acceptor)
    (setf *server* acceptor
          *server-start-time* (get-universal-time))
    (format t "~&[clawmacs/http-server] Started on ~a:~a~%" address port)
    (format t "~&[clawmacs/http-server] Auth: ~a~%"
            (if (and *api-token* (not (string= *api-token* "")))
                "bearer token required"
                "disabled (no auth)"))
    (format t "~&[clawmacs/http-server] Logging to ~a~%" clawmacs/logging:*log-file*)
    (clawmacs/logging:log-event "server_start" "port" port "address" address)
    acceptor))

(defun stop-server ()
  "Stop the running Clawmacs HTTP API server."
  (when *server*
    (hunchentoot:stop *server*)
    (format t "~&[clawmacs/http-server] Stopped.~%")
    (setf *server* nil))
  nil)

(defun server-running-p ()
  "Return T if the HTTP server is currently running."
  (and *server* (hunchentoot:started-p *server*)))

(defun restart-server (&key (port *default-port*) (address "127.0.0.1"))
  "Stop and restart the HTTP server."
  (stop-server)
  (start-server :port port :address address))
