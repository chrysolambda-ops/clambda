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
   (display-name
    :initarg :display-name
    :accessor agent-display-name
    :initform nil
    :type (or null string)
    :documentation "Human-facing display name for channels/UIs.")
   (emoji
    :initarg :emoji
    :accessor agent-emoji
    :initform nil
    :type (or null string)
    :documentation "Optional identity emoji.")
   (theme
    :initarg :theme
    :accessor agent-theme
    :initform nil
    :type (or null string)
    :documentation "Optional identity theme string.")
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
   (workspace
    :initarg :workspace
    :accessor agent-workspace
    :initform nil
    :type (or null pathname)
    :documentation "Pathname of the agent workspace directory.")
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
    (format stream "~s/~s ~@[~a ~]role=~s model=~s"
            (agent-name agent)
            (or (agent-display-name agent) "-")
            (agent-emoji agent)
            (agent-role agent)
            (or (agent-model agent) "(default)"))))

;;; ── Constructor ──────────────────────────────────────────────────────────────

(defun default-agent-workspace (agent-name)
  "Return the default workspace pathname for AGENT-NAME.

Default: ~/.clawmacs/agents/<agent-name>/"
  (uiop:ensure-directory-pathname
   (merge-pathnames (format nil ".clawmacs/agents/~a/" agent-name)
                    (user-homedir-pathname))))

(defun agent-workspace-path (agent)
  "Backward-compatible workspace path accessor as a namestring (or NIL)."
  (let ((ws (agent-workspace agent)))
    (when ws
      (namestring ws))))

(defun make-agent (&key name display-name emoji theme role model workspace workspace-path
                     system-prompt client tool-registry)
  "Create a new AGENT."
  (let* ((agent-name (or name "agent"))
         (ws-input   (or workspace workspace-path))
         (ws         (uiop:ensure-directory-pathname
                      (typecase ws-input
                        (null (default-agent-workspace agent-name))
                        (pathname ws-input)
                        (string (uiop:parse-native-namestring ws-input))))))
    (make-instance 'agent
                   :name           agent-name
                   :display-name   display-name
                   :emoji          emoji
                   :theme          theme
                   :role           (or role "assistant")
                   :model          model
                   :workspace      ws
                   :system-prompt  system-prompt
                   :client         client
                   :tool-registry  tool-registry)))

;;; ── Computed properties ──────────────────────────────────────────────────────

(defun agent-effective-system-prompt (agent)
  "Return the agent's system prompt, generating a default if not set."
  (or (agent-system-prompt agent)
      (let ((who (or (agent-display-name agent) (agent-name agent)))
            (emoji (agent-emoji agent)))
        (format nil "You are ~a~@[ ~a~], a ~a AI assistant.~@[
Theme: ~a~]~@[
Your workspace is at: ~a~]
Be helpful, concise, and accurate."
                who
                emoji
                (agent-role agent)
                (agent-theme agent)
                (agent-workspace-path agent)))))

(defun agent-with-tools (agent tool-registry)
  "Return a new agent with the given TOOL-REGISTRY, sharing all other slots."
  (make-instance 'agent
                 :name           (agent-name agent)
                 :display-name   (agent-display-name agent)
                 :emoji          (agent-emoji agent)
                 :theme          (agent-theme agent)
                 :role           (agent-role agent)
                 :model          (agent-model agent)
                 :workspace      (agent-workspace agent)
                 :system-prompt  (agent-system-prompt agent)
                 :client         (agent-client agent)
                 :tool-registry  tool-registry))
