;;;; clawmacs-gui.asd — ASDF system definition for clawmacs-gui
;;;;
;;;; McCLIM graphical frontend for the clawmacs agent platform.
;;;; Provides a windowed chat interface with colored message display,
;;;; sidebar agent info, streaming support, and a command table.

(defsystem "clawmacs-gui"
  :description "McCLIM graphical frontend for clawmacs-core"
  :version "0.1.0"
  :author "Gensym <gensym@cl-team>"
  :license "AGPL-3.0-or-later"
  :depends-on ("clawmacs-core"
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
  :in-order-to ((test-op (test-op "clawmacs-gui/tests"))))

(defsystem "clawmacs-gui/tests"
  :description "Tests for clawmacs-gui (non-GUI parts)"
  :depends-on ("clawmacs-gui")
  :serial t
  :components ((:file "t/packages")
               (:file "t/smoke")))
