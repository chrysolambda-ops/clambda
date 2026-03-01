(ql:quickload :cl-llm :silent t)
;; Test build-anthropic-request-ht
(let* ((msgs (list (cl-llm:system-message "You are helpful.")
                   (cl-llm:user-message "Hello")))
       (ht (cl-llm/protocol::build-anthropic-request-ht "claude-opus-4-5" msgs nil nil))
       (json (com.inuoe.jzon:stringify ht :pretty t)))
  (format t "Request JSON:~%~a~%" json))
(quit)
