;;;; gui-test.lisp — Launch the clawmacs-gui window for visual testing
;;;;
;;;; Run with:
;;;;   export DISPLAY=:11.0
;;;;   sbcl --load gui-test.lisp

(asdf:clear-configuration)
(asdf:initialize-source-registry)

(format t "~%Loading clawmacs-gui...~%")
(ql:quickload "clawmacs-gui" :silent t)
(format t "Loaded.~%")

(format t "~%DISPLAY=~a~%" (uiop:getenv "DISPLAY"))

;; Check if we can connect to an X display
(handler-case
    (progn
      (format t "Starting GUI (will block until window is closed)...~%")
      (format t "Model: ~a~%~%" clawmacs-gui::*default-model*)

      ;; Launch with test session
      (let ((session (clawmacs-gui:make-gui-session
                      :name  "Gensym"
                      :role  "assistant"
                      :model "google/gemma-3-4b")))
        (clawmacs-gui:run-gui :session session))

      (format t "~%GUI exited normally.~%"))
  (error (e)
    (format t "~%GUI error: ~a~%" e)
    (format t "~%This may be OK if no X display is available.~%")))
