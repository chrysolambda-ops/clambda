;;;; src/chat-record.lisp — In-memory chat message record

(in-package #:clawmacs-gui)

;;; ── Chat message struct ───────────────────────────────────────────────────────
;;;
;;; A CHAT-MESSAGE is our GUI-side representation of a conversation entry.
;;; Separate from the CL-LLM MESSAGE struct: this is purely for display.

(defstruct (chat-message (:constructor %make-chat-message))
  "A single chat message for GUI display."
  (role      :user      :type keyword)    ; :system :user :assistant :tool
  (content   ""         :type string)     ; message text / tool result
  (timestamp 0          :type integer)    ; universal-time when added
  (tool-name nil))                        ; string if role is :tool, else nil

(defun make-chat-message (role content &key tool-name)
  "Create a new CHAT-MESSAGE.

ROLE — :system :user :assistant or :tool.
CONTENT — string text of the message.
TOOL-NAME — for :tool messages, the tool function name (optional)."
  (%make-chat-message
   :role      (or role :user)
   :content   (or content "")
   :timestamp (get-universal-time)
   :tool-name tool-name))

;;; ── Timestamp formatting ──────────────────────────────────────────────────────

(defun format-timestamp (universal-time)
  "Return a short time string HH:MM:SS from UNIVERSAL-TIME."
  (multiple-value-bind (sec min hr)
      (decode-universal-time universal-time)
    (format nil "~2,'0d:~2,'0d:~2,'0d" hr min sec)))

;;; ── Session → chat-log conversion ────────────────────────────────────────────

(defun session-messages->chat-log (session)
  "Convert a clawmacs SESSION's message history to a list of CHAT-MESSAGE structs.

Skips system messages (those are shown in the sidebar instead).
Returns a fresh list."
  (loop :for msg :in (session-messages session)
        :for role = (role-from-message msg)
        :unless (eq role :system)
          :collect
          (let* ((content (or (message-content msg) ""))
                 ;; For tool messages, try to grab the tool name
                 (tool-name nil))
            ;; If it's an assistant message with tool calls, render them
            (when (and (eq role :assistant)
                       (message-tool-calls msg))
              (setf content
                    (format nil "~@[~a~]~{~%[tool-call: ~a]~}"
                            (unless (string= content "")
                              content)
                            (mapcar #'tool-call-function-name
                                    (message-tool-calls msg)))))
            (make-chat-message role content :tool-name tool-name))))
