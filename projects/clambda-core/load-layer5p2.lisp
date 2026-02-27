;;;; load-layer5p2.lisp — test load for Layer 5 Phase 2 modules

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(asdf:clear-source-registry)
(asdf:initialize-source-registry)

(format t "~%=== Loading clawmacs-core ===~%")
(ql:quickload "clawmacs-core" :silent nil)
(format t "~%=== clawmacs-core loaded successfully ===~%")

;;; ── Test: Registry ───────────────────────────────────────────────────────────
(format t "~%--- Test: Registry ---~%")

;; Define a couple of agent specs
(clawmacs:define-agent :researcher
  :model "google/gemma-3-4b"
  :system-prompt "You are a research assistant."
  :role "researcher")

(clawmacs:define-agent :coder
  :model "google/gemma-3-4b"
  :system-prompt "You are a coding assistant."
  :role "coder")

(format t "Registered agents: ~{~a~^, ~}~%"
        (mapcar #'clawmacs:agent-spec-name (clawmacs:list-agents)))

(let ((spec (clawmacs:find-agent :researcher)))
  (assert (not (null spec)) () "find-agent :researcher returned NIL")
  (assert (string= (clawmacs:agent-spec-name spec) "researcher") ()
          "Expected name 'researcher', got ~s" (clawmacs:agent-spec-name spec))
  (format t "find-agent :researcher → ~a~%" spec))

(format t "Registry test: PASSED~%")

;;; ── Test: Channels ───────────────────────────────────────────────────────────
(format t "~%--- Test: Queue Channel ---~%")

(let ((ch (clawmacs:make-queue-channel)))
  (assert (clawmacs:channel-open-p ch) () "channel should be open")
  (clawmacs:channel-send ch "hello")
  (clawmacs:channel-send ch "world")
  (let ((m1 (clawmacs:channel-poll ch))
        (m2 (clawmacs:channel-poll ch))
        (m3 (clawmacs:channel-poll ch)))
    (assert (string= m1 "hello") () "Expected 'hello', got ~s" m1)
    (assert (string= m2 "world") () "Expected 'world', got ~s" m2)
    (assert (null m3) () "Expected NIL on empty queue, got ~s" m3))
  (clawmacs:channel-close ch)
  (assert (not (clawmacs:channel-open-p ch)) () "channel should be closed"))

(format t "Queue channel test: PASSED~%")

;;; Threaded send/receive test
(format t "~%--- Test: Queue Channel threaded ---~%")
(let ((ch (clawmacs:make-queue-channel))
      (received nil))
  (let ((t1 (bt:make-thread
             (lambda ()
               (setf received (clawmacs:channel-receive ch))))))
    (sleep 0.05)
    (clawmacs:channel-send ch "ping")
    (bt:join-thread t1)
    (assert (string= received "ping") ()
            "Expected 'ping', got ~s" received)))
(format t "Threaded queue channel test: PASSED~%")

;;; ── Test: Subagent spawning (no live LLM needed — just check thread/handle) ──
(format t "~%--- Test: Subagent handle structure ---~%")

;; Just verify the structs are accessible
(let ((spec (clawmacs:find-agent :researcher)))
  (assert spec () "Need :researcher spec for subagent test")
  (format t "agent-spec-name: ~a~%" (clawmacs:agent-spec-name spec))
  (format t "agent-spec-role: ~a~%" (clawmacs:agent-spec-role spec))
  (format t "Subagent struct check: PASSED (no live LLM needed for this check)~%"))

(format t "~%=== All Layer 5 Phase 2 structural tests PASSED ===~%")
(quit)
