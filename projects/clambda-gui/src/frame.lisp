;;;; src/frame.lisp — Main McCLIM application frame for clawmacs-gui

(in-package #:clawmacs-gui)

;;; ── Application frame ────────────────────────────────────────────────────────

(clim:define-application-frame clawmacs-gui-frame ()
  ;;
  ;; Frame slots
  ;;
  ((session
    :initarg  :session
    :accessor frame-session
    :initform nil
    :documentation "The active clawmacs SESSION.")

   (chat-log
    :accessor frame-chat-log
    :initform '()
    :documentation "List of CHAT-MESSAGE structs, oldest first.")

   (status
    :accessor frame-status
    :initform "Ready — send a message below"
    :documentation "Status bar text.")

   (streaming-buffer
    :accessor frame-streaming-buffer
    :initform nil
    :documentation "If non-NIL, a string of tokens being streamed (in-progress).")

   (worker-thread
    :accessor frame-worker-thread
    :initform nil
    :documentation "Currently active LLM background thread, or NIL.")

   (token-count
    :accessor frame-token-count
    :initform 0
    :documentation "Running total of tokens used this session."))

  ;;
  ;; Pane definitions
  ;;
  (:panes
   ;; Main chat display — scrollable, redrawn on each message
   (chat-display
    :application
    :display-function 'display-chat-pane
    :scroll-bars      :vertical
    :incremental-redisplay nil
    :background       +bg-main+
    :foreground       clim:+white+
    :text-style       +text-style-body+)

   ;; Sidebar — agent info + session stats
   (sidebar-pane
    :application
    :display-function 'display-sidebar-pane
    :scroll-bars      nil
    :background       +bg-sidebar+
    :foreground       clim:+white+
    :text-style       +text-style-ui+
    :min-width 220 :width 220 :max-width 220)

   ;; Status bar at the bottom
   (status-bar
    :application
    :display-function 'display-status-pane
    :scroll-bars      nil
    :background       +bg-status+
    :foreground       clim:+white+
    :text-style       +text-style-ui+
    :min-height 22 :height 22 :max-height 22)

   ;; Interactor for command/message input
   (user-input
    :interactor
    :background       +bg-input+
    :foreground       clim:+white+
    :text-style       +text-style-body+
    :min-height 60 :height 60 :max-height 60
    :scroll-bars      nil))

  ;;
  ;; Window layout
  ;;
  ;; ┌──────────┬────────────────────────────┐
  ;; │          │   Chat display (scroll)    │
  ;; │ Sidebar  │                            │
  ;; │          ├────────────────────────────┤
  ;; │          │   Input (interactor)       │
  ;; └──────────┴────────────────────────────┘
  ;; │       Status bar                      │
  ;; └───────────────────────────────────────┘
  ;;
  (:layouts
   (:default
    (clim:vertically ()
      (clim:horizontally ()
        sidebar-pane
        (clim:vertically ()
          chat-display
          user-input))
      status-bar)))

  (:command-table (clawmacs-gui-commands
                   :inherit-from (clim:global-command-table)))
  (:menu-bar nil))

;;; ── Helpers ───────────────────────────────────────────────────────────────────

(defun safe-redisplay (frame pane-name)
  "Redisplay pane PANE-NAME on FRAME, silently skipping if pane is not yet live."
  (let ((pane (clim:find-pane-named frame pane-name)))
    (when pane
      (clim:redisplay-frame-pane frame pane))))

(defun append-chat-message (frame role content &key tool-name)
  "Add a CHAT-MESSAGE to FRAME's chat-log WITHOUT triggering redisplay.
Use this before RUN-FRAME-TOP-LEVEL (panes not yet realized)."
  (let ((msg (make-chat-message role content :tool-name tool-name)))
    (setf (frame-chat-log frame)
          (append (frame-chat-log frame) (list msg)))))

(defun push-chat-message (frame role content &key tool-name)
  "Add a new CHAT-MESSAGE to FRAME's chat-log and redisplay.
Safe to call at any time — redisplay is skipped if panes not yet live."
  (append-chat-message frame role content :tool-name tool-name)
  (safe-redisplay frame 'chat-display)
  (safe-redisplay frame 'sidebar-pane))

(defun set-status (frame text)
  "Update the status bar text and redisplay."
  (setf (frame-status frame) text)
  (safe-redisplay frame 'status-bar))

(defun frame-busy-p (frame)
  "Return T if the LLM worker thread is still running."
  (let ((thread (frame-worker-thread frame)))
    (and thread (bt:thread-alive-p thread))))
