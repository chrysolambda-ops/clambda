;;;; src/irc.lisp — IRC client channel for Clawmacs (Layer 6c)
;;;;
;;;; Raw IRC protocol implementation. No external IRC library — raw sockets only.
;;;; Uses USOCKET for TCP, CL+SSL for TLS.
;;;;
;;;; Features:
;;;;   - Connect, NICK/USER registration, JOIN channels
;;;;   - PRIVMSG send/receive with flood protection (≤2/sec)
;;;;   - PING/PONG keepalive
;;;;   - NickServ IDENTIFY after RPL_WELCOME (001)
;;;;   - CTCP VERSION response
;;;;   - Message routing: channel mention or DM → agent loop → PRIVMSG reply
;;;;   - Background reader thread + flood-sender thread
;;;;   - Automatic reconnection with exponential backoff (max 5 min)
;;;;   - register-channel :irc specialisation
;;;;
;;;; Live testing setup:
;;;;   1. Register a bot nick on irc.libera.chat via the web:
;;;;      https://libera.chat/guides/registration
;;;;   2. Start Clawmacs IRC channel:
;;;;      (clawmacs/config:load-user-config) ; if using init.lisp
;;;;      ;; OR directly:
;;;;      (defparameter *conn*
;;;;        (clawmacs/irc:start-irc
;;;;          :server "irc.libera.chat" :port 6697 :tls t
;;;;          :nick "clawmacs-bot"
;;;;          :channels '("#test-channel")))
;;;;   3. In another IRC client: join #test-channel and say "clawmacs-bot: hello"
;;;;   4. Monitor *standard-output* for connection/routing status.
;;;;   5. To stop: (clawmacs/irc:stop-irc)
;;;;
;;;; IRC protocol reference: RFC 2812 (https://tools.ietf.org/html/rfc2812)
;;;; This is a simplified subset — no DCC, no CTCP beyond VERSION, no channel ops.

(in-package #:clawmacs/irc)

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 1. Globals
;;;; ─────────────────────────────────────────────────────────────────────────────

(defvar *irc-connection* nil
  "The active IRC connection (an IRC-CONNECTION struct), or NIL if not connected.
Set automatically by START-IRC and cleared by STOP-IRC.")

(defvar *irc-send-interval* 0.5
  "Seconds between outgoing IRC messages for flood protection.
Default 0.5 = max 2 messages/second. Decrease at your own risk — IRC servers
may kick/ban bots that flood.")

(defvar *irc-default-system-prompt*
  "You are a helpful IRC bot. Keep responses short and conversational (1-3 sentences max, ~400 chars). \
No markdown — IRC is plain text."
  "Default system prompt for the IRC bot agent.")

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 2. Connection Struct
;;;; ─────────────────────────────────────────────────────────────────────────────

(defstruct (irc-connection (:conc-name irc-))
  "Complete state for one IRC connection.

Slots:
  CONFIG (set at creation):
    server          — hostname string
    port            — integer port
    tls-p           — boolean: use TLS
    nick            — bot nick string (may be updated if server changes it)
    realname        — IRC real name string
    channels        — list of channel strings to auto-join
    nickserv-password — string or NIL
    allowed-users   — list of nick strings allowed to use the bot, or NIL (all allowed)
    trigger-prefix  — string prefix to trigger channel responses, or NIL (use nick:)

  RUNTIME (managed internally):
    socket          — usocket socket object, or NIL
    stream          — character I/O stream (plain or TLS), or NIL
    reader-thread   — bordeaux-threads thread: reads lines from server
    flood-thread    — bordeaux-threads thread: sends queued lines at rate limit
    flood-queue     — list of raw strings waiting to be sent
    flood-lock      — mutex protecting flood-queue
    flood-cvar      — condition variable for flood-thread wakeup
    running-p       — boolean: T while connection should be alive
    reconnect-delay — integer seconds to wait before reconnecting (doubles on failure)

  ROUTING:
    agent           — clawmacs/agent:agent instance, a name string/keyword, or NIL
    sessions        — hash-table: target-string → clawmacs/session:session
    sessions-lock   — mutex protecting sessions table"
  ;; Config
  (server           "irc.libera.chat" :type string)
  (port             6697 :type integer)
  (tls-p            t)
  (nick             "clawmacs" :type string)
  (realname         "Clawmacs IRC Bot" :type string)
  (channels         '() :type list)
  (nickserv-password nil)
  (allowed-users    nil)
  (trigger-prefix   nil)
  ;; Per-channel allowlist (Layer 9b)
  (channel-policies nil)            ; alist of (channel-name :allowed-users list)
  (dm-allowed-users nil)            ; list of nicks allowed to DM, or NIL (use global)
  ;; Runtime (nil = not connected)
  (socket           nil)
  (stream           nil)
  (reader-thread    nil)
  (flood-thread     nil)
  (flood-queue      '() :type list)
  (flood-lock       (bt:make-lock "irc-flood-lock"))
  (flood-cvar       (bt:make-condition-variable :name "irc-flood-cvar"))
  (running-p        nil)
  (reconnect-delay  5 :type integer)
  ;; Routing
  (agent            nil)
  (sessions         (make-hash-table :test 'equal))
  (sessions-lock    (bt:make-lock "irc-sessions-lock")))

;;; Public predicates and accessors

(defun irc-connected-p (&optional (conn *irc-connection*))
  "Return T if CONN has an active connection (stream is non-nil and running)."
  (and conn (irc-running-p conn) (irc-stream conn) t))

(defun irc-effective-trigger (conn)
  "Return the trigger prefix: configured value or '<nick>:'."
  (or (irc-trigger-prefix conn)
      (concatenate 'string (irc-nick conn) ":")))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 3. IRC Protocol: Parsing and Building
;;;; ─────────────────────────────────────────────────────────────────────────────

(defun parse-irc-line (line)
  "Parse a raw IRC protocol line into a plist.

  Returns: (:prefix PREFIX :command COMMAND :params PARAMS :trailing TRAILING)

  PREFIX   — sender prefix (string like 'nick!user@host' or 'server.name'), or NIL
  COMMAND  — command or 3-digit numeric (uppercased string)
  PARAMS   — list of non-trailing parameter strings
  TRAILING — trailing parameter (after ' :'), or NIL

  Examples:
    ':nick!u@h PRIVMSG #chan :Hello world'
    => (:prefix \"nick!u@h\" :command \"PRIVMSG\" :params (\"#chan\") :trailing \"Hello world\")

    'PING :irc.libera.chat'
    => (:prefix nil :command \"PING\" :params nil :trailing \"irc.libera.chat\")

    ':server 001 mynick :Welcome to libera.chat'
    => (:prefix \"server\" :command \"001\" :params (\"mynick\") :trailing \"Welcome...\")"
  (let ((pos 0)
        (len (length line))
        prefix command params trailing)
    ;; Optional prefix: starts with ':' followed by non-space chars, then space
    (when (and (< pos len) (char= (char line pos) #\:))
      (incf pos) ; skip ':'
      (let ((end (or (position #\Space line :start pos) len)))
        (setf prefix (subseq line pos end))
        (setf pos (min len (1+ end)))))  ; skip trailing space

    ;; Command (mandatory): uppercase letters or 3 digits
    (let ((end (or (position #\Space line :start pos) len)))
      (setf command (string-upcase (subseq line pos end)))
      (setf pos (min len (1+ end))))  ; skip trailing space

    ;; Parameters: space-separated, last one may be ':'-prefixed (trailing)
    (loop while (< pos len)
          do (cond
               ;; Trailing parameter: ':' prefix, rest of line
               ((char= (char line pos) #\:)
                (setf trailing (subseq line (1+ pos)))
                (setf pos len))             ; done
               ;; Normal parameter: up to next space
               (t
                (let ((end (or (position #\Space line :start pos) len)))
                  (push (subseq line pos end) params)
                  (setf pos (min len (1+ end)))))))

    (list :prefix  prefix
          :command command
          :params  (nreverse params)
          :trailing trailing)))

(defun prefix-nick (prefix)
  "Extract the nick from a prefix string 'nick!user@host'.
Returns NIL if PREFIX is NIL or doesn't contain '!' (i.e., it's a server name)."
  (when prefix
    (let ((bang (position #\! prefix)))
      (when bang (subseq prefix 0 bang)))))

(defun irc-build-line (command &optional params trailing)
  "Build a raw IRC protocol line string (without CRLF terminator).

  COMMAND  — IRC command string (e.g. \"PRIVMSG\", \"JOIN\", \"PONG\")
  PARAMS   — list of parameter strings not needing ':' quoting (no spaces)
  TRAILING — trailing parameter string (may contain spaces); formatted as ':TEXT'

  Examples:
    (irc-build-line \"PONG\" nil \"irc.libera.chat\")
    => \"PONG :irc.libera.chat\"

    (irc-build-line \"PRIVMSG\" '(\"#clawmacs\") \"Hello, world!\")
    => \"PRIVMSG #clawmacs :Hello, world!\"

    (irc-build-line \"JOIN\" '(\"#clawmacs\"))
    => \"JOIN #clawmacs\"

    (irc-build-line \"NICK\" '(\"mynick\"))
    => \"NICK mynick\""
  (with-output-to-string (s)
    (write-string command s)
    (dolist (p params)
      (write-char #\Space s)
      (write-string (princ-to-string p) s))
    (when trailing
      (write-char #\Space s)
      (write-char #\: s)
      (write-string (princ-to-string trailing) s))))

(defun %strip-cr (line)
  "Strip trailing carriage-return from LINE (IRC lines end with CRLF)."
  (if (and (> (length line) 0)
           (char= (char line (1- (length line))) #\Return))
      (subseq line 0 (1- (length line)))
      line))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 4. Raw Send & Flood Protection
;;;; ─────────────────────────────────────────────────────────────────────────────

(defun %write-raw-line (stream line)
  "Write LINE to STREAM with IRC CRLF line ending. Not flood-protected."
  (write-string line stream)
  (write-char #\Return stream)
  (write-char #\Newline stream)
  (force-output stream))

(defun %send-raw (conn line)
  "Send LINE immediately to the IRC stream, bypassing flood protection.
Use only during initial registration. For all other sends, use IRC-ENQUEUE-RAW."
  (let ((stream (irc-stream conn)))
    (when stream
      (handler-case (%write-raw-line stream line)
        (error (e)
          (format *error-output* "~&[irc] Direct send error: ~A~%" e))))))

(defun irc-enqueue-raw (conn line)
  "Enqueue LINE for flood-rate-limited sending via the flood-sender thread.
LINE should be a raw IRC command string without CRLF."
  (bt:with-lock-held ((irc-flood-lock conn))
    ;; Append to end of queue (FIFO order)
    (setf (irc-flood-queue conn)
          (nconc (irc-flood-queue conn) (list line)))
    (bt:condition-notify (irc-flood-cvar conn))))

(defun %flood-sender-loop (conn)
  "Background thread: dequeues and sends IRC lines at *IRC-SEND-INTERVAL* rate.
Runs until (irc-running-p conn) is NIL."
  (let ((lock (irc-flood-lock conn))
        (cvar (irc-flood-cvar conn)))
    (loop while (irc-running-p conn)
          do (let ((line nil))
               ;; Wait for something to send (or a stop signal)
               (bt:with-lock-held (lock)
                 (loop while (and (irc-running-p conn)
                                  (null (irc-flood-queue conn)))
                       do (bt:condition-wait cvar lock))
                 ;; Dequeue one line
                 (when (irc-flood-queue conn)
                   (setf line (first (irc-flood-queue conn)))
                   (setf (irc-flood-queue conn) (rest (irc-flood-queue conn)))))
               ;; Send it
               (when line
                 (let ((stream (irc-stream conn)))
                   (when stream
                     (handler-case (%write-raw-line stream line)
                       (error (e)
                         (format *error-output*
                                 "~&[irc] Flood-send error: ~A~%" e)))))
                 ;; Rate limit: sleep before next send
                 (sleep *irc-send-interval*))))))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 5. High-Level IRC Commands
;;;; ─────────────────────────────────────────────────────────────────────────────

(defun irc-send-privmsg (target message &optional (conn *irc-connection*))
  "Send a PRIVMSG to TARGET (channel or nick) with MESSAGE body.
Message is split into multiple PRIVMSGs if longer than ~400 characters.
Uses flood-rate-limited queue."
  (when (and conn (irc-stream conn))
    (dolist (chunk (%split-response message))
      (irc-enqueue-raw conn (irc-build-line "PRIVMSG" (list target) chunk)))))

(defun irc-join (channel &optional (conn *irc-connection*))
  "Join CHANNEL (e.g. \"#clawmacs\"). Queued via flood protection."
  (when conn
    (irc-enqueue-raw conn (irc-build-line "JOIN" (list channel)))))

(defun irc-part (channel &optional (reason "Leaving") (conn *irc-connection*))
  "Leave CHANNEL with optional REASON message."
  (when conn
    (irc-enqueue-raw conn (irc-build-line "PART" (list channel) reason))))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 6. Connection Management
;;;; ─────────────────────────────────────────────────────────────────────────────

(defun %register (conn)
  "Send NICK and USER registration commands immediately (bypassing flood queue).
Called immediately after TCP/TLS connection is established."
  (let ((nick     (irc-nick conn))
        (realname (irc-realname conn)))
    (%send-raw conn (irc-build-line "NICK" (list nick)))
    (%send-raw conn (irc-build-line "USER" (list nick "0" "*") realname))))

(defun %do-connect (conn)
  "Establish TCP (or TLS) connection to the IRC server and register.
Sets irc-socket and irc-stream slots. On failure, leaves them NIL."
  (let ((host  (irc-server conn))
        (port  (irc-port  conn))
        (tls-p (irc-tls-p conn)))
    (format t "~&[irc] Connecting to ~A:~A~:[~; (TLS)~]...~%" host port tls-p)
    (handler-case
        (let* (;; For TLS we need a binary stream; for plain, character is fine
               (element-type (if tls-p '(unsigned-byte 8) 'character))
               (socket (usocket:socket-connect host port :element-type element-type))
               (tcp-stream (usocket:socket-stream socket))
               (io-stream  (if tls-p
                               (cl+ssl:make-ssl-client-stream tcp-stream :hostname host)
                               tcp-stream)))
          (setf (irc-socket conn) socket
                (irc-stream conn) io-stream)
          ;; Send NICK/USER immediately (before flood thread loop can run)
          (%register conn)
          (format t "~&[irc] Registration sent. Waiting for server welcome...~%"))
      (error (e)
        (format *error-output* "~&[irc] Connection to ~A:~A failed: ~A~%" host port e)
        ;; Clean up any partial state
        (when (irc-socket conn)
          (handler-case (usocket:socket-close (irc-socket conn)) (error () nil)))
        (setf (irc-socket conn) nil
              (irc-stream conn) nil)))))

(defun %do-disconnect (conn)
  "Close the IRC stream and socket cleanly. Sends QUIT if stream is open."
  (let ((stream (irc-stream conn)))
    (when stream
      ;; Try to send a polite QUIT
      (handler-case
          (progn
            (%write-raw-line stream (irc-build-line "QUIT" nil "Clawmacs signing off"))
            (close stream))
        (error () nil))
      (setf (irc-stream conn) nil)))
  (let ((socket (irc-socket conn)))
    (when socket
      (handler-case (usocket:socket-close socket) (error () nil))
      (setf (irc-socket conn) nil))))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 7. Agent Resolution and Session Routing
;;;; ─────────────────────────────────────────────────────────────────────────────

(defun %make-fallback-agent ()
  "Create a minimal fallback agent using *DEFAULT-MODEL* and the builtin registry."
  (let ((client (cl-llm:make-client
                  :base-url "http://localhost:1234/v1"
                  :api-key  "lm-studio"
                  :model    clawmacs/config:*default-model*)))
    (clawmacs/agent:make-agent
      :name          "irc-bot"
      :client        client
      :tool-registry (clawmacs/builtins:make-builtin-registry)
      :system-prompt *irc-default-system-prompt*)))

(defun %resolve-agent (conn)
  "Resolve the agent for CONN to a CLAMBDA/AGENT:AGENT instance.

  - If (irc-agent conn) is already an agent instance, use it.
  - If it's a string or keyword, look up in *AGENT-REGISTRY*.
  - If NIL, look up 'default' in registry.
  - If nothing found, create a fallback agent with *DEFAULT-MODEL*."
  (let ((a (irc-agent conn)))
    (cond
      ;; Already a live agent
      ((typep a 'clawmacs/agent:agent) a)

      ;; Named agent — look up in registry
      ((or (stringp a) (keywordp a))
       (let* ((name  (if (keywordp a) (string-downcase (symbol-name a)) a))
              (entry (clawmacs/registry:find-agent name)))
         (if entry
             (etypecase entry
               (clawmacs/agent:agent entry)
               (clawmacs/registry:agent-spec (clawmacs/registry:instantiate-agent-spec entry)))
             (%make-fallback-agent))))

      ;; NIL — try "default" in registry, then fallback
      (t
       (let ((entry (clawmacs/registry:find-agent "default")))
         (if entry
             (etypecase entry
               (clawmacs/agent:agent entry)
               (clawmacs/registry:agent-spec (clawmacs/registry:instantiate-agent-spec entry)))
             (%make-fallback-agent)))))))

(defun %find-or-create-session (conn target)
  "Find or create a conversation session for TARGET (channel or nick string).
Sessions are per-target — one conversation thread per channel/DM."
  (bt:with-lock-held ((irc-sessions-lock conn))
    (or (gethash target (irc-sessions conn))
        (let* ((agent (%resolve-agent conn))
               (sess  (clawmacs/session:make-session :agent agent)))
          (setf (gethash target (irc-sessions conn)) sess)
          sess))))

(defun %split-response (text &optional (max-len 400))
  "Split TEXT into chunks of at most MAX-LEN chars for IRC PRIVMSG.
Tries to break at word boundaries (spaces). IRC lines are limited to ~512 chars
total; 400 chars for message text is conservative and safe."
  (if (<= (length text) max-len)
      (list text)
      (let ((result '())
            (start  0)
            (len    (length text)))
        (loop while (< start len)
              do (let ((end (min (+ start max-len) len)))
                   ;; Try to break at a space for readability
                   (when (< end len)
                     (let ((space (position #\Space text
                                            :start start :end end :from-end t)))
                       (when space (setf end (1+ space)))))
                   (let ((chunk (string-trim " " (subseq text start end))))
                     (when (> (length chunk) 0)
                       (push chunk result)))
                   (setf start end)))
        (nreverse result))))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 8. Line Dispatch
;;;; ─────────────────────────────────────────────────────────────────────────────

(defun %handle-ping (conn server-name)
  "Respond to PING with PONG (flood-queued)."
  (irc-enqueue-raw conn (irc-build-line "PONG" nil server-name)))

(defun %handle-001 (conn)
  "Handle RPL_WELCOME (001): identify with NickServ and join configured channels."
  (format t "~&[irc] Welcome received. Logged in as ~A.~%" (irc-nick conn))
  ;; Reset reconnect delay on successful welcome
  (setf (irc-reconnect-delay conn) 5)
  ;; NickServ IDENTIFY
  (when (irc-nickserv-password conn)
    (irc-enqueue-raw conn
      (irc-build-line "PRIVMSG" '("NickServ")
                      (format nil "IDENTIFY ~A" (irc-nickserv-password conn))))
    (format t "~&[irc] Sent NickServ IDENTIFY.~%"))
  ;; Join configured channels
  (dolist (channel (irc-channels conn))
    (irc-enqueue-raw conn (irc-build-line "JOIN" (list channel)))
    (format t "~&[irc] Joining ~A...~%" channel)))

(defun %handle-ctcp-version (conn sender-nick)
  "Respond to CTCP VERSION request."
  (let ((ctrl-a (string (code-char 1))))
    (irc-enqueue-raw conn
      (irc-build-line "NOTICE" (list sender-nick)
                      (format nil "~AVERSION Clawmacs IRC Bot 0.1 (Common Lisp / SBCL)~A"
                              ctrl-a ctrl-a)))))

(defun %extract-message-body (conn is-channel text sender-nick)
  "Return the message body to pass to the agent, or NIL if not triggered.

For channel messages: triggered when text starts with the trigger prefix
  (default: '<botnicck>:') OR mentions the bot nick anywhere in the text.
For DMs: always return text (stripped of leading whitespace)."
  (declare (ignore sender-nick))
  (if (not is-channel)
      ;; DMs always trigger
      (string-left-trim " " text)
      ;; Channel messages need a trigger
      (let ((trigger (irc-effective-trigger conn)))
        (cond
          ;; Starts with "<botnick>:" or configured trigger prefix
          ((and (>= (length text) (length trigger))
                (string-equal text trigger :end1 (length trigger)))
           (string-left-trim " " (subseq text (length trigger))))
          ;; Text mentions the bot nick anywhere (case-insensitive)
          ((search (irc-nick conn) text :test #'char-equal)
           (string-left-trim " " text))
          ;; Not triggered
          (t nil)))))

(defun %route-message (conn reply-target message sender-nick)
  "Run the agent loop on MESSAGE and reply to REPLY-TARGET via PRIVMSG.
Called in a background thread per incoming message.
SENDER-NICK is included for context but responses go to REPLY-TARGET."
  (declare (ignore sender-nick))
  (handler-case
      (let* ((session  (%find-or-create-session conn reply-target))
             (response (clawmacs/loop:run-agent
                         session message
                         :options (clawmacs/loop:make-loop-options
                                    :max-turns 5
                                    :stream nil))))
        (when (and response (> (length response) 0))
          (irc-send-privmsg reply-target response conn)))
    (error (e)
      (format *error-output*
              "~&[irc] Agent error for ~A: ~A~%" reply-target e)
      ;; Send a user-facing error notice
      (handler-case
          (irc-send-privmsg reply-target
                            (format nil "Error: ~A" e)
                            conn)
        (error () nil)))))

(defun %effective-channel-allowed (conn channel-name)
  "Return the effective allowed-users list for CHANNEL-NAME in CONN.

If CHANNEL-NAME has an explicit policy in (irc-channel-policies conn):
  - Returns its :allowed-users value (NIL means all users allowed in that channel).
If no policy exists for this channel:
  - Falls back to (irc-allowed-users conn) (global allowlist)."
  (let ((entry (assoc channel-name (irc-channel-policies conn)
                      :test #'string-equal)))
    (if entry
        (getf (cdr entry) :allowed-users)
        (irc-allowed-users conn))))

(defun %effective-dm-allowed (conn)
  "Return the effective allowed-users list for DMs to CONN.

If (irc-dm-allowed-users conn) is non-NIL, returns it.
Otherwise falls back to (irc-allowed-users conn)."
  (or (irc-dm-allowed-users conn)
      (irc-allowed-users conn)))

(defun %handle-privmsg (conn prefix target text)
  "Dispatch an incoming PRIVMSG line.

  - Checks allowed-users (if configured)
  - Handles CTCP VERSION
  - Determines trigger (nick mention or direct trigger prefix for channels; any for DMs)
  - Spawns a background thread to run the agent"
  (let* ((sender-nick (prefix-nick prefix))
         ;; Channels start with '#' or '&'
         (is-channel  (and (> (length target) 0)
                           (member (char target 0) '(#\# #\&))))
         ;; Reply to channel (for channel msgs) or sender (for DMs)
         (reply-target (if is-channel target sender-nick)))

    ;; Sanity checks
    (unless (and text sender-nick reply-target) (return-from %handle-privmsg nil))

    ;; Check per-target allowlist (channel policy overrides global; DM uses dm-allowed-users)
    (let ((effective-allowed (if is-channel
                                 (%effective-channel-allowed conn target)
                                 (%effective-dm-allowed conn))))
      (when (and effective-allowed
                 (not (member sender-nick effective-allowed :test #'string-equal)))
        (return-from %handle-privmsg nil)))

    ;; Handle CTCP (text wrapped in ctrl-A)
    (let ((ctrl-a (code-char 1)))
      (when (and (> (length text) 0) (char= (char text 0) ctrl-a))
        (when (search "VERSION" text)
          (%handle-ctcp-version conn sender-nick))
        (return-from %handle-privmsg nil)))

    ;; Extract message body (applies trigger check for channels)
    (let ((body (%extract-message-body conn is-channel text sender-nick)))
      (when body
        ;; Dispatch to agent in a background thread
        (bt:make-thread
          (lambda () (%route-message conn reply-target body sender-nick))
          :name (format nil "irc-agent-~A" reply-target))))))

(defun %dispatch-line (conn line)
  "Parse and dispatch a single IRC line to the appropriate handler."
  (let* ((msg      (parse-irc-line line))
         (command  (getf msg :command))
         (prefix   (getf msg :prefix))
         (params   (getf msg :params))
         (trailing (getf msg :trailing)))
    (cond
      ;; Keepalive
      ((string= command "PING")
       (%handle-ping conn (or trailing (first params) "")))

      ;; Welcome — join channels and NickServ identify
      ((string= command "001")
       (%handle-001 conn))

      ;; Incoming message
      ((string= command "PRIVMSG")
       (when (and prefix params)
         (%handle-privmsg conn prefix (first params) trailing)))

      ;; Server nick change for us (433 nick-in-use, 436 nick collision)
      ((member command '("433" "436") :test #'string=)
       ;; Append underscore and try again
       (let ((new-nick (concatenate 'string (irc-nick conn) "_")))
         (format t "~&[irc] Nick ~A in use, trying ~A~%" (irc-nick conn) new-nick)
         (setf (irc-nick conn) new-nick)
         (%send-raw conn (irc-build-line "NICK" (list new-nick)))))

      ;; Server error
      ((string= command "ERROR")
       (format *error-output* "~&[irc] Server ERROR: ~A~%"
               (or trailing (format nil "~{~A~^ ~}" params))))

      ;; Ignore NOTICE, MODE, JOIN, PART, etc.
      (t nil))))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 9. Reader Thread
;;;; ─────────────────────────────────────────────────────────────────────────────

(defun %read-loop (conn)
  "Read and dispatch IRC lines from CONN's stream until EOF or error.
Returns normally when the connection drops or (irc-running-p conn) is NIL."
  (handler-case
      (loop
        (unless (irc-running-p conn) (return))
        (let ((raw (read-line (irc-stream conn) nil nil)))
          (unless raw (return))  ; EOF — server closed connection
          (let ((line (%strip-cr raw)))
            (when (> (length line) 0)
              (%dispatch-line conn line)))))
    (error (e)
      (when (irc-running-p conn)
        (format *error-output* "~&[irc] Read error: ~A~%" e)))))

(defun %reader-loop (conn)
  "Top-level reader thread function: connects, reads, reconnects on failure.
Implements exponential backoff reconnection (max 300 seconds)."
  (loop while (irc-running-p conn)
        do (progn
             ;; Attempt connection
             (%do-connect conn)
             ;; Read until disconnect (or stop)
             (when (irc-stream conn)
               (%read-loop conn)
               ;; Connection dropped — clean up stream state
               (%do-disconnect conn))
             ;; Reconnect if still running
             (when (irc-running-p conn)
               (let ((delay (irc-reconnect-delay conn)))
                 (format t "~&[irc] Disconnected from ~A. Reconnecting in ~As...~%"
                         (irc-server conn) delay)
                 (sleep delay)
                 ;; Exponential backoff: double delay, cap at 5 minutes
                 (setf (irc-reconnect-delay conn)
                       (min 300 (* delay 2))))))))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 10. Lifecycle: start-irc / stop-irc
;;;; ─────────────────────────────────────────────────────────────────────────────

(defun start-irc (&key server (port 6697) (tls t)
                       nick (realname "Clawmacs IRC Bot")
                       channels nickserv-password
                       allowed-users trigger-prefix
                       agent channel-policies dm-allowed-users
                  &aux (conn *irc-connection*))
  "Connect to an IRC server and start background threads.

  If *IRC-CONNECTION* is already set (e.g. via REGISTER-CHANNEL :IRC), uses and
  updates that connection. Otherwise creates a new IRC-CONNECTION.

  Keyword parameters:
    :server            — hostname (default: \"irc.libera.chat\")
    :port              — port (default: 6697)
    :tls               — use TLS (default: T)
    :nick              — bot nick (default: \"clawmacs\")
    :realname          — IRC real name (default: \"Clawmacs IRC Bot\")
    :channels          — list of channel strings to auto-join (e.g. '(\"#clawmacs\"))
    :nickserv-password — optional NickServ password string
    :allowed-users     — optional list of nicks that may use the bot (nil = all)
    :trigger-prefix    — optional trigger prefix (nil = use '<nick>:')
    :agent             — agent instance, name string/keyword, or nil (uses default)
    :channel-policies  — alist of (channel :allowed-users list) per-channel overrides
    :dm-allowed-users  — list of nicks allowed to DM the bot (nil = use allowed-users)

  Returns the IRC-CONNECTION struct. Also sets *IRC-CONNECTION*.

  Usage:
    ;; Basic:
    (start-irc :server \"irc.libera.chat\" :nick \"mybot\" :channels '(\"#test\"))

    ;; With NickServ:
    (start-irc :server \"irc.libera.chat\" :nick \"mybot\"
               :nickserv-password \"s3cr3t\"
               :channels '(\"#mybot\"))

    ;; Stop later:
    (stop-irc)"
  ;; Use existing connection or create new one
  (unless conn
    (setf conn (make-irc-connection)))
  ;; Apply keyword parameters
  (when server            (setf (irc-server conn)            server))
  (when port              (setf (irc-port conn)              port))
  (when nick              (setf (irc-nick conn)              nick))
  (when realname          (setf (irc-realname conn)          realname))
  (when channels          (setf (irc-channels conn)          channels))
  (when nickserv-password (setf (irc-nickserv-password conn) nickserv-password))
  (when allowed-users     (setf (irc-allowed-users conn)     allowed-users))
  (when trigger-prefix    (setf (irc-trigger-prefix conn)    trigger-prefix))
  (when agent             (setf (irc-agent conn)             agent))
  (when channel-policies  (setf (irc-channel-policies conn)  channel-policies))
  (when dm-allowed-users  (setf (irc-dm-allowed-users conn)  dm-allowed-users))
  ;; Apply tls-p (always override, even if nil)
  (setf (irc-tls-p conn) tls)
  ;; Set as global
  (setf *irc-connection* conn)
  ;; Already running? Stop first.
  (when (irc-running-p conn)
    (format t "~&[irc] Already running — stopping first.~%")
    (stop-irc conn))
  ;; Mark as running
  (setf (irc-running-p conn) t)
  (setf (irc-reconnect-delay conn) 5)
  ;; Start flood sender thread
  (setf (irc-flood-thread conn)
        (bt:make-thread
          (lambda () (%flood-sender-loop conn))
          :name "irc-flood-sender"))
  ;; Start reader/reconnect thread
  (setf (irc-reader-thread conn)
        (bt:make-thread
          (lambda () (%reader-loop conn))
          :name "irc-reader"))
  (format t "~&[irc] Started. Connecting to ~A:~A...~%" (irc-server conn) (irc-port conn))
  conn)

(defun stop-irc (&optional (conn *irc-connection*))
  "Disconnect from IRC and stop all background threads.

  Sends QUIT to the server (if connected), closes the socket, and terminates
  the reader and flood-sender threads.

  Returns T if CONN was running, NIL if already stopped."
  (unless (and conn (irc-running-p conn))
    (return-from stop-irc nil))

  (format t "~&[irc] Stopping...~%")
  ;; Signal threads to stop
  (setf (irc-running-p conn) nil)
  ;; Wake up flood thread so it can exit
  (bt:with-lock-held ((irc-flood-lock conn))
    (bt:condition-notify (irc-flood-cvar conn)))
  ;; Close stream/socket (also causes read-line to return NIL on reader thread)
  (%do-disconnect conn)
  ;; Brief pause to let threads notice
  (sleep 0.5)
  ;; Clear global if it's this connection
  (when (eq conn *irc-connection*)
    (setf *irc-connection* nil))
  (format t "~&[irc] Stopped.~%")
  t)

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 11. register-channel :irc
;;;; ─────────────────────────────────────────────────────────────────────────────

(defmethod clawmacs/config:register-channel
    ((type (eql :irc))
     &rest args
     &key (server "irc.libera.chat") (port 6697) (tls t)
          (nick "clawmacs") (realname "Clawmacs IRC Bot")
          channels nickserv-password allowed-users trigger-prefix
          agent channel-policies dm-allowed-users
     &allow-other-keys)
  "Register an IRC channel from init.lisp. Creates and stores an IRC-CONNECTION.
Does NOT auto-connect — call (START-IRC) to connect.

Example in init.lisp:
  (register-channel :irc
    :server \"irc.libera.chat\"
    :port 6697
    :tls t
    :nick \"clawmacs\"
    :channels '(\"#clawmacs\" \"#lisp\")
    :nickserv-password \"s3cr3t\"
    :allowed-users '(\"alice\" \"bob\")
    :channel-policies '((\"#bots\" :allowed-users nil)
                        (\"#priv\" :allowed-users (\"alice\")))
    :dm-allowed-users '(\"alice\"))

  ;; Then connect:
  (add-hook '*after-init-hook* #'clawmacs/irc:start-irc)"
  (declare (ignore args))
  (let ((conn (make-irc-connection
                :server            server
                :port              port
                :tls-p             tls
                :nick              nick
                :realname          realname
                :channels          (or channels '())
                :nickserv-password nickserv-password
                :allowed-users     allowed-users
                :trigger-prefix    trigger-prefix
                :agent             agent
                :channel-policies  channel-policies
                :dm-allowed-users  dm-allowed-users)))
    (setf *irc-connection* conn)
    (format t "~&[irc] Channel configured: ~A:~A~:[~; (TLS)~] nick=~A channels=~A~%"
            server port tls nick (or channels '())))
  ;; Store config in *registered-channels* via default method
  (call-next-method))
