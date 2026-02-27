;;;; t/test-cron.lisp — Tests for clawmacs/cron (Layer 8a)
;;;;
;;;; Test coverage:
;;;;   1. Struct construction + accessor smoke tests
;;;;   2. schedule-task / schedule-once round-trip
;;;;   3. find-task / list-tasks
;;;;   4. cancel-task removes from registry
;;;;   5. clear-tasks removes everything
;;;;   6. task-info serialization
;;;;   7. Periodic task actually fires (short-interval live test)
;;;;   8. Once task actually fires + self-removes (live test)
;;;;   9. Error in task function is caught (does not crash thread)
;;;;  10. Duplicate name replaces existing task
;;;;  11. describe-tasks runs without error

(in-package #:clawmacs-core/tests/cron)

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Helpers
;;; ─────────────────────────────────────────────────────────────────────────────

(defmacro with-clean-registry (&body body)
  "Run BODY with a clean task registry, restored afterwards.
We rebind *task-registry* to an empty table so tests are isolated.
The global *task-lock* is shared — safe for sequential tests."
  `(let ((clawmacs/cron:*task-registry* (make-hash-table :test 'equal)))
     ,@body))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; 1. Struct construction
;;; ─────────────────────────────────────────────────────────────────────────────

(define-test "cron-struct: make-scheduled-task creates a task with correct defaults"
  (let ((task (make-scheduled-task :name "foo" :kind :once :interval 60 :fire-at 0
                                   :function (lambda ()))))
    (is string= "foo" (task-name task))
    (is eq :once (task-kind task))
    (is = 60 (task-interval task))
    (is eq t (task-active-p task))
    (is = 0 (task-run-count task))
    (false (task-last-run task))
    (false (task-last-error task))))

(define-test "cron-struct: :periodic kind"
  (let ((task (make-scheduled-task :name "bar" :kind :periodic :interval 30
                                   :fire-at 0 :function (lambda ()))))
    (is eq :periodic (task-kind task))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; 2. schedule-task / schedule-once (no firing — verify registry insertion)
;;; ─────────────────────────────────────────────────────────────────────────────

(define-test "schedule-task: registers a task and returns it"
  (with-clean-registry
    (let ((task (schedule-task "periodic-test"
                               :every 3600
                               :function (lambda ())
                               :description "hourly task")))
      (true (typep task 'scheduled-task))
      (is string= "periodic-test" (task-name task))
      (is eq :periodic (task-kind task))
      (is = 3600 (task-interval task))
      (is string= "hourly task" (task-description task))
      (true (task-active-p task))
      ;; Clean up
      (cancel-task "periodic-test"))))

(define-test "schedule-once: registers a once task and returns it"
  (with-clean-registry
    (let ((task (schedule-once "once-test"
                               :after 9999
                               :function (lambda ())
                               :description "one shot")))
      (true (typep task 'scheduled-task))
      (is string= "once-test" (task-name task))
      (is eq :once (task-kind task))
      (is = 9999 (task-interval task))
      (true (task-active-p task))
      (cancel-task "once-test"))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; 3. find-task / list-tasks
;;; ─────────────────────────────────────────────────────────────────────────────

(define-test "find-task: returns registered task by name"
  (with-clean-registry
    (schedule-task "alpha" :every 3600 :function (lambda ()))
    (let ((t1 (find-task "alpha")))
      (true t1)
      (is string= "alpha" (task-name t1)))
    (cancel-task "alpha")))

(define-test "find-task: returns NIL for unknown name"
  (with-clean-registry
    (false (find-task "does-not-exist"))))

(define-test "list-tasks: returns all tasks"
  (with-clean-registry
    (schedule-task "t1" :every 3600 :function (lambda ()))
    (schedule-task "t2" :every 1800 :function (lambda ()))
    (let ((tasks (list-tasks)))
      (is = 2 (length tasks))
      (true (find-if (lambda (tsk) (string= "t1" (task-name tsk))) tasks))
      (true (find-if (lambda (tsk) (string= "t2" (task-name tsk))) tasks)))
    (cancel-task "t1")
    (cancel-task "t2")))

(define-test "list-tasks: returns empty list when no tasks"
  (with-clean-registry
    (is eq nil (list-tasks))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; 4. cancel-task
;;; ─────────────────────────────────────────────────────────────────────────────

(define-test "cancel-task: removes task from registry"
  (with-clean-registry
    (schedule-task "to-cancel" :every 3600 :function (lambda ()))
    (true (find-task "to-cancel"))
    (is eq t (cancel-task "to-cancel"))
    (false (find-task "to-cancel"))))

(define-test "cancel-task: returns NIL when task not found"
  (with-clean-registry
    (false (cancel-task "nonexistent"))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; 5. clear-tasks
;;; ─────────────────────────────────────────────────────────────────────────────

(define-test "clear-tasks: removes all tasks and returns count"
  (with-clean-registry
    (schedule-task "c1" :every 3600 :function (lambda ()))
    (schedule-task "c2" :every 1800 :function (lambda ()))
    (schedule-task "c3" :every  900 :function (lambda ()))
    (is = 3 (clear-tasks))
    (is = 0 (length (list-tasks)))))

(define-test "clear-tasks: safe when registry is empty"
  (with-clean-registry
    (is = 0 (clear-tasks))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; 6. task-info serialization
;;; ─────────────────────────────────────────────────────────────────────────────

(define-test "task-info: returns a hash-table with required keys"
  (with-clean-registry
    (let* ((task (schedule-task "info-test" :every 60
                                :function (lambda ())
                                :description "test desc"))
           (ht (task-info task)))
      (true (hash-table-p ht))
      (is string= "info-test" (gethash "name" ht))
      (is string= "periodic"  (gethash "kind" ht))
      (is = 60 (gethash "interval" ht))
      (is string= "test desc" (gethash "description" ht))
      (is eq t (gethash "active" ht))
      (is eq :null (gethash "last_run" ht))
      (is eq :null (gethash "last_error" ht))
      (is = 0 (gethash "run_count" ht))
      (true (>= (gethash "fires_in" ht) 0)))
    (cancel-task "info-test")))

(define-test "task-info: once task shows kind 'once'"
  (with-clean-registry
    (let* ((task (schedule-once "once-info" :after 9999 :function (lambda ())))
           (ht (task-info task)))
      (is string= "once" (gethash "kind" ht)))
    (cancel-task "once-info")))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; 7. Periodic task actually fires (short-interval live test)
;;; ─────────────────────────────────────────────────────────────────────────────

(define-test "periodic-task: fires and increments run-count"
  ;; Uses global registry directly so background thread sees the same state.
  ;; Pre-cancel in case of leftover from a previous test run.
  (cancel-task "fast-periodic-live")
  (let* ((counter 0)
         (clawmacs/cron:*cron-sleep-interval* 0.05))
    (schedule-task "fast-periodic-live"
                   :every 0.2
                   :function (lambda () (incf counter)))
    ;; Wait up to 2 seconds for at least 2 firings
    (let ((deadline (+ (get-universal-time) 2)))
      (loop while (and (< counter 2) (< (get-universal-time) deadline))
            do (sleep 0.1)))
    (cancel-task "fast-periodic-live")
    (true (>= counter 2)
          "Periodic task should have fired at least twice in 2 seconds")))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; 8. Once task fires + self-removes
;;; ─────────────────────────────────────────────────────────────────────────────

(define-test "once-task: fires once and marks itself inactive"
  ;; NOTE: We test on the global registry so thread self-removal works correctly.
  ;; We pre-cancel any existing task with this name and clean up after.
  (cancel-task "fast-once-live")
  (let* ((fired-p nil)
         (clawmacs/cron:*cron-sleep-interval* 0.05))
    (schedule-once "fast-once-live"
                   :after 0.2
                   :function (lambda () (setf fired-p t)))
    ;; Wait up to 2 seconds for the task to fire
    (let ((deadline (+ (get-universal-time) 2)))
      (loop while (and (not fired-p) (< (get-universal-time) deadline))
            do (sleep 0.1)))
    ;; Give thread a moment to self-remove from registry
    (sleep 0.3)
    (true fired-p "Once task should have fired")
    ;; After self-removal, find-task returns NIL (from global registry)
    (false (find-task "fast-once-live")
           "Once task should self-remove after firing")))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; 9. Error in task function is caught
;;; ─────────────────────────────────────────────────────────────────────────────

(define-test "error-in-task: error is caught and stored in last-error"
  ;; Uses global registry so background thread operates on the same state.
  (cancel-task "error-task-live")
  (let* ((clawmacs/cron:*cron-sleep-interval* 0.05)
         (task (schedule-once "error-task-live"
                              :after 0.2
                              :function (lambda () (error "deliberate test error")))))
    ;; Wait for it to fire (up to 2 seconds)
    (let ((deadline (+ (get-universal-time) 2)))
      (loop while (and (null (task-last-error task))
                       (< (get-universal-time) deadline))
            do (sleep 0.1)))
    ;; Task should have recorded the error
    (true (task-last-error task)
          "last-error should be set after task function errors")))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; 10. Duplicate name replaces existing task
;;; ─────────────────────────────────────────────────────────────────────────────

(define-test "duplicate-name: second schedule-task replaces first"
  (with-clean-registry
    ;; First task with 1800s interval
    (schedule-task "dup" :every 1800 :function (lambda ()))
    ;; Second task with different interval — replaces first
    (schedule-task "dup" :every 900 :function (lambda ()))
    ;; Only one task with name "dup"
    (let ((tasks (list-tasks)))
      (is = 1 (length tasks))
      (is = 900 (task-interval (first tasks))))
    (cancel-task "dup")))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; 11. describe-tasks
;;; ─────────────────────────────────────────────────────────────────────────────

(define-test "describe-tasks: runs without error on empty registry"
  (with-clean-registry
    (finish (describe-tasks (make-broadcast-stream)))))

(define-test "describe-tasks: runs without error with tasks present"
  (with-clean-registry
    (schedule-task "dt-test" :every 3600 :function (lambda ()))
    (finish (describe-tasks (make-broadcast-stream)))
    (cancel-task "dt-test")))
