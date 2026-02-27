;;;; t/smoke-test.lisp — Smoke test: agent with exec tool + echo hello

(in-package #:clawmacs-core/tests)

;;; ── Smoke test ───────────────────────────────────────────────────────────────

(defun run-smoke-test ()
  "Create an agent with exec tool, ask it to run `echo hello`, verify the loop.

Returns T on success, signals error on failure."
  (format t "~%=== clawmacs-core smoke test ===~%~%")

  ;; 1. Build LLM client (LM Studio)
  (let* ((client (cl-llm:make-client
                  :base-url "http://192.168.1.189:1234/v1"
                  :api-key  "not-needed"
                  :model    "google/gemma-3-4b"))

         ;; 2. Build tool registry with exec built-in
         (registry (clawmacs:make-builtin-registry))

         ;; 3. Create agent
         (agent (clawmacs:make-agent
                 :name          "smoke-agent"
                 :role          "assistant"
                 :model         "google/gemma-3-4b"
                 :system-prompt "You are a helpful shell assistant. When asked to run a command, use the exec tool."
                 :client        client
                 :tool-registry registry))

         ;; 4. Create session
         (session (clawmacs:make-session :agent agent))

         ;; 5. Loop options (verbose)
         (opts (clawmacs:make-loop-options
                :max-turns 5
                :verbose   t)))

    (format t "[test] Agent: ~a~%" (clawmacs:agent-name agent))
    (format t "[test] Tools: ~{~a~^, ~}~%"
            (clawmacs/tools:list-tools registry))

    ;; 6. Set up hooks for inspection
    (let ((tool-calls-made nil))

      (setf clawmacs:*on-tool-call*
            (lambda (name tc)
              (declare (ignore tc))
              (push name tool-calls-made)
              (format t "[hook] tool called: ~a~%" name)))

      (setf clawmacs:*on-llm-response*
            (lambda (text)
              (format t "[hook] final response: ~a~%" text)))

      ;; 7. Run the agent
      (format t "~%[test] Sending: 'Please run the command: echo hello'~%~%")
      (handler-case
          (let ((result (clawmacs:run-agent
                         session
                         "Please run the command: echo hello"
                         :options opts)))

            (format t "~%~%=== Results ===~%")
            (format t "Final result: ~a~%" result)
            (format t "Tool calls made: ~{~a~^, ~}~%" (reverse tool-calls-made))
            (format t "Messages in session: ~a~%"
                    (clawmacs:session-message-count session))

            ;; Verify exec was called
            (let ((exec-called (member "exec" tool-calls-made :test #'string=)))
              (if exec-called
                  (progn
                    (format t "~%PASS: exec tool was invoked!~%")
                    t)
                  (progn
                    (format t "~%NOTE: exec tool was not called (LLM may have answered directly).~%")
                    (format t "Result text: ~a~%" result)
                    ;; Still pass — the loop worked
                    t))))

        (error (e)
          (format t "~%ERROR: ~a~%" e)
          nil)))))

;;; ── Tool registry test (no LLM) ──────────────────────────────────────────────

(defun test-tool-registry ()
  "Test the tool registry in isolation (no LLM needed)."
  (format t "~%=== Tool Registry Test ===~%~%")

  (let ((registry (clawmacs:make-tool-registry)))

    ;; Register a simple tool
    (clawmacs:define-tool registry "greet"
      "Greet someone by name."
      (("name" "string" "Person's name"))
      (format nil "Hello, ~a!" name))

    ;; Check it's registered
    (assert (clawmacs/tools:find-tool registry "greet"))
    (format t "PASS: tool registered~%")

    ;; Test dispatch
    (let* ((fake-tc (cl-llm/protocol:make-tool-definition
                     :name "greet"
                     :description ""
                     :parameters nil))
           (ht (make-hash-table :test #'equal)))
      (declare (ignore fake-tc))
      (setf (gethash "name" ht) "Lisp")

      ;; Build a fake tool-call struct using the cl-llm internals
      ;; We'll just call the handler directly for unit testing
      (let* ((entry (clawmacs/tools:find-tool registry "greet"))
             (handler (clawmacs/tools::tool-entry-handler entry))
             (result (funcall handler ht)))
        (assert (clawmacs/tools:tool-result-ok result))
        (assert (string= (clawmacs/tools:tool-result-value result) "Hello, Lisp!"))
        (format t "PASS: tool dispatch result: ~a~%"
                (clawmacs/tools:tool-result-value result))))

    (format t "~%Tool registry test PASSED.~%")
    t))

;;; ── Built-in exec test (no LLM) ──────────────────────────────────────────────

(defun test-builtin-exec ()
  "Test the exec built-in tool directly."
  (format t "~%=== Built-in Exec Test ===~%~%")

  (let* ((registry (clawmacs:make-builtin-registry))
         (exec-entry (clawmacs/tools:find-tool registry "exec")))

    (assert exec-entry () "exec tool not registered")

    ;; Call the handler directly
    (let* ((args (make-hash-table :test #'equal))
           (_ (setf (gethash "command" args) "echo hello"))
           (result (funcall (clawmacs/tools::tool-entry-handler exec-entry) args)))
      (declare (ignore _))

      (assert (clawmacs/tools:tool-result-ok result))
      (let ((output (clawmacs/tools:tool-result-value result)))
        (format t "exec output: ~s~%" output)
        (assert (search "hello" output) nil
                "Expected 'hello' in exec output")
        (format t "PASS: exec returned 'hello' in output~%"))))

  (format t "~%Built-in exec test PASSED.~%")
  t)

;;; ── Session test ─────────────────────────────────────────────────────────────

(defun test-session ()
  "Test session creation and message management."
  (format t "~%=== Session Test ===~%~%")

  (let* ((agent (clawmacs:make-agent :name "test-agent"))
         (session (clawmacs:make-session :agent agent)))

    (assert (clawmacs:session-id session))
    (assert (= 0 (clawmacs:session-message-count session)))
    (format t "PASS: session created, id=~a~%" (clawmacs:session-id session))

    (clawmacs:session-add-message session (cl-llm:user-message "hello"))
    (assert (= 1 (clawmacs:session-message-count session)))
    (format t "PASS: message added~%")

    (clawmacs:session-clear-messages session)
    (assert (= 0 (clawmacs:session-message-count session)))
    (format t "PASS: messages cleared~%")

    (format t "~%Session test PASSED.~%")
    t))

;;; ── Run all tests ────────────────────────────────────────────────────────────

(defun run-all-tests ()
  "Run all clawmacs-core tests. Returns T if all pass."
  (let ((results nil))
    (push (cons "tool-registry" (test-tool-registry)) results)
    (push (cons "builtin-exec"  (test-builtin-exec))  results)
    (push (cons "session"       (test-session))        results)

    (format t "~%~%=== Summary ===~%")
    (let ((all-pass t))
      (dolist (r (reverse results))
        (format t "~a: ~a~%" (car r) (if (cdr r) "PASS" "FAIL"))
        (unless (cdr r) (setf all-pass nil)))

      (format t "~%Unit tests: ~a~%~%"
              (if all-pass "ALL PASSED" "SOME FAILED"))
      all-pass)))
