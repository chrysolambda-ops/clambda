;;;; src/registry.lisp — Agent Registry (Task 2.2)
;;;;
;;;; Provides a global registry of named agent specs.
;;;; Specs can be created declaratively with DEFINE-AGENT and
;;;; instantiated into live AGENT objects with INSTANTIATE-AGENT-SPEC.

(in-package #:clawmacs/registry)

(declaim (special clawmacs/config::*heartbeat-interval*
                  clawmacs/config::*default-max-turns*))

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
  (client        nil)                    ; a CL-LLM:CLIENT, or NIL
  ;; Heartbeat configuration (per-agent override of global *heartbeat-interval*)
  (heartbeat-interval nil :type (or null integer))  ; seconds; NIL = use global
  (heartbeat-prompt   nil :type (or null string))   ; custom prompt; NIL = default
  (heartbeat-quiet-start nil :type (or null integer)) ; hour 0-23; NIL = no quiet hours
  (heartbeat-quiet-end   nil :type (or null integer)) ; hour 0-23
  (heartbeat-channel     nil :type (or null keyword)) ; :telegram, :irc, or NIL
  (heartbeat-target      nil :type (or null string))) ; channel target (chat-id, channel name)

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

;;; ── Heartbeat System ──────────────────────────────────────────────────────────
;;;
;;; OpenClaw-parity heartbeat with:
;;;   - Per-agent intervals and prompts
;;;   - HEARTBEAT_OK detection (suppress empty replies)
;;;   - Quiet hours (skip heartbeats during sleep time)
;;;   - State tracking (heartbeat-state.json in workspace)
;;;   - Channel delivery (send non-trivial replies to Telegram/IRC)
;;;   - Default prompt reads HEARTBEAT.md + workspace context

(defvar *default-heartbeat-prompt*
  "Read HEARTBEAT.md if it exists (workspace context). Follow it strictly.
Do not infer or repeat old tasks from prior chats.
If nothing needs attention, reply HEARTBEAT_OK."
  "Default heartbeat prompt used when agent-spec has no custom prompt.")

(defvar *heartbeat-callback* nil
  "Optional (lambda (agent-name reply channel target)) called for non-trivial heartbeat replies.
Set this to integrate with channel delivery. If NIL, replies are logged only.")

(defun %heartbeat-task-name (name)
  (format nil "heartbeat:~a" (normalize-name name)))

(defun %current-hour ()
  "Return current hour (0-23) in local time."
  (nth-value 2 (decode-universal-time (get-universal-time))))

(defun %in-quiet-hours-p (spec)
  "Return T if current time is within SPEC's quiet hours."
  (let ((start (agent-spec-heartbeat-quiet-start spec))
        (end   (agent-spec-heartbeat-quiet-end spec)))
    (when (and start end)
      (let ((hour (%current-hour)))
        (if (<= start end)
            ;; Normal range: e.g. 23-8 wraps, 9-17 doesn't
            ;; Wait, start <= end means no wrap: e.g. start=9 end=17
            (and (>= hour start) (< hour end))
            ;; Wrapped: e.g. start=23 end=8 means 23,0,1,...,7
            (or (>= hour start) (< hour end)))))))

(defun %heartbeat-state-path (workspace)
  "Return path to heartbeat-state.json in WORKSPACE."
  (merge-pathnames "memory/heartbeat-state.json" workspace))

(defun %load-heartbeat-state (workspace)
  "Load heartbeat state from workspace, or return empty alist."
  (let ((path (%heartbeat-state-path workspace)))
    (if (probe-file path)
        (handler-case
            (com.inuoe.jzon:parse (uiop:read-file-string path) :key-fn #'identity)
          (error () (make-hash-table :test 'equal)))
        (make-hash-table :test 'equal))))

(defun %save-heartbeat-state (workspace state)
  "Save heartbeat STATE hash-table to workspace."
  (let ((path (%heartbeat-state-path workspace)))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output
                              :if-exists :supersede
                              :external-format :utf-8)
      (com.inuoe.jzon:stringify state :stream out :pretty t))))

(defun %heartbeat-ok-p (reply)
  "Return T if REPLY is a heartbeat-ok acknowledgment (nothing to report)."
  (when (stringp reply)
    (let ((trimmed (string-trim '(#\Space #\Tab #\Newline #\Return) reply)))
      (or (string= trimmed "HEARTBEAT_OK")
          (string= trimmed "heartbeat_ok")
          (string= trimmed "Heartbeat_OK")
          ;; Also catch "HEARTBEAT_OK" embedded at start/end
          (and (>= (length trimmed) 12)
               (or (search "HEARTBEAT_OK" trimmed)
                   (search "heartbeat_ok" trimmed)))))))

(defun %build-heartbeat-prompt (spec workspace)
  "Build the full heartbeat prompt for SPEC, incorporating HEARTBEAT.md if present."
  (let* ((custom-prompt (agent-spec-heartbeat-prompt spec))
         (base-prompt   (or custom-prompt *default-heartbeat-prompt*))
         (heartbeat-file (and workspace (merge-pathnames "HEARTBEAT.md" workspace)))
         (heartbeat-content (when (and heartbeat-file (probe-file heartbeat-file))
                              (string-trim '(#\Space #\Tab #\Newline #\Return)
                                           (uiop:read-file-string heartbeat-file)))))
    ;; If there's a custom prompt, use it directly
    (if custom-prompt
        custom-prompt
        ;; Otherwise build the default: prompt + HEARTBEAT.md contents
        (if (and heartbeat-content (> (length heartbeat-content) 0)
                 ;; Skip if HEARTBEAT.md is only comments
                 (not (every (lambda (line)
                               (let ((trimmed (string-trim '(#\Space #\Tab) line)))
                                 (or (= (length trimmed) 0)
                                     (char= (char trimmed 0) #\#))))
                             (uiop:split-string heartbeat-content :separator '(#\Newline)))))
            (format nil "~a~%~%--- HEARTBEAT.md contents ---~%~a" base-prompt heartbeat-content)
            ;; HEARTBEAT.md is empty/comments-only: nothing to do
            nil))))

(defun %heartbeat-body (name)
  "Execute one heartbeat cycle for agent NAME."
  (handler-case
      (let* ((spec (find-agent name))
             (agent (and spec (car (multiple-value-list (instantiate-agent-spec spec)))))
             (workspace (and agent (clawmacs/agent::agent-workspace agent))))
        (when (and spec agent)
          ;; Check quiet hours
          (when (%in-quiet-hours-p spec)
            (format t "~&[heartbeat:~a] Skipping — quiet hours~%" name)
            (return-from %heartbeat-body nil))

          ;; Build prompt
          (let ((prompt (%build-heartbeat-prompt spec workspace)))
            (unless prompt
              ;; No HEARTBEAT.md content and no custom prompt → skip
              (return-from %heartbeat-body nil))

            ;; Ensure workspace context is fresh
            (when (boundp 'clawmacs/bootstrap::ensure-agent-ready)
              (handler-case
                  (clawmacs/bootstrap:ensure-agent-ready agent :auto-bootstrap nil)
                (error () nil)))

            ;; Run the agent
            (let* ((session (clawmacs/session:make-session :agent agent))
                   (reply (clawmacs/loop:run-agent session prompt
                                                   :options (clawmacs/loop:make-loop-options
                                                             :max-turns (or (agent-spec-max-turns spec)
                                                                            clawmacs/config:*default-max-turns*)))))
              ;; Update heartbeat state
              (when workspace
                (handler-case
                    (let ((state (%load-heartbeat-state workspace)))
                      (setf (gethash "lastHeartbeat" state) (get-universal-time))
                      (setf (gethash "lastReply" state)
                            (if (%heartbeat-ok-p reply) "ok" "active"))
                      (%save-heartbeat-state workspace state))
                  (error () nil)))

              ;; Process reply
              (cond
                ;; HEARTBEAT_OK → nothing to do, agent says all clear
                ((%heartbeat-ok-p reply)
                 (format t "~&[heartbeat:~a] OK — nothing to report~%" name))

                ;; Non-trivial reply → deliver via callback or log
                ((and reply (> (length (string-trim '(#\Space #\Tab #\Newline #\Return)
                                                    reply)) 0))
                 (format t "~&[heartbeat:~a] Active reply (~d chars)~%"
                         name (length reply))
                 ;; Deliver via callback if set
                 (when *heartbeat-callback*
                   (handler-case
                       (funcall *heartbeat-callback*
                                name reply
                                (agent-spec-heartbeat-channel spec)
                                (agent-spec-heartbeat-target spec))
                     (error (e)
                       (warn "heartbeat callback for ~a failed: ~a" name e)))))

                ;; Empty/nil reply
                (t
                 (format t "~&[heartbeat:~a] Empty reply~%" name)))))))
    (error (e)
      (warn "heartbeat for ~a failed: ~a" name e))))

(defun %heartbeat-interval-for (spec)
  "Return the effective heartbeat interval for SPEC in seconds."
  (or (agent-spec-heartbeat-interval spec)
      (and (boundp 'clawmacs/config::*heartbeat-interval*)
           clawmacs/config::*heartbeat-interval*)
      nil))

(defun %maybe-enable-heartbeat (name)
  "Schedule a heartbeat cron task for agent NAME if an interval is configured."
  (let* ((spec (find-agent name))
         (interval (and spec (%heartbeat-interval-for spec))))
    (when (and interval (> interval 0))
      (clawmacs/cron:schedule-task (%heartbeat-task-name name)
                                   :every interval
                                   :description (format nil "Heartbeat for agent ~a (every ~ds)" name interval)
                                   :function (lambda () (%heartbeat-body name))))))

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
                                   tools max-turns client
                                   heartbeat-interval heartbeat-prompt
                                   heartbeat-quiet-start heartbeat-quiet-end
                                   heartbeat-channel heartbeat-target)
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
:HEARTBEAT-INTERVAL — seconds between heartbeats (overrides global *heartbeat-interval*).
:HEARTBEAT-PROMPT — custom heartbeat prompt (default reads HEARTBEAT.md).
:HEARTBEAT-QUIET-START / :HEARTBEAT-QUIET-END — hour range (0-23) to skip heartbeats.
:HEARTBEAT-CHANNEL — :telegram or :irc for reply delivery.
:HEARTBEAT-TARGET — channel target (chat-id, channel name).

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
                  :client        ,client
                  :heartbeat-interval    ,heartbeat-interval
                  :heartbeat-prompt      ,heartbeat-prompt
                  :heartbeat-quiet-start ,heartbeat-quiet-start
                  :heartbeat-quiet-end   ,heartbeat-quiet-end
                  :heartbeat-channel     ,heartbeat-channel
                  :heartbeat-target      ,heartbeat-target)))
       (register-agent ,name-form spec)
       spec)))
