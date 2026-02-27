;;;; src/commands.lisp — Command table definitions for clawmacs-gui

(in-package #:clawmacs-gui)

;;; ── Helper: run LLM call in background thread ────────────────────────────────

(defun run-llm-async (frame user-text)
  "Dispatch user text to the LLM in a background thread.

Sets up streaming hooks so tokens update the chat pane in real-time.
Adds the completed assistant response to the chat log when done."
  (when (frame-busy-p frame)
    (set-status frame "Busy — still processing previous message")
    (return-from run-llm-async nil))

  (let ((session (frame-session frame)))
    (unless session
      (set-status frame "Error — no active session")
      (return-from run-llm-async nil))

    ;; Add the user message to the display immediately
    (push-chat-message frame :user user-text)
    (set-status frame "Sending message to LLM...")

    ;; Spawn background thread for LLM call
    (setf (frame-worker-thread frame)
          (bt:make-thread
           (lambda ()
             (handler-case
                 (%llm-worker frame session user-text)
               (error (e)
                 (let ((err-text (format nil "Error: ~a" e)))
                   (push-chat-message frame :system err-text)
                   (set-status frame (format nil "Error: ~a" e))))))
           :name "clawmacs-gui-llm-worker"))))

(defun %llm-worker (frame session user-text)
  "Do the actual LLM call + display updates (runs in background thread)."
  ;; Set up streaming: accumulate tokens in streaming-buffer
  ;; and force a redisplay on each chunk.
  (let (;; Streaming display text — accumulated as tokens arrive.
        ;; We use a fill-pointer array to avoid O(n^2) string concatenation.
        (text-buf (make-array 0
                              :element-type 'character
                              :fill-pointer 0
                              :adjustable t))
        (chat-pane (clim:find-pane-named frame 'chat-display)))

    (setf (frame-streaming-buffer frame) "")

    ;; Hook: on each stream delta, append to buffer and redisplay
    (let ((*on-stream-delta*
           (lambda (delta)
             ;; Append delta to our adjustable char array
             (loop :for ch :across delta :do
               (vector-push-extend ch text-buf))
             ;; Update the streaming display buffer (a fresh string snapshot)
             (setf (frame-streaming-buffer frame)
                   (coerce text-buf 'string))
             ;; Redisplay the chat pane to show new tokens
             (when chat-pane
               (clim:redisplay-frame-pane frame chat-pane))))

          ;; Hook: show tool invocations in the chat
          (*on-tool-call*
           (lambda (tool-name tc)
             (declare (ignore tc))
             ;; If we've accumulated any streaming text, commit it as an
             ;; assistant message before showing the tool call
             (let ((acc-so-far (coerce text-buf 'string)))
               (when (> (length acc-so-far) 0)
                 (push-chat-message frame :assistant acc-so-far)
                 ;; Reset accumulator for next segment
                 (setf (fill-pointer text-buf) 0)
                 (setf (frame-streaming-buffer frame) nil)))
             (push-chat-message frame :tool
                                (format nil "→ calling ~a" tool-name)
                                :tool-name tool-name)
             (set-status frame (format nil "Tool: ~a" tool-name))))

          ;; Hook: show tool results
          (*on-tool-result*
           (lambda (tool-name result-str)
             (let ((preview (if (> (length result-str) 200)
                                (concatenate 'string
                                             (subseq result-str 0 200) "...")
                                result-str)))
               (push-chat-message frame :tool
                                  (format nil "← ~a result:~%~a"
                                          tool-name preview)
                                  :tool-name tool-name))
             (set-status frame "Tool call complete, waiting for LLM...")))

          ;; Hook: track total tokens from responses
          (*on-llm-response*
           (lambda (text)
             (declare (ignore text))
             nil)))

      (set-status frame "LLM responding...")

      ;; Run the agent loop (this blocks until complete)
      (let ((response
             (run-agent session user-text
                        :options (make-loop-options :stream t
                                                    :max-turns 10))))

        ;; Any remaining content in text-buf is the final response text
        (let ((final-text (coerce text-buf 'string)))
          ;; Clear the streaming in-progress display
          (setf (frame-streaming-buffer frame) nil)

          ;; Push the final assistant response to chat-log
          (cond
            ;; We have streamed text — use that directly
            ((> (length final-text) 0)
             (push-chat-message frame :assistant final-text))
            ;; Streaming was interrupted by tool calls and run-agent returned text
            ((and (stringp response) (> (length response) 0))
             (push-chat-message frame :assistant response))
            ;; Fallback: inspect last session message
            (t
             (let ((last-msg (car (last (session-messages session)))))
               (when (and last-msg
                          (eq (role-from-message last-msg) :assistant))
                 (let ((content (message-content last-msg)))
                   (when (and content (> (length content) 0))
                     (push-chat-message frame :assistant content))))))))

        ;; Also show any tool calls that happened
        ;; (they're already in the session; add them to display if not yet)
        ;; We do this by scanning new session messages added since the user msg
        ;; — for now we rely on *on-tool-call* / *on-tool-result* hooks instead

        (set-status frame "Ready — send a message below"))))

  (setf (frame-worker-thread frame) nil)

  ;; Final redisplay
  (clim:redisplay-frame-pane frame (clim:find-pane-named frame 'chat-display))
  (clim:redisplay-frame-pane frame (clim:find-pane-named frame 'status-bar))
  (clim:redisplay-frame-pane frame (clim:find-pane-named frame 'sidebar-pane)))

;;; ── Commands ─────────────────────────────────────────────────────────────────

;;; COM-SEND — send a message to the LLM
(clim:define-command (com-send :name "Send" :menu t
                               :command-table clawmacs-gui-commands)
    ((message 'string :prompt "Message"))
  (let ((frame clim:*application-frame*)
        (text  (string-trim " " message)))
    (unless (string= text "")
      (run-llm-async frame text))))

;;; COM-CLEAR — clear chat history
(clim:define-command (com-clear :name "Clear History" :menu t
                                :command-table clawmacs-gui-commands)
    ()
  (let ((frame clim:*application-frame*))
    (when (frame-session frame)
      (session-clear-messages (frame-session frame)))
    (setf (frame-chat-log frame) '()
          (frame-token-count frame) 0
          (frame-streaming-buffer frame) nil)
    (push-chat-message frame :system "Chat history cleared.")
    (set-status frame "History cleared")))

;;; COM-SWITCH-MODEL — change the active model
(clim:define-command (com-switch-model :name "Switch Model" :menu t
                                       :command-table clawmacs-gui-commands)
    ((model-name 'string :prompt "Model name"))
  (let* ((frame clim:*application-frame*)
         (session (frame-session frame))
         (agent   (when session (session-agent session))))
    (cond
      ((null agent)
       (set-status frame "Error: no active agent"))
      ((string= (string-trim " " model-name) "")
       (set-status frame (format nil "Current model: ~a"
                                 (or (agent-model agent) "(default)"))))
      (t
       (setf (agent-model agent) (string-trim " " model-name))
       (push-chat-message frame :system
                          (format nil "Model switched to: ~a" (agent-model agent)))
       (set-status frame (format nil "Model: ~a" (agent-model agent)))
       (clim:redisplay-frame-pane frame
                                   (clim:find-pane-named frame 'sidebar-pane))))))

;;; COM-SET-SYSTEM — set or view system prompt
(clim:define-command (com-set-system :name "Set System Prompt" :menu t
                                     :command-table clawmacs-gui-commands)
    ((prompt 'string :prompt "System prompt (empty to show current)"))
  (let* ((frame   clim:*application-frame*)
         (session (frame-session frame))
         (agent   (when session (session-agent session))))
    (cond
      ((null agent)
       (set-status frame "Error: no active agent"))
      ((string= (string-trim " " prompt) "")
       ;; Show current
       (let ((current (agent-system-prompt agent)))
         (push-chat-message frame :system
                            (format nil "System prompt: ~a"
                                    (or current "(auto-generated)")))
         (set-status frame "Showing system prompt")))
      (t
       ;; Set it
       (setf (agent-system-prompt agent) (string-trim " " prompt))
       ;; Clear history so the new system prompt takes effect
       (when session
         (session-clear-messages session))
       (setf (frame-chat-log frame) '())
       (push-chat-message frame :system
                          (format nil "System prompt updated. History cleared.~%~a"
                                  (agent-system-prompt agent)))
       (set-status frame "System prompt updated")))))

;;; COM-QUIT — exit
(clim:define-command (com-quit :name "Quit" :menu t
                               :command-table clawmacs-gui-commands
                               :keystroke (#\q :control))
    ()
  (clim:frame-exit clim:*application-frame*))

;;; ── Tool call hooks for display ──────────────────────────────────────────────

(defun install-tool-hooks (frame)
  "Set up *on-tool-call* and *on-tool-result* to show tool invocations.

These are dynamic vars, so they must be let-bound around each LLM call.
This function is called from %LLM-WORKER to set up the thread-local bindings."
  (declare (ignorable frame))
  ;; No-op: the %llm-worker does its own let-binding
  ;; This exists as a hook point for future use
  nil)
