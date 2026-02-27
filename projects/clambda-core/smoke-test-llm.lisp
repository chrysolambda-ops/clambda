;;;; smoke-test-llm.lisp — Full LLM smoke test for clawmacs-core

(pushnew (truename "../cl-llm/") ql:*local-project-directories* :test #'equal)
(pushnew (truename "./") ql:*local-project-directories* :test #'equal)
(ql:quickload "clawmacs-core/tests" :silent t)

(in-package #:clawmacs-core/tests)
(run-smoke-test)
(uiop:quit 0)
