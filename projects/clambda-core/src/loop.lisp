;;;; src/loop.lisp — The core agent loop

(in-package #:clambda/loop)

;;; ── Dynamic hooks ────────────────────────────────────────────────────────────

(defvar *on-tool-call* nil
  "If set, called (tool-name args-ht) before each tool dispatch.")

(defvar *on-tool-result* nil
  "If set, called (tool-name result-string) after each tool dispatch.")

(defvar *on-llm-response* nil
  "If set, called (response-text) when LLM returns a final text response.")

(defvar *on-stream-delta* nil
  "If set, called (delta-string) for each streaming chunk.")

;;; ── Loop options ─────────────────────────────────────────────────────────────

(defstruct (loop-options (:constructor %make-loop-options))
  "Options for an agent loop run."
  (max-turns  10   :type fixnum)
  (stream     nil  :type boolean)
  (verbose    nil  :type boolean))

(defun make-loop-options (&key (max-turns 10) stream verbose)
  "Create LOOP-OPTIONS.

MAX-TURNS — maximum number of LLM call-and-tool-dispatch iterations (default: 10).
STREAM — use streaming mode (default: NIL).
VERBOSE — print loop status to *STANDARD-OUTPUT* (default: NIL)."
  (%make-loop-options :max-turns max-turns :stream stream :verbose verbose))

;;; ── Helpers ──────────────────────────────────────────────────────────────────

(defun build-messages (session)
  "Build the full message list for an LLM call: system prompt + history."
  (let* ((agent (session-agent session))
         (sys-prompt (clambda/agent:agent-effective-system-prompt agent))
         (history (clambda/session:session-messages session)))
    (cons (cl-llm/protocol:system-message sys-prompt) history)))

(defun handle-tool-calls (session registry tool-calls verbose)
  "Execute all TOOL-CALLS via REGISTRY and add results to SESSION.
Returns a list of tool result strings."
  (mapcar
   (lambda (tc)
     (let ((name (cl-llm/protocol:tool-call-function-name tc))
           (tid  (cl-llm/protocol:tool-call-id tc)))
       (when verbose
         (format t "~%[tool] calling: ~a~%" name))
       (when *on-tool-call*
         (funcall *on-tool-call* name tc))

       (let* ((result (clambda/tools:dispatch-tool-call registry tc))
              (result-str (clambda/tools:format-tool-result result)))

         (when verbose
           (format t "[tool] result: ~a~%" result-str))
         (when *on-tool-result*
           (funcall *on-tool-result* name result-str))

         ;; Add tool result message to session
         (clambda/session:session-add-message
          session
          (cl-llm/protocol:tool-message result-str tid))

         result-str)))
   tool-calls))

(defun extract-text-from-response (response)
  "Extract the text content from a CL-LLM COMPLETION-RESPONSE.
Returns the text string or NIL if none."
  (let* ((choices (cl-llm/protocol:response-choices response))
         (choice  (first choices))
         (msg     (when choice (cl-llm/protocol:choice-message choice))))
    (when msg
      (cl-llm/protocol:message-content msg))))

(defun extract-tool-calls-from-response (response)
  "Extract tool calls from a CL-LLM COMPLETION-RESPONSE.
Returns a list of TOOL-CALL structs, or NIL."
  (let* ((choices (cl-llm/protocol:response-choices response))
         (choice  (first choices))
         (msg     (when choice (cl-llm/protocol:choice-message choice))))
    (when msg
      (cl-llm/protocol:message-tool-calls msg))))

(defun finish-reason (response)
  "Return the finish reason keyword from RESPONSE."
  (let* ((choices (cl-llm/protocol:response-choices response))
         (choice  (first choices)))
    (when choice
      (cl-llm/protocol:choice-finish-reason choice))))

;;; ── Single turn ──────────────────────────────────────────────────────────────

(defun agent-turn (session &key options)
  "Execute a single LLM call (and any resulting tool dispatch) for SESSION.

Returns (values final-text-or-nil tool-calls-executed response).
The SESSION is updated in place with assistant + tool messages.

OPTIONS — a LOOP-OPTIONS struct (default: standard options)."
  (let* ((opts     (or options (make-loop-options)))
         (agent    (session-agent session))
         (client   (clambda/agent:agent-client agent))
         (model    (clambda/agent:agent-model agent))
         (registry (clambda/agent:agent-tool-registry agent))
         (tools    (when registry
                     (clambda/tools:tool-definitions-for-llm registry)))
         (messages (build-messages session))
         (verbose  (loop-options-verbose opts)))

    (when verbose
      (format t "~%[agent] ~a: calling LLM (~a messages)~%"
              (clambda/agent:agent-name agent)
              (length messages)))

    ;; Call the LLM
    (let ((response
           (if (loop-options-stream opts)
               ;; Streaming — accumulate and fake a response
               (let ((full-text
                      (cl-llm:chat-stream
                       client messages
                       (lambda (delta)
                         (when *on-stream-delta*
                           (funcall *on-stream-delta* delta))
                         (when verbose
                           (write-string delta)
                           (finish-output)))
                       :model model
                       :tools tools)))
                 ;; Build a pseudo-response from streamed text
                 ;; (no tool calls in streaming for now)
                 (list :text full-text :tool-calls nil :raw nil))
               ;; Non-streaming — structured response
               (cl-llm:chat client messages :model model :tools tools))))

      ;; Handle streaming pseudo-response
      (when (and (listp response) (eq (car response) :text))
        (let ((text (getf response :text)))
          (when text
            (when *on-llm-response* (funcall *on-llm-response* text))
            (clambda/session:session-add-message
             session (cl-llm/protocol:assistant-message text)))
          (return-from agent-turn (values text nil nil))))

      ;; Non-streaming structured response
      (let* ((text       (extract-text-from-response response))
             (tool-calls (extract-tool-calls-from-response response))
             (reason     (finish-reason response)))

        (when verbose
          (format t "[agent] finish-reason: ~a, tool-calls: ~a~%"
                  reason (length tool-calls)))

        ;; Add assistant message to history
        (let ((asst-msg (cl-llm/protocol:choice-message
                         (first (cl-llm/protocol:response-choices response)))))
          (when asst-msg
            (clambda/session:session-add-message session asst-msg)))

        ;; Dispatch tool calls if any
        (when (and registry tool-calls (not (endp tool-calls)))
          (handle-tool-calls session registry tool-calls verbose))

        ;; Return final text if no more tool calls (or after tool execution)
        (when (and text (endp tool-calls))
          (when *on-llm-response* (funcall *on-llm-response* text)))

        (values text tool-calls response)))))

;;; ── Full agent loop ──────────────────────────────────────────────────────────

(defun run-agent (session user-message &key options)
  "Run the full agent loop for USER-MESSAGE string.

1. Add USER-MESSAGE to SESSION history.
2. Call LLM.
3. If tool calls returned: dispatch them, add results, go to 2.
4. If final text returned (or max turns hit): return it.

Returns the final text response string.
SESSION is updated in place with the full conversation.

OPTIONS — a LOOP-OPTIONS struct."
  (let* ((opts      (or options (make-loop-options)))
         (max-turns (loop-options-max-turns opts))
         (verbose   (loop-options-verbose opts)))

    ;; Add the user message to history
    (clambda/session:session-add-message
     session (cl-llm/protocol:user-message user-message))

    (when verbose
      (format t "~%[run-agent] starting loop (max-turns: ~a)~%" max-turns))

    ;; The loop
    (restart-case
        (loop
          :for turn :from 1 :to max-turns
          :do
             (when verbose
               (format t "~%[run-agent] turn ~a/~a~%" turn max-turns))
             (multiple-value-bind (text tool-calls response)
                 (agent-turn session :options opts)
               (declare (ignore response))
               ;; If no tool calls, we have the final answer
               (when (or (null tool-calls) (endp tool-calls))
                 (return (or text "")))
               ;; Otherwise loop continues (tool results added to session by agent-turn)
               (when verbose
                 (format t "[run-agent] executed ~a tool call(s), continuing...~%"
                         (length tool-calls))))
          :finally
             ;; Max turns exceeded
             (restart-case
                 (error 'clambda/conditions:agent-loop-error
                        :message (format nil "Agent loop exceeded max-turns (~a)" max-turns))
               (abort-agent-loop ()
                 :report "Abort the agent loop and return empty string."
                 (return-from run-agent ""))))
      (abort-agent-loop ()
        :report "Abort the agent loop."
        ""))))
