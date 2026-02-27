;;;; src/subagents.lisp — Sub-agent Spawning (Task 2.1)
;;;;
;;;; Provides SPAWN-SUBAGENT, which launches a child agent in a new
;;;; bordeaux-thread and returns a SUBAGENT-HANDLE for monitoring/joining.
;;;;
;;;; The spawned subagent runs the full CLAMBDA/LOOP:RUN-AGENT loop with
;;;; its own fresh SESSION, and the final text response is captured in
;;;; the handle's result slot.

(in-package #:clawmacs/subagents)

;;; ── Status values ────────────────────────────────────────────────────────────

;;  :running   — thread is live
;;  :done      — completed successfully, result in handle-result
;;  :failed    — unhandled condition, cause in handle-error
;;  :killed    — explicitly cancelled via SUBAGENT-KILL

;;; ── Handle struct ────────────────────────────────────────────────────────────

(defstruct (subagent-handle (:constructor %make-subagent-handle))
  "A handle to a running or completed sub-agent.

THREAD  — the bordeaux-threads thread object.
SESSION — the SESSION used by the subagent.
STATUS  — one of :running :done :failed :killed.
RESULT  — final text when STATUS is :done (or NIL).
ERROR   — the condition when STATUS is :failed (or NIL)."
  (thread  nil)
  (session nil)
  (status  :running :type keyword)
  (result  nil)
  (error   nil)
  ;; internal sync
  (lock    nil)
  (cvar    nil))

(defmethod print-object ((h subagent-handle) stream)
  (print-unreadable-object (h stream :type t)
    (format stream "status=~a" (subagent-handle-status h))))

;;; ── Spawn ────────────────────────────────────────────────────────────────────

(defun spawn-subagent (agent-or-spec task-message
                       &key callback options session-id)
  "Spawn a sub-agent in a new thread to handle TASK-MESSAGE.

AGENT-OR-SPEC — an AGENT object or an AGENT-SPEC (from registry).
TASK-MESSAGE  — the user message string to send to the agent.
CALLBACK      — optional (lambda (result)) called in the sub-thread when done.
OPTIONS       — a LOOP-OPTIONS for the sub-agent loop.
SESSION-ID    — optional string ID for the sub-session (auto-generated if NIL).

Returns a SUBAGENT-HANDLE immediately.
Use SUBAGENT-WAIT to block for the result, or SUBAGENT-STATUS to poll."
  ;; Resolve spec → agent
  (let* ((agent (typecase agent-or-spec
                  (clawmacs/agent:agent agent-or-spec)
                  (clawmacs/registry:agent-spec
                   (clawmacs/registry:instantiate-agent-spec agent-or-spec))
                  (t (error "SPAWN-SUBAGENT: expected AGENT or AGENT-SPEC, got ~s"
                            agent-or-spec))))
         (sid     (or session-id
                      (format nil "subagent-~a-~a"
                              (clawmacs/agent:agent-name agent)
                              (get-universal-time))))
         (sess    (clawmacs/session:make-session
                   :id sid :agent agent))
         (lock    (bt:make-lock "subagent-lock"))
         (cvar    (bt:make-condition-variable :name "subagent-cvar"))
         (handle  (%make-subagent-handle
                   :session sess
                   :lock    lock
                   :cvar    cvar
                   :status  :running)))
    ;; Spawn the thread
    (let ((thread
           (bt:make-thread
            (lambda ()
              (handler-case
                  (let ((result (clawmacs/loop:run-agent sess task-message
                                                        :options options)))
                    ;; Store result and signal completion
                    (bt:with-lock-held (lock)
                      (setf (subagent-handle-result handle) result
                            (subagent-handle-status handle) :done)
                      (bt:condition-notify cvar))
                    (when callback
                      (funcall callback result)))
                (serious-condition (c)
                  (bt:with-lock-held (lock)
                    (setf (subagent-handle-error  handle) c
                          (subagent-handle-status handle) :failed)
                    (bt:condition-notify cvar))
                  (when callback
                    (funcall callback nil)))))
            :name (format nil "subagent-~a" sid))))
      (setf (subagent-handle-thread handle) thread)
      handle)))

;;; ── Status / Join / Kill ─────────────────────────────────────────────────────

(defun subagent-status (handle)
  "Return the current status of HANDLE: :running, :done, :failed, or :killed."
  (check-type handle subagent-handle)
  (bt:with-lock-held ((subagent-handle-lock handle))
    (subagent-handle-status handle)))

(defun subagent-wait (handle &key (timeout nil))
  "Block until HANDLE's subagent finishes (or TIMEOUT seconds elapses).

Returns (values result status).
RESULT — the final text, or NIL if failed/killed/timed-out.
STATUS — :done :failed :killed or :running (if timed out)."
  (check-type handle subagent-handle)
  (let ((lock (subagent-handle-lock handle))
        (cvar (subagent-handle-cvar handle)))
    (bt:with-lock-held (lock)
      ;; Wait until status is no longer :running
      (loop :while (eq (subagent-handle-status handle) :running)
            :do (if timeout
                    (bt:condition-wait cvar lock :timeout timeout)
                    (bt:condition-wait cvar lock)))
      (values (subagent-handle-result handle)
              (subagent-handle-status handle)))))

(defun subagent-kill (handle)
  "Attempt to cancel HANDLE's subagent.

Destroys the thread and sets status to :killed.
Note: thread destruction is asynchronous and may leave resources uncleaned.
Returns T if the thread was alive and destroyed, NIL if already finished."
  (check-type handle subagent-handle)
  (bt:with-lock-held ((subagent-handle-lock handle))
    (let ((thread (subagent-handle-thread handle)))
      (when (and thread (bt:thread-alive-p thread))
        (bt:destroy-thread thread)
        (setf (subagent-handle-status handle) :killed)
        (bt:condition-notify (subagent-handle-cvar handle))
        t))))
