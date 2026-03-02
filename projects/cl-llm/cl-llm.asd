;;;; cl-llm.asd — ASDF system definition for cl-llm

(defsystem "cl-llm"
  :description "Clean Common Lisp interface to OpenAI-compatible LLM APIs"
  :version "0.1.0"
  :author "Gensym <gensym@cl-team>"
  :license "AGPL-3.0-or-later"
  :depends-on ("dexador"
               "com.inuoe.jzon"
               "alexandria"
               "cl-ppcre")
  :serial t
  :components ((:file "src/packages")
               (:file "src/conditions")
               (:file "src/json")
               (:file "src/http")
               (:file "src/protocol")
               (:file "src/client")
               (:file "src/streaming")
               (:file "src/tools")
               (:file "src/claude-cli")
               (:file "src/codex-cli"))
  :in-order-to ((test-op (test-op "cl-llm/tests"))))

(defsystem "cl-llm/tests"
  :description "Tests for cl-llm"
  :depends-on ("cl-llm" "parachute")
  :serial t
  :components ((:file "t/packages")
               (:file "t/test-basic")))
