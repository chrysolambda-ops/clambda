;;;; src/swank.lisp — SWANK/SLIME server integration for Clawmacs
;;;;
;;;; Provides a built-in SWANK server that gives live inspection, hot-reload,
;;;; and interactive debugging via Emacs SLIME or Sly.
;;;;
;;;; This is a core Lisp superpower: while Clawmacs is running (handling messages,
;;;; running agents, scheduling tasks) you can connect SLIME and:
;;;;   - Inspect any agent, session, or running state live
;;;;   - Redefine functions and methods WITHOUT restarting the server
;;;;   - Set breakpoints and trace agent-turn, tool dispatch, etc.
;;;;   - Choose condition system restarts manually for stuck agents
;;;;   - Hot-patch bugs in tool handlers while agents run
;;;;
;;;; OpenClaw (Node.js) requires a full process restart for ANY code change.
;;;; Clawmacs + SLIME never needs to restart for code changes.
;;;;
;;;; Usage from init.lisp:
;;;;
;;;;   (start-swank)   ; defaults to port 4005
;;;;
;;;;   ;; Or with a custom port:
;;;;   (setf *swank-port* 4007)
;;;;   (start-swank)
;;;;
;;;;   ;; Then in Emacs: M-x slime-connect RET 127.0.0.1 RET 4005 RET
;;;;   ;; Or in Sly:     M-x sly-connect RET 127.0.0.1 RET 4005 RET
;;;;
;;;; The server is non-blocking (background thread). Clawmacs continues
;;;; running normally; SLIME connects asynchronously.

(in-package #:clawmacs/swank)

;;;; ── Config ──────────────────────────────────────────────────────────────────

(clawmacs/config:defoption *swank-port* 4005
  :type integer
  :doc "Port for the built-in SWANK server (used by SLIME/Sly).
Default: 4005 (standard SLIME port). Set before calling (start-swank).

Example init.lisp:
  (setf *swank-port* 4007)
  (start-swank)")

;;;; ── State ───────────────────────────────────────────────────────────────────

(defvar *swank-server-port* nil
  "Port of the currently running SWANK server, or NIL if not started.")

;;;; ── Lifecycle ───────────────────────────────────────────────────────────────

(defun start-swank (&key (port *swank-port*))
  "Start a SWANK server on PORT for SLIME/Sly connections.

The server runs in a background thread and does not block Clawmacs.

Connect from Emacs:
  M-x slime-connect RET 127.0.0.1 RET <port> RET

Connect from Sly:
  M-x sly-connect RET 127.0.0.1 RET <port> RET

Returns the port number on success, NIL on failure."
  (when *swank-server-port*
    (format t "~&[clawmacs/swank] SWANK already running on port ~a.~%"
            *swank-server-port*)
    (return-from start-swank *swank-server-port*))

  (handler-case
      (progn
        ;; Suppress SWANK's verbose startup messages
        (let ((swank::*log-output*
               (make-broadcast-stream)))
          (declare (special swank::*log-output*))
          ;; Create the server — returns the actual port
          (let ((actual-port
                 (swank:create-server :port port :dont-close t)))
            (setf *swank-server-port* actual-port)
            (format t "~&[clawmacs/swank] SWANK server started on port ~a.~%~
                       ~&[clawmacs/swank] Connect with: M-x slime-connect ~
                         RET 127.0.0.1 RET ~a RET~%"
                    actual-port actual-port)
            actual-port)))
    (error (e)
      (format *error-output*
              "~&[clawmacs/swank] Failed to start SWANK on port ~a: ~a~%~
               ~&[clawmacs/swank] Is 'swank' system loaded? (ql:quickload :swank)~%"
              port e)
      nil)))

(defun stop-swank ()
  "Stop the running SWANK server.

Returns T if stopped, NIL if not running."
  (if *swank-server-port*
      (handler-case
          (progn
            (swank:stop-server *swank-server-port*)
            (format t "~&[clawmacs/swank] SWANK server on port ~a stopped.~%"
                    *swank-server-port*)
            (setf *swank-server-port* nil)
            t)
        (error (e)
          (format *error-output*
                  "~&[clawmacs/swank] Error stopping SWANK: ~a~%" e)
          ;; Reset state anyway
          (setf *swank-server-port* nil)
          nil))
      (progn
        (format t "~&[clawmacs/swank] SWANK is not running.~%")
        nil)))

(defun swank-running-p ()
  "Return T if the SWANK server is currently running."
  (not (null *swank-server-port*)))
