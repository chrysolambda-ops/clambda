;;;; src/telegram.lisp — Telegram Bot API channel for Clambda
;;;;
;;;; Implements a Telegram channel using long-polling (getUpdates).
;;;; Integrates with the config system: users call (register-channel :telegram ...)
;;;; in init.lisp, then (start-telegram) or (start-all-channels) to begin polling.
;;;;
;;;; Architecture:
;;;;   - One background thread per channel (bordeaux-threads).
;;;;   - Per-chat-id session table: incoming message → find/create session → run-agent.
;;;;   - Responses sent back via sendMessage.
;;;;   - Allowlist: if :allowed-users is non-nil, reject other user IDs silently.
;;;;   - Error handling: network/parse errors in the loop are caught, logged, retried.
;;;;
;;;; Testing live:
;;;;   1. Create a Telegram bot via @BotFather — note the token.
;;;;   2. In SBCL:
;;;;        (ql:quickload :clambda-core)
;;;;        (clambda/config:register-channel :telegram :token "TOKEN")
;;;;        (clambda/telegram:start-telegram)
;;;;        ;; Now send a message to your bot in Telegram.
;;;;        (clambda/telegram:stop-telegram)
;;;;
;;;; Unit tests (no real token needed) are in t/test-telegram.lisp.
;;;; Mock tests simulate update parsing and allowlist logic without HTTP.

(in-package #:clambda/telegram)

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 1. Global State and Options
;;;; ─────────────────────────────────────────────────────────────────────────────

(defvar *telegram-channel* nil
  "The most recently registered/started Telegram channel, or NIL.
Set automatically by REGISTER-CHANNEL :TELEGRAM.")

(defvar *telegram-llm-base-url* "http://localhost:1234/v1"
  "LLM API base URL for the Telegram channel agent.
Defaults to LM Studio local endpoint. Override in init.lisp:
  (setf clambda/telegram:*telegram-llm-base-url* \"http://...\").")

(defvar *telegram-llm-api-key* "lm-studio"
  "LLM API key for the Telegram channel agent.")

(defvar *telegram-system-prompt*
  "You are a helpful AI assistant accessible via Telegram. \
Keep responses concise and suitable for a chat interface."
  "System prompt injected into every new Telegram session.
Override in init.lisp to customise the bot's personality.")

(defvar *telegram-poll-timeout* 5
  "Seconds to wait in each getUpdates long-poll call (default 5).
Shorter values mean faster shutdown when STOP-TELEGRAM is called.
Maximum allowed by Telegram API is 30.")

(defvar *telegram-streaming* t
  "When T (default), stream partial agent responses via editMessageText.
When NIL, send the complete response as a single sendMessage.")

(defvar *telegram-stream-debounce-ms* 500
  "Minimum milliseconds between editMessageText calls during streaming.
Prevents flooding the Telegram API with too-frequent edit requests.
Default 500ms = at most 2 edits/second.")

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 2. Channel Struct
;;;; ─────────────────────────────────────────────────────────────────────────────

(defstruct (telegram-channel
            (:constructor %make-telegram-channel)
            (:conc-name telegram-channel-))
  "A Telegram Bot API channel.

Slots:
  TOKEN            — bot token from @BotFather.
  ALLOWED-USERS    — NIL (all users allowed) or a list of integer user-IDs.
  POLLING-INTERVAL — seconds to sleep between getUpdates calls (default 1).
  THREAD           — background polling thread, or NIL.
  RUNNING          — T while the polling loop is active.
  LAST-UPDATE-ID   — last received update_id; used as offset so updates
                     are not re-processed.
  SESSIONS         — hash-table of chat-id (integer) → session.
  SESSIONS-LOCK    — mutex protecting SESSIONS."
  (token            ""  :type string)
  (allowed-users    nil)              ; NIL = open; list of integers = allowlist
  (polling-interval 1   :type fixnum)
  (thread           nil)              ; bt:thread or NIL
  (running          nil :type boolean)
  (last-update-id   0   :type fixnum)
  (sessions         (make-hash-table :test 'eql))
  (sessions-lock    (bt:make-lock "telegram-sessions")))

(defun make-telegram-channel (&key token (allowed-users nil) (polling-interval 1))
  "Create and return a TELEGRAM-CHANNEL.

TOKEN            — required; the bot token string from @BotFather.
ALLOWED-USERS    — optional list of integer Telegram user IDs.
                   NIL (default) means all users are accepted.
POLLING-INTERVAL — seconds to sleep between poll cycles (default 1).
                   With long-polling this is a brief inter-poll delay,
                   not the wait-for-updates timeout."
  (check-type token string)
  (check-type polling-interval fixnum)
  (%make-telegram-channel :token            token
                           :allowed-users    allowed-users
                           :polling-interval polling-interval))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 3. Bot API HTTP Helpers
;;;; ─────────────────────────────────────────────────────────────────────────────

(defun telegram-api-url (token method)
  "Return the full URL for a Telegram Bot API method call.

Examples:
  (telegram-api-url \"123:ABC\" \"getUpdates\")
  => \"https://api.telegram.org/bot123:ABC/getUpdates\""
  (format nil "https://api.telegram.org/bot~A/~A" token method))

(defun %plist->ht (plist)
  "Convert a flat keyword/value PLIST to an equal-keyed string hash-table.
Keyword keys are downcased: :chat_id → \"chat_id\"."
  (let ((ht (make-hash-table :test 'equal)))
    (loop for (k v) on plist by #'cddr
          do (setf (gethash (string-downcase (string k)) ht) v))
    ht))

(defun %tg-call (token method &rest params)
  "Call Telegram Bot API METHOD with PARAMS (flat plist of key-value pairs).

Returns the full response as a parsed hash-table (com.inuoe.jzon).
Signals a condition on HTTP or network failure — callers should handle.

Example:
  (%tg-call \"TOKEN\" \"sendMessage\" :chat_id 12345 :text \"Hello\")"
  (let* ((url  (telegram-api-url token method))
         (body (if params
                   (com.inuoe.jzon:stringify (%plist->ht params))
                   "{}"))
         (resp (dexador:post url
                             :headers '(("Content-Type" . "application/json"))
                             :content body)))
    (com.inuoe.jzon:parse resp)))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 4. Supported Bot API Methods
;;;; ─────────────────────────────────────────────────────────────────────────────

(defun telegram-get-me (chan)
  "Call getMe for CHAN. Returns the bot info hash-table on success.
Useful for verifying the token is valid:
  (telegram-get-me *telegram-channel*)"
  (%tg-call (telegram-channel-token chan) "getMe"))

(defun telegram-get-updates (chan)
  "Call getUpdates for CHAN using long-polling.

Uses CHAN's LAST-UPDATE-ID as offset (so already-seen updates are skipped).
Blocks for up to *TELEGRAM-POLL-TIMEOUT* seconds waiting for new messages.
Returns a list of update hash-tables (may be empty if no updates arrived)."
  (let* ((offset (1+ (telegram-channel-last-update-id chan)))
         (result (%tg-call (telegram-channel-token chan) "getUpdates"
                           :offset          offset
                           :timeout         *telegram-poll-timeout*
                           :allowed_updates (list "message"))))
    (if (gethash "ok" result)
        (coerce (or (gethash "result" result) #()) 'list)
        '())))

(defun telegram-send-message (chan chat-id text &key (parse-mode "Markdown"))
  "Send TEXT to CHAT-ID via CHAN's bot token.
PARSE-MODE defaults to \"Markdown\" — Telegram's simplified Markdown subset.

Returns the API response hash-table on success.
Catches and logs errors rather than propagating them (so the polling loop
continues even if one sendMessage fails)."
  (handler-case
      (%tg-call (telegram-channel-token chan) "sendMessage"
                :chat_id    chat-id
                :text       text
                :parse_mode parse-mode)
    (error (e)
      (format *error-output*
              "~&[telegram] sendMessage error (chat ~A): ~A~%" chat-id e)
      nil)))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 5. Allowlist Enforcement
;;;; ─────────────────────────────────────────────────────────────────────────────

(defun allowed-user-p (chan user-id)
  "Return T if USER-ID is permitted to interact with the bot through CHAN.

Rules:
  - If CHAN has no allowlist (TELEGRAM-CHANNEL-ALLOWED-USERS is NIL),
    all users are permitted and this always returns T.
  - If an allowlist is set, USER-ID must appear in it (compared with EQL).
    Any integer user-id not in the list is rejected."
  (let ((allowed (telegram-channel-allowed-users chan)))
    (if allowed
        (and (member user-id allowed :test #'eql) t)
        t)))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 6. Session Management
;;;; ─────────────────────────────────────────────────────────────────────────────

(defun %make-telegram-agent ()
  "Build a default Clambda agent for Telegram.

Client:  *TELEGRAM-LLM-BASE-URL* + *TELEGRAM-LLM-API-KEY* + *DEFAULT-MODEL*.
Tools:   builtin registry (exec, read_file, write_file, list_dir, web_fetch, tts).
Prompt:  *TELEGRAM-SYSTEM-PROMPT*.

Users can override any of these vars in init.lisp before starting the channel."
  (let* ((client   (cl-llm:make-client
                    :base-url *telegram-llm-base-url*
                    :api-key  *telegram-llm-api-key*
                    :model    clambda/config:*default-model*))
         (registry (clambda/builtins:make-builtin-registry)))
    (clambda/agent:make-agent
     :name          "telegram-bot"
     :client        client
     :tool-registry registry
     :system-prompt *telegram-system-prompt*)))

(defun find-or-create-session (chan chat-id)
  "Find the Clambda session for CHAT-ID in CHAN, creating one if needed.

Each chat_id gets its own isolated session (separate conversation history
and agent instance). Thread-safe: protected by CHAN's SESSIONS-LOCK.

Returns the session."
  (bt:with-lock-held ((telegram-channel-sessions-lock chan))
    (let ((tbl (telegram-channel-sessions chan)))
      (or (gethash chat-id tbl)
          (let ((session (clambda/session:make-session
                          :agent (%make-telegram-agent))))
            (setf (gethash chat-id tbl) session)
            session)))))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 7. Streaming Helpers
;;;; ─────────────────────────────────────────────────────────────────────────────

(defun %current-time-ms ()
  "Return current time in milliseconds as an integer.
Uses GET-INTERNAL-REAL-TIME and INTERNAL-TIME-UNITS-PER-SECOND."
  (floor (* 1000 (get-internal-real-time)) internal-time-units-per-second))

(defun %split-telegram-text (text &optional (max-len 4096))
  "Split TEXT into chunks of at most MAX-LEN characters for Telegram messages.
Tries to break at a newline boundary first, then at a space, then hard-cuts.
Returns a list of chunk strings."
  (if (<= (length text) max-len)
      (list text)
      (let ((result '())
            (start  0)
            (len    (length text)))
        (loop while (< start len)
              do (let ((end (min (+ start max-len) len)))
                   ;; Try to break at a newline for readability
                   (when (< end len)
                     (let ((nl (position #\Newline text
                                         :start start :end end :from-end t)))
                       (if nl
                           (setf end (1+ nl))
                           ;; No newline — try space
                           (let ((space (position #\Space text
                                                  :start start :end end
                                                  :from-end t)))
                             (when space (setf end (1+ space)))))))
                   (let ((chunk (string-trim " " (subseq text start end))))
                     (when (> (length chunk) 0)
                       (push chunk result)))
                   (setf start end)))
        (nreverse result))))

(defun telegram-edit-message (chan chat-id message-id text
                              &key (parse-mode "Markdown"))
  "Edit an existing Telegram message using the editMessageText API method.

CHAN       — telegram-channel struct
CHAT-ID    — integer chat ID
MESSAGE-ID — integer message ID to edit
TEXT       — new text content
PARSE-MODE — Telegram parse mode (default: \"Markdown\")

Silently swallows \"message is not modified\" errors (Telegram 400 when the
text is unchanged).  Logs other errors to *ERROR-OUTPUT* without propagating.
Returns the API response hash-table on success, NIL on error."
  (handler-case
      (%tg-call (telegram-channel-token chan) "editMessageText"
                :chat_id    chat-id
                :message_id message-id
                :text       text
                :parse_mode parse-mode)
    (error (e)
      (let ((msg (princ-to-string e)))
        (cond
          ;; Silently swallow "message is not modified" — text was unchanged
          ((search "message is not modified" msg :test #'char-equal)
           nil)
          ;; Log other errors
          (t
           (format *error-output*
                   "~&[telegram] editMessageText error (chat ~A, msg ~A): ~A~%"
                   chat-id message-id e)
           nil))))))

(defun %run-agent-streaming (chan chat-id session text)
  "Run the agent with streaming partial-response updates via Telegram editMessageText.

Steps:
  1. Send a placeholder '…' message and capture its message_id.
  2. If placeholder send failed, fall back to non-streaming.
  3. Create an adjustable char buffer for token accumulation.
  4. Dynamically bind *ON-STREAM-DELTA* to a lambda that appends each token
     to the buffer and calls editMessageText after *TELEGRAM-STREAM-DEBOUNCE-MS*.
  5. Run the agent with :STREAM T.
  6. After the agent finishes, do a final edit with the complete response.
  7. If the final response exceeds 4096 chars, split it and send extra chunks."
  (let* ((placeholder-resp (telegram-send-message chan chat-id "…"))
         (placeholder-id   (and placeholder-resp
                                (gethash "message_id"
                                         (gethash "result" placeholder-resp)))))
    (if (null placeholder-id)
        ;; Fallback: non-streaming (placeholder send failed)
        (let* ((opts     (clambda/loop:make-loop-options
                          :max-turns clambda/config:*default-max-turns*
                          :stream    nil))
               (response (handler-case
                              (clambda/loop:run-agent session text :options opts)
                            (error (e)
                              (format *error-output*
                                      "~&[telegram] Agent error (chat ~A): ~A~%"
                                      chat-id e)
                              (format nil "Sorry, I ran into an error: ~A" e)))))
          (telegram-send-message chan chat-id (or response "…")))

        ;; Streaming path: edit the placeholder as tokens arrive
        (let* ((buf          (make-array 0
                                         :element-type 'character
                                         :fill-pointer 0
                                         :adjustable   t))
               (last-edit-ms (%current-time-ms))
               (opts         (clambda/loop:make-loop-options
                              :max-turns clambda/config:*default-max-turns*
                              :stream    t)))
          (handler-case
              (let ((clambda/loop:*on-stream-delta*
                      (lambda (delta)
                        (loop for ch across delta
                              do (vector-push-extend ch buf))
                        (let* ((now          (%current-time-ms))
                               (current-text (coerce buf 'string)))
                          (when (>= (- now last-edit-ms)
                                    *telegram-stream-debounce-ms*)
                            ;; Debounce window expired — send an intermediate edit
                            (let ((edit-text (if (> (length current-text) 4096)
                                                 (subseq current-text 0 4096)
                                                 current-text)))
                              (telegram-edit-message chan chat-id placeholder-id
                                                     edit-text))
                            (setf last-edit-ms now))))))
                (clambda/loop:run-agent session text :options opts))
            (error (e)
              (format *error-output*
                      "~&[telegram] Streaming agent error (chat ~A): ~A~%"
                      chat-id e)))

          ;; Final edit: send complete accumulated response
          (let ((final-text (coerce buf 'string)))
            (if (> (length final-text) 0)
                (let ((chunks (%split-telegram-text final-text 4096)))
                  ;; Edit placeholder with first chunk
                  (telegram-edit-message chan chat-id placeholder-id (first chunks))
                  ;; Send any additional chunks as new messages
                  (dolist (chunk (rest chunks))
                    (telegram-send-message chan chat-id chunk)))
                ;; Buffer is empty — agent produced no output
                (telegram-edit-message chan chat-id placeholder-id
                                       "Sorry, I couldn't generate a response.")))))))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 8. Update Processing
;;;; ─────────────────────────────────────────────────────────────────────────────

(defun %extract-message-fields (update)
  "Extract key fields from a Telegram update hash-table.

Returns (values text chat-id user-id first-name) for text messages.
Returns (values nil nil nil nil) for non-text or malformed updates."
  (let* ((msg   (gethash "message" update))
         (text  (and msg (gethash "text" msg)))
         (chat  (and msg (gethash "chat" msg)))
         (chat-id (and chat (gethash "id" chat)))
         (from  (and msg (gethash "from" msg)))
         (uid   (and from (gethash "id" from)))
         (name  (and from (gethash "first_name" from))))
    (values text chat-id uid name)))

(defun process-update (chan update)
  "Process one Telegram update.

Steps:
  1. Extract text / chat-id / user-id from the update.
  2. Ignore non-text messages (photos, stickers, etc.).
  3. Check allowlist — silently skip if user is blocked.
  4. Fire *CHANNEL-MESSAGE-HOOK* (chan text).
  5. Find or create a session for this chat_id.
  6. Run the agent loop: (run-agent session text).
  7. Send the response via sendMessage.

Agent errors are caught and reported to the user as an error message
rather than crashing the polling loop."
  (multiple-value-bind (text chat-id user-id user-name)
      (%extract-message-fields update)
    (when (and text chat-id)          ; ignore non-text updates
      (cond
        ;; Allowlist rejection
        ((not (allowed-user-p chan user-id))
         (format *error-output*
                 "~&[telegram] Rejected message from user ~A (not in allowlist).~%"
                 user-id))

        ;; Accepted — process the message
        (t
         (format t "~&[telegram] ~A (chat ~A): ~A~%"
                 (or user-name "?") chat-id
                 (if (> (length text) 80)
                     (concatenate 'string (subseq text 0 80) "…")
                     text))

         ;; Fire channel-message-hook
         (clambda/config:run-hook-with-args 'clambda/config:*channel-message-hook*
                                             chan text)

         ;; Get or create session for this chat, then dispatch
         (let ((session (find-or-create-session chan chat-id)))
           (if *telegram-streaming*
               ;; Streaming: send placeholder, edit as tokens arrive
               (%run-agent-streaming chan chat-id session text)
               ;; Non-streaming: run agent, then sendMessage
               (let* ((opts     (clambda/loop:make-loop-options
                                 :max-turns clambda/config:*default-max-turns*
                                 :stream    nil))
                      (response (handler-case
                                    (clambda/loop:run-agent session text :options opts)
                                  (error (e)
                                    (format *error-output*
                                            "~&[telegram] Agent error (chat ~A): ~A~%"
                                            chat-id e)
                                    (format nil "Sorry, I ran into an error: ~A" e)))))
                 (telegram-send-message chan chat-id (or response "…"))))))))))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 8. The Polling Loop
;;;; ─────────────────────────────────────────────────────────────────────────────

(defun %polling-loop (chan)
  "Main long-polling loop. Runs in a background thread.

Each iteration:
  1. Call telegram-get-updates — blocks for *TELEGRAM-POLL-TIMEOUT* seconds.
  2. For each received update, call PROCESS-UPDATE and advance LAST-UPDATE-ID.
  3. Sleep POLLING-INTERVAL seconds.
  4. Repeat while RUNNING is T.

Network/parse errors are caught, logged, and retried (does not crash the thread).
The loop exits cleanly when RUNNING is set to NIL (by STOP-TELEGRAM)."
  (format t "~&[telegram] Polling loop started (token ~A...).~%"
          (subseq (telegram-channel-token chan) 0 (min 8 (length (telegram-channel-token chan)))))
  (loop while (telegram-channel-running chan)
        do (handler-case
               (let ((updates (telegram-get-updates chan)))
                 (dolist (update updates)
                   (let ((uid (gethash "update_id" update)))
                     (when (and uid (> uid (telegram-channel-last-update-id chan)))
                       (setf (telegram-channel-last-update-id chan) uid))
                     (handler-case
                         (process-update chan update)
                       (error (e)
                         (format *error-output*
                                 "~&[telegram] Error processing update ~A: ~A~%"
                                 uid e)))))
                 (when updates
                   (sleep (telegram-channel-polling-interval chan))))
             ;; Network / HTTP errors — log and retry after a brief wait
             (error (e)
               (when (telegram-channel-running chan)   ; don't log during shutdown
                 (format *error-output*
                         "~&[telegram] Polling error: ~A — retrying in ~As~%"
                         e (telegram-channel-polling-interval chan)))
               (sleep (telegram-channel-polling-interval chan)))))
  (format t "~&[telegram] Polling loop stopped.~%"))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 9. Start / Stop
;;;; ─────────────────────────────────────────────────────────────────────────────

(defun telegram-running-p (&optional (chan *telegram-channel*))
  "Return T if CHAN's polling loop is active."
  (and chan
       (telegram-channel-running chan)
       (telegram-channel-thread chan)
       t))

(defun start-telegram (&optional (chan *telegram-channel*))
  "Start the polling thread for CHAN (default: *TELEGRAM-CHANNEL*).

If CHAN is NIL, signals an error — register a channel first:
  (register-channel :telegram :token \"TOKEN\")
  (start-telegram)

If the channel is already running, this is a no-op (prints a warning).

Returns CHAN."
  (unless chan
    (error "[telegram] No channel to start. Call (register-channel :telegram :token \"...\") first."))
  (when (telegram-channel-running chan)
    (format t "~&[telegram] Channel is already running.~%")
    (return-from start-telegram chan))
  (setf (telegram-channel-running chan) t)
  (setf (telegram-channel-thread chan)
        (bt:make-thread
         (lambda () (%polling-loop chan))
         :name "clambda-telegram-poll"))
  (setf *telegram-channel* chan)
  (format t "~&[telegram] Channel started.~%")
  chan)

(defun stop-telegram (&optional (chan *telegram-channel*))
  "Stop the polling thread for CHAN (default: *TELEGRAM-CHANNEL*).

Sets the running flag to NIL. The polling loop will exit after the current
getUpdates call completes (within *TELEGRAM-POLL-TIMEOUT* seconds).
Does not join the thread — returns immediately.

Returns CHAN."
  (when (and chan (telegram-channel-running chan))
    (setf (telegram-channel-running chan) nil)
    (format t "~&[telegram] Stop requested; polling will exit shortly.~%"))
  chan)

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 10. Multi-Channel Startup
;;;; ─────────────────────────────────────────────────────────────────────────────

(defun start-all-channels ()
  "Start all channels registered in *REGISTERED-CHANNELS*.

Currently supports :telegram (other channel types are skipped with a notice).
Call this after loading init.lisp and registering channels:

  ;; In init.lisp:
  (register-channel :telegram :token \"BOT_TOKEN\")

  ;; After loading:
  (clambda/telegram:start-all-channels)

Returns the list of successfully started channel objects."
  (let ((started '()))
    (dolist (entry clambda/config:*registered-channels*)
      (let ((type (car entry)))
        (case type
          (:telegram
           (if *telegram-channel*
               (progn
                 (start-telegram *telegram-channel*)
                 (push *telegram-channel* started))
               (format *error-output*
                       "~&[telegram] :telegram registered but *telegram-channel* is NIL~%")))
          (otherwise
           (format t "~&[telegram] start-all-channels: no starter for channel ~A~%" type)))))
    (nreverse started)))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 11. register-channel Specialization
;;;; ─────────────────────────────────────────────────────────────────────────────

(defmethod clambda/config:register-channel
    ((type (eql :telegram)) &rest args
     &key token
          (allowed-users nil)
          (polling-interval 1)
          (streaming t)
     &allow-other-keys)
  "Register a Telegram channel from init.lisp.

Creates a TELEGRAM-CHANNEL struct and stores it in *TELEGRAM-CHANNEL*.
Does NOT start polling — call START-TELEGRAM or START-ALL-CHANNELS to begin.

Usage:
  (register-channel :telegram
    :token \"BOT_TOKEN\"
    :allowed-users '(12345678)  ; optional user-ID allowlist
    :polling-interval 1         ; seconds between polls (default 1)
    :streaming t)               ; enable streaming partial responses (default T)

After init.lisp loads, start the channel explicitly:
  (clambda/telegram:start-telegram)
  ;; or, to start all registered channels:
  (clambda/telegram:start-all-channels)"
  (declare (ignore args))
  (unless (and token (not (string= token "")))
    (error "[telegram] register-channel :telegram requires a :token argument."))
  (let ((chan (make-telegram-channel :token            token
                                      :allowed-users    allowed-users
                                      :polling-interval polling-interval)))
    (setf *telegram-channel* chan)
    (setf *telegram-streaming* streaming)
    (format t "~&[telegram] Channel registered (not yet polling). ~
               Call (start-telegram) to begin.~%"))
  ;; Store raw config in *registered-channels* via default method
  (call-next-method))
