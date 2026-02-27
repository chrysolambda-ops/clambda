;;;; src/conditions.lisp — Condition hierarchy for clawmacs-core

(in-package #:clawmacs/conditions)

;;; ── Base ─────────────────────────────────────────────────────────────────────

(define-condition clawmacs-error (error)
  ()
  (:documentation "Base condition for all clawmacs-core errors."))

;;; ── Agent errors ─────────────────────────────────────────────────────────────

(define-condition agent-error (clawmacs-error)
  ((agent :initarg :agent :reader agent-error-agent))
  (:report (lambda (c s)
             (format s "Agent error~@[ for ~a~]"
                     (and (slot-boundp c 'agent) (agent-error-agent c)))))
  (:documentation "Error related to an agent."))

;;; ── Session errors ───────────────────────────────────────────────────────────

(define-condition session-error (clawmacs-error)
  ((session :initarg :session :reader session-error-session))
  (:report (lambda (c s)
             (format s "Session error~@[ for ~a~]"
                     (and (slot-boundp c 'session) (session-error-session c)))))
  (:documentation "Error related to a session."))

;;; ── Tool errors ──────────────────────────────────────────────────────────────

(define-condition tool-not-found (clawmacs-error)
  ((name :initarg :name :reader tool-not-found-name))
  (:report (lambda (c s)
             (format s "No tool registered with name: ~s"
                     (tool-not-found-name c))))
  (:documentation "Signalled when a tool name is not found in the registry."))

(define-condition tool-execution-error (clawmacs-error)
  ((tool-name :initarg :tool-name :reader tool-execution-error-tool-name)
   (cause     :initarg :cause     :reader tool-execution-error-cause)
   (input     :initarg :input     :reader tool-execution-error-input
              :initform nil
              :documentation "The arguments hash-table that caused the failure (or NIL)."))
  (:report (lambda (c s)
             (format s "Error executing tool ~s: ~a"
                     (tool-execution-error-tool-name c)
                     (tool-execution-error-cause c))))
  (:documentation
   "Signalled when a tool handler signals an error during dispatch.
Establishes the RETRY-WITH-FIXED-INPUT restart so the LLM (or a human
via SLIME) can supply corrected arguments and retry without unwinding."))

;;; ── Loop errors ──────────────────────────────────────────────────────────────

(define-condition agent-loop-error (clawmacs-error)
  ((message :initarg :message :initform "Agent loop error" :reader agent-loop-error-message))
  (:report (lambda (c s)
             (write-string (agent-loop-error-message c) s)))
  (:documentation "Error in the agent loop (e.g., max turns exceeded)."))

(define-condition agent-turn-error (clawmacs-error)
  ((session :initarg :session :reader agent-turn-error-session :initform nil)
   (cause   :initarg :cause   :reader agent-turn-error-cause   :initform nil))
  (:report (lambda (c s)
             (format s "Agent turn error~@[: ~a~]"
                     (agent-turn-error-cause c))))
  (:documentation
   "Signalled when an agent turn fails at the LLM-call level (not a tool error).
Offers the ABORT-AGENT-LOOP restart."))

;;; ── Budget errors ────────────────────────────────────────────────────────────

(define-condition budget-exceeded (clawmacs-error)
  ((kind    :initarg :kind    :reader budget-exceeded-kind
            :documentation "Either :tokens or :turns.")
   (limit   :initarg :limit   :reader budget-exceeded-limit)
   (current :initarg :current :reader budget-exceeded-current))
  (:report (lambda (c s)
             (format s "Budget exceeded: ~a limit ~a reached (current: ~a)"
                     (budget-exceeded-kind c)
                     (budget-exceeded-limit c)
                     (budget-exceeded-current c))))
  (:documentation
   "Signalled when a session exceeds its configured token or turn budget.
KIND  — :tokens or :turns.
LIMIT — the configured maximum.
CURRENT — the actual value that exceeded it."))

;;; ── Restart names ────────────────────────────────────────────────────────────

;; Restart name symbols. Defined (via export) in this package so that all
;; packages that establish or invoke restarts use the SAME symbol object.
;;
;;   RETRY-WITH-FIXED-INPUT — retry a failing tool call with corrected args
;;     Accepts one argument: the new args hash-table.
;;     Established by dispatch-tool-call. Invoked by the LLM repair handler
;;     in handle-tool-calls or by a human via SLIME.
;;
;;   SKIP-TOOL-CALL — skip the failing tool call, return an empty error result
;;
;;   RETRY-TOOL-CALL — retry the tool call without changes (for transient errors)
;;
;;   ABORT-AGENT-LOOP — terminate the agent loop immediately

;; These symbols are already exported; just document them here.
;; They work as restart names because restart-case and invoke-restart
;; compare symbols by identity (package + name).
