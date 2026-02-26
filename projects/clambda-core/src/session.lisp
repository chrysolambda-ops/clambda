;;;; src/session.lisp — Session management

(in-package #:clambda/session)

;;; ── ID generation ────────────────────────────────────────────────────────────

(defun generate-session-id ()
  "Generate a simple unique session ID string."
  (format nil "session-~a-~a"
          (get-universal-time)
          (random 99999)))

;;; ── Session class ────────────────────────────────────────────────────────────

(defclass session ()
  ((id
    :initarg :id
    :accessor session-id
    :type string
    :documentation "Unique session identifier.")
   (agent
    :initarg :agent
    :accessor session-agent
    :documentation "The AGENT this session belongs to.")
   (messages
    :initarg :messages
    :accessor session-messages
    :initform nil
    :type list
    :documentation "Ordered list of CL-LLM MESSAGE structs (conversation history).")
   (metadata
    :initarg :metadata
    :accessor session-metadata
    :initform nil
    :type list
    :documentation "Plist of arbitrary session metadata.")
   (created-at
    :initarg :created-at
    :accessor session-created-at
    :documentation "Universal time when this session was created."))
  (:documentation
   "A session represents a conversation context for an agent.
It holds the message history and is associated with one agent."))

(defmethod print-object ((session session) stream)
  (print-unreadable-object (session stream :type t :identity t)
    (format stream "~s msgs=~a"
            (session-id session)
            (length (session-messages session)))))

;;; ── Constructor ──────────────────────────────────────────────────────────────

(defun make-session (&key agent id metadata)
  "Create a new SESSION for AGENT.

AGENT — the CLAMBDA/AGENT:AGENT this session belongs to.
ID — optional session ID string (auto-generated if not provided).
METADATA — optional plist of metadata."
  (make-instance 'session
                 :id         (or id (generate-session-id))
                 :agent      agent
                 :messages   nil
                 :metadata   metadata
                 :created-at (get-universal-time)))

;;; ── Message operations ───────────────────────────────────────────────────────

(defun session-add-message (session message)
  "Append MESSAGE to SESSION's history. Returns SESSION."
  (setf (session-messages session)
        (append (session-messages session) (list message)))
  session)

(defun session-clear-messages (session)
  "Remove all messages from SESSION. Returns SESSION."
  (setf (session-messages session) nil)
  session)

(defun session-message-count (session)
  "Return the number of messages in SESSION."
  (length (session-messages session)))

(defun session-last-message (session)
  "Return the last message in SESSION, or NIL if empty."
  (car (last (session-messages session))))

;;; ── Basic persistence ────────────────────────────────────────────────────────

(defun messages->json-list (messages)
  "Convert a list of cl-llm MESSAGE structs to a serializable list."
  (mapcar (lambda (msg)
            (let ((ht (make-hash-table :test #'equal)))
              (setf (gethash "role" ht)
                    (string-downcase
                     (symbol-name (cl-llm/protocol:message-role msg))))
              (setf (gethash "content" ht)
                    (or (cl-llm/protocol:message-content msg) ""))
              ;; Tool call id if present
              (when (cl-llm/protocol:message-tool-call-id msg)
                (setf (gethash "tool_call_id" ht)
                      (cl-llm/protocol:message-tool-call-id msg)))
              ht))
          messages))

(defun save-session (session path)
  "Save SESSION's message history to PATH as JSON.
Returns the path string."
  (let* ((data (make-hash-table :test #'equal))
         (path-str (if (pathnamep path) (namestring path) path)))
    (setf (gethash "id" data) (session-id session))
    (setf (gethash "created_at" data) (session-created-at session))
    (setf (gethash "messages" data)
          (coerce (messages->json-list (session-messages session)) 'vector))
    (ensure-directories-exist path-str)
    (with-open-file (out path-str
                         :direction :output
                         :if-exists :supersede
                         :if-does-not-exist :create)
      (com.inuoe.jzon:stringify data :stream out :pretty t))
    path-str))

(defun load-session (agent path)
  "Load a session from PATH (JSON) and return a new SESSION for AGENT.
Message history is restored as raw message structs where possible."
  (let* ((path-str (if (pathnamep path) (namestring path) path))
         (data (com.inuoe.jzon:parse (uiop:read-file-string path-str)))
         (session (make-session
                   :agent agent
                   :id (gethash "id" data)
                   :metadata nil))
         (msgs-data (gethash "messages" data)))
    ;; Restore messages as USER/ASSISTANT/etc. message structs
    (when msgs-data
      (loop :for msg-ht :across msgs-data
            :for role = (gethash "role" msg-ht "user")
            :for content = (gethash "content" msg-ht "")
            :for msg = (cond
                         ((string= role "system")
                          (cl-llm/protocol:system-message content))
                         ((string= role "assistant")
                          (cl-llm/protocol:assistant-message content))
                         ((string= role "tool")
                          (cl-llm/protocol:tool-message
                           content
                           (gethash "tool_call_id" msg-ht "")))
                         (t
                          (cl-llm/protocol:user-message content)))
            :do (session-add-message session msg)))
    session))
