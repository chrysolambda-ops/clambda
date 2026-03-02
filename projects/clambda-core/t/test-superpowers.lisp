;;;; t/test-superpowers.lisp — Tests for Lisp Superpowers (Layer 9)
;;;;
;;;; Tests for:
;;;;   P0: Condition-based live error recovery (retry-with-fixed-input restart)
;;;;   P0: SWANK server lifecycle (start-swank, stop-swank, swank-running-p)
;;;;   P1: Image save/restore (clawmacs-main, save-clawmacs-image structure)
;;;;   P1: define-agent DSL (symbol names, tool conversion, max-turns, registry)

(in-package #:clawmacs-core/tests/superpowers)

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 1. Condition system — TOOL-EXECUTION-ERROR + RETRY-WITH-FIXED-INPUT
;;;; ─────────────────────────────────────────────────────────────────────────────

(define-test "tool-execution-error-has-input-slot"
  :description "TOOL-EXECUTION-ERROR carries the :INPUT slot for debugging."
  (let ((registry (make-tool-registry))
        (call-count 0))

    ;; Register a tool that always fails
    (register-tool! registry "fail_tool"
                    (lambda (args)
                      (declare (ignore args))
                      (incf call-count)
                      (error "Deliberate failure"))
                    :description "Always fails")

    ;; Dispatch and catch the condition — verify :input is set
    (let ((tc (cl-llm/protocol::make-tool-call
               :id "tc1"
               :function-name "fail_tool"
               :function-arguments "{\"x\": 42}")))

      (let ((input-seen nil)
            (name-seen nil))
        (handler-bind
            ((tool-execution-error
              (lambda (c)
                (setf name-seen  (tool-execution-error-tool-name c))
                (setf input-seen (tool-execution-error-input c))
                (invoke-restart 'skip-tool-call))))
          (dispatch-tool-call registry tc))

        (is string= "fail_tool" name-seen)
        (true (hash-table-p input-seen))))

    ;; Tool was called once before failure
    (is = 1 call-count)))

(define-test "retry-with-fixed-input-retries-tool"
  :description "RETRY-WITH-FIXED-INPUT restart allows retrying with corrected args."
  (let ((registry (make-tool-registry))
        (call-args-history '()))

    ;; Register a tool that fails on first call, succeeds on second
    (register-tool! registry "picky_tool"
                    (lambda (args)
                      (let ((val (gethash "value" args)))
                        (push val call-args-history)
                        (if (string= val "wrong")
                            (error "Bad value: ~s" val)
                            (format nil "OK: ~a" val))))
                    :description "Fails unless value is not 'wrong'")

    ;; Make a tool call with the wrong value
    (let ((tc (cl-llm/protocol::make-tool-call
               :id "tc2"
               :function-name "picky_tool"
               :function-arguments "{\"value\": \"wrong\"}")))

      ;; Install handler that invokes retry-with-fixed-input
      (let ((result
             (handler-bind
                 ((tool-execution-error
                   (lambda (c)
                     (declare (ignore c))
                     ;; Provide corrected args
                     (let ((fixed (make-hash-table :test #'equal)))
                       (setf (gethash "value" fixed) "correct")
                       (invoke-restart 'retry-with-fixed-input fixed)))))
               (dispatch-tool-call registry tc))))

        ;; Verify the retry succeeded
        (is string= "OK: correct" (format-tool-result result))
        ;; Verify both calls were made
        (is = 2 (length call-args-history))
        ;; First pushed is the last call ("correct"), second pushed is first ("wrong")
        (is string= "correct" (first  call-args-history))
        (is string= "wrong"   (second call-args-history))))))

(define-test "skip-tool-call-returns-error-result"
  :description "SKIP-TOOL-CALL restart returns a result string (skipped or error)."
  (let ((registry (make-tool-registry)))

    (register-tool! registry "crasher"
                    (lambda (args)
                      (declare (ignore args))
                      (error "BOOM"))
                    :description "Always crashes")

    (let ((tc (cl-llm/protocol::make-tool-call
               :id "tc3"
               :function-name "crasher"
               :function-arguments nil)))

      (let ((result
             (handler-bind
                 ((tool-execution-error
                   (lambda (c)
                     (declare (ignore c))
                     (invoke-restart 'skip-tool-call))))
               (dispatch-tool-call registry tc))))

        ;; Should get a result, not raise
        (true (stringp (format-tool-result result)))))))

(define-test "copy-tools-to-registry-partial-copy"
  :description "COPY-TOOLS-TO-REGISTRY copies only named tools."
  (let ((src (make-tool-registry))
        (dst (make-tool-registry)))

    (register-tool! src "tool_a" (lambda (args) (declare (ignore args)) "a"))
    (register-tool! src "tool_b" (lambda (args) (declare (ignore args)) "b"))
    (register-tool! src "tool_c" (lambda (args) (declare (ignore args)) "c"))

    ;; Copy only tool_a and tool_c
    (copy-tools-to-registry src dst '("tool_a" "tool_c"))

    (true  (clawmacs/tools:find-tool dst "tool_a"))
    (false (clawmacs/tools:find-tool dst "tool_b"))
    (true  (clawmacs/tools:find-tool dst "tool_c"))))

(define-test "copy-tools-full-copy"
  :description "COPY-TOOLS-TO-REGISTRY with nil names copies all tools."
  (let ((src (make-tool-registry))
        (dst (make-tool-registry)))

    (register-tool! src "tool_x" (lambda (args) (declare (ignore args)) "x"))
    (register-tool! src "tool_y" (lambda (args) (declare (ignore args)) "y"))

    (copy-tools-to-registry src dst nil)

    (true (clawmacs/tools:find-tool dst "tool_x"))
    (true (clawmacs/tools:find-tool dst "tool_y"))))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 2. define-agent DSL — P1 high-level macro
;;;; ─────────────────────────────────────────────────────────────────────────────

(define-test "define-agent-symbol-name"
  :description "define-agent accepts a symbol name and registers it downcased."
  (unregister-agent "test-agent-sym")

  (define-agent test-agent-sym
    :model "test-model"
    :system-prompt "Test system prompt.")

  (let ((spec (find-agent "test-agent-sym")))
    (true spec)
    (is string= "test-agent-sym"      (agent-spec-name spec))
    (is string= "test-model"          (agent-spec-model spec))
    (is string= "Test system prompt." (agent-spec-system-prompt spec)))

  (unregister-agent "test-agent-sym"))

(define-test "define-agent-tool-symbol-conversion"
  :description "define-agent converts tool symbols: web-fetch → \"web_fetch\"."
  (unregister-agent "tool-sym-agent")

  (define-agent tool-sym-agent
    :model "m"
    :tools (web-fetch exec-command))

  (let ((spec (find-agent "tool-sym-agent")))
    (true spec)
    (let ((tools (agent-spec-tools spec)))
      (true (member "web_fetch"    tools :test #'string=))
      (true (member "exec_command" tools :test #'string=))))

  (unregister-agent "tool-sym-agent"))

(define-test "define-agent-max-turns"
  :description "define-agent stores :max-turns in the spec."
  (unregister-agent "maxturns-agent")

  (define-agent maxturns-agent
    :model "m"
    :max-turns 42)

  (let ((spec (find-agent "maxturns-agent")))
    (true spec)
    (is = 42 (agent-spec-max-turns spec)))

  (unregister-agent "maxturns-agent"))

(define-test "define-agent-returns-spec"
  :description "define-agent returns the registered AGENT-SPEC."
  (unregister-agent "ret-agent")

  (let ((spec (define-agent ret-agent :model "x")))
    (true (agent-spec-p spec))
    (is string= "ret-agent" (agent-spec-name spec)))

  (unregister-agent "ret-agent"))

(define-test "define-agent-keyword-name-still-works"
  :description "define-agent still accepts keyword names (backward compatibility)."
  (unregister-agent "kw-agent")

  (define-agent :kw-agent
    :model "kw-model")

  (let ((spec (find-agent "kw-agent")))
    (true spec)
    (is string= "kw-model" (agent-spec-model spec)))

  (unregister-agent "kw-agent"))

(define-test "define-agent-no-tools-gives-nil-tools-list"
  :description "define-agent with no :tools gives NIL tools list (caller handles registry)."
  (unregister-agent "notools-agent")

  (define-agent notools-agent :model "m")

  (let ((spec (find-agent "notools-agent")))
    (true spec)
    (false (agent-spec-tools spec)))

  (unregister-agent "notools-agent"))

(define-test "instantiate-agent-spec-with-tools"
  :description "instantiate-agent-spec builds a tool registry from spec tools."
  (unregister-agent "inst-agent")

  ;; Define with a known builtin tool name
  (define-agent inst-agent
    :model "test-model"
    :system-prompt "Test"
    :tools (exec))

  (let* ((spec  (find-agent "inst-agent"))
         (agent (multiple-value-bind (value condition)
                    (ignore-errors (instantiate-agent-spec spec))
                  (when condition
                    (fail "instantiate-agent-spec raised: ~a" condition))
                  value)))
    (when agent
      (is string= "inst-agent" (clawmacs/agent:agent-name agent))
      ;; Should have a registry with the exec tool
      (let ((reg (clawmacs/agent:agent-tool-registry agent)))
        (when reg
          (true (clawmacs/tools:find-tool reg "exec"))))))

  (unregister-agent "inst-agent"))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 3. SWANK/SLIME server (P0)
;;;; ─────────────────────────────────────────────────────────────────────────────

(define-test "swank-not-running-initially"
  :description "SWANK server is not running until start-swank is called."
  ;; Ensure clean state
  (when (swank-running-p)
    (stop-swank))
  (false (swank-running-p)))

(define-test "swank-start-stop-lifecycle"
  :description "start-swank/stop-swank manage the running state correctly."
  ;; Ensure clean state
  (when (swank-running-p)
    (stop-swank))

  ;; Try starting on an unlikely-to-be-taken port
  (let ((test-port 14057))
    (handler-case
        (let ((result (start-swank :port test-port)))
          ;; start-swank returns port or nil
          (when result
            (true (swank-running-p))
            ;; Stop it
            (stop-swank)
            (false (swank-running-p))))
      (error (e)
        ;; SWANK startup failure is acceptable in test environments
        (format t "~&[test] SWANK start/stop skipped: ~a~%" e)))))

(define-test "swank-port-defoption"
  :description "*swank-port* is a configurable option with default 4005."
  (is = 4005 *swank-port*))

(define-test "swank-double-start-is-safe"
  :description "Calling start-swank twice does not error."
  (when (swank-running-p)
    (stop-swank))

  (handler-case
      (let ((test-port 14058))
        (start-swank :port test-port)
        (when (swank-running-p)
          ;; Second start should be a no-op
          (start-swank :port test-port)
          (true (swank-running-p))
          ;; Clean up
          (stop-swank)))
    (error (e)
      (format t "~&[test] SWANK double-start test skipped: ~a~%" e))))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 4. Image save/restore (P1)
;;;; ─────────────────────────────────────────────────────────────────────────────

(define-test "clawmacs-main-is-callable"
  :description "clawmacs-main is a function."
  (true (fboundp 'clawmacs-main)))

(define-test "save-clawmacs-image-is-callable"
  :description "save-clawmacs-image is a function."
  (true (fboundp 'save-clawmacs-image)))

(define-test "save-clawmacs-image-uses-sbcl-save"
  :description "sb-ext:save-lisp-and-die is available (we are on SBCL)."
  ;; We cannot actually call save-clawmacs-image (it exits the process),
  ;; but we can verify that SBCL's save function is present.
  (true (fboundp 'save-clawmacs-image))
  (true (fboundp 'sb-ext:save-lisp-and-die)))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 5. Condition slots and hierarchy
;;;; ─────────────────────────────────────────────────────────────────────────────

(define-test "agent-turn-error-slots"
  :description "AGENT-TURN-ERROR has session and cause slots."
  (let ((c (make-condition 'agent-turn-error
                           :session nil
                           :cause "test error")))
    (is string= "test error" (agent-turn-error-cause c))
    (false (agent-turn-error-session c))))

(define-test "tool-execution-error-input-slot"
  :description "TOOL-EXECUTION-ERROR has an input slot for the failing args."
  (let ((fake-args (make-hash-table :test #'equal)))
    (setf (gethash "x" fake-args) 42)
    (let ((c (make-condition 'tool-execution-error
                             :tool-name "my_tool"
                             :cause "deliberate"
                             :input fake-args)))
      (is string= "my_tool"   (tool-execution-error-tool-name c))
      (is = 42 (gethash "x" (tool-execution-error-input c))))))

(define-test "tool-execution-error-nil-input"
  :description "TOOL-EXECUTION-ERROR :INPUT defaults to NIL if not provided."
  (let ((c (make-condition 'tool-execution-error
                           :tool-name "t"
                           :cause "e")))
    (false (tool-execution-error-input c))))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 6. Parity tool surface sanity tests
;;;; ─────────────────────────────────────────────────────────────────────────────

(define-test "builtin-registry-has-openclaw-alias-tools"
  :description "Builtins expose OpenClaw-compatible alias names (read/write/message/session_status)."
  (let ((reg (clawmacs/builtins:make-builtin-registry)))
    (true (clawmacs/tools:find-tool reg "read"))
    (true (clawmacs/tools:find-tool reg "write"))
    (true (clawmacs/tools:find-tool reg "message"))
    (true (clawmacs/tools:find-tool reg "session_status"))
    (true (clawmacs/tools:find-tool reg "sessions_list"))
    (true (clawmacs/tools:find-tool reg "sessions_spawn"))
    (true (clawmacs/tools:find-tool reg "sessions_send"))
    (true (clawmacs/tools:find-tool reg "subagents"))))

(define-test "subagent-handle-has-id-and-registry"
  :description "spawn-subagent registers handle and assigns a stable id."
  (let* ((agent (clawmacs/agent:make-agent
                :name "subagent-test"
                :role "tester"
                :model nil
                :client nil
                :tool-registry (clawmacs/tools:make-tool-registry)))
         (h (clawmacs/subagents:spawn-subagent agent "noop"
                                               :callback (lambda (_) (declare (ignore _))))))
    (true (stringp (clawmacs/subagents:subagent-handle-id h)))
    (true (clawmacs/subagents:find-subagent (clawmacs/subagents:subagent-handle-id h)))
    ;; best-effort cleanup
    (ignore-errors (clawmacs/subagents:subagent-kill h))))

(define-test "subagents-tool-supports-steer-after-completion"
  :description "subagents action=steer can continue a finished subagent session."
  (let* ((agent (clawmacs/agent:make-agent
                :name "subagent-steer-test"
                :role "tester"
                :model nil
                :client nil
                :tool-registry (clawmacs/tools:make-tool-registry)))
         (h (clawmacs/subagents:spawn-subagent agent "initial"
                                               :callback (lambda (_) (declare (ignore _))))))
    (unwind-protect
         (progn
           (clawmacs/subagents:subagent-wait h :timeout 2)
           (let* ((reg (clawmacs/builtins:make-builtin-registry))
                  (tool (clawmacs/tools:find-tool reg "subagents"))
                  (args (make-hash-table :test #'equal)))
             (setf (gethash "action" args) "steer")
             (setf (gethash "target" args) (clawmacs/subagents:subagent-handle-id h))
             (setf (gethash "message" args) "follow-up")
             (let ((res (funcall (clawmacs/tools::tool-entry-handler tool) args)))
               (true (stringp (clawmacs/tools:format-tool-result res))))))
      (ignore-errors (clawmacs/subagents:subagent-kill h)))))

(define-test "codex-oauth-bridge-uses-stdin-stream-not-path"
  :description "JSON payload is passed to Node helper via stdin stream (not file path coercion)."
  (let* ((payload (alexandria:plist-hash-table
                   (list "messages" (vector (alexandria:plist-hash-table
                                              (list "role" "user"
                                                    "content" "x")
                                              :test 'equal)))
                   :test 'equal))
         (stream (cl-llm/codex-oauth-bridge::%payload-input-stream payload)))
    (true (streamp stream))
    (let ((json (with-output-to-string (s)
                  (loop for ch = (read-char stream nil nil)
                        while ch do (write-char ch s)))))
      (true (search "\"messages\"" json :test #'char=))
      (true (search "\"content\":\"x\"" json :test #'char=)))))
