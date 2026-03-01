;;;; src/packages.lisp — Package definitions for cl-tui

(defpackage #:cl-tui/ansi
  (:use #:cl)
  (:export
   ;; Text attributes
   #:+reset+
   #:+bold+
   #:+dim+
   ;; Foreground colors
   #:+fg-black+  #:+fg-red+     #:+fg-green+  #:+fg-yellow+
   #:+fg-blue+   #:+fg-magenta+ #:+fg-cyan+   #:+fg-white+
   #:+fg-bright-black+  #:+fg-bright-red+   #:+fg-bright-green+
   #:+fg-bright-yellow+ #:+fg-bright-blue+  #:+fg-bright-magenta+
   #:+fg-bright-cyan+   #:+fg-bright-white+
   ;; Cursor & screen
   #:+clear-screen+
   #:+clear-line+
   #:+cursor-up+
   #:+cursor-home+
   ;; Composing
   #:esc
   #:colored
   #:strip-ansi
   ;; Output helpers
   #:write-colored
   #:newline))

(defpackage #:cl-tui/state
  (:use #:cl)
  (:import-from #:cl-llm
                #:make-client #:client
                #:system-message #:user-message #:assistant-message
                #:message-role #:message-content)
  (:export
   #:*app*
   ;; App struct
   #:app
   #:make-app
   #:app-client
   #:app-messages
   #:app-model
   #:app-system-prompt
   #:app-running-p
   #:app-stream
   ;; Mutators
   #:app-push-message
   #:app-set-model
   #:app-set-system-prompt
   #:app-stop
   ;; Message helpers
   #:get-chat-messages))

(defpackage #:cl-tui/display
  (:use #:cl)
  (:import-from #:cl-tui/ansi
                #:colored #:write-colored
                #:+reset+ #:+bold+ #:+dim+
                #:+fg-red+
                #:+fg-yellow+ #:+fg-cyan+ #:+fg-green+ #:+fg-blue+
                #:+fg-white+ #:+fg-magenta+
                #:+fg-bright-black+
                #:+fg-bright-white+ #:+fg-bright-cyan+ #:+fg-bright-yellow+
                #:+fg-bright-green+ #:+fg-bright-blue+ #:+fg-bright-magenta+
                #:+clear-screen+ #:+cursor-home+)
  (:import-from #:cl-tui/state
                #:app #:app-model #:app-system-prompt
                #:app-messages
                #:*app*)
  (:import-from #:cl-llm
                #:message-role #:message-content)
  (:export
   #:print-header
   #:print-message
   #:print-prompt
   #:print-system-notice
   #:print-error-notice
   #:print-token
   #:print-assistant-start
   #:print-assistant-end
   #:print-separator
   #:clear-screen))

(defpackage #:cl-tui/commands
  (:use #:cl)
  (:import-from #:cl-tui/state
                #:*app* #:app-stop #:app-set-model #:app-set-system-prompt)
  (:import-from #:cl-tui/display
                #:print-system-notice #:print-error-notice)
  (:export
   #:handle-command
   #:command-p))

(defpackage #:cl-tui/loop
  (:use #:cl)
  (:import-from #:cl-tui/state
                #:*app* #:make-app #:app-client #:app-messages
                #:app-model #:app-system-prompt #:app-running-p #:app-stop
                #:app-stream #:app-push-message #:get-chat-messages)
  (:import-from #:cl-tui/display
                #:print-header #:print-message #:print-prompt
                #:print-token #:print-assistant-start #:print-assistant-end
                #:print-system-notice #:print-error-notice
                #:print-separator #:clear-screen)
  (:import-from #:cl-tui/commands
                #:handle-command #:command-p)
  (:import-from #:cl-llm
                #:make-client
                #:user-message #:assistant-message)
  (:export
   #:run
   #:run-tui))

;; Top-level convenience package
(defpackage #:cl-tui
  (:use #:cl)
  (:import-from #:cl-tui/loop #:run #:run-tui)
  (:export #:run #:run-tui))
