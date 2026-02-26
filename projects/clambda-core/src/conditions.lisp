;;;; src/conditions.lisp — Condition hierarchy for clambda-core

(in-package #:clambda/conditions)

;;; ── Base ─────────────────────────────────────────────────────────────────────

(define-condition clambda-error (error)
  ()
  (:documentation "Base condition for all clambda-core errors."))

;;; ── Agent errors ─────────────────────────────────────────────────────────────

(define-condition agent-error (clambda-error)
  ((agent :initarg :agent :reader agent-error-agent))
  (:report (lambda (c s)
             (format s "Agent error~@[ for ~a~]"
                     (and (slot-boundp c 'agent) (agent-error-agent c)))))
  (:documentation "Error related to an agent."))

;;; ── Session errors ───────────────────────────────────────────────────────────

(define-condition session-error (clambda-error)
  ((session :initarg :session :reader session-error-session))
  (:report (lambda (c s)
             (format s "Session error~@[ for ~a~]"
                     (and (slot-boundp c 'session) (session-error-session c)))))
  (:documentation "Error related to a session."))

;;; ── Tool errors ──────────────────────────────────────────────────────────────

(define-condition tool-not-found (clambda-error)
  ((name :initarg :name :reader tool-not-found-name))
  (:report (lambda (c s)
             (format s "No tool registered with name: ~s"
                     (tool-not-found-name c))))
  (:documentation "Signalled when a tool name is not found in the registry."))

(define-condition tool-execution-error (clambda-error)
  ((tool-name :initarg :tool-name :reader tool-execution-error-tool-name)
   (cause     :initarg :cause     :reader tool-execution-error-cause))
  (:report (lambda (c s)
             (format s "Error executing tool ~s: ~a"
                     (tool-execution-error-tool-name c)
                     (tool-execution-error-cause c))))
  (:documentation "Signalled when a tool handler signals an error during dispatch."))

;;; ── Loop errors ──────────────────────────────────────────────────────────────

(define-condition agent-loop-error (clambda-error)
  ((message :initarg :message :initform "Agent loop error" :reader agent-loop-error-message))
  (:report (lambda (c s)
             (write-string (agent-loop-error-message c) s)))
  (:documentation "Error in the agent loop (e.g., max turns exceeded)."))

;;; ── Restart names ────────────────────────────────────────────────────────────

;; These are just symbols used as restart names — no need to define them specially.
;; Documented here for reference:
;;   SKIP-TOOL-CALL — skip the failing tool call, return empty result
;;   RETRY-TOOL-CALL — retry the tool call (caller must re-invoke)
;;   ABORT-AGENT-LOOP — terminate the agent loop immediately
