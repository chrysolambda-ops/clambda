;;;; src/main.lisp — Entry points for clawmacs-gui

(in-package #:clawmacs-gui)

;;; ── Default LM Studio client ─────────────────────────────────────────────────

(defparameter *default-lm-studio-host* "http://192.168.1.189:1234"
  "Default LM Studio server host:port.")

(defparameter *default-model* "google/gemma-3-4b"
  "Default model for new sessions.")

(defun make-default-client ()
  "Create a default CL-LLM client connecting to LM Studio."
  (make-client :base-url (format nil "~a/v1" *default-lm-studio-host*)
               :api-key  "not-needed"
               :model    *default-model*))

(defun make-default-agent (&key name role model client)
  "Create an agent with sensible defaults for the GUI."
  (make-agent :name   (or name "Clawmacs")
              :role   (or role "assistant")
              :model  (or model *default-model*)
              :client (or client (make-default-client))))

;;; ── Session setup ─────────────────────────────────────────────────────────────

(defun make-gui-session (&key agent name role model)
  "Create a fresh clawmacs SESSION ready for the GUI.

AGENT — an existing AGENT, or NIL to auto-create one.
NAME  — agent name override (if auto-creating).
ROLE  — agent role override (if auto-creating).
MODEL — model override (if auto-creating)."
  (let ((ag (or agent (make-default-agent :name name :role role :model model))))
    (make-session :agent ag)))

;;; ── Frame instantiation ───────────────────────────────────────────────────────

(defun make-gui-frame (session &key (width 1100) (height 750))
  "Create a new CLAMBDA-GUI-FRAME for SESSION."
  (clim:make-application-frame
   'clawmacs-gui-frame
   :session session
   :width   width
   :height  height
   :pretty-name "Clawmacs — LLM Chat"))

;;; ── Welcome banner ────────────────────────────────────────────────────────────

(defun show-welcome (frame)
  "Append welcome message to the chat log BEFORE the frame is live.
Uses APPEND-CHAT-MESSAGE (no redisplay) so it is safe to call before
RUN-FRAME-TOP-LEVEL realises the panes."
  (let* ((session (frame-session frame))
         (agent   (when session (session-agent session))))
    (append-chat-message
     frame :system
     (format nil
             "Welcome to Clawmacs GUI~@[ — agent: ~a~]~@[ (model: ~a)~]~%~
              Type your message in the input pane below.~%~
              Commands: Send / Clear History / Switch Model / Set System / Quit"
             (when agent (agent-name agent))
             (when agent (agent-model agent))))))

;;; ── Main entry point ──────────────────────────────────────────────────────────

(defun run-gui (&key session agent name role model
                     (width 1100) (height 750))
  "Start the clawmacs-gui application.

SESSION — an existing clawmacs session (takes priority over other options).
AGENT   — use an existing agent (takes priority over NAME/ROLE/MODEL).
NAME    — agent name (default: \"Clawmacs\").
ROLE    — agent role (default: \"assistant\").
MODEL   — model name (default: *default-model*).
WIDTH, HEIGHT — initial window size.

Blocks until the user closes the window."
  (let* ((sess  (or session
                    (make-gui-session :agent agent :name name
                                      :role role :model model)))
         (frame (make-gui-frame sess :width width :height height)))

    (show-welcome frame)

    ;; clim:run-frame-top-level blocks until the frame exits
    (clim:run-frame-top-level frame)

    ;; Return the session so callers can inspect the conversation
    (frame-session frame)))

;;; ── Non-blocking launch ───────────────────────────────────────────────────────

(defun launch-gui (&rest run-gui-args)
  "Launch the clawmacs-gui in a background thread.
Returns the thread object.

Accepts all the same keyword arguments as RUN-GUI."
  (bt:make-thread
   (lambda ()
     (apply #'run-gui run-gui-args))
   :name "clawmacs-gui-main"))
