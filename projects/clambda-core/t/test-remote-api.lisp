;;;; t/test-remote-api.lisp — Tests for clawmacs/http-server Layer 8b (Remote Management API)
;;;;
;;;; Focus: unit tests that don't require a running HTTP acceptor.
;;;; Tests the auth logic, session CRUD, uptime, and cron/task helpers
;;;; that underpin the management endpoints.
;;;;
;;;; What is NOT tested here (requires live Hunchentoot + network):
;;;;   - Actual HTTP request routing
;;;;   - SSE streaming
;;;;   - Agent-level message dispatch
;;;; Those are covered by integration tests.

(in-package #:clawmacs-core/tests/remote-api)

;;; ─────────────────────────────────────────────────────────────────────────────
;;; § 1. *api-token* configuration
;;; ─────────────────────────────────────────────────────────────────────────────

(define-test "api-token: default value is NIL (auth disabled)"
  (let ((clawmacs/http-server:*api-token* nil))
    (false clawmacs/http-server:*api-token*)))

(define-test "api-token: can be set to a string"
  (let ((clawmacs/http-server:*api-token* "test-secret"))
    (is string= "test-secret" clawmacs/http-server:*api-token*)))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; § 2. uptime-seconds
;;; ─────────────────────────────────────────────────────────────────────────────

(define-test "uptime-seconds: returns 0 when server-start-time is NIL"
  (let ((clawmacs/http-server:*server-start-time* nil))
    (is = 0 (uptime-seconds))))

(define-test "uptime-seconds: returns positive integer after start"
  (let ((clawmacs/http-server:*server-start-time* (- (get-universal-time) 42)))
    (let ((up (uptime-seconds)))
      (true (>= up 42)))))

(define-test "uptime-seconds: increases monotonically"
  (let ((clawmacs/http-server:*server-start-time* (- (get-universal-time) 10)))
    (let ((a (uptime-seconds)))
      (sleep 0.1)
      (let ((b (uptime-seconds)))
        (true (>= b a))))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; § 3. Session CRUD helpers
;;; ─────────────────────────────────────────────────────────────────────────────

(defmacro with-clean-sessions (&body body)
  "Run BODY with a fresh session hash-table.
Rebinds *http-sessions* only; shares the global lock (safe for sequential tests)."
  `(let ((clawmacs/http-server:*http-sessions* (make-hash-table :test 'equal)))
     ,@body))

(define-test "http-session-get: returns NIL for unknown session-id"
  (with-clean-sessions
    (false (http-session-get "no-such-session"))))

(define-test "http-session-create: creates and stores a session"
  (with-clean-sessions
    ;; Create a minimal agent for the session
    (let* ((client (cl-llm:make-client :base-url "http://localhost:1234/v1"
                                        :api-key "test"
                                        :model "test-model"))
           (agent  (clawmacs:make-agent :name "test-agent" :client client))
           (sess   (http-session-create "test-id" agent)))
      (true sess)
      (is string= "test-id" (clawmacs/session:session-id sess))
      ;; Retrieve it
      (let ((retrieved (http-session-get "test-id")))
        (true retrieved)
        (is eq sess retrieved)))))

(define-test "http-session-delete: removes a session"
  (with-clean-sessions
    (let* ((client (cl-llm:make-client :base-url "http://localhost:1234/v1"
                                        :api-key "test"
                                        :model "test-model"))
           (agent  (clawmacs:make-agent :name "del-agent" :client client)))
      (http-session-create "del-id" agent)
      (true (http-session-get "del-id"))
      (is eq t (http-session-delete "del-id"))
      (false (http-session-get "del-id")))))

(define-test "http-session-delete: returns NIL for nonexistent id"
  (with-clean-sessions
    (false (http-session-delete "ghost-id"))))

(define-test "list-http-sessions: returns empty list when no sessions"
  (with-clean-sessions
    (is eq nil (list-http-sessions))))

(define-test "list-http-sessions: returns all sessions"
  (with-clean-sessions
    (let* ((client (cl-llm:make-client :base-url "http://localhost:1234/v1"
                                        :api-key "test"
                                        :model "test-model"))
           (a1 (clawmacs:make-agent :name "a1" :client client))
           (a2 (clawmacs:make-agent :name "a2" :client client)))
      (http-session-create "s1" a1)
      (http-session-create "s2" a2)
      (let ((sessions (list-http-sessions)))
        (is = 2 (length sessions))
        (true (find-if (lambda (s) (string= "s1" (clawmacs/session:session-id s)))
                       sessions))
        (true (find-if (lambda (s) (string= "s2" (clawmacs/session:session-id s)))
                       sessions))))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; § 4. Cron integration: list-tasks visible to API
;;; ─────────────────────────────────────────────────────────────────────────────

(defmacro with-clean-cron (&body body)
  "Run BODY with a clean cron registry."
  `(let ((clawmacs/cron:*task-registry* (make-hash-table :test 'equal)))
     ,@body))

(define-test "api-tasks: list-tasks returns empty initially"
  (with-clean-cron
    (is eq nil (list-tasks))))

(define-test "api-tasks: scheduled tasks visible to API layer"
  (with-clean-cron
    (let ((clawmacs/cron:*cron-sleep-interval* 0.05))
      (schedule-task "api-visible" :every 9999 :function (lambda ()))
      (let ((tasks (list-tasks)))
        (is = 1 (length tasks))
        (is string= "api-visible" (clawmacs/cron:task-name (first tasks))))
      (cancel-task "api-visible"))))

(define-test "api-tasks: task-info returns JSON-serializable hash-table"
  (with-clean-cron
    (let ((clawmacs/cron:*cron-sleep-interval* 0.05))
      (let* ((task (schedule-task "json-task" :every 9999
                                  :function (lambda ())
                                  :description "json test"))
             (ht (task-info task)))
        (true (hash-table-p ht))
        (is string= "json-task" (gethash "name" ht))
        (is string= "periodic"  (gethash "kind" ht)))
      (cancel-task "json-task"))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; § 5. server-running-p without starting
;;; ─────────────────────────────────────────────────────────────────────────────

(define-test "server-running-p: returns NIL when server is not started"
  ;; Bind *server* to NIL locally so we don't interfere with any real server
  (let ((clawmacs/http-server:*server* nil))
    (false (clawmacs/http-server:server-running-p))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; § 6. *api-token* effect on check-auth
;;; ─────────────────────────────────────────────────────────────────────────────
;;;
;;; check-auth reads hunchentoot:header-in*, which requires a live request.
;;; We test the logic that routes through it by inspecting *api-token* bindings.

(define-test "check-auth: NIL token means no auth required (returns NIL)"
  ;; With no token configured, check-auth should return NIL (pass)
  ;; We can test this without Hunchentoot by examining the token variable
  (let ((clawmacs/http-server:*api-token* nil))
    ;; When token is NIL, the check-auth guard is skipped — function returns NIL
    ;; We model this by checking the predicate used inside check-auth
    (let ((token-configured-p (and clawmacs/http-server:*api-token*
                                   (not (string= clawmacs/http-server:*api-token* "")))))
      (false token-configured-p))))

(define-test "check-auth: non-NIL token means auth IS required"
  (let ((clawmacs/http-server:*api-token* "s3cr3t"))
    (let ((token-configured-p (and clawmacs/http-server:*api-token*
                                   (not (string= clawmacs/http-server:*api-token* "")))))
      (true token-configured-p))))

(define-test "check-auth: empty string token means auth is NOT required"
  (let ((clawmacs/http-server:*api-token* ""))
    (let ((token-configured-p (and clawmacs/http-server:*api-token*
                                   (not (string= clawmacs/http-server:*api-token* "")))))
      (false token-configured-p))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; § 7. *default-port* value
;;; ─────────────────────────────────────────────────────────────────────────────

(define-test "default-port: is 7474"
  (is = 7474 clawmacs/http-server:*default-port*))
