# Pattern: McCLIM Chat Application Frame

## Overview

Building a chat-style GUI with McCLIM: scrolling message log, input pane,
sidebar, and background LLM threads.

## Core Frame Pattern

```lisp
(clim:define-application-frame my-frame ()
  ;; Slots for application state
  ((chat-log  :accessor frame-chat-log  :initform '())
   (status    :accessor frame-status    :initform "Ready")
   (worker    :accessor frame-worker    :initform nil))

  (:panes
   (chat-display
    :application
    :display-function 'display-chat-pane   ; redraws all messages
    :scroll-bars :vertical
    :background (clim:make-rgb-color 0.07 0.07 0.12)
    :foreground clim:+white+)

   (sidebar-pane
    :application
    :display-function 'display-sidebar-pane
    :min-width 220 :width 220 :max-width 220)

   (status-bar
    :application
    :display-function 'display-status-pane
    :min-height 22 :height 22 :max-height 22)

   (user-input
    :interactor                             ; standard CLIM command input
    :min-height 60 :height 60 :max-height 60))

  (:layouts
   (:default
    (clim:vertically ()
      (clim:horizontally ()
        sidebar-pane
        (clim:vertically ()
          chat-display
          user-input))
      status-bar)))

  (:command-table (my-frame-commands
                   :inherit-from (clim:global-command-table)))
  (:menu-bar nil))
```

## Safe Redisplay (Critical!)

Never call `redisplay-frame-pane` with a NIL pane — panes aren't live until
`run-frame-top-level` is running.

```lisp
(defun safe-redisplay (frame pane-name)
  "Redisplay pane by name, safe to call before frame is fully live."
  (let ((pane (clim:find-pane-named frame pane-name)))
    (when pane
      (clim:redisplay-frame-pane frame pane))))
```

And for pre-launch setup (e.g. welcome messages):

```lisp
;; WRONG: push-chat-message calls redisplay-frame-pane → NIL crash
(push-chat-message frame :system "Welcome!")   ; crashes before run-frame-top-level

;; RIGHT: just add to the slot, no redisplay
(defun append-chat-message (frame role content)
  (let ((msg (make-chat-message role content)))
    (setf (frame-chat-log frame)
          (append (frame-chat-log frame) (list msg)))))
```

## Display Functions with Color

```lisp
(defun display-chat-pane (frame pane)
  (dolist (msg (frame-chat-log frame))
    (let ((ink (role-ink (chat-message-role msg))))
      ;; Role badge in message color
      (clim:with-drawing-options (pane :ink ink
                                       :text-style (clim:make-text-style
                                                    :sans-serif :bold 11))
        (format pane "~%[~a]~%" (role-label (chat-message-role msg))))
      ;; Body in white
      (clim:with-drawing-options (pane :ink clim:+white+)
        (write-string (chat-message-content msg) pane)
        (terpri pane)))))
```

## Background LLM Thread

```lisp
(defun run-llm-async (frame user-text)
  (when (and (frame-worker frame)
             (bt:thread-alive-p (frame-worker frame)))
    (return-from run-llm-async nil)) ; busy

  (setf (frame-worker frame)
        (bt:make-thread
         (lambda ()
           (handler-case
               (%do-llm-call frame user-text)
             (error (e)
               (push-chat-message frame :system
                                  (format nil "Error: ~a" e)))))
         :name "llm-worker")))
```

## Streaming with Adjustable Array

`get-output-stream-string` CLEARS the stream on every call — do NOT use it
as a rolling accumulator.

```lisp
;; WRONG: only shows last token
(let ((s (make-string-output-stream)))
  (lambda (delta)
    (write-string delta s)
    (get-output-stream-string s)))   ; clears buffer!

;; RIGHT: adjustable fill-pointer array
(let ((buf (make-array 0 :element-type 'character
                         :fill-pointer 0
                         :adjustable t)))
  (lambda (delta)
    (loop :for ch :across delta :do
      (vector-push-extend ch buf))
    (coerce buf 'string)))   ; snapshot without clearing
```

## Commands

```lisp
(clim:define-command (com-send :name "Send" :menu t
                               :command-table my-frame-commands)
    ((message 'string :prompt "Message"))
  (run-llm-async clim:*application-frame* message))

(clim:define-command (com-quit :name "Quit" :menu t
                               :command-table my-frame-commands
                               :keystroke (#\q :control))
    ()
  (clim:frame-exit clim:*application-frame*))
```

## Entry Point

```lisp
(defun run-gui (&key session width height)
  (let ((frame (clim:make-application-frame 'my-frame
                  :session session
                  :width (or width 1100)
                  :height (or height 750)
                  :pretty-name "My App")))
    ;; Add welcome message WITHOUT redisplay (frame not live yet)
    (append-chat-message frame :system "Welcome!")
    ;; Blocks until frame exits
    (clim:run-frame-top-level frame)
    frame))
```

## Gotchas

1. **Pre-launch redisplay** — panes are NIL before `run-frame-top-level`
2. **`get-output-stream-string` clears** — use adjustable arrays for streaming
3. **`*on-stream-delta*`** — not re-exported by `clawmacs` top package; import from `clawmacs/loop`
4. **Command table** — define inline in frame with `:inherit-from (clim:global-command-table)`, or create standalone first
5. **Thread safety** — McCLIM redisplay from worker threads is generally OK but use `safe-redisplay` as a guard
