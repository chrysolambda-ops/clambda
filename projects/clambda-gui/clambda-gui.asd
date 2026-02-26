;;;; clambda-gui.asd — ASDF system definition for clambda-gui
;;;;
;;;; McCLIM graphical frontend for the clambda agent platform.
;;;; Provides a windowed chat interface with colored message display,
;;;; sidebar agent info, streaming support, and a command table.

(defsystem "clambda-gui"
  :description "McCLIM graphical frontend for clambda-core"
  :version "0.1.0"
  :author "Gensym <gensym@cl-team>"
  :license "AGPL-3.0-or-later"
  :depends-on ("clambda-core"
               "cl-llm"
               "mcclim"
               "bordeaux-threads")
  :serial t
  :components ((:file "src/packages")
               (:file "src/colors")
               (:file "src/chat-record")
               (:file "src/frame")
               (:file "src/display")
               (:file "src/commands")
               (:file "src/main"))
  :in-order-to ((test-op (test-op "clambda-gui/tests"))))

(defsystem "clambda-gui/tests"
  :description "Tests for clambda-gui (non-GUI parts)"
  :depends-on ("clambda-gui")
  :serial t
  :components ((:file "t/packages")
               (:file "t/smoke")))
