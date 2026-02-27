;;;; src/loop.lisp — The core agent loop

(in-package #:clawmacs/loop)

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
  (max-tokens nil               )  ; NIL = unlimited; integer = token limit
  (stream     nil  :type boolean)
  (verbose    nil  :type boolean))

(defun make-loop-options (&key (max-turns 10) max-tokens stream verbose)
  "Create LOOP-OPTIONS.

MAX-TURNS  — maximum number of LLM call-and-tool-dispatch iterations (default: 10).
MAX-TOKENS — optional cumulative token budget for the session (default: NIL = unlimited).
             Signals BUDGET-EXCEEDED when the session's total-tokens exceeds this.
STREAM     — use streaming mode (default: NIL).
VERBOSE    — print loop status to *STANDARD-OUTPUT* (default: NIL)."
  (%make-loop-options :max-turns max-turns
                      :max-tokens max-tokens
                      :stream stream
                      :verbose verbose))

;;; ── LLM Auto-Repair ──────────────────────────────────────────────────────────

(defun %ask-llm-for-tool-fix (session condition)
  "Ask the LLM to provide corrected arguments for a failing tool call.

SESSION — the current agent session (used to get client + model).
CONDITION — a TOOL-EXECUTION-ERROR condition.

Returns a hash-table of corrected arguments, or NIL if the LLM can't help.
The LLM is asked to return pure JSON. If parsing fails, returns NIL."
  (handler-case
      (let* ((agent   (session-agent session))
             (client  (clawmacs/agent:agent-client agent))
             (model   (clawmacs/agent:agent-model agent))
             (tname   (tool-execution-error-tool-name condition))
             (cause   (tool-execution-error-cause condition))
             (input   (tool-execution-error-input condition))
             ;; Describe what failed
             (input-str
              (if input
                  (handler-case
                      (com.inuoe.jzon:stringify input)
                    (error () "(unparseable)"))
                  "{}"))
             (prompt
              (format nil
                      "A tool call failed and needs to be repaired.~2%~
                       Tool: ~s~%~
                       Input arguments (JSON): ~a~%~
                       Error: ~a~2%~
                       Please provide corrected JSON arguments for this tool call.~%~
                       Reply with ONLY a JSON object — no explanations, no markdown.~%~
                       Example: {\"path\": \"/correct/path.txt\"}"
                      tname input-str cause))
             (fix-text
              (cl-llm:chat client
                           (list (cl-llm/protocol:user-message prompt))
                           :model model)))
        ;; Try to extract JSON from the response
        (when (and fix-text (> (length fix-text) 0))
          ;; Strip markdown code fences if present
          (let ((clean (cl-ppcre:regex-replace-all
                        "```(?:json)?\\s*|\\s*```" fix-text "")))
            (let ((start (position #\{ clean))
                  (end   (position #\} clean :from-end t)))
              (when (and start end (< start end))
                (handler-case
                    (com.inuoe.jzon:parse
                     (subseq clean start (1+ end)))
                  (error ()
                    (format *error-output*
                            "~&[clawmacs/loop] LLM fix parse error — raw: ~s~%"
                            clean)
                    nil)))))))
    (error (e)
      (format *error-output*
              "~&[clawmacs/loop] LLM auto-repair request failed: ~a~%" e)
      nil)))

;;; ── Helpers ──────────────────────────────────────────────────────────────────

(defun build-messages (session)
  "Build the full message list for an LLM call: system prompt + history."
  (let* ((agent (session-agent session))
         (sys-prompt (clawmacs/agent:agent-effective-system-prompt agent))
         (history (clawmacs/session:session-messages session)))
    (cons (cl-llm/protocol:system-message sys-prompt) history)))

(defun handle-tool-calls (session registry tool-calls verbose &optional opts)
  "Execute all TOOL-CALLS via REGISTRY and add results to SESSION.
Returns a list of tool result strings.

OPTS — a LOOP-OPTIONS struct (used to access the LLM client for auto-repair).

When a tool call fails with TOOL-EXECUTION-ERROR, establishes a
HANDLER-BIND that asks the LLM to suggest corrected arguments and
automatically invokes the RETRY-WITH-FIXED-INPUT restart.
This gives the agent one shot at self-repair before returning an error.
A human connected via SLIME can also intercept and choose restarts manually."
  (declare (ignore opts))   ; opts reserved for future per-call budget tracking
  (mapcar
   (lambda (tc)
     (let ((name (cl-llm/protocol:tool-call-function-name tc))
           (tid  (cl-llm/protocol:tool-call-id tc)))
       (when verbose
         (format t "~%[tool] calling: ~a~%" name))
       (when *on-tool-call*
         (funcall *on-tool-call* name tc))

       (let* ((result
               ;; Install LLM auto-repair handler.
               ;; The restart (RETRY-WITH-FIXED-INPUT) is established inside
               ;; dispatch-tool-call via %try-tool-handler. This handler-bind
               ;; fires while that frame is still on the stack, so it can
               ;; invoke the restart without unwinding.
               (handler-bind
                   ((tool-execution-error
                     (lambda (c)
                       (when verbose
                         (format t
                                 "~&[tool] ~a failed: ~a — asking LLM for fix...~%"
                                 name (tool-execution-error-cause c)))
                       (let ((fixed-args (%ask-llm-for-tool-fix session c)))
                         (when fixed-args
                           (when verbose
                             (format t "~&[tool] LLM provided fix — retrying ~a~%"
                                     name))
                           (invoke-restart 'retry-with-fixed-input fixed-args))
                         ;; If no fix available, fall through to error result
                         )))
                    (clawmacs/conditions:tool-not-found
                     (lambda (c)
                       (declare (ignore c))
                       (invoke-restart 'clawmacs/conditions:skip-tool-call))))
                 (clawmacs/tools:dispatch-tool-call registry tc)))
              (result-str (clawmacs/tools:format-tool-result result)))

         ;; Log tool call
         (clawmacs/logging:log-tool-call
          (clawmacs/agent:agent-name (clawmacs/session:session-agent session))
          name
          (let ((args (cl-llm/protocol:tool-call-function-arguments tc)))
            (if args (format nil "~a" args) "")))
         ;; Log tool result — success if result-str doesn't start with "ERROR:"
         (clawmacs/logging:log-tool-result
          (clawmacs/agent:agent-name (clawmacs/session:session-agent session))
          name
          (not (and (>= (length result-str) 6)
                    (string= (subseq result-str 0 6) "ERROR:")))
          (length result-str))

         (when verbose
           (format t "[tool] result: ~a~%" result-str))
         (when *on-tool-result*
           (funcall *on-tool-result* name result-str))

         ;; Add tool result message to session
         (clawmacs/session:session-add-message
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
         (client   (clawmacs/agent:agent-client agent))
         (model    (clawmacs/agent:agent-model agent))
         (registry (clawmacs/agent:agent-tool-registry agent))
         (tools    (when registry
                     (clawmacs/tools:tool-definitions-for-llm registry)))
         (messages (build-messages session))
         (verbose  (loop-options-verbose opts)))

    (when verbose
      (format t "~%[agent] ~a: calling LLM (~a messages)~%"
              (clawmacs/agent:agent-name agent)
              (length messages)))

    ;; Log the LLM request
    (clawmacs/logging:log-llm-request
     (clawmacs/agent:agent-name agent)
     (or model "unknown")
     (length messages)
     :tools-count (length tools))

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
            (clawmacs/session:session-add-message
             session (cl-llm/protocol:assistant-message text)))
          (return-from agent-turn (values text nil nil))))

      ;; Track token usage from response
      (let ((usage (cl-llm/protocol:response-usage response)))
        (when usage
          (let ((total (cl-llm/protocol:usage-total-tokens usage)))
            (incf (clawmacs/session:session-total-tokens session) total)
            ;; Check token budget
            (let ((max-tokens (loop-options-max-tokens opts)))
              (when (and max-tokens
                         (> (clawmacs/session:session-total-tokens session)
                            max-tokens))
                (restart-case
                    (error 'clawmacs/conditions:budget-exceeded
                           :kind    :tokens
                           :limit   max-tokens
                           :current (clawmacs/session:session-total-tokens session))
                  (abort-agent-loop ()
                    :report "Abort the agent loop due to token budget exceeded."
                    (return-from agent-turn (values nil nil nil)))))))))

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
            (clawmacs/session:session-add-message session asst-msg)))

        ;; Dispatch tool calls if any
        (when (and registry tool-calls (not (endp tool-calls)))
          (handle-tool-calls session registry tool-calls verbose opts))

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
    (clawmacs/session:session-add-message
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
                 (error 'clawmacs/conditions:agent-loop-error
                        :message (format nil "Agent loop exceeded max-turns (~a)" max-turns))
               (abort-agent-loop ()
                 :report "Abort the agent loop and return empty string."
                 (return-from run-agent ""))))
      (abort-agent-loop ()
        :report "Abort the agent loop."
        ""))))
