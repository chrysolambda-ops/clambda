;;;; src/agent.lisp — Agent CLOS class

(in-package #:clawmacs/agent)

;;; ── Agent class ──────────────────────────────────────────────────────────────

(defclass agent ()
  ((name
    :initarg :name
    :accessor agent-name
    :initform "agent"
    :type string
    :documentation "Agent identifier / handle.")
   (role
    :initarg :role
    :accessor agent-role
    :initform "assistant"
    :type string
    :documentation "Agent role label (e.g. \"assistant\", \"coder\", \"researcher\").")
   (model
    :initarg :model
    :accessor agent-model
    :initform nil
    :type (or null string)
    :documentation "LLM model name; overrides client default if set.")
   (workspace-path
    :initarg :workspace-path
    :accessor agent-workspace-path
    :initform nil
    :type (or null string)
    :documentation "Path to the agent's workspace directory.")
   (system-prompt
    :initarg :system-prompt
    :accessor agent-system-prompt
    :initform nil
    :type (or null string)
    :documentation "System prompt for this agent. If NIL, a default is generated.")
   (client
    :initarg :client
    :accessor agent-client
    :initform nil
    :documentation "CL-LLM client (cl-llm:client) used for LLM calls.")
   (tool-registry
    :initarg :tool-registry
    :accessor agent-tool-registry
    :initform nil
    :documentation "A CLAMBDA/TOOLS:TOOL-REGISTRY for this agent's tools."))
  (:documentation
   "An agent is the primary actor in clawmacs-core.
It has an identity (name, role), an LLM backend (client + model),
a workspace directory, a system prompt, and a set of tools."))

(defmethod print-object ((agent agent) stream)
  (print-unreadable-object (agent stream :type t :identity t)
    (format stream "~s role=~s model=~s"
            (agent-name agent)
            (agent-role agent)
            (or (agent-model agent) "(default)"))))

;;; ── Constructor ──────────────────────────────────────────────────────────────

(defun make-agent (&key name role model workspace-path system-prompt client tool-registry)
  "Create a new AGENT.

NAME — string identifier (default: \"agent\").
ROLE — role label (default: \"assistant\").
MODEL — LLM model override (string, or NIL to use client default).
WORKSPACE-PATH — directory path string for the agent's files.
SYSTEM-PROMPT — system prompt string (or NIL to auto-generate).
CLIENT — a CL-LLM:CLIENT instance.
TOOL-REGISTRY — a CLAMBDA/TOOLS:TOOL-REGISTRY instance."
  (make-instance 'agent
                 :name           (or name "agent")
                 :role           (or role "assistant")
                 :model          model
                 :workspace-path workspace-path
                 :system-prompt  system-prompt
                 :client         client
                 :tool-registry  tool-registry))

;;; ── Computed properties ──────────────────────────────────────────────────────

(defun agent-effective-system-prompt (agent)
  "Return the agent's system prompt, generating a default if not set."
  (or (agent-system-prompt agent)
      (format nil "You are ~a, a ~a AI assistant.~@[
Your workspace is at: ~a~]
Be helpful, concise, and accurate."
              (agent-name agent)
              (agent-role agent)
              (agent-workspace-path agent))))

(defun agent-with-tools (agent tool-registry)
  "Return a new agent with the given TOOL-REGISTRY, sharing all other slots."
  (make-instance 'agent
                 :name           (agent-name agent)
                 :role           (agent-role agent)
                 :model          (agent-model agent)
                 :workspace-path (agent-workspace-path agent)
                 :system-prompt  (agent-system-prompt agent)
                 :client         (agent-client agent)
                 :tool-registry  tool-registry))
