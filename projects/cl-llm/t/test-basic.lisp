;;;; t/test-basic.lisp — Basic smoke tests for cl-llm

(in-package #:cl-llm/tests)

;;; Minimal test framework (no deps beyond what cl-llm already needs)
(defvar *pass* 0)
(defvar *fail* 0)

(defmacro is (form &optional description)
  `(if ,form
       (progn (incf *pass*)
              (format t "  PASS: ~a~%" ,(or description (format nil "~s" form))))
       (progn (incf *fail*)
              (format t "  FAIL: ~a~%" ,(or description (format nil "~s" form))))))

(defmacro is-equal (expected actual &optional description)
  (let ((e (gensym)) (a (gensym)))
    `(let ((,e ,expected) (,a ,actual))
       (if (equal ,e ,a)
           (progn (incf *pass*)
                  (format t "  PASS: ~a → ~s~%"
                          ,(or description "is-equal") ,a))
           (progn (incf *fail*)
                  (format t "  FAIL: ~a → expected ~s, got ~s~%"
                          ,(or description "is-equal") ,e ,a))))))

(defmacro signals (condition-type form &optional description)
  `(handler-case
       (progn ,form
              (incf *fail*)
              (format t "  FAIL: ~a (no condition signalled)~%"
                      ,(or description (format nil "~s signals ~s" form condition-type))))
     (,condition-type ()
       (incf *pass*)
       (format t "  PASS: ~a (signalled ~s)~%"
               ,(or description (format nil "~s" form)) ',condition-type))))

;;; ── Unit tests (no network) ──────────────────────────────────────────────────

(defun test-message-construction ()
  (format t "~%[Message construction]~%")
  (let ((sm (system-message "You are helpful."))
        (um (user-message "Hello!"))
        (am (assistant-message "Hi there!" :tool-calls nil))
        (tm (tool-message "42" "call-1")))
    (is-equal :system    (message-role sm)    "system-message role")
    (is-equal "You are helpful." (message-content sm) "system-message content")
    (is-equal :user      (message-role um)    "user-message role")
    (is-equal :assistant (message-role am)    "assistant-message role")
    (is-equal :tool      (message-role tm)    "tool-message role")
    (is-equal "call-1"   (message-tool-call-id tm) "tool-message call-id")))

(defun test-json-roundtrip ()
  (format t "~%[JSON roundtrip]~%")
  (let* ((msg (user-message "hi"))
         (ht  (cl-llm/protocol::message->ht msg))
         (str (com.inuoe.jzon:stringify ht))
         (back (com.inuoe.jzon:parse str)))
    (is-equal "user" (gethash "role" back)    "role survives roundtrip")
    (is-equal "hi"   (gethash "content" back) "content survives roundtrip")))

(defun test-request-options ()
  (format t "~%[Request options]~%")
  (let* ((opts (make-request-options :temperature 0.7 :max-tokens 100))
         (ht   (cl-llm/protocol::build-request-ht
                "test-model"
                (list (user-message "hi"))
                opts
                nil))
         (str  (com.inuoe.jzon:stringify ht))
         (back (com.inuoe.jzon:parse str)))
    (is-equal 0.7d0 (gethash "temperature" back) "temperature in request")
    (is-equal 100   (gethash "max_tokens" back)   "max_tokens in request")
    (is-equal "test-model" (gethash "model" back) "model in request")))

(defun test-conditions ()
  (format t "~%[Conditions]~%")
  (signals cl-llm:parse-error*
    (cl-llm/protocol::parse-response "not json at all")
    "bad JSON signals parse-error*")
  ;; api-error from well-formed error response
  (signals cl-llm:api-error
    (cl-llm/protocol::parse-response
     "{\"error\":{\"type\":\"invalid_request_error\",\"code\":null,\"message\":\"test\"}}")
    "API error object signals api-error"))

(defun test-tool-registry ()
  (format t "~%[Tool registry]~%")
  (let* ((reg (make-registry))
         (result nil))
    (register-tool reg "echo"
                   (lambda (args)
                     (setf result (gethash "text" args))
                     result)
                   :description "Echo input"
                   :parameters '(:|type| "object"
                                 :|properties| (:|text| (:|type| "string"))
                                 :|required| #("text")))
    (let ((tc (cl-llm/protocol::make-tool-call
               :id "call-1"
               :function-name "echo"
               :function-arguments "{\"text\":\"hello\"}")))
      (dispatch-tool-call reg tc)
      (is-equal "hello" result "dispatch-tool-call extracts arg"))))

(defun test-sse-parsing ()
  (format t "~%[SSE parsing]~%")
  (let ((chunks '()))
    (flet ((collect (delta)
             (when delta (push delta chunks))))
      ;; Normal chunk
      (cl-llm/streaming:parse-sse-line
       "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}"
       #'collect)
      ;; Empty line → nothing
      (cl-llm/streaming:parse-sse-line "" #'collect)
      ;; [DONE] → nothing
      (cl-llm/streaming:parse-sse-line "data: [DONE]" #'collect)
      ;; Another chunk
      (cl-llm/streaming:parse-sse-line
       "data: {\"choices\":[{\"delta\":{\"content\":\" world\"}}]}"
       #'collect))
    (is-equal '(" world" "Hello") chunks "SSE chunks collected correctly")))

;;; ── Network tests (require live Ollama) ──────────────────────────────────────

;; Ollama endpoint — primary is remote, fallback to local
(defparameter *ollama-url* "http://192.168.1.189:11434/v1")
(defparameter *ollama-model* "llama3.1:8b")
;; For local fallback (qwen2:0.5b available locally):
;; (defparameter *ollama-url* "http://localhost:11434/v1")
;; (defparameter *ollama-model* "qwen2:0.5b")

(defun test-live-simple-chat ()
  (format t "~%[Live: simple-chat via Ollama]~%")
  (handler-case
      (let* ((client (make-client :base-url *ollama-url*
                                  :api-key "ollama-local"
                                  :model *ollama-model*))
             (response (simple-chat client "Reply with exactly: pong"
                                    :system "You are a ping-pong bot. Reply only with 'pong'.")))
        (format t "  Response: ~s~%" response)
        (is (stringp response) "response is a string")
        (is (> (length response) 0) "response is non-empty"))
    (error (e)
      (incf *fail*)
      (format t "  FAIL (network): ~a~%" e))))

(defun test-live-streaming ()
  (format t "~%[Live: streaming via Ollama]~%")
  (handler-case
      (let* ((client (make-client :base-url *ollama-url*
                                  :api-key "ollama-local"
                                  :model *ollama-model*))
             (chunks-seen 0)
             (full-text (chat-stream
                         client
                         (list (user-message "Count from 1 to 5, one number per line."))
                         (lambda (delta)
                           (incf chunks-seen)
                           (write-string delta))
                         :model *ollama-model*)))
        (terpri)
        (format t "  Chunks received: ~a~%" chunks-seen)
        (format t "  Full text: ~s~%" full-text)
        (is (> chunks-seen 1) "streaming received multiple chunks")
        (is (stringp full-text) "streaming returns string"))
    (error (e)
      (incf *fail*)
      (format t "  FAIL (network): ~a~%" e))))

;;; ── Entry point ──────────────────────────────────────────────────────────────

(defun run-tests (&key (live t))
  "Run all tests. Set LIVE NIL to skip network tests."
  (setf *pass* 0 *fail* 0)
  (format t "~%═══ cl-llm test suite ═══~%")
  ;; Unit tests
  (test-message-construction)
  (test-json-roundtrip)
  (test-request-options)
  (test-conditions)
  (test-tool-registry)
  (test-sse-parsing)
  ;; Live tests
  (when live
    (test-live-simple-chat)
    (test-live-streaming))
  (format t "~%─── Results: ~a pass, ~a fail ───~%"
          *pass* *fail*)
  (zerop *fail*))
