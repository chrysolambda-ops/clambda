;;;; src/channels.lisp — Channel Protocol (Task 3.1)
;;;;
;;;; Defines a generic I/O channel protocol used to wire agent loops to
;;;; different I/O backends (REPL, in-memory queue, HTTP, sockets, etc.).
;;;;
;;;; Protocol:
;;;;   CHANNEL-SEND    (channel message) → nil
;;;;   CHANNEL-RECEIVE (channel &key timeout) → message-string or nil
;;;;   CHANNEL-POLL    (channel) → message-string or nil (non-blocking)
;;;;   CHANNEL-CLOSE   (channel) → nil
;;;;   CHANNEL-OPEN-P  (channel) → boolean

(in-package #:clawmacs/channels)

;;; ── Conditions ───────────────────────────────────────────────────────────────

(define-condition channel-closed-error (error)
  ((channel :initarg :channel :reader channel-closed-error-channel))
  (:report (lambda (c s)
             (format s "Channel is closed: ~s"
                     (channel-closed-error-channel c)))))

(define-condition channel-timeout-error (error)
  ((channel :initarg :channel :reader channel-timeout-error-channel)
   (timeout :initarg :timeout :reader channel-timeout-error-timeout))
  (:report (lambda (c s)
             (format s "Channel receive timed out after ~a seconds: ~s"
                     (channel-timeout-error-timeout c)
                     (channel-timeout-error-channel c)))))

;;; ── Abstract base class ──────────────────────────────────────────────────────

(defclass channel ()
  ((open-p :initform t :accessor channel-open-p
           :documentation "T while the channel is open for I/O."))
  (:documentation
   "Abstract base class for I/O channels.
Subclasses implement CHANNEL-SEND, CHANNEL-RECEIVE, CHANNEL-POLL."))

(defmethod print-object ((ch channel) stream)
  (print-unreadable-object (ch stream :type t)
    (format stream "open=~a" (channel-open-p ch))))

;;; ── Generic functions ────────────────────────────────────────────────────────

(defgeneric channel-send (channel message)
  (:documentation
   "Send MESSAGE (a string) to CHANNEL.
Signals CHANNEL-CLOSED-ERROR if the channel is not open."))

(defgeneric channel-receive (channel &key timeout)
  (:documentation
   "Block until a message is available on CHANNEL and return it.
TIMEOUT — seconds to wait before signalling CHANNEL-TIMEOUT-ERROR (NIL = wait forever).
Signals CHANNEL-CLOSED-ERROR if the channel is closed."))

(defgeneric channel-poll (channel)
  (:documentation
   "Return the next message from CHANNEL if available, or NIL immediately.
Does not block. Does not signal on empty channel."))

(defgeneric channel-close (channel)
  (:documentation
   "Close CHANNEL. After closing, sends signal CHANNEL-CLOSED-ERROR."))

;;; Default check helper
(defun %assert-open (channel)
  (unless (channel-open-p channel)
    (error 'channel-closed-error :channel channel)))

;;; ── REPL Channel ─────────────────────────────────────────────────────────────
;;;
;;; Reads from an input stream, writes to an output stream.
;;; Default: *standard-input* / *standard-output*.

(defclass repl-channel (channel)
  ((input  :initarg :input  :accessor repl-channel-input
           :initform *standard-input*)
   (output :initarg :output :accessor repl-channel-output
           :initform *standard-output*))
  (:documentation
   "A channel that reads lines from INPUT stream and writes to OUTPUT stream.
Default: *STANDARD-INPUT* / *STANDARD-OUTPUT*."))

(defun make-repl-channel (&key (input *standard-input*)
                                (output *standard-output*))
  "Create a REPL-CHANNEL reading from INPUT and writing to OUTPUT."
  (make-instance 'repl-channel :input input :output output))

(defmethod channel-send ((ch repl-channel) message)
  (%assert-open ch)
  (write-string message (repl-channel-output ch))
  (terpri (repl-channel-output ch))
  (finish-output (repl-channel-output ch))
  nil)

(defmethod channel-receive ((ch repl-channel) &key timeout)
  (%assert-open ch)
  ;; REPL channel doesn't support timeout — just block on read-line
  (when timeout
    ;; Warn but don't error — timeout is advisory for REPL
    (format *error-output*
            "~&[repl-channel] WARNING: timeout ~a ignored (blocking read)~%"
            timeout))
  (read-line (repl-channel-input ch) nil nil))

(defmethod channel-poll ((ch repl-channel))
  ;; listen returns T if input is ready without blocking
  (when (listen (repl-channel-input ch))
    (read-line (repl-channel-input ch) nil nil)))

(defmethod channel-close ((ch repl-channel))
  (setf (channel-open-p ch) nil))

;;; ── Queue Channel ────────────────────────────────────────────────────────────
;;;
;;; An in-memory FIFO queue (list).
;;; Thread-safe using a mutex + condition variable.
;;; Useful for testing and programmatic message passing.

(defclass queue-channel (channel)
  ((queue :initform '()    :accessor queue-channel-queue)
   (lock  :initform (bt:make-lock "queue-channel-lock")
          :accessor queue-channel-lock)
   (cvar  :initform (bt:make-condition-variable :name "queue-channel-cvar")
          :accessor queue-channel-cvar))
  (:documentation
   "An in-memory FIFO queue channel.
Thread-safe using a mutex and condition variable.
CHANNEL-SEND enqueues; CHANNEL-RECEIVE blocks until data available."))

(defun make-queue-channel ()
  "Create a new empty QUEUE-CHANNEL."
  (make-instance 'queue-channel))

(defmethod channel-send ((ch queue-channel) message)
  (%assert-open ch)
  (bt:with-lock-held ((queue-channel-lock ch))
    ;; Append to end of queue (FIFO)
    (setf (queue-channel-queue ch)
          (nconc (queue-channel-queue ch) (list message)))
    (bt:condition-notify (queue-channel-cvar ch)))
  nil)

(defmethod channel-receive ((ch queue-channel) &key timeout)
  (%assert-open ch)
  (bt:with-lock-held ((queue-channel-lock ch))
    (if timeout
        ;; Timed wait
        (let ((deadline (+ (get-internal-real-time)
                           (round (* timeout internal-time-units-per-second)))))
          (loop
            (when (queue-channel-queue ch)
              (return (pop (queue-channel-queue ch))))
            (unless (channel-open-p ch)
              (error 'channel-closed-error :channel ch))
            (let ((remaining (/ (- deadline (get-internal-real-time))
                                (float internal-time-units-per-second))))
              (when (<= remaining 0)
                (error 'channel-timeout-error :channel ch :timeout timeout))
              (bt:condition-wait (queue-channel-cvar ch)
                                 (queue-channel-lock ch)
                                 :timeout remaining))))
        ;; Blocking (no timeout)
        (loop
          (when (queue-channel-queue ch)
            (return (pop (queue-channel-queue ch))))
          (unless (channel-open-p ch)
            (error 'channel-closed-error :channel ch))
          (bt:condition-wait (queue-channel-cvar ch)
                             (queue-channel-lock ch))))))

(defmethod channel-poll ((ch queue-channel))
  (bt:with-lock-held ((queue-channel-lock ch))
    (when (queue-channel-queue ch)
      (pop (queue-channel-queue ch)))))

(defmethod channel-close ((ch queue-channel))
  (bt:with-lock-held ((queue-channel-lock ch))
    (setf (channel-open-p ch) nil)
    ;; Wake up any blocked receivers (notify once; they check open-p and exit)
    (bt:condition-notify (queue-channel-cvar ch))))
