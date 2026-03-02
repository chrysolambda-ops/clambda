;;;; src/telegram.lisp — Telegram Bot API channel for Clawmacs
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
;;;;        (ql:quickload :clawmacs-core)
;;;;        (clawmacs/config:register-channel :telegram :token "TOKEN")
;;;;        (clawmacs/telegram:start-telegram)
;;;;        ;; Now send a message to your bot in Telegram.
;;;;        (clawmacs/telegram:stop-telegram)
;;;;
;;;; Unit tests (no real token needed) are in t/test-telegram.lisp.
;;;; Mock tests simulate update parsing and allowlist logic without HTTP.

(in-package #:clawmacs/telegram)

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 1. Global State and Options
;;;; ─────────────────────────────────────────────────────────────────────────────

(defvar *telegram-channel* nil
  "The most recently registered/started Telegram channel, or NIL.
Set automatically by REGISTER-CHANNEL :TELEGRAM.")

(defvar *telegram-llm-base-url* "http://localhost:1234/v1"
  "LLM API base URL for the Telegram channel agent.
Defaults to LM Studio local endpoint. Override in init.lisp:
  (setf clawmacs/telegram:*telegram-llm-base-url* \"http://...\").")

(defvar *telegram-llm-api-key* "lm-studio"
  "LLM API key for the Telegram channel agent.")

(defvar *telegram-llm-api-type* :openai
  "API type for the Telegram channel LLM client.
Use :OPENAI (default) for OpenAI-compatible APIs (OpenRouter, LM Studio, etc.)
Use :ANTHROPIC for the direct Anthropic Messages API.
Use :CLAUDE-CLI or :CODEX-CLI for OAuth-authenticated local CLI backends.
Use :CODEX-OAUTH for native browser-link OAuth (no codex CLI required).")

(defvar *telegram-codex-auth-mode* :oauth-session
  "Auth mode used when *TELEGRAM-LLM-API-TYPE* is :CODEX-CLI.

:OAUTH-SESSION (default) mirrors OpenClaw behavior: rely on the linked
local Codex CLI OAuth session (created by `codex login`) and do not require
an API key in Clawmacs config.")

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

(defvar *telegram-model-state-path*
  (merge-pathnames "telegram-model-state.lisp" clawmacs/config:*clawmacs-home*)
  "Path to persisted Telegram model selection state.")

(defparameter *telegram-model-catalog*
  '((:provider "OpenAI Codex OAuth"
     :models ("gpt-5.3-codex" "gpt-5-codex" "gpt-5-mini"))
    (:provider "Claude CLI"
     :models ("claude-opus-4-6" "claude-sonnet-4" "claude-3-5-sonnet-latest"))
    (:provider "OpenRouter / OpenAI-compatible"
     :models ("anthropic/claude-sonnet-4"
              "google/gemma-3-4b"
              "openai/gpt-4o-mini"
              "meta-llama/llama-3.3-70b-instruct"
              "deepseek/deepseek-chat-v3-0324"))
    (:provider "Local (LM Studio / Ollama)"
     :models ("local/qwen2.5-7b" "local/llama3.1-8b" "google/gemma-3-12b")))
  "Curated model catalog shown by /models.")

(defparameter *telegram-codex-only-model-catalog*
  '((:provider "OpenAI Codex OAuth"
     :models ("gpt-5.3-codex" "gpt-5-codex" "gpt-5-mini")))
  "Safe model catalog when Telegram is running in :CODEX-OAUTH mode.")

(defun %active-model-catalog ()
  (if (eq *telegram-llm-api-type* :codex-oauth)
      *telegram-codex-only-model-catalog*
      *telegram-model-catalog*))


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
Keyword keys are downcased: :chat_id → \"chat_id\".
NIL values are omitted (not serialized)."
  (let ((ht (make-hash-table :test 'equal)))
    (loop for (k v) on plist by #'cddr
          when v
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
                           :allowed_updates (list "message" "callback_query"))))
    (if (gethash "ok" result)
        (coerce (or (gethash "result" result) #()) 'list)
        '())))

(defun telegram-send-chat-action (chan chat-id action)
  "Send a chat action (e.g. \"typing\") to CHAT-ID.
Shows a status indicator in Telegram while the bot is processing.
Silently swallows errors."
  (handler-case
      (%tg-call (telegram-channel-token chan) "sendChatAction"
                :chat_id chat-id
                :action  action)
    (error (e)
      (format *error-output*
              "~&[telegram] sendChatAction error (chat ~A): ~A~%" chat-id e)
      (log-error :telegram "sendChatAction error (chat ~A): ~A" chat-id e)
      nil)))

(defun telegram-send-message (chan chat-id text &key (parse-mode nil) (reply-markup nil))
  "Send TEXT to CHAT-ID via CHAN's bot token.
PARSE-MODE defaults to \"Markdown\" — Telegram's simplified Markdown subset.
REPLY-MARKUP optionally carries Telegram reply markup (inline keyboard, etc.)."
  (handler-case
      (%tg-call (telegram-channel-token chan) "sendMessage"
                :chat_id      chat-id
                :text         text
                :parse_mode   parse-mode
                :reply_markup reply-markup)
    (error (e)
      (format *error-output*
              "~&[telegram] sendMessage error (chat ~A): ~A~%" chat-id e)
      (log-error :telegram "sendMessage error (chat ~A): ~A" chat-id e)
      nil)))

(defun telegram-answer-callback-query (chan callback-query-id text)
  "Answer Telegram callback query to clear client loading UI."
  (handler-case
      (%tg-call (telegram-channel-token chan) "answerCallbackQuery"
                :callback_query_id callback-query-id
                :text text)
    (error (e)
      (format *error-output* "~&[telegram] answerCallbackQuery error: ~A~%" e)
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

(defvar *telegram-agent-name* "telegram-bot"
  "Name used for the Telegram bot agent. Corresponds to the agent name shown in logs and system prompt.")

(defvar *telegram-agent-workspace* nil
  "Workspace path for the Telegram bot agent.
If NIL, defaults to ~/.clawmacs/agents/ceo-chryso/ (or the first registered agent's workspace).
Set from init.lisp or register-channel.")

(defun %resolve-telegram-workspace ()
  "Return the workspace path for the Telegram agent.
Checks *TELEGRAM-AGENT-WORKSPACE* first, then looks up the agent registry."
  (or *telegram-agent-workspace*
      (handler-case
          (let* ((registry clawmacs/registry:*agent-registry*)
                 ;; Try ceo-chryso first (the standard Telegram persona)
                 (spec (or (clawmacs/registry:find-agent "ceo-chryso")
                           (and registry (first (clawmacs/registry:list-agents))))))
            (when spec
              (clawmacs/registry:agent-spec-workspace spec)))
        (error () nil))
      (merge-pathnames ".clawmacs/agents/telegram/"
                       (user-homedir-pathname))))

(defun %build-telegram-system-prompt (registry)
  "Build the dynamic system prompt for the Telegram agent.
Includes personality from *TELEGRAM-SYSTEM-PROMPT*, tool listing, workspace files, runtime info."
  (handler-case
      (clawmacs/system-prompt:build-telegram-system-prompt
       :agent-name        *telegram-agent-name*
       :workspace-path    (%resolve-telegram-workspace)
       :tool-registry     registry
       :personality-prompt *telegram-system-prompt*)
    (error (e)
      ;; Fall back to static prompt if builder fails
      (format *error-output*
              "~&[telegram] system-prompt builder error: ~A — using static prompt~%" e)
      *telegram-system-prompt*)))

(defun %make-telegram-agent ()
  "Build a default Clawmacs agent for Telegram.

Client:  *TELEGRAM-LLM-BASE-URL* + *TELEGRAM-LLM-API-KEY* + *DEFAULT-MODEL*.
         Uses *TELEGRAM-LLM-API-TYPE* to select :OPENAI or :ANTHROPIC.
Tools:   builtin registry (exec, read_file, write_file, list_dir, web_fetch, tts, eval_lisp, etc.).
Prompt:  dynamically built by BUILD-TELEGRAM-SYSTEM-PROMPT (workspace files + tool listing).

Users can override any of these vars in init.lisp before starting the channel."
  (let* ((client   (cond
                     ((eq *telegram-llm-api-type* :claude-cli)
                      (cl-llm:make-claude-cli-client
                       :model clawmacs/config:*default-model*))
                     ((eq *telegram-llm-api-type* :codex-oauth)
                      (format t "~&[telegram] ~A~%" (cl-llm:codex-oauth-status-string))
                      (cl-llm:make-codex-oauth-client
                       :model clawmacs/config:*default-model*))
                     ((eq *telegram-llm-api-type* :codex-cli)
                      (setf cl-llm:*codex-auth-mode* *telegram-codex-auth-mode*)
                      (format t "~&[telegram] ~A~%"
                              (cl-llm:codex-auth-status-string
                               :model clawmacs/config:*default-model*))
                      (when (and *telegram-llm-api-key*
                                 (not (string= (string-trim " " *telegram-llm-api-key*) "")))
                        (format t "~&[telegram] NOTE: *TELEGRAM-LLM-API-KEY* is set, but :CODEX-CLI uses OAuth session from `codex login`.~%"))
                      (cl-llm:make-codex-cli-client
                       :model clawmacs/config:*default-model*))
                     ((eq *telegram-llm-api-type* :anthropic)
                      (cl-llm:make-anthropic-client
                       :api-key *telegram-llm-api-key*
                       :model   clawmacs/config:*default-model*))
                     (t
                      (cl-llm:make-client
                       :base-url *telegram-llm-base-url*
                       :api-key  *telegram-llm-api-key*
                       :model    clawmacs/config:*default-model*))))
         (registry (clawmacs/builtins:make-builtin-registry))
         (prompt   (%build-telegram-system-prompt registry)))
    (clawmacs/agent:make-agent
     :name          *telegram-agent-name*
     :model         clawmacs/config:*default-model*
     :client        client
     :tool-registry registry
     :system-prompt prompt)))

(defun find-or-create-session (chan chat-id)
  "Find the Clawmacs session for CHAT-ID in CHAN, creating one if needed.

Each chat_id gets its own isolated session (separate conversation history
and agent instance). Thread-safe: protected by CHAN's SESSIONS-LOCK.

Returns the session."
  (bt:with-lock-held ((telegram-channel-sessions-lock chan))
    (let ((tbl (telegram-channel-sessions chan)))
      (or (gethash chat-id tbl)
          (let ((session (clawmacs/session:make-session
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
                              &key (parse-mode nil))
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
           (log-error :telegram "editMessageText error (chat ~A, msg ~A): ~A"
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
        (let* ((opts     (clawmacs/loop:make-loop-options
                          :max-turns clawmacs/config:*default-max-turns*
                          :stream    nil))
               (response (handler-case
                              (clawmacs/loop:run-agent session text :options opts)
                            (error (e)
                              (format *error-output*
                                      "~&[telegram] Agent error (chat ~A): ~A~%"
                                      chat-id e)
                              (log-error :telegram "Agent error (chat ~A): ~A" chat-id e)
                              (format nil "Sorry, I ran into an error: ~A" e)))))
          (telegram-send-message chan chat-id (or response "…")))

        ;; Streaming path: edit the placeholder as tokens arrive
        (let* ((buf          (make-array 0
                                         :element-type 'character
                                         :fill-pointer 0
                                         :adjustable   t))
               (last-edit-ms (%current-time-ms))
               (opts         (clawmacs/loop:make-loop-options
                              :max-turns clawmacs/config:*default-max-turns*
                              :stream    t)))
          (handler-case
              (let ((clawmacs/loop:*on-stream-delta*
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
                (clawmacs/loop:run-agent session text :options opts))
            (error (e)
              (format *error-output*
                      "~&[telegram] Streaming agent error (chat ~A): ~A~%"
                      chat-id e)
              (log-error :telegram "Streaming agent error (chat ~A): ~A" chat-id e)))

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
;;;; § 8. Slash Command Handling
;;;; ─────────────────────────────────────────────────────────────────────────────

(defvar *bot-start-time* (get-universal-time)
  "Universal time when the Telegram bot was started.")

(defun %all-supported-models ()
  (loop for entry in (%active-model-catalog)
        append (getf entry :models)))

(defun %model-supported-p (model-id)
  (and (stringp model-id)
       (member model-id (%all-supported-models) :test #'string=)))

(defun %persist-telegram-model (model-id)
  (ensure-directories-exist *telegram-model-state-path*)
  (with-open-file (out *telegram-model-state-path*
                       :direction :output :if-exists :supersede :if-does-not-exist :create)
    (format out ";;; Auto-generated by Clawmacs Telegram /models~%")
    (format out "(in-package #:clawmacs/config)~%")
    (format out "(setf *default-model* ~S)~%" model-id))
  model-id)

(defun load-persisted-telegram-model ()
  (when (probe-file *telegram-model-state-path*)
    (handler-case
        (load *telegram-model-state-path* :verbose nil :print nil)
      (error (e)
        (format *error-output* "~&[telegram] Failed loading model state ~A: ~A~%"
                (namestring *telegram-model-state-path*) e)))))

(defun %enforce-codex-safe-profile ()
  "Harden Telegram runtime for :CODEX-OAUTH deployments."
  (when (eq *telegram-llm-api-type* :codex-oauth)
    ;; Disable cross-provider fallback chain that can leak unavailable model/provider errors.
    (setf clawmacs/config:*fallback-models* nil)
    ;; Prefer best supported Codex OAuth model.
    (unless (%model-supported-p clawmacs/config:*default-model*)
      (setf clawmacs/config:*default-model* "gpt-5.3-codex"))
    ;; Force safe default if persisted state is a non-codex model.
    (unless (member clawmacs/config:*default-model*
                    '("gpt-5.3-codex" "gpt-5-codex" "gpt-5-mini")
                    :test #'string=)
      (setf clawmacs/config:*default-model* "gpt-5.3-codex"))
    (setf cl-llm:*codex-oauth-fallback-enabled* nil)))

(defun %set-telegram-model! (session model-id)
  (setf clawmacs/config:*default-model* model-id)
  (let* ((agent (clawmacs/session:session-agent session))
         (client (and agent (clawmacs/agent:agent-client agent))))
    (when agent (setf (clawmacs/agent:agent-model agent) model-id))
    (when client
      (handler-case (setf (cl-llm:client-model client) model-id)
        (error () nil))))
  (%persist-telegram-model model-id)
  model-id)

(defun %models-help-text ()
  "Usage:\n/models — show grouped model list\n/models set &lt;model-id&gt; — set active model\n\nExample:\n/models set gpt-5.3-codex")

(defun %build-models-inline-keyboard ()
  (let* ((models (%all-supported-models))
         (rows (make-array 0 :adjustable t :fill-pointer 0)))
    (loop for i from 0 below (length models) by 2
          do (let ((row (make-array 0 :adjustable t :fill-pointer 0)))
               (dolist (model (subseq models i (min (+ i 2) (length models))))
                 (let ((b (make-hash-table :test 'equal)))
                   (setf (gethash "text" b) model)
                   (setf (gethash "callback_data" b) (format nil "models:set:~A" model))
                   (vector-push-extend b row)))
               (vector-push-extend row rows)))
    (let ((markup (make-hash-table :test 'equal)))
      (setf (gethash "inline_keyboard" markup) rows)
      markup)))

(defun %render-models-list ()
  (with-output-to-string (out)
    (format out "🧠 <b>Model Selection</b>~%")
    (format out "Current: <code>~A</code>~2%" clawmacs/config:*default-model*)
    (dolist (entry (%active-model-catalog))
      (format out "<b>~A</b>~%" (getf entry :provider))
      (dolist (model (getf entry :models))
        (format out "• <code>~A</code>~A~%"
                model
                (if (string= model clawmacs/config:*default-model*) " ✅" "")))
      (terpri out))))

(defun %format-uptime (seconds)
  "Format SECONDS into a human-readable uptime string."
  (let* ((days    (floor seconds 86400))
         (rem1    (mod seconds 86400))
         (hours   (floor rem1 3600))
         (rem2    (mod rem1 3600))
         (minutes (floor rem2 60))
         (secs    (mod rem2 60)))
    (if (> days 0)
        (format nil "~Ad ~Ah ~Am ~As" days hours minutes secs)
        (format nil "~Ah ~Am ~As" hours minutes secs))))

(defun %session-token-estimate (session)
  "Estimate total tokens used in SESSION (from tracking + current history)."
  (let* ((messages (clawmacs/session:session-messages session))
         (hist-estimate (reduce #'+ messages
                                :key (lambda (m)
                                       (max 1 (ceiling (length (or (cl-llm/protocol:message-content m) "")) 4)))
                                :initial-value 0))
         (tracked (clawmacs/session:session-total-tokens session)))
    (max hist-estimate tracked)))

(defun handle-cmd-new (chan chat-id session)
  "Handle /new or /reset — clear conversation history."
  (clawmacs/session:session-clear-messages session)
  (setf (clawmacs/session:session-total-tokens session) 0)
  (format t "~&[telegram] /new — cleared session for chat ~A~%" chat-id)
  (telegram-send-message chan chat-id
   "✅ <b>New session started.</b> Conversation history cleared."
   :parse-mode "HTML"))

(defun handle-cmd-status (chan chat-id session)
  "Handle /status — show session info."
  (let* ((agent   (clawmacs/session:session-agent session))
         (model   (or (clawmacs/agent:agent-model agent) "(unknown)"))
         (uptime  (%format-uptime (- (get-universal-time) *bot-start-time*)))
         (msgs    (length (clawmacs/session:session-messages session)))
         (tracked (clawmacs/session:session-total-tokens session))
         (tokens  (%session-token-estimate session))
         (window  (if (boundp 'clawmacs/config:*default-context-window*)
                      clawmacs/config:*default-context-window*
                      32768))
         (pct     (if (> window 0)
                      (floor (* 100 tokens) window)
                      0)))
    (telegram-send-message chan chat-id
     (cond
       ((eq *telegram-llm-api-type* :codex-cli)
        (let* ((auth (cl-llm:codex-auth-status :model model))
               (linked (if (getf auth :linked-session-found) "linked" "missing"))
               (cli (if (getf auth :codex-cli-found) "found" "missing")))
          (format nil
                  "📊 <b>Clawmacs Status</b>~%~%Model: <code>~A</code>~%Uptime: ~A~%Messages in history: ~A~%Token usage: ~A~%Compaction: ~A~%Codex CLI: ~A~%Codex OAuth session: ~A"
                  model uptime msgs
                  (if (= tracked 0)
                      (format nil "~A (estimated) / ~A (~A%%)" tokens window pct)
                      (format nil "~A / ~A (~A%%)" tokens window pct))
                  (if (and (boundp 'clawmacs/config:*compaction-enabled*)
                           clawmacs/config:*compaction-enabled*)
                      "enabled" "disabled")
                  cli linked)))
       ((eq *telegram-llm-api-type* :codex-oauth)
        (let* ((auth (cl-llm:codex-oauth-status))
               (linked (if (getf auth :linked) "linked" "missing"))
               (expired (if (getf auth :expired) "yes" "no"))
               (transport (or cl-llm:*codex-oauth-last-transport* :uninitialized))
               (transport-error (or cl-llm:*codex-oauth-last-transport-error* "none")))
          (format nil
                  "📊 <b>Clawmacs Status</b>~%~%Backend: <code>~A</code>~%Model: <code>~A</code>~%Uptime: ~A~%Messages in history: ~A~%Token usage: ~A~%Compaction: ~A~%Codex OAuth linked: ~A~%Token expired: ~A~%Runtime bridge fallback: ~A~%Last transport: <code>~A</code>~%Last transport error: <code>~A</code>"
                  *telegram-llm-api-type* model uptime msgs
                  (if (= tracked 0)
                      (format nil "~A (estimated) / ~A (~A%%)" tokens window pct)
                      (format nil "~A / ~A (~A%%)" tokens window pct))
                  (if (and (boundp 'clawmacs/config:*compaction-enabled*)
                           clawmacs/config:*compaction-enabled*)
                      "enabled" "disabled")
                  linked expired
                  (if cl-llm:*codex-oauth-fallback-enabled* "enabled" "disabled")
                  transport transport-error)))
       (t
        (format nil
                "📊 <b>Clawmacs Status</b>~%~%Model: <code>~A</code>~%Uptime: ~A~%Messages in history: ~A~%Token usage: ~A~%Compaction: ~A"
                model uptime msgs
                (if (= tracked 0)
                    (format nil "~A (estimated) / ~A (~A%%)" tokens window pct)
                    (format nil "~A / ~A (~A%%)" tokens window pct))
                (if (and (boundp 'clawmacs/config:*compaction-enabled*)
                         clawmacs/config:*compaction-enabled*)
                    "enabled" "disabled"))))
     :parse-mode "HTML")))

(defun handle-cmd-help (chan chat-id)
  "Handle /help — list available commands."
  (telegram-send-message chan chat-id
   (concatenate 'string
    "🤖 <b>Clawmacs Bot Commands</b>\n\n"
    "/new — Start a fresh conversation\n"
    "/reset — Same as /new\n"
    "/status — Show session info (model, uptime, tokens)\n"
    "/model — Show current model\n"
    "/model &lt;name&gt; — Set model (validated)\n"
    "/models — Show grouped model picker\n"
    "/models set &lt;model-id&gt; — Persist and set active model\n"
    "/codex_login — Start browser-link Codex OAuth\n"
    "/codex_link <redirect-url|code#state> — Complete OAuth link\n"
    "/codex_status — Codex OAuth status\n"
    "/codex_auth_status — Legacy Codex CLI diagnostics\n"
    "/help — Show this help\n\n"
    "Any other message is sent to the AI.")
   :parse-mode "HTML"))

(defun handle-cmd-codex-login (chan chat-id)
  "Handle /codex_login — start native OAuth browser-link flow."
  (handler-case
      (let* ((result (cl-llm:codex-oauth-start))
             (url (getf result :auth-url))
             (state (getf result :state)))
        (telegram-send-message chan chat-id
                               (format nil "🔐 <b>Codex OAuth Login</b>~%~%1) Open this URL:~%<code>~A</code>~%~%2) Approve access in browser.~%3) Paste the full redirect URL to:~%<code>/codex_link &lt;redirect-url&gt;</code>~%~%State: <code>~A</code>" url state)
                               :parse-mode "HTML"))
    (error (e)
      (telegram-send-message chan chat-id (format nil "Could not start Codex OAuth: ~A" e)))))

(defun handle-cmd-codex-link (chan chat-id args)
  "Handle /codex_link <redirect-or-code-state> — complete OAuth exchange."
  (let ((payload (string-trim " " (or args ""))))
    (if (string= payload "")
        (telegram-send-message chan chat-id
                               "Usage: /codex_link <redirect-url|code#state>")
        (let ((res (cl-llm:codex-oauth-complete payload)))
          (telegram-send-message chan chat-id
                                 (if (getf res :ok)
                                     "✅ Codex OAuth linked. You can now chat using :codex-oauth."
                                     (format nil "❌ Codex OAuth link failed: ~A" (getf res :message))))))))

(defun handle-cmd-codex-status (chan chat-id)
  "Handle /codex_status — show native OAuth status."
  (telegram-send-message chan chat-id
                         (format nil "<pre>~A</pre>" (cl-llm:codex-oauth-status-string))
                         :parse-mode "HTML"))

(defun handle-cmd-codex-auth-status (chan chat-id)
  "Handle /codex_auth_status — show Codex OAuth diagnostics."
  (if (eq *telegram-llm-api-type* :codex-cli)
      (telegram-send-message chan chat-id
                             (format nil "<pre>~A</pre>"
                                     (cl-llm:codex-auth-status-string
                                      :model clawmacs/config:*default-model*))
                             :parse-mode "HTML")
      (telegram-send-message chan chat-id
                             "Legacy Codex CLI diagnostics are relevant when `*TELEGRAM-LLM-API-TYPE*` is :CODEX-CLI.")))

(defun handle-cmd-model (chan chat-id session args)
  "Backward-compatible /model alias."
  (let ((trimmed (string-trim " " (or args ""))))
    (if (string= trimmed "")
        (telegram-send-message chan chat-id
                               (format nil "🤖 Current model: <code>~A</code>" clawmacs/config:*default-model*)
                               :parse-mode "HTML")
        (if (%model-supported-p trimmed)
            (progn
              (%set-telegram-model! session trimmed)
              (telegram-send-message chan chat-id
                                     (format nil "✅ Model changed to <code>~A</code>" trimmed)
                                     :parse-mode "HTML"))
            (telegram-send-message chan chat-id
                                   (format nil "❌ Unknown model: <code>~A</code>~%~%~A"
                                           trimmed
                                           (%models-help-text))
                                   :parse-mode "HTML")))))

(defun handle-cmd-models (chan chat-id session args)
  "Handle /models and /models set <model-id>."
  (let ((trimmed (string-trim " " (or args ""))))
    (cond
      ((or (string= trimmed "") (string= trimmed "list"))
       (telegram-send-message chan chat-id
                              (%render-models-list)
                              :parse-mode "HTML"
                              :reply-markup (%build-models-inline-keyboard)))
      ((and (> (length trimmed) 4)
            (string= (subseq trimmed 0 4) "set "))
       (let ((model-id (string-trim " " (subseq trimmed 4))))
         (if (%model-supported-p model-id)
             (progn
               (%set-telegram-model! session model-id)
               (telegram-send-message chan chat-id
                                      (format nil "✅ Active model set to <code>~A</code>" model-id)
                                      :parse-mode "HTML"))
             (telegram-send-message chan chat-id
                                    (format nil "❌ Invalid model id: <code>~A</code>~%~%~A"
                                            model-id
                                            (%models-help-text))
                                    :parse-mode "HTML"))))
      (t
       (telegram-send-message chan chat-id
                              (%models-help-text)
                              :parse-mode "HTML")))))

(defun handle-models-callback (chan callback-id chat-id session callback-data)
  "Handle inline-button callback data for /models quick picks."
  (let ((prefix "models:set:"))
    (when (and callback-data
               (>= (length callback-data) (length prefix))
               (string= prefix (subseq callback-data 0 (length prefix))))
      (let ((model-id (subseq callback-data (length prefix))))
        (if (%model-supported-p model-id)
            (progn
              (%set-telegram-model! session model-id)
              (telegram-answer-callback-query chan callback-id
                                              (format nil "Model set: ~A" model-id))
              (telegram-send-message chan chat-id
                                     (format nil "✅ Active model set to <code>~A</code>" model-id)
                                     :parse-mode "HTML"))
            (telegram-answer-callback-query chan callback-id
                                            (format nil "Invalid model: ~A" model-id)))))))

(defun %parse-command (text)
  "Parse a slash command from TEXT.
Returns (values command args) where command is e.g. \"new\" and args is remainder.
Returns (values nil nil) if TEXT is not a slash command."
  (when (and (> (length text) 0) (char= (char text 0) #\/))
    (let* ((body (subseq text 1))
           (space-pos (position #\Space body))
           (cmd-token (if space-pos (subseq body 0 space-pos) body))
           (args (if space-pos
                     (string-trim " " (subseq body (1+ space-pos)))
                     ""))
           (at-pos (position #\@ cmd-token))
           (cmd (if at-pos (subseq cmd-token 0 at-pos) cmd-token)))
      (values (string-downcase cmd) args))))

(defun dispatch-command (chan chat-id session text)
  "Try to dispatch TEXT as a slash command. Returns T if handled, NIL otherwise."
  (multiple-value-bind (cmd args)
      (%parse-command text)
    (when cmd
      (cond
        ((or (string= cmd "new") (string= cmd "reset"))
         (handle-cmd-new chan chat-id session)
         t)
        ((string= cmd "status")
         (handle-cmd-status chan chat-id session)
         t)
        ((or (string= cmd "help") (string= cmd "start"))
         (handle-cmd-help chan chat-id)
         t)
        ((string= cmd "model")
         (handle-cmd-model chan chat-id session args)
         t)
        ((string= cmd "models")
         (handle-cmd-models chan chat-id session args)
         t)
        ((string= cmd "codex_login")
         (handle-cmd-codex-login chan chat-id)
         t)
        ((string= cmd "codex_link")
         (handle-cmd-codex-link chan chat-id args)
         t)
        ((string= cmd "codex_status")
         (handle-cmd-codex-status chan chat-id)
         t)
        ((string= cmd "codex_auth_status")
         (handle-cmd-codex-auth-status chan chat-id)
         t)
        (t
         ;; Unknown command
         (telegram-send-message chan chat-id
          (format nil "Unknown command: /~A&#10;Type /help to see available commands." cmd)
          :parse-mode "HTML")
         t)))))

(defun %register-bot-commands (chan)
  "Register bot commands with Telegram via setMyCommands API.
Called on startup to populate the command menu in Telegram clients."
  (handler-case
      (let ((commands
             (vector
              (let ((ht (make-hash-table :test 'equal)))
                (setf (gethash "command" ht) "new")
                (setf (gethash "description" ht) "Start a fresh conversation")
                ht)
              (let ((ht (make-hash-table :test 'equal)))
                (setf (gethash "command" ht) "reset")
                (setf (gethash "description" ht) "Clear history (same as /new)")
                ht)
              (let ((ht (make-hash-table :test 'equal)))
                (setf (gethash "command" ht) "status")
                (setf (gethash "description" ht) "Show session info")
                ht)
              (let ((ht (make-hash-table :test 'equal)))
                (setf (gethash "command" ht) "model")
                (setf (gethash "description" ht) "Show or change current model")
                ht)
              (let ((ht (make-hash-table :test 'equal)))
                (setf (gethash "command" ht) "models")
                (setf (gethash "description" ht) "Show model picker and set model")
                ht)
              (let ((ht (make-hash-table :test 'equal)))
                (setf (gethash "command" ht) "codex_login")
                (setf (gethash "description" ht) "Start Codex OAuth browser login")
                ht)
              (let ((ht (make-hash-table :test 'equal)))
                (setf (gethash "command" ht) "codex_link")
                (setf (gethash "description" ht) "Complete Codex OAuth with pasted redirect")
                ht)
              (let ((ht (make-hash-table :test 'equal)))
                (setf (gethash "command" ht) "codex_status")
                (setf (gethash "description" ht) "Show Codex OAuth status")
                ht)
              (let ((ht (make-hash-table :test 'equal)))
                (setf (gethash "command" ht) "codex_auth_status")
                (setf (gethash "description" ht) "Show legacy Codex CLI auth diagnostics")
                ht)
              (let ((ht (make-hash-table :test 'equal)))
                (setf (gethash "command" ht) "help")
                (setf (gethash "description" ht) "List available commands")
                ht))))
        (let* ((url  (telegram-api-url (telegram-channel-token chan) "setMyCommands"))
               (body (let ((ht (make-hash-table :test 'equal)))
                       (setf (gethash "commands" ht) commands)
                       (com.inuoe.jzon:stringify ht)))
               (resp (dexador:post url
                                   :headers '(("Content-Type" . "application/json"))
                                   :content body))
               (parsed (com.inuoe.jzon:parse resp)))
          (if (gethash "ok" parsed)
              (format t "~&[telegram] Bot commands registered successfully.~%")
              (format *error-output*
                      "~&[telegram] setMyCommands failed: ~A~%" parsed))))
    (error (e)
      (format *error-output*
              "~&[telegram] Failed to register bot commands: ~A~%" e)
      (log-error :telegram "Failed to register bot commands: ~A" e))))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 9. Update Processing (was § 8)
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

(defun %extract-callback-fields (update)
  "Extract callback query fields. Returns callback-id, data, chat-id, user-id."
  (let* ((cb (gethash "callback_query" update))
         (callback-id (and cb (gethash "id" cb)))
         (data (and cb (gethash "data" cb)))
         (from (and cb (gethash "from" cb)))
         (user-id (and from (gethash "id" from)))
         (msg (and cb (gethash "message" cb)))
         (chat (and msg (gethash "chat" msg)))
         (chat-id (and chat (gethash "id" chat))))
    (values callback-id data chat-id user-id)))

(defun process-update (chan update)
  "Process one Telegram update (message or callback query)."
  (multiple-value-bind (callback-id callback-data cb-chat-id cb-user-id)
      (%extract-callback-fields update)
    (when (and callback-id callback-data cb-chat-id)
      (if (allowed-user-p chan cb-user-id)
          (let ((session (find-or-create-session chan cb-chat-id)))
            (handle-models-callback chan callback-id cb-chat-id session callback-data))
          (telegram-answer-callback-query chan callback-id "Not allowed"))
      (return-from process-update nil)))
  (multiple-value-bind (text chat-id user-id user-name)
      (%extract-message-fields update)
    (when (and text chat-id)
      (cond
        ((not (allowed-user-p chan user-id))
         (format *error-output*
                 "~&[telegram] Rejected message from user ~A (not in allowlist).~%"
                 user-id))
        (t
         (format t "~&[telegram] ~A (chat ~A): ~A~%"
                 (or user-name "?") chat-id
                 (if (> (length text) 80)
                     (concatenate 'string (subseq text 0 80) "…")
                     text))
         (clawmacs/config:run-hook-with-args 'clawmacs/config:*channel-message-hook*
                                             chan text)
         (let ((session (find-or-create-session chan chat-id)))
           (when (dispatch-command chan chat-id session text)
             (return-from process-update nil))
           (telegram-send-chat-action chan chat-id "typing")
           (if *telegram-streaming*
               (%run-agent-streaming chan chat-id session text)
               (let* ((opts     (clawmacs/loop:make-loop-options
                                 :max-turns clawmacs/config:*default-max-turns*
                                 :stream    nil))
                      (response (handler-case
                                    (clawmacs/loop:run-agent session text :options opts)
                                  (error (e)
                                    (format *error-output*
                                            "~&[telegram] Agent error (chat ~A): ~A~%"
                                            chat-id e)
                                    (log-error :telegram "Agent error (chat ~A): ~A" chat-id e)
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
                                 uid e)
                         (log-error :telegram "Error processing update ~A: ~A" uid e)))))
                 (when updates
                   (sleep (telegram-channel-polling-interval chan))))
             ;; Network / HTTP errors — log and retry after a brief wait
             (error (e)
               (when (telegram-channel-running chan)   ; don't log during shutdown
                 (format *error-output*
                         "~&[telegram] Polling error: ~A — retrying in ~As~%"
                         e (telegram-channel-polling-interval chan))
                 (log-error :telegram "Polling error: ~A" e))
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
  (setf *bot-start-time* (get-universal-time))
  (load-persisted-telegram-model)
  (%enforce-codex-safe-profile)
  ;; Register slash commands with Telegram
  (%register-bot-commands chan)
  (setf (telegram-channel-thread chan)
        (bt:make-thread
         (lambda () (%polling-loop chan))
         :name "clawmacs-telegram-poll"))
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
  (clawmacs/telegram:start-all-channels)

Returns the list of successfully started channel objects."
  (let ((started '()))
    (dolist (entry clawmacs/config:*registered-channels*)
      (let ((type (car entry)))
        (case type
          (:telegram
           (if *telegram-channel*
               (progn
                 (start-telegram *telegram-channel*)
                 (push *telegram-channel* started))
               (format *error-output*
                       "~&[telegram] :telegram registered but *telegram-channel* is NIL~%")))
          (:irc
           (handler-case
               (progn
                 (clawmacs/irc:start-irc)
                 (format t "~&[start-all-channels] IRC channel started.~%")
                 (push :irc started))
             (error (e)
               (format *error-output*
                       "~&[start-all-channels] IRC start failed: ~A~%" e))))
          (otherwise
           (format t "~&[start-all-channels] no starter for channel ~A~%" type)))))
    (nreverse started)))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 11. register-channel Specialization
;;;; ─────────────────────────────────────────────────────────────────────────────

(defmethod clawmacs/config:register-channel
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
  (clawmacs/telegram:start-telegram)
  ;; or, to start all registered channels:
  (clawmacs/telegram:start-all-channels)"
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
