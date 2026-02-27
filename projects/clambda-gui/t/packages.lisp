;;;; t/packages.lisp — Test package for clawmacs-gui

(defpackage #:clawmacs-gui/tests
  (:use #:clim-lisp)
  (:import-from #:clawmacs-gui
                #:make-chat-message
                #:chat-message-role
                #:chat-message-content
                #:chat-message-timestamp
                #:format-timestamp
                #:role-ink
                #:role-label))
