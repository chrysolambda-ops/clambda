;;;; clambda-core.asd — ASDF system definition for clambda-core
;;;;
;;;; The core OpenClaw-inspired agent platform in Common Lisp.
;;;; Provides: agent definition, session management, tool protocol,
;;;; built-in tools (exec, read, write, list-dir, web-fetch),
;;;; structured logging, workspace memory, the agent loop,
;;;; agent registry, sub-agent spawning, channel protocol, HTTP API,
;;;; the Emacs-style configuration system (Layer 6a),
;;;; the Telegram Bot API channel (Layer 6b),
;;;; and the IRC client channel (Layer 6c).

(defsystem "clambda-core"
  :description "Core agent platform architecture in Common Lisp"
  :version "0.6.0"
  :author "Gensym <gensym@cl-team>"
  :license "AGPL-3.0-or-later"
  :depends-on ("cl-llm"
               "alexandria"
               "com.inuoe.jzon"
               "uiop"
               "dexador"
               "cl-ppcre"
               "bordeaux-threads"
               "hunchentoot"
               ;; Layer 6c: IRC raw socket + TLS
               "usocket"
               "cl+ssl")
  :serial t
  :components ((:file "src/packages")
               (:file "src/conditions")
               (:file "src/agent")
               (:file "src/session")
               (:file "src/tools")
               (:file "src/logging")
               (:file "src/memory")
               (:file "src/builtins")
               (:file "src/loop")
               ;; Layer 5 Phase 2
               (:file "src/registry")
               (:file "src/subagents")
               (:file "src/channels")
               (:file "src/http-server")
               ;; Layer 6a: Emacs-style config system
               (:file "src/config")
               ;; Layer 6b: Telegram Bot API channel
               (:file "src/telegram")
               ;; Layer 6c: IRC client channel (raw sockets)
               (:file "src/irc"))
  :in-order-to ((test-op (test-op "clambda-core/tests"))))

(defsystem "clambda-core/tests"
  :description "Tests for clambda-core"
  :depends-on ("clambda-core" "parachute")
  :serial t
  :components ((:file "t/packages")
               (:file "t/smoke-test")
               (:file "t/test-config")
               (:file "t/test-telegram")
               ;; Layer 6c: IRC tests
               (:file "t/test-irc")))
