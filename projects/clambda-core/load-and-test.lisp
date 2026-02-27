;;;; load-and-test.lisp — Load and run clawmacs-core tests

;; Set up ASDF to find local systems
(pushnew (truename "../cl-llm/") ql:*local-project-directories* :test #'equal)
(pushnew (truename "./") ql:*local-project-directories* :test #'equal)

;; Load
(ql:quickload "clawmacs-core" :silent nil)

;; Run unit tests (no LLM needed)
(in-package #:clawmacs-core/tests)
(run-all-tests)

;; Exit
(uiop:quit 0)
