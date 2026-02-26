;;;; try-load.lisp — Load and sanity-check cl-llm, then test against Ollama

;; Register with ASDF
(pushnew (truename #p"./") asdf:*central-registry* :test #'equal)

;; Load
(handler-case
    (progn
      (ql:quickload "cl-llm" :silent nil)
      (format t "~%✓ cl-llm loaded successfully~%"))
  (error (e)
    (format t "~%✗ Load FAILED: ~a~%" e)
    (sb-ext:exit :code 1)))

;; Unit tests (no network)
(load "t/packages.lisp")
(load "t/test-basic.lisp")

(format t "~%--- Running unit tests only ---~%")
(let ((result (cl-llm/tests:run-tests :live nil)))
  (if result
      (format t "~%✓ All unit tests passed~%")
      (format t "~%✗ Some unit tests FAILED~%")))

;; Live test against our actual Ollama
(format t "~%--- Live Ollama test ---~%")
(handler-case
    (let* ((client (cl-llm:make-client
                    :base-url "http://192.168.1.189:11434/v1"
                    :api-key "ollama-local"
                    :model "llama3.1:8b"))
           (response (cl-llm:simple-chat client "Reply with exactly the word: pong"
                                         :system "You are a bot. Reply only with 'pong'.")))
      (format t "  Response: ~s~%" response)
      (format t "  ✓ Basic chat works!~%"))
  (error (e)
    (format t "  ✗ Live chat FAILED: ~a~%" e)))

;; Streaming test
(format t "~%--- Streaming Ollama test ---~%")
(handler-case
    (let* ((client (cl-llm:make-client
                    :base-url "http://192.168.1.189:11434/v1"
                    :api-key "ollama-local"
                    :model "llama3.1:8b"))
           (chunks 0)
           (result (cl-llm:chat-stream
                    client
                    (list (cl-llm:user-message "Say 'hello streaming' and nothing else."))
                    (lambda (delta)
                      (incf chunks)
                      (write-string delta)
                      (force-output)))))
      (terpri)
      (format t "  Chunks: ~a, full text: ~s~%" chunks result)
      (format t "  ✓ Streaming works!~%"))
  (error (e)
    (format t "  ✗ Streaming FAILED: ~a~%" e)))

(sb-ext:exit :code 0)
