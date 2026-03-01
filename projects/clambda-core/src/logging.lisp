;;;; src/logging.lisp — Structured JSON logging for clawmacs-core
;;;;
;;;; Writes newline-delimited JSON log entries to a configurable file.
;;;; Each entry has at minimum: timestamp, event-type, and event-specific fields.
;;;;
;;;; Usage:
;;;;   (setf clawmacs/logging:*log-file* "/tmp/clawmacs.log")
;;;;   (clawmacs/logging:log-llm-request "my-agent" "gpt-4" 3)
;;;;   (clawmacs/logging:with-logging ("/path/to/log") body...)

(in-package #:clawmacs/logging)

;;; ── Configuration ────────────────────────────────────────────────────────────

(defvar *log-file* nil
  "Path to the JSON log file. NIL means logging is disabled.")

(defvar *log-enabled* t
  "Set to NIL to suppress all logging even if *log-file* is set.")

;;; ── Internal helpers ─────────────────────────────────────────────────────────

(defun current-timestamp ()
  "Return ISO-8601-like timestamp string for the current moment."
  (multiple-value-bind (sec min hour day month year)
      (decode-universal-time (get-universal-time) 0)  ; UTC
    (format nil "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0dZ"
            year month day hour min sec)))

(defun write-log-entry (ht)
  "Append HT (a hash-table) as a single JSON line to *LOG-FILE*.
Thread-safe via WITH-OPEN-FILE :IF-EXISTS :APPEND.
Silently ignores errors (logging must not break agent operation)."
  (when (and *log-enabled* *log-file*)
    (handler-case
        (with-open-file (out *log-file*
                             :direction :output
                             :if-exists :append
                             :if-does-not-exist :create)
          (com.inuoe.jzon:stringify ht :stream out)
          (write-char #\Newline out))
      (error (e)
        ;; Logging failures are non-fatal; print to stderr at most
        (ignore-errors
          (format *error-output*
                  "~&[clawmacs/logging] write error: ~a~%" e))))))

(defun make-base-entry (event-type)
  "Return a fresh hash-table with timestamp and event_type pre-populated."
  (let ((ht (make-hash-table :test #'equal)))
    (setf (gethash "timestamp"  ht) (current-timestamp))
    (setf (gethash "event_type" ht) event-type)
    ht))

;;; ── Public log functions ─────────────────────────────────────────────────────

(defun log-event (event-type &rest plist)
  "Log a generic event with EVENT-TYPE and arbitrary key-value pairs from PLIST.

PLIST should be alternating string keys and printable values:
  (log-event \"my_event\" \"key\" \"value\" \"count\" 42)"
  (let ((ht (make-base-entry event-type)))
    (loop :for (k v) :on plist :by #'cddr
          :do (setf (gethash (string-downcase (string k)) ht)
                    (if (or (stringp v) (numberp v) (eq v t) (null v))
                        v
                        (format nil "~a" v))))
    (write-log-entry ht)))

(defun log-llm-request (agent-name model message-count &key tools-count)
  "Log an LLM request event.

AGENT-NAME — name string of the agent making the call.
MODEL — model identifier string.
MESSAGE-COUNT — number of messages in the conversation.
TOOLS-COUNT — optional number of tools available."
  (let ((ht (make-base-entry "llm_request")))
    (setf (gethash "agent"         ht) (or agent-name "unknown"))
    (setf (gethash "model"         ht) (or model "unknown"))
    (setf (gethash "message_count" ht) message-count)
    (when tools-count
      (setf (gethash "tools_count" ht) tools-count))
    (write-log-entry ht)))

(defun log-tool-call (agent-name tool-name args-summary)
  "Log a tool call event.

AGENT-NAME — agent name string.
TOOL-NAME — tool identifier string.
ARGS-SUMMARY — brief string description of args (not the full args — can be large)."
  (let ((ht (make-base-entry "tool_call")))
    (setf (gethash "agent"     ht) (or agent-name "unknown"))
    (setf (gethash "tool"      ht) (or tool-name "unknown"))
    (setf (gethash "args"      ht) (or args-summary ""))
    (write-log-entry ht)))

(defun log-tool-result (agent-name tool-name success-p result-length)
  "Log a tool result event.

AGENT-NAME — agent name string.
TOOL-NAME — tool identifier string.
SUCCESS-P — T if tool call succeeded, NIL if error.
RESULT-LENGTH — character length of result string (for size tracking)."
  (let ((ht (make-base-entry "tool_result")))
    (setf (gethash "agent"         ht) (or agent-name "unknown"))
    (setf (gethash "tool"          ht) (or tool-name "unknown"))
    (setf (gethash "success"       ht) (if success-p t :false))
    (setf (gethash "result_length" ht) (or result-length 0))
    (write-log-entry ht)))

(defun log-error-event (agent-name error-type message &key context)
  "Log an error event.

AGENT-NAME — agent name string (may be NIL).
ERROR-TYPE — string category of the error.
MESSAGE — error message string.
CONTEXT — optional extra string context."
  (let ((ht (make-base-entry "error")))
    (setf (gethash "agent"      ht) (or agent-name "unknown"))
    (setf (gethash "error_type" ht) (or error-type "unknown"))
    (setf (gethash "message"    ht) (or message ""))
    (when context
      (setf (gethash "context" ht) context))
    (write-log-entry ht)))

;;; ── Error log (human-readable append log) ────────────────────────────────────

(defvar *error-log-file*
  "/home/slime/.openclaw/workspace-gensym/logs/clawmacs-errors.log"
  "Path to the human-readable error log. NIL to disable.")

(defvar *error-log-lock* (bt:make-lock "clawmacs-error-log")
  "Lock guarding concurrent writes to *ERROR-LOG-FILE*.")

(defun log-error (component format-string &rest args)
  "Append a formatted error line to *ERROR-LOG-FILE* and also to *error-output*.

FORMAT: [ISO-8601 timestamp] [COMPONENT] ERROR: message

COMPONENT is a keyword or string — e.g. :telegram, :loop, :llm, :tool, :cron, :system.
FORMAT-STRING / ARGS are passed to FORMAT to build the message."
  (let ((msg (apply #'format nil format-string args))
        (ts  (current-timestamp))
        (comp (string-downcase (string component))))
    ;; Always print to stderr
    (format *error-output* "~&[~a] [~a] ERROR: ~a~%" ts comp msg)
    ;; Append to file if configured
    (when *error-log-file*
      (ignore-errors
        (bt:with-lock-held (*error-log-lock*)
          (with-open-file (out *error-log-file*
                               :direction :output
                               :if-exists :append
                               :if-does-not-exist :create)
            (format out "[~a] [~a] ERROR: ~a~%" ts comp msg)))))))

;;; ── Setup macro ──────────────────────────────────────────────────────────────

(defmacro with-logging ((log-path &key (enabled t)) &body body)
  "Execute BODY with *LOG-FILE* bound to LOG-PATH and *LOG-ENABLED* to ENABLED.

Example:
  (with-logging (\"/tmp/agent.log\")
    (run-agent session \"Hello\"))"
  `(let ((*log-file*    ,log-path)
         (*log-enabled* ,enabled))
     ,@body))
