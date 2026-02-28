;;;; src/protocol.lisp — Data structures for the OpenAI chat completions protocol

(in-package #:cl-llm/protocol)

;;; ── Messages ─────────────────────────────────────────────────────────────────

(defstruct (message (:constructor %make-message))
  "A chat message."
  (role         nil :type (member :system :user :assistant :tool))
  (content      nil :type (or null string list))   ; list for multi-part
  (tool-calls   nil :type (or null list))
  (tool-call-id nil :type (or null string)))

(defun system-message (content)
  "Create a system message."
  (%make-message :role :system :content content))

(defun user-message (content)
  "Create a user message."
  (%make-message :role :user :content content))

(defun assistant-message (content &key tool-calls)
  "Create an assistant message, optionally with tool calls."
  (%make-message :role :assistant :content content :tool-calls tool-calls))

(defun tool-message (content tool-call-id)
  "Create a tool result message."
  (%make-message :role :tool :content content :tool-call-id tool-call-id))

;;; ── Tool definitions ─────────────────────────────────────────────────────────

(defstruct tool-definition
  "Defines a tool/function the LLM can call."
  (name        nil :type string)
  (description nil :type (or null string))
  (parameters  nil :type (or null hash-table list))) ; JSON Schema

;;; ── Tool calls (from model responses) ───────────────────────────────────────

(defstruct tool-call
  "A tool call requested by the model."
  (id              nil :type (or null string))
  (function-name   nil :type (or null string))
  (function-arguments nil :type (or null string hash-table)))

;;; ── Request options ──────────────────────────────────────────────────────────

(defstruct request-options
  "Optional parameters for a chat completion request."
  (temperature      nil :type (or null real))
  (max-tokens       nil :type (or null integer))
  (top-p            nil :type (or null real))
  (frequency-penalty nil :type (or null real))
  (presence-penalty  nil :type (or null real))
  (stop             nil :type (or null string list))
  (seed             nil :type (or null integer))
  (response-format  nil :type (or null hash-table list))
  (extra            nil :type list))  ; alist of extra fields

;;; ── Responses ────────────────────────────────────────────────────────────────

(defstruct (completion-response (:conc-name response-))
  "A completed chat response from the API."
  (id      nil :type (or null string))
  (model   nil :type (or null string))
  (choices nil :type list)
  (usage   nil))

(defstruct (choice (:conc-name choice-))
  "One choice in a completion response."
  (message       nil)
  (finish-reason nil :type (or null string keyword)))

(defstruct (usage (:conc-name usage-))
  "Token usage from a completion response."
  (prompt-tokens     0 :type integer)
  (completion-tokens 0 :type integer)
  (total-tokens      0 :type integer))

;;; ── Serialization ────────────────────────────────────────────────────────────

(defun message->ht (msg)
  "Serialize a MESSAGE struct to a hash-table for JSON encoding."
  (let ((ht (make-hash-table :test #'equal)))
    (setf (gethash "role" ht)
          (string-downcase (symbol-name (message-role msg))))
    ;; Content: can be string or nil
    (when (message-content msg)
      (setf (gethash "content" ht) (message-content msg)))
    ;; Tool call id (for role=tool)
    (when (message-tool-call-id msg)
      (setf (gethash "tool_call_id" ht) (message-tool-call-id msg)))
    ;; Tool calls (for role=assistant)
    (when (message-tool-calls msg)
      (setf (gethash "tool_calls" ht)
            (map 'vector #'tool-call->ht (message-tool-calls msg))))
    ht))

(defun tool-call->ht (tc)
  "Serialize a TOOL-CALL struct to a hash-table."
  (let ((ht (make-hash-table :test #'equal))
        (fn-ht (make-hash-table :test #'equal)))
    (setf (gethash "id" ht) (tool-call-id tc))
    (setf (gethash "type" ht) "function")
    (setf (gethash "name" fn-ht) (tool-call-function-name tc))
    (setf (gethash "arguments" fn-ht)
          (let ((args (tool-call-function-arguments tc)))
            (etypecase args
              (string args)
              (hash-table (com.inuoe.jzon:stringify args))
              (list (com.inuoe.jzon:stringify
                     (cl-llm/json:plist->object args))))))
    (setf (gethash "function" ht) fn-ht)
    ht))

(defun tool-definition->ht (td)
  "Serialize a TOOL-DEFINITION to the OpenAI function-calling format."
  (let ((ht (make-hash-table :test #'equal))
        (fn-ht (make-hash-table :test #'equal)))
    (setf (gethash "type" ht) "function")
    (setf (gethash "name" fn-ht) (tool-definition-name td))
    (when (tool-definition-description td)
      (setf (gethash "description" fn-ht) (tool-definition-description td)))
    (when (tool-definition-parameters td)
      (let ((params (tool-definition-parameters td)))
        (setf (gethash "parameters" fn-ht)
              (etypecase params
                (hash-table params)
                (list (cl-llm/json:plist->object params))))))
    (setf (gethash "function" ht) fn-ht)
    ht))

(defun build-request-ht (model messages options tools)
  "Build the full request hash-table."
  (let ((ht (make-hash-table :test #'equal)))
    (setf (gethash "model" ht) model)
    (setf (gethash "messages" ht)
          (map 'vector #'message->ht messages))
    ;; Options
    (when options
      (flet ((maybe-set (json-key accessor)
               (let ((val (funcall accessor options)))
                 (when val (setf (gethash json-key ht) val)))))
        (maybe-set "temperature"       #'request-options-temperature)
        (maybe-set "max_tokens"        #'request-options-max-tokens)
        (maybe-set "top_p"             #'request-options-top-p)
        (maybe-set "frequency_penalty" #'request-options-frequency-penalty)
        (maybe-set "presence_penalty"  #'request-options-presence-penalty)
        (maybe-set "stop"              #'request-options-stop)
        (maybe-set "seed"              #'request-options-seed)
        (maybe-set "response_format"   #'request-options-response-format)
        ;; Extra fields
        (loop :for (k . v) :in (request-options-extra options)
              :do (setf (gethash k ht) v))))
    ;; Tools
    (when tools
      (setf (gethash "tools" ht)
            (map 'vector #'tool-definition->ht tools))
      ;; Be explicit for smaller models / local providers.
      (setf (gethash "tool_choice" ht) "auto"))
    ht))

;;; ── Deserialization ──────────────────────────────────────────────────────────

(defun ht->tool-call (ht)
  "Parse a tool call from a JSON hash-table."
  (let* ((fn-ht (gethash "function" ht)))
    (make-tool-call
     :id              (gethash "id" ht)
     :function-name   (when fn-ht (gethash "name" fn-ht))
     :function-arguments (when fn-ht (gethash "arguments" fn-ht)))))

(defun ht->message (ht)
  "Parse a message from a JSON hash-table."
  (let ((role (gethash "role" ht))
        (content (gethash "content" ht))
        (tool-calls (gethash "tool_calls" ht))
        (tool-call-id (gethash "tool_call_id" ht)))
    (%make-message
     :role (cond ((string= role "system")    :system)
                 ((string= role "user")      :user)
                 ((string= role "assistant") :assistant)
                 ((string= role "tool")      :tool)
                 (t (intern (string-upcase role) :keyword)))
     :content content
     :tool-call-id tool-call-id
     :tool-calls (when (and tool-calls (> (length tool-calls) 0))
                   (map 'list #'ht->tool-call tool-calls)))))

(defun parse-response (json-string)
  "Parse an API response JSON string into a COMPLETION-RESPONSE."
  (handler-case
      (let* ((obj (com.inuoe.jzon:parse json-string))
             ;; Check for API-level error
             (error-obj (gethash "error" obj)))
        (when error-obj
          (error 'cl-llm/conditions:api-error
                 :type    (gethash "type" error-obj)
                 :code    (gethash "code" error-obj)
                 :message (gethash "message" error-obj)))
        ;; Parse choices
        (let ((choices-vec (gethash "choices" obj))
              (usage-ht    (gethash "usage" obj)))
          (make-completion-response
           :id      (gethash "id" obj)
           :model   (gethash "model" obj)
           :choices (when choices-vec
                      (map 'list
                           (lambda (c)
                             (make-choice
                              :message (ht->message (gethash "message" c))
                              :finish-reason (gethash "finish_reason" c)))
                           choices-vec))
           :usage   (when usage-ht
                      (make-usage
                       :prompt-tokens     (or (gethash "prompt_tokens" usage-ht) 0)
                       :completion-tokens (or (gethash "completion_tokens" usage-ht) 0)
                       :total-tokens      (or (gethash "total_tokens" usage-ht) 0))))))
    (cl-llm/conditions:api-error (e) (error e))
    (error (e)
      (error 'cl-llm/conditions:parse-error*
             :raw json-string))))
