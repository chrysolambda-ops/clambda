;;;; clawmacs-core.asd — ASDF system definition for clawmacs-core
;;;;
;;;; The core OpenClaw-inspired agent platform in Common Lisp.
;;;; Provides: agent definition, session management, tool protocol,
;;;; built-in tools (exec, read, write, list-dir, web-fetch),
;;;; structured logging, workspace memory, the agent loop,
;;;; agent registry, sub-agent spawning, channel protocol, HTTP API,
;;;; the Emacs-style configuration system (Layer 6a),
;;;; the Telegram Bot API channel (Layer 6b),
;;;; the IRC client channel (Layer 6c),
;;;; the Playwright browser control module (Layer 7),
;;;; the cron scheduler + remote management API (Layer 8),
;;;; and the Lisp Superpowers (Layer 9):
;;;;   P0: condition-based live error recovery + SWANK/SLIME server
;;;;   P1: image save/restore + enhanced define-agent DSL

(defsystem "clawmacs-core"
  :description "Core agent platform architecture in Common Lisp"
  :version "0.9.0"
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
               "cl+ssl"
               ;; Layer 9 (P0): SWANK/SLIME server for live inspection
               "swank")
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
               ;; Layer 8a: Cron / scheduled task scheduler
               (:file "src/cron")
               (:file "src/http-server")
               ;; Layer 6a: Emacs-style config system
               (:file "src/config")
               ;; Layer 6b: Telegram Bot API channel
               (:file "src/telegram")
               ;; Layer 6c: IRC client channel (raw sockets)
               (:file "src/irc")
               ;; Layer 7: Playwright browser control
               (:file "src/browser")
               ;; Layer 9 (P0): SWANK/SLIME server for live inspection + hot-reload
               (:file "src/swank")
               ;; Layer 9 (P1): Image save/restore (Genera-style)
               (:file "src/image"))
  :in-order-to ((test-op (test-op "clawmacs-core/tests"))))

(defsystem "clawmacs-core/tests"
  :description "Tests for clawmacs-core"
  :depends-on ("clawmacs-core" "parachute")
  :serial t
  :components ((:file "t/packages")
               (:file "t/smoke-test")
               (:file "t/test-config")
               (:file "t/test-telegram")
               ;; Layer 6c: IRC tests
               (:file "t/test-irc")
               ;; Layer 7: Browser tests
               (:file "t/test-browser")
               ;; Layer 8: Cron + Remote Management API tests
               (:file "t/test-cron")
               (:file "t/test-remote-api")
               ;; Layer 9: Lisp Superpowers tests
               (:file "t/test-superpowers")))
