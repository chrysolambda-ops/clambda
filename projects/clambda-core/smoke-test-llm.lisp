;;;; smoke-test-llm.lisp — Full LLM smoke test for clambda-core

(pushnew (truename "../cl-llm/") ql:*local-project-directories* :test #'equal)
(pushnew (truename "./") ql:*local-project-directories* :test #'equal)
(ql:quickload "clambda-core/tests" :silent t)

(in-package #:clambda-core/tests)
(run-smoke-test)
(uiop:quit 0)
