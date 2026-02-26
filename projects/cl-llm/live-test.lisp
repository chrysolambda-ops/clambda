;;;; live-test.lisp — Live integration test against local Ollama (qwen2:0.5b)

(pushnew (truename #p"./") asdf:*central-registry* :test #'equal)
(ql:quickload "cl-llm" :silent t)

(defparameter *client*
  (cl-llm:make-client
   :base-url "http://localhost:11434/v1"
   :api-key "ollama-local"
   :model "qwen2:0.5b"))

(let ((pass 0) (fail 0))

  ;; Test 1: basic chat
  (format t "~%[Test 1: simple-chat]~%")
  (handler-case
      (let ((resp (cl-llm:simple-chat *client* "Say the word 'pong' and nothing else.")))
        (format t "  Response: ~s~%" resp)
        (if (stringp resp)
            (progn (incf pass) (format t "  PASS: Got string response~%"))
            (progn (incf fail) (format t "  FAIL: Response is not a string~%"))))
    (error (e)
      (incf fail)
      (format t "  FAIL Error: ~a~%" e)))

  ;; Test 2: full chat with response object
  (format t "~%[Test 2: full chat response]~%")
  (handler-case
      (let* ((response (cl-llm:chat *client*
                                    (list (cl-llm:system-message "Be brief.")
                                          (cl-llm:user-message "What is 2+2? Answer with only the number."))))
             (choice (first (cl-llm:response-choices response)))
             (msg    (cl-llm:choice-message choice))
             (usage  (cl-llm:response-usage response)))
        (format t "  Model: ~s~%" (cl-llm:response-model response))
        (format t "  Content: ~s~%" (cl-llm:message-content msg))
        (format t "  Finish reason: ~s~%" (cl-llm:choice-finish-reason choice))
        (when usage
          (format t "  Tokens: ~a prompt, ~a completion, ~a total~%"
                  (cl-llm:usage-prompt-tokens usage)
                  (cl-llm:usage-completion-tokens usage)
                  (cl-llm:usage-total-tokens usage)))
        (if (and msg (stringp (cl-llm:message-content msg)))
            (progn (incf pass) (format t "  PASS: Full response object works~%"))
            (progn (incf fail) (format t "  FAIL: Response object broken~%"))))
    (error (e)
      (incf fail)
      (format t "  FAIL Error: ~a~%" e)))

  ;; Test 3: streaming
  (format t "~%[Test 3: streaming]~%")
  (handler-case
      (let ((chunks 0)
            (result nil))
        (setf result
              (cl-llm:chat-stream
               *client*
               (list (cl-llm:user-message "Count: 1, 2, 3"))
               (lambda (delta)
                 (incf chunks)
                 (write-string delta)
                 (force-output))))
        (terpri)
        (format t "  Chunks: ~a~%" chunks)
        (format t "  Full text: ~s~%" result)
        (if (and (stringp result) (> (length result) 0))
            (progn (incf pass) (format t "  PASS: Streaming works (~a chunks)~%" chunks))
            (progn (incf fail) (format t "  FAIL: Streaming broken~%"))))
    (error (e)
      (incf fail)
      (format t "  FAIL Streaming error: ~a~%" e)))

  ;; Test 4: request-options
  (format t "~%[Test 4: request-options]~%")
  (handler-case
      (let* ((opts (cl-llm:make-request-options :temperature 0.1 :max-tokens 20))
             (resp (cl-llm:simple-chat *client* "Say hello.")))
        (declare (ignore opts))
        (format t "  Response: ~s~%" resp)
        (if (stringp resp)
            (progn (incf pass) (format t "  PASS: Options accepted~%"))
            (progn (incf fail) (format t "  FAIL: Options test failed~%"))))
    (error (e)
      (incf fail)
      (format t "  FAIL Error: ~a~%" e)))

  ;; Summary
  (format t "~%=== Live Test Results: ~a pass, ~a fail ===~%" pass fail)
  (sb-ext:exit :code (if (zerop fail) 0 1)))
