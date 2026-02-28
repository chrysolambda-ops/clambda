;;;; src/cron.lisp — Cron / Scheduled Task Scheduler (Layer 8a)
;;;;
;;;; Provides a thread-based task scheduler for Clawmacs agents.
;;;;
;;;; Two task kinds:
;;;;   :periodic  — repeats every N seconds until cancelled
;;;;   :once      — fires once after a delay, then removes itself
;;;;
;;;; Each task runs in its own bordeaux-thread.  The thread sleeps in
;;;; small increments (checking the active flag) so cancellation is
;;;; responsive without relying on bt:destroy-thread.
;;;;
;;;; Public API:
;;;;
;;;;   (schedule-task "name" :every 30 #'fn &key description)
;;;;   (schedule-once "name" :after 300 #'fn &key description)
;;;;   (cancel-task "name")        → T / NIL
;;;;   (find-task "name")          → task or NIL
;;;;   (list-tasks)                → list of tasks
;;;;   (clear-tasks)               → nil (cancels all)
;;;;   (task-info task)            → hash-table (for JSON / display)
;;;;
;;;; Integration with init.lisp:
;;;;   ;; In ~/.clawmacs/init.lisp:
;;;;   (schedule-task "check-email" :every (* 30 60) #'check-email-fn
;;;;                  :description "Poll mailbox every 30 minutes")
;;;;   (schedule-once "startup-ping" :after 5 #'ping-fn
;;;;                  :description "One-time startup notification")
;;;;
;;;; Error handling:
;;;;   Errors in the task function are caught, stored in task-last-error,
;;;;   logged (via clawmacs/logging if available), and the task continues
;;;;   (periodic tasks keep firing; once tasks just exit after the error).

(in-package #:clawmacs/cron)

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 1. Data Types
;;;; ─────────────────────────────────────────────────────────────────────────────

(defstruct (scheduled-task (:conc-name task-))
  "A scheduled task managed by the Clawmacs cron system."
  (name        ""    :type string)
  (kind        :once :type keyword)        ; :periodic or :once
  (interval    0     :type real)           ; seconds (fire interval or initial delay)
  (fire-at     0     :type integer)        ; universal-time of next scheduled firing
  (function    nil)                        ; (lambda ()) — the task body
  (thread      nil)                        ; bt:thread or NIL
  (active-p    t     :type boolean)        ; NIL → thread should exit
  (description nil)                        ; string or NIL
  (last-run    nil)                        ; universal-time or NIL
  (last-error  nil)                        ; string or NIL
  (run-count   0     :type integer))       ; total number of successful runs

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 2. Global Registry
;;;; ─────────────────────────────────────────────────────────────────────────────

(defvar *task-registry*
  (make-hash-table :test 'equal)
  "Hash-table mapping task-name (string) → SCHEDULED-TASK.
Protected by *TASK-LOCK*.")

(defvar *task-lock*
  (bt:make-lock "clawmacs/cron:*task-lock*")
  "Lock protecting *TASK-REGISTRY*.")

(defvar *cron-sleep-interval* 0.5
  "How many seconds the cron thread sleeps between active-flag checks.
Smaller = more responsive cancellation, higher CPU overhead.")

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 3. Internal Helpers
;;;; ─────────────────────────────────────────────────────────────────────────────

(defun %register-task (task)
  "Store TASK in *TASK-REGISTRY* under its name."
  (bt:with-lock-held (*task-lock*)
    (setf (gethash (task-name task) *task-registry*) task)))

(defun %unregister-task (name)
  "Remove task NAME from *TASK-REGISTRY*."
  (bt:with-lock-held (*task-lock*)
    (remhash name *task-registry*)))

(defun %log (fmt &rest args)
  "Emit a log entry if clawmacs/logging is loaded and enabled."
  (handler-case
      (when (boundp 'clawmacs/logging:*log-enabled*)
        (when clawmacs/logging:*log-enabled*
          (clawmacs/logging:log-event "cron" "message" (apply #'format nil fmt args))))
    (error () nil))
  ;; Always print to stderr
  (apply #'format *error-output* (concatenate 'string "~&[clawmacs/cron] " fmt "~%") args))

(defun %sleep-until (target-time task)
  "Sleep in *CRON-SLEEP-INTERVAL* increments until TARGET-TIME (universal-time),
checking TASK's active-p flag on each wake.  Returns T if we reached target time,
NIL if the task was cancelled."
  (loop
    (when (not (task-active-p task))
      (return nil))
    (let ((remaining (- target-time (get-universal-time))))
      (when (<= remaining 0)
        (return t))
      (sleep (min *cron-sleep-interval* (max 0.01 remaining))))))

(defun %run-task-function (task)
  "Call TASK's function, updating run statistics.
Catches and records any error without propagating."
  (handler-case
      (progn
        (funcall (task-function task))
        (setf (task-last-run task) (get-universal-time)
              (task-last-error task) nil)
        (incf (task-run-count task)))
    (error (c)
      (let ((msg (format nil "~a" c)))
        (setf (task-last-error task) msg)
        (%log "Task ~s errored: ~a" (task-name task) msg)))))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 4. Thread Entry Points
;;;; ─────────────────────────────────────────────────────────────────────────────

(defun %periodic-task-loop (task)
  "Thread body for a :PERIODIC task.
Sleeps until fire-at, runs the function, updates fire-at, loops."
  (%log "Periodic task ~s started (every ~as)" (task-name task) (task-interval task))
  (loop
    ;; Sleep until scheduled fire time (or cancelled)
    (unless (%sleep-until (task-fire-at task) task)
      (return))                          ; task was cancelled
    ;; Fire
    (%run-task-function task)
    ;; Schedule next run
    (setf (task-fire-at task)
          (+ (get-universal-time) (round (task-interval task)))))
  (%log "Periodic task ~s exited" (task-name task)))

(defun %once-task-body (task)
  "Thread body for a :ONCE task.
Sleeps until fire-at, runs function once, then removes itself."
  (%log "Once task ~s scheduled (delay ~as)" (task-name task) (task-interval task))
  (when (%sleep-until (task-fire-at task) task)
    (%run-task-function task)
    (%log "Once task ~s completed" (task-name task)))
  ;; Self-remove from registry
  (%unregister-task (task-name task))
  (setf (task-active-p task) nil))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 5. Public API
;;;; ─────────────────────────────────────────────────────────────────────────────

(defun schedule-task (name &rest args)
  "Schedule a task with NAME.

Supports two modes:

  Periodic:
    (schedule-task name :every <seconds> :function fn [:description str])

  One-shot (compat):
    (schedule-task name :after <seconds> :function fn [:description str])
    (schedule-task name :after <seconds> fn [:description str])

When :AFTER is supplied, delegates to SCHEDULE-ONCE.
When :EVERY is supplied, creates a repeating periodic task.
:EVERY and :AFTER are mutually exclusive."
  (check-type name string)
  (let ((every nil)
        (after nil)
        (function nil)
        (description nil)
        (tail args))
    ;; Parse mixed positional/keyword args.
    ;; Accept a trailing positional function for convenience:
    ;;   (schedule-task "x" :after 5 (lambda () ...))
    (loop :while tail
          :for key = (first tail)
          :do
             (cond
               ;; Positional trailing function designator.
               ((and (null (rest tail))
                     (typep key '(or function symbol)))
                (setf function key
                      tail nil))
               ((keywordp key)
                (unless (rest tail)
                  (error "Keyword ~s requires a value in schedule-task." key))
                (let ((val (second tail)))
                  (case key
                    (:every       (setf every val))
                    (:after       (setf after val))
                    (:function    (setf function val))
                    (:description (setf description val))
                    (otherwise
                     (error "Unknown keyword ~s in schedule-task." key))))
                (setf tail (cddr tail)))
               (t
                (error "Invalid schedule-task argument: ~s" key))))

    (when (and every after)
      (error "schedule-task accepts either :EVERY or :AFTER, not both."))
    (when (null function)
      (error ":FUNCTION is required for schedule-task."))

    (cond
      (after
       (schedule-once name :after after :function function :description description))
      (every
       ;; Cancel any existing task with same name
       (cancel-task name)
       (let* ((task (make-scheduled-task
                     :name        name
                     :kind        :periodic
                     :interval    every
                     :fire-at     (+ (get-universal-time) (round every))
                     :function    function
                     :active-p    t
                     :description description
                     :run-count   0)))
         (%register-task task)
         (setf (task-thread task)
               (bt:make-thread
                (lambda () (%periodic-task-loop task))
                :name (format nil "cron:~a" name)))
         task))
      (t
       (error "schedule-task requires either :EVERY or :AFTER.")))))

(defun schedule-once (name &key after function description)
  "Schedule FUNCTION to run once after AFTER seconds, with the given NAME.

NAME        — string identifier.
:AFTER      — delay in seconds before firing (real number).
:FUNCTION   — a (lambda ()) or function designator.
:DESCRIPTION — optional string documentation.

The task self-removes from the registry after it fires.
Cancel with (CANCEL-TASK name) before it fires.

Example:
  (schedule-once \"startup-ping\" :after 5 #'ping-fn
                 :description \"One-time startup notification\")"
  (check-type name string)
  (assert after () ":AFTER delay is required for schedule-once")
  (assert function () ":FUNCTION is required for schedule-once")
  (cancel-task name)
  (let* ((task (make-scheduled-task
                :name        name
                :kind        :once
                :interval    after
                :fire-at     (+ (get-universal-time) (round after))
                :function    function
                :active-p    t
                :description description
                :run-count   0)))
    (%register-task task)
    (setf (task-thread task)
          (bt:make-thread
           (lambda () (%once-task-body task))
           :name (format nil "cron:once:~a" name)))
    task))

(defun cancel-task (name)
  "Cancel the task named NAME.  Returns T if a task was found and cancelled, NIL otherwise.

Cancellation is cooperative: the task thread will exit after at most
*CRON-SLEEP-INTERVAL* more seconds (default 0.5s)."
  (check-type name string)
  (bt:with-lock-held (*task-lock*)
    (let ((task (gethash name *task-registry*)))
      (when task
        (setf (task-active-p task) nil)
        (remhash name *task-registry*)
        t))))

(defun find-task (name)
  "Return the SCHEDULED-TASK named NAME, or NIL if not found."
  (check-type name string)
  (bt:with-lock-held (*task-lock*)
    (gethash name *task-registry*)))

(defun list-tasks ()
  "Return a list of all currently registered SCHEDULED-TASK objects."
  (bt:with-lock-held (*task-lock*)
    (let ((result '()))
      (maphash (lambda (k v) (declare (ignore k)) (push v result))
               *task-registry*)
      (nreverse result))))

(defun clear-tasks ()
  "Cancel all registered tasks.  Returns the count of tasks cancelled."
  (bt:with-lock-held (*task-lock*)
    (let ((count (hash-table-count *task-registry*)))
      (maphash (lambda (k v)
                 (declare (ignore k))
                 (setf (task-active-p v) nil))
               *task-registry*)
      (clrhash *task-registry*)
      count)))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 6. Introspection / Display
;;;; ─────────────────────────────────────────────────────────────────────────────

(defun task-info (task)
  "Return a hash-table with a JSON-serializable summary of TASK.

Keys: name, kind, interval, fire_at, active, description,
      last_run, last_error, run_count."
  (let ((ht (make-hash-table :test 'equal))
        (now (get-universal-time)))
    (setf (gethash "name"        ht) (task-name task)
          (gethash "kind"        ht) (string-downcase (symbol-name (task-kind task)))
          (gethash "interval"    ht) (task-interval task)
          (gethash "fires_in"    ht) (max 0 (- (task-fire-at task) now))
          (gethash "active"      ht) (if (task-active-p task) t :false)
          (gethash "description" ht) (or (task-description task) "")
          (gethash "last_run"    ht) (or (task-last-run task) :null)
          (gethash "last_error"  ht) (or (task-last-error task) :null)
          (gethash "run_count"   ht) (task-run-count task))
    ht))

(defun describe-tasks (&optional (stream t))
  "Print a human-readable summary of all scheduled tasks to STREAM."
  (let ((tasks (list-tasks)))
    (if (null tasks)
        (format stream "~&No scheduled tasks.~%")
        (dolist (task tasks)
          (format stream "~&  ~a [~a] every ~as  runs:~a~@[  ~a~]~%"
                  (task-name task)
                  (task-kind task)
                  (task-interval task)
                  (task-run-count task)
                  (task-description task)))))
  (values))
