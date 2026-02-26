;;;; clambda-core.asd — ASDF system definition for clambda-core
;;;;
;;;; The core OpenClaw-inspired agent platform in Common Lisp.
;;;; Provides: agent definition, session management, tool protocol,
;;;; built-in tools, and the agent loop.

(defsystem "clambda-core"
  :description "Core agent platform architecture in Common Lisp"
  :version "0.1.0"
  :author "Gensym <gensym@cl-team>"
  :license "MIT"
  :depends-on ("cl-llm"
               "alexandria"
               "com.inuoe.jzon"
               "uiop")
  :serial t
  :components ((:file "src/packages")
               (:file "src/conditions")
               (:file "src/agent")
               (:file "src/session")
               (:file "src/tools")
               (:file "src/builtins")
               (:file "src/loop"))
  :in-order-to ((test-op (test-op "clambda-core/tests"))))

(defsystem "clambda-core/tests"
  :description "Tests for clambda-core"
  :depends-on ("clambda-core")
  :serial t
  :components ((:file "t/packages")
               (:file "t/smoke-test")))
