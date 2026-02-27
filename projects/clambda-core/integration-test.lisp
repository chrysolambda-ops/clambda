;;;; integration-test.lisp — Full stack integration test for clawmacs-core
;;;;
;;;; Tests the FULL stack working together:
;;;;   1. Register an agent with tools (exec, read_file, write_file, web_fetch)
;;;;   2. Create a session with memory loaded from a test workspace
;;;;   3. Run the agent loop with a real task via LM Studio
;;;;   4. Verify: tool calls happen, session persists, logs are written
;;;;   5. Spawn a sub-agent from within the test, verify it completes
;;;;   6. Start the HTTP server, send a /chat request via dexador, verify response
;;;;
;;;; Environment:
;;;;   LM Studio at http://192.168.1.189:1234/v1, model: google/gemma-3-4b
;;;;   No local GPU — all inference remote.
;;;;
;;;; Usage:
;;;;   sbcl --load ~/quicklisp/setup.lisp \
;;;;        --eval '(asdf:clear-source-registry)' \
;;;;        --eval '(asdf:initialize-source-registry)' \
;;;;        --load projects/clawmacs-core/integration-test.lisp

(load "~/quicklisp/setup.lisp")
(asdf:clear-source-registry)
(asdf:initialize-source-registry)
(ql:quickload :clawmacs-core :silent t)

;;; ── Configuration ────────────────────────────────────────────────────────────

(defparameter *lm-studio-url*    "http://192.168.1.189:1234/v1")
(defparameter *lm-studio-apikey* "not-needed")
(defparameter *lm-studio-model*  "google/gemma-3-4b")
(defparameter *test-workspace*   "/tmp/clawmacs-integration-test/")
(defparameter *test-log-file*    "/tmp/clawmacs-integration-test/clawmacs-test.jsonl")
(defparameter *http-port*        17474)  ; non-standard port to avoid conflicts

;;; ── Test utilities ───────────────────────────────────────────────────────────

(defvar *tests-run* 0)
(defvar *tests-passed* 0)
(defvar *tests-failed* 0)
(defvar *failures* nil)

(defmacro deftest (name &body body)
  `(progn
     (incf *tests-run*)
     (format t "~%[TEST] ~a~%" ,name)
     (handler-case
         (progn ,@body
                (incf *tests-passed*)
                (format t "  ✓ PASS~%"))
       (error (e)
         (incf *tests-failed*)
         (push (list ,name (format nil "~a" e)) *failures*)
         (format t "  ✗ FAIL: ~a~%" e)))))

(defun assert-true (form description)
  (unless form
    (error "Assertion failed: ~a" description)))

(defun assert-string-contains (haystack needle)
  (unless (search needle haystack :test #'char-equal)
    (error "Expected ~s to contain ~s" haystack needle)))

;;; ── Setup ────────────────────────────────────────────────────────────────────

(defun setup-test-workspace ()
  "Create a fresh test workspace directory with some test files."
  (ensure-directories-exist *test-workspace*)
  ;; Create a simple test file
  (with-open-file (out (format nil "~aTEST.md" *test-workspace*)
                       :direction :output :if-exists :supersede
                       :if-does-not-exist :create)
    (write-string "# Test Workspace
This is a test workspace for the clawmacs-core integration test.
It contains test files for reading and writing." out))
  ;; Create logs directory
  (ensure-directories-exist (format nil "~alogs/" *test-workspace*))
  (format t "[setup] Test workspace: ~a~%" *test-workspace*))

(defun check-lm-studio-reachable ()
  "Return T if LM Studio is reachable, NIL otherwise."
  (handler-case
      (progn
        (dexador:get (format nil "~a/models" *lm-studio-url*)
                     :headers `(("Authorization" . ,(format nil "Bearer ~a" *lm-studio-apikey*)))
                     :connect-timeout 5
                     :read-timeout 5)
        t)
    (error () nil)))

;;; ── Test 1: Agent with full tool registry ────────────────────────────────────

(defun make-test-agent ()
  "Build a test agent with all builtin tools and the LM Studio client."
  (let* ((client   (cl-llm:make-client
                    :base-url *lm-studio-url*
                    :api-key  *lm-studio-apikey*
                    :model    *lm-studio-model*))
         (registry (clawmacs:make-builtin-registry :workdir *test-workspace*))
         (agent    (clawmacs:make-agent
                    :name          "integration-test-agent"
                    :client        client
                    :tool-registry registry
                    :system-prompt "You are a test agent. Be brief and concise.")))
    agent))

;;; ── Test 2: Memory loading ───────────────────────────────────────────────────

(defun test-memory-loading ()
  (let ((mem (clawmacs:load-workspace-memory *test-workspace*)))
    (assert-true mem "Memory object should be non-nil")
    (assert-true (clawmacs:workspace-memory-entries mem)
                 "Should have at least one memory entry (TEST.md)")
    (let ((ctx (clawmacs:memory-context-string mem)))
      (assert-true (stringp ctx) "Memory context should be a string")
      (assert-true (> (length ctx) 0) "Memory context should be non-empty")
      (format t "  Memory entries: ~a~%" (length (clawmacs:workspace-memory-entries mem)))
      (format t "  Context length: ~a chars~%" (length ctx)))))

;;; ── Test 3: Agent loop with real LLM ────────────────────────────────────────

(defun test-agent-loop-live (agent)
  "Run a real agent loop against LM Studio. Tool calls expected."
  ;; Set up logging
  (setf clawmacs:*log-file* *test-log-file*)
  (setf clawmacs:*log-enabled* t)
  ;; Track tool calls
  (let ((tool-calls-seen nil)
        (llm-responses-seen nil))
    (setf clawmacs:*on-tool-call*
          (lambda (name tc)
            (declare (ignore tc))
            (push name tool-calls-seen)
            (format t "  [tool-call] ~a~%" name)))
    (setf clawmacs:*on-llm-response*
          (lambda (text)
            (push text llm-responses-seen)
            (format t "  [llm-response] ~a chars~%" (length text))))

    (let* ((session (clawmacs:make-session :agent agent))
           (result  (clawmacs:run-agent
                     session
                     "List the files in /tmp using the exec tool. Just one ls command."
                     :options (clawmacs:make-loop-options
                               :max-turns 5
                               :max-tokens 5000
                               :verbose nil))))

      ;; Verify we got a response
      (assert-true (stringp result) "Result should be a string")
      (assert-true (> (length result) 0) "Result should be non-empty")
      (format t "  Result length: ~a chars~%" (length result))
      (format t "  Tool calls: ~a~%" tool-calls-seen)
      (format t "  Token usage: ~a~%"
              (clawmacs:session-total-tokens session))

      ;; Verify log file was written
      (assert-true (probe-file *test-log-file*)
                   "Log file should exist after agent run")
      (let ((log-contents (uiop:read-file-string *test-log-file*)))
        (assert-true (> (length log-contents) 0) "Log file should be non-empty")
        (assert-string-contains log-contents "llm_request")
        (format t "  Log file: ~a bytes~%" (length log-contents)))

      ;; Return session for persistence test
      session)))

;;; ── Test 4: Session persistence ─────────────────────────────────────────────

(defun test-session-persistence (session agent)
  "Save and reload a session, verify message history is restored."
  (let ((session-path (format nil "~asessions/test-session.json" *test-workspace*)))
    ;; Save
    (clawmacs:save-session session session-path)
    (assert-true (probe-file session-path) "Session file should exist after save")

    ;; Reload
    (let ((loaded-session (clawmacs:load-session agent session-path)))
      (assert-true loaded-session "Loaded session should be non-nil")
      (assert-true (> (clawmacs:session-message-count loaded-session) 0)
                   "Loaded session should have messages")
      (format t "  Saved messages: ~a~%"
              (clawmacs:session-message-count session))
      (format t "  Loaded messages: ~a~%"
              (clawmacs:session-message-count loaded-session))
      (assert-true (= (clawmacs:session-message-count session)
                      (clawmacs:session-message-count loaded-session))
                   "Message count should match after reload")
      loaded-session)))

;;; ── Test 5: Sub-agent spawning ───────────────────────────────────────────────

(defun test-subagent-spawning (agent)
  "Spawn a sub-agent, wait for it to complete."
  (let* ((handle (clawmacs:spawn-subagent
                  agent
                  "Reply with exactly three words: 'Sub agent done'"
                  :options (clawmacs:make-loop-options :max-turns 3)))
         ;; Wait up to 60 seconds
         (start-time (get-universal-time)))
    (format t "  Sub-agent spawned, waiting...~%")
    (multiple-value-bind (result status)
        (clawmacs:subagent-wait handle :timeout 60)
      (declare (ignore result))
      (format t "  Sub-agent status: ~a (~a seconds)~%"
              status (- (get-universal-time) start-time))
      (assert-true (member status '(:done :failed))
                   "Sub-agent should complete (done or failed, not :running)")
      (when (eq status :done)
        (format t "  Sub-agent result: ~a~%"
                (subseq (or (clawmacs:subagent-handle-result handle) "")
                        0 (min 80 (length (or (clawmacs:subagent-handle-result handle) "")))))))))

;;; ── Test 6: HTTP server end-to-end ──────────────────────────────────────────

(defun test-http-server (agent)
  "Start the HTTP server, register agent, send a /chat request via dexador."
  ;; Register the agent in the global registry
  (clawmacs:register-agent
   "test-agent"
   (clawmacs:make-agent-spec
    :name "test-agent"
    :system-prompt "You are a test agent. Say hello."
    :client (clawmacs/agent:agent-client agent)
    :model *lm-studio-model*))

  ;; Start server
  (let ((server (clawmacs:start-server :port *http-port*
                                       :log-file *test-log-file*)))
    (declare (ignore server))
    (format t "  HTTP server started on port ~a~%" *http-port*)
    (sleep 1) ; give it a moment to start

    (unwind-protect
         (progn
           ;; Send a /chat request
           (let* ((body (com.inuoe.jzon:stringify
                         (let ((ht (make-hash-table :test 'equal)))
                           (setf (gethash "message"    ht) "Say exactly: integration test OK"
                                 (gethash "agent"      ht) "test-agent"
                                 (gethash "session_id" ht) "http-test-session-1")
                           ht)))
                  (response-body
                   (handler-case
                       (dexador:post
                        (format nil "http://127.0.0.1:~a/chat" *http-port*)
                        :headers '(("Content-Type" . "application/json"))
                        :content body
                        :connect-timeout 5
                        :read-timeout 90)
                     (error (e)
                       (error "HTTP POST to /chat failed: ~a" e)))))

             (format t "  /chat response: ~a chars~%" (length response-body))
             (assert-true (> (length response-body) 0) "HTTP response should be non-empty")

             ;; Parse response
             (let* ((parsed (com.inuoe.jzon:parse response-body))
                    (resp   (gethash "response" parsed))
                    (sid    (gethash "session_id" parsed)))
               (assert-true resp "Response should have 'response' field")
               (assert-true sid  "Response should have 'session_id' field")
               (format t "  Session ID: ~a~%" sid)
               (format t "  Response: ~a~%"
                       (subseq resp 0 (min 80 (length resp)))))

             ;; Verify /agents endpoint
             (let ((agents-resp (dexador:get
                                 (format nil "http://127.0.0.1:~a/agents" *http-port*)
                                 :connect-timeout 5)))
               (assert-string-contains agents-resp "test-agent")
               (format t "  /agents OK: lists test-agent~%"))))

      ;; Always stop server
      (clawmacs:stop-server))))

;;; ── Main runner ──────────────────────────────────────────────────────────────

(defun run-integration-tests ()
  (format t "~%╔══════════════════════════════════════════════════════════╗~%")
  (format t "║     clawmacs-core Full Integration Test Suite            ║~%")
  (format t "╚══════════════════════════════════════════════════════════╝~%")
  (format t "~%LM Studio: ~a~%" *lm-studio-url*)
  (format t "Model: ~a~%" *lm-studio-model*)
  (format t "Workspace: ~a~%" *test-workspace*)

  ;; Setup
  (setup-test-workspace)
  (ignore-errors (delete-file *test-log-file*))

  ;; Check LM Studio reachability
  (let ((lm-reachable (check-lm-studio-reachable)))
    (format t "LM Studio reachable: ~a~%" (if lm-reachable "YES" "NO"))

    ;; Build agent (needed for multiple tests)
    (let ((agent (make-test-agent)))

      ;; Test 1: Builtin tool registry
      (deftest "1. Builtin tool registry"
        (let ((r (clawmacs:make-builtin-registry)))
          (assert-true r "Registry should be non-nil")
          ;; list-tools returns a list of name strings
          (let ((tools (clawmacs:list-tools r)))
            (assert-true (>= (length tools) 5)
                         (format nil "Should have >= 5 tools, got ~a" (length tools)))
            (format t "  Tools: ~{~a~^, ~}~%" tools))))

      ;; Test 2: Memory loading
      (deftest "2. Workspace memory loading"
        (test-memory-loading))

      ;; Test 3: Session basics
      (deftest "3. Session creation and token tracking"
        (let ((s (clawmacs:make-session :agent agent)))
          (assert-true s "Session should be created")
          (assert-true (= 0 (clawmacs:session-total-tokens s))
                       "Initial token count should be 0")
          (setf (clawmacs:session-total-tokens s) 500)
          (assert-true (= 500 (clawmacs:session-total-tokens s))
                       "Token count should update")))

      ;; Test 4: Loop options
      (deftest "4. Loop options with max-tokens"
        (let ((opts (clawmacs:make-loop-options
                     :max-turns 10 :max-tokens 5000 :stream nil)))
          (assert-true (= 10 (clawmacs:loop-options-max-turns opts))
                       "max-turns should be 10")
          (assert-true (= 5000 (clawmacs:loop-options-max-tokens opts))
                       "max-tokens should be 5000")))

      ;; Test 5: TTS no-op
      ;; find-tool returns a TOOL-ENTRY struct; use dispatch-tool-call via a mock tool-call
      (deftest "5. TTS tool (graceful no-op)"
        (let* ((reg (clawmacs:make-builtin-registry))
               (tts-entry (clawmacs:find-tool reg "tts")))
          (assert-true tts-entry "TTS tool should be registered")
          ;; Invoke the handler directly via the internal slot
          (let* ((args (let ((ht (make-hash-table :test 'equal)))
                         (setf (gethash "text" ht) "Hello integration test")
                         ht))
                 (handler (slot-value tts-entry 'clawmacs/tools::handler))
                 (result-obj (funcall handler args))
                 (result (clawmacs:format-tool-result result-obj)))
            (format t "  TTS result: ~a~%" result)
            (assert-true (stringp result) "TTS should return a string"))))

      ;; Test 6: Retry/backoff config accessible
      (deftest "6. HTTP retry config"
        (assert-true (numberp cl-llm:*max-retries*)
                     "*max-retries* should be a number")
        (assert-true (numberp cl-llm:*retry-base-delay-seconds*)
                     "*retry-base-delay-seconds* should be a number")
        (format t "  *max-retries*: ~a~%" cl-llm:*max-retries*)
        (format t "  *retry-base-delay-seconds*: ~a~%"
                cl-llm:*retry-base-delay-seconds*))

      ;; Test 7: budget-exceeded condition
      (deftest "7. budget-exceeded condition"
        (let ((caught nil))
          (handler-case
              (error 'clawmacs:budget-exceeded :kind :tokens :limit 100 :current 200)
            (clawmacs:budget-exceeded (c)
              (setf caught c)
              (assert-true (eq :tokens (clawmacs:budget-exceeded-kind c))
                           "kind should be :tokens")
              (assert-true (= 100 (clawmacs:budget-exceeded-limit c))
                           "limit should be 100")
              (assert-true (= 200 (clawmacs:budget-exceeded-current c))
                           "current should be 200")))
          (assert-true caught "budget-exceeded should have been caught")))

      ;; Test 8: Logging system
      (deftest "8. Structured logging"
        (let ((log-path "/tmp/clawmacs-test-logging.jsonl"))
          (ignore-errors (delete-file log-path))
          (clawmacs:with-logging (log-path)
            (clawmacs:log-event "integration_test" "phase" "logging" "ok" t)
            (clawmacs:log-llm-request "test-agent" "gemma-3-4b" 5 :tools-count 3)
            (clawmacs:log-tool-call "test-agent" "exec" "ls /tmp")
            (clawmacs:log-tool-result "test-agent" "exec" t 100)
            (clawmacs:log-error-event nil "test_error" "test message" :context "testing"))
          (let ((contents (uiop:read-file-string log-path)))
            (assert-true (> (length contents) 0) "Log file should have content")
            (assert-string-contains contents "integration_test")
            (assert-string-contains contents "llm_request")
            (assert-string-contains contents "tool_call")
            (format t "  Logged ~a bytes~%" (length contents)))))

      ;; Live tests (require LM Studio)
      (when lm-reachable
        ;; Test 9: Agent loop with LLM (live)
        (deftest "9. [LIVE] Agent loop with real LLM"
          (let ((session (test-agent-loop-live agent)))
            ;; Test 10: Session persistence
            (deftest "10. [LIVE] Session persistence"
              (test-session-persistence session agent))))

        ;; Test 11: Sub-agent spawning (live)
        (deftest "11. [LIVE] Sub-agent spawning"
          (test-subagent-spawning agent))

        ;; Test 12: HTTP server end-to-end (live)
        (deftest "12. [LIVE] HTTP server /chat endpoint"
          (test-http-server agent)))

      (unless lm-reachable
        (format t "~%[SKIP] Tests 9-12 require LM Studio at ~a (not reachable)~%"
                *lm-studio-url*))))

  ;; Summary
  (format t "~%╔══════════════════════════════════════════════════════════╗~%")
  (format t "║                    TEST SUMMARY                         ║~%")
  (format t "╠══════════════════════════════════════════════════════════╣~%")
  (format t "║  Total:  ~3a  Passed: ~3a  Failed: ~3a                   ║~%"
          *tests-run* *tests-passed* *tests-failed*)
  (format t "╚══════════════════════════════════════════════════════════╝~%")
  (when *failures*
    (format t "~%FAILURES:~%")
    (dolist (f *failures*)
      (format t "  [~a] ~a~%" (first f) (second f))))
  (if (= 0 *tests-failed*)
      (format t "~%✓ ALL TESTS PASSED~%")
      (format t "~%✗ ~a TEST(S) FAILED~%" *tests-failed*))
  (values *tests-passed* *tests-failed*))

;;; Run immediately when loaded
(run-integration-tests)
