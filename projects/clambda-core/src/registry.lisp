;;;; src/registry.lisp — Agent Registry (Task 2.2)
;;;;
;;;; Provides a global registry of named agent specs.
;;;; Specs can be created declaratively with DEFINE-AGENT and
;;;; instantiated into live AGENT objects with INSTANTIATE-AGENT-SPEC.

(in-package #:clawmacs/registry)

;;; ── Agent Spec ───────────────────────────────────────────────────────────────

(defstruct (agent-spec (:conc-name agent-spec-))
  "A declarative description of an agent (data, not a live object).
Can be registered by name and later instantiated into an AGENT."
  (name          ""  :type string)
  (role          "assistant" :type string)
  (display-name  nil :type (or null string))
  (emoji         nil :type (or null string))
  (theme         nil :type (or null string))
  (model         nil :type (or null string))
  (workspace     nil :type (or null pathname))
  (system-prompt nil :type (or null string))
  (tools         nil :type list)         ; list of tool name strings
  (max-turns     nil :type (or null integer)) ; override *default-max-turns*
  (client        nil))                   ; a CL-LLM:CLIENT, or NIL

(defmethod print-object ((spec agent-spec) stream)
  (print-unreadable-object (spec stream :type t)
    (format stream "~s role=~s model=~s"
            (agent-spec-name spec)
            (agent-spec-role spec)
            (or (agent-spec-model spec) "(default)"))))

;;; ── Global Registry ──────────────────────────────────────────────────────────

(defvar *agent-registry* (make-hash-table :test 'equal)
  "Global registry mapping agent name strings (and keywords) to AGENT-SPEC objects.
Use REGISTER-AGENT / FIND-AGENT / LIST-AGENTS to access it.")

(defvar *registry-lock* (bt:make-lock "agent-registry-lock")
  "Protects *AGENT-REGISTRY* for concurrent access.")

(defvar *agent-message-queues* (make-hash-table :test 'equal)
  "Per-agent FIFO queues for inter-agent messages.")

;;; ── Operations ───────────────────────────────────────────────────────────────

(defun normalize-name (name)
  "Normalize NAME to a string key. Accepts strings and keywords."
  (etypecase name
    (string  name)
    (keyword (string-downcase (symbol-name name)))))

(defun send-to-agent (target-name message &key from)
  "Queue MESSAGE for TARGET-NAME. Returns T when queued, NIL when target missing."
  (let ((key (normalize-name target-name)))
    (bt:with-lock-held (*registry-lock*)
      (when (gethash key *agent-registry*)
        (setf (gethash key *agent-message-queues*)
              (append (gethash key *agent-message-queues*)
                      (list (if from
                                (format nil "From ~a: ~a" from message)
                                message))))
        t))))

(defun consume-agent-messages (name)
  "Return and clear pending inter-agent messages for NAME."
  (let ((key (normalize-name name)))
    (bt:with-lock-held (*registry-lock*)
      (prog1 (copy-list (gethash key *agent-message-queues*))
        (setf (gethash key *agent-message-queues*) nil)))))

(defun %heartbeat-task-name (name)
  (format nil "heartbeat:~a" (normalize-name name)))

(defun %heartbeat-body (name)
  (handler-case
      (let* ((spec (find-agent name))
             (agent (and spec (car (multiple-value-list (instantiate-agent-spec spec)))))
             (workspace (and agent (clawmacs/agent::agent-workspace agent)))
             (heartbeat-file (and workspace (merge-pathnames "HEARTBEAT.md" workspace))))
        (when (and heartbeat-file (probe-file heartbeat-file))
          (let ((prompt (string-trim '(#\Space #\Tab #\Newline #\Return)
                                     (uiop:read-file-string heartbeat-file))))
            (when (> (length prompt) 0)
              (let* ((session (clawmacs/session:make-session :agent agent))
                     (reply (clawmacs/loop:run-agent session prompt
                                                     :options (clawmacs/loop:make-loop-options
                                                               :max-turns (or (agent-spec-max-turns spec)
                                                                              clawmacs/config:*default-max-turns*)))))
                (declare (ignore reply)))))))
    (error (e)
      (warn "heartbeat for ~a failed: ~a" name e))))

(defun %maybe-enable-heartbeat (name)
  (when (and (boundp 'clawmacs/config::*heartbeat-interval*)
             clawmacs/config::*heartbeat-interval*
             (> clawmacs/config::*heartbeat-interval* 0))
    (clawmacs/cron:schedule-task (%heartbeat-task-name name)
                                 :every clawmacs/config::*heartbeat-interval*
                                 :description (format nil "Heartbeat for agent ~a" name)
                                 :function (lambda () (%heartbeat-body name)))))

(defun register-agent (name spec)
  "Register SPEC (an AGENT-SPEC or an AGENT) under NAME in *AGENT-REGISTRY*.
NAME can be a string or keyword. Returns SPEC."
  (let ((key (normalize-name name)))
    (bt:with-lock-held (*registry-lock*)
      (setf (gethash key *agent-registry*) spec))
    (%maybe-enable-heartbeat key))
  spec)

(defun find-agent (name)
  "Return the AGENT-SPEC registered under NAME, or NIL if not found.
NAME can be a string or keyword."
  (let ((key (normalize-name name)))
    (bt:with-lock-held (*registry-lock*)
      (gethash key *agent-registry*))))

(defun unregister-agent (name)
  "Remove the entry for NAME from *AGENT-REGISTRY*. Returns T if removed."
  (let ((key (normalize-name name)))
    (bt:with-lock-held (*registry-lock*)
      (remhash key *agent-message-queues*)
      (remhash key *agent-registry*))))

(defun list-agents ()
  "Return a list of all registered AGENT-SPECs."
  (bt:with-lock-held (*registry-lock*)
    (let ((result '()))
      (maphash (lambda (k v)
                 (declare (ignore k))
                 (push v result))
               *agent-registry*)
      (nreverse result))))

(defun clear-registry ()
  "Remove all entries from *AGENT-REGISTRY*."
  (bt:with-lock-held (*registry-lock*)
    (clrhash *agent-registry*)
    (clrhash *agent-message-queues*)))

;;; ── Tool name conversion ─────────────────────────────────────────────────────

(defun %tool-symbol-to-name (sym)
  "Convert a tool symbol to its canonical string name.
SYM may be a symbol (web-fetch → \"web_fetch\") or a string (returned as-is)."
  (etypecase sym
    (symbol (substitute #\_ #\- (string-downcase (symbol-name sym))))
    (string sym)))

;;; ── Instantiation ────────────────────────────────────────────────────────────

(defun instantiate-agent-spec (spec)
  "Create a live AGENT from SPEC (an AGENT-SPEC).

If the spec has a :TOOLS list, build a filtered TOOL-REGISTRY containing only
those tools from the global built-in registry. If :TOOLS is NIL, tool-registry
is NIL and the caller is responsible for wiring tools.

Returns: (values agent spec)"
  (check-type spec agent-spec)
  (let ((registry
         (when (agent-spec-tools spec)
           ;; Build a registry containing only the specified built-in tools.
           (handler-case
               (let ((builtin (clawmacs/builtins:make-builtin-registry))
                     (new     (clawmacs/tools:make-tool-registry)))
                 (dolist (tool-name (agent-spec-tools spec))
                   (unless (clawmacs/tools:find-tool builtin tool-name)
                     (warn "define-agent: tool ~s not found in builtin registry"
                           tool-name)))
                 (clawmacs/tools:copy-tools-to-registry
                  builtin new (agent-spec-tools spec))
                 new)
             (error (e)
               (warn "instantiate-agent-spec: error building tool registry: ~a" e)
               nil)))))
    (values
     (clawmacs/agent:make-agent
      :name           (agent-spec-name spec)
      :role           (agent-spec-role spec)
      :display-name   (agent-spec-display-name spec)
      :emoji          (agent-spec-emoji spec)
      :theme          (agent-spec-theme spec)
      :model          (agent-spec-model spec)
      :workspace      (or (agent-spec-workspace spec)
                          (clawmacs/agent::default-agent-workspace
                           (agent-spec-name spec)))
      :system-prompt  (agent-spec-system-prompt spec)
      :client         (agent-spec-client spec)
      :tool-registry  registry)
     spec)))

;;; ── Declarative Definition Macro ─────────────────────────────────────────────

(defun %normalize-agent-name (name)
  "Normalize NAME to a lowercase string for the registry.
Accepts symbols, keywords, or strings."
  (etypecase name
    (string  name)
    (keyword (string-downcase (symbol-name name)))
    (symbol  (string-downcase (symbol-name name)))))

(defmacro define-agent (name &key (role "assistant") display-name emoji theme
                                   model workspace system-prompt
                                   tools max-turns client)
  "High-level DSL for defining and registering an agent spec.

Idiomatic usage from init.lisp:

  (define-agent researcher
    :model \"google/gemma-3-4b\"
    :system-prompt \"You are a research agent.\"
    :tools (web-fetch browser-navigate)
    :max-turns 20)

NAME — a symbol, keyword, or string. Symbol names are lowercased.
:ROLE — role label (default: \"assistant\").
:DISPLAY-NAME — optional human-facing name.
:EMOJI — optional identity emoji.
:THEME — optional theme string.
:MODEL — LLM model string. NIL uses *default-model* at instantiation time.
:WORKSPACE — pathname/string workspace directory (default ~/.clawmacs/agents/<name>/).
:SYSTEM-PROMPT — agent system prompt.
:TOOLS — list of tool name symbols or strings. Symbols are converted:
         web-fetch → \"web_fetch\", browser-navigate → \"browser_navigate\".
         Tools are looked up in the built-in registry at instantiation time.
:MAX-TURNS — maximum turns for this agent's loop (overrides *default-max-turns*).
:CLIENT — a CL-LLM:CLIENT instance, or NIL.

Registers the spec in *AGENT-REGISTRY*. To create a live agent, call
INSTANTIATE-AGENT-SPEC on the registered spec.

This macro expands to: spec creation + tool name encoding + registry registration."
  (let* ((name-form
          ;; Convert compile-time symbol/keyword to string
          (cond
            ((stringp name)  name)
            ((keywordp name) (string-downcase (symbol-name name)))
            ((symbolp name)  (string-downcase (symbol-name name)))
            (t `(%normalize-agent-name ,name))))
         ;; Convert tool symbols to strings at compile time if possible
         (tools-form
          (if (and (listp tools)
                   (every (lambda (t1) (or (symbolp t1) (stringp t1))) tools))
              `(list ,@(mapcar (lambda (t1) (%tool-symbol-to-name t1)) tools))
              `(mapcar #'%tool-symbol-to-name (list ,@tools)))))
    `(let ((spec (make-agent-spec
                  :name          ,name-form
                  :role          ,role
                  :display-name  ,display-name
                  :emoji         ,emoji
                  :theme         ,theme
                  :model         ,model
                  :workspace     ,(if (null workspace)
                                       `(clawmacs/agent::default-agent-workspace ,name-form)
                                       workspace)
                  :system-prompt ,system-prompt
                  :tools         ,tools-form
                  :max-turns     ,max-turns
                  :client        ,client)))
       (register-agent ,name-form spec)
       spec)))
