;;;; t/test-irc.lisp — Unit tests for clawmacs/irc (Layer 6c)
;;;;
;;;; Tests cover:
;;;;   1. IRC line parser (parse-irc-line)
;;;;   2. IRC line builder (irc-build-line)
;;;;   3. prefix-nick extraction
;;;;   4. Flood limiter queue mechanics (no socket required)
;;;;   5. Message body extraction / trigger detection
;;;;   6. Response splitting
;;;;
;;;; Tests do NOT require a live IRC server or network.
;;;; They test all pure/functional components in isolation.

(in-package #:clawmacs-core/tests/irc)

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 1. parse-irc-line tests
;;;; ─────────────────────────────────────────────────────────────────────────────

(define-test "parse-irc-line: PING with trailing"
  (let ((r (parse-irc-line "PING :irc.libera.chat")))
    (is string= "PING"           (getf r :command))
    (is eq      nil              (getf r :prefix))
    (is equal   '()             (getf r :params))
    (is string= "irc.libera.chat" (getf r :trailing))))

(define-test "parse-irc-line: PRIVMSG to channel"
  (let ((r (parse-irc-line ":alice!alice@libera PRIVMSG #test :Hello world")))
    (is string= "PRIVMSG"        (getf r :command))
    (is string= "alice!alice@libera" (getf r :prefix))
    (is equal   '("#test")      (getf r :params))
    (is string= "Hello world"   (getf r :trailing))))

(define-test "parse-irc-line: PRIVMSG direct message"
  (let ((r (parse-irc-line ":bob!b@host PRIVMSG clawmacs :Can you help me?")))
    (is string= "PRIVMSG"       (getf r :command))
    (is string= "bob!b@host"   (getf r :prefix))
    (is equal   '("clawmacs")   (getf r :params))
    (is string= "Can you help me?" (getf r :trailing))))

(define-test "parse-irc-line: 001 RPL_WELCOME"
  (let ((r (parse-irc-line ":irc.libera.chat 001 clawmacs :Welcome to Libera")))
    (is string= "001"            (getf r :command))
    (is string= "irc.libera.chat" (getf r :prefix))
    (is equal   '("clawmacs")    (getf r :params))
    (is string= "Welcome to Libera" (getf r :trailing))))

(define-test "parse-irc-line: NICK change"
  (let ((r (parse-irc-line ":oldnick!u@h NICK :newnick")))
    (is string= "NICK"          (getf r :command))
    (is string= "oldnick!u@h"  (getf r :prefix))
    (is equal   '()            (getf r :params))
    (is string= "newnick"      (getf r :trailing))))

(define-test "parse-irc-line: JOIN (no trailing)"
  (let ((r (parse-irc-line ":user!u@h JOIN #channel")))
    (is string= "JOIN"          (getf r :command))
    (is equal   '("#channel")  (getf r :params))
    (is eq      nil             (getf r :trailing))))

(define-test "parse-irc-line: ERROR message"
  (let ((r (parse-irc-line "ERROR :Closing Link: you (Quit: Bye)")))
    (is string= "ERROR"         (getf r :command))
    (is eq      nil             (getf r :prefix))
    (is equal   '()            (getf r :params))
    (is string= "Closing Link: you (Quit: Bye)" (getf r :trailing))))

(define-test "parse-irc-line: 433 nick-in-use"
  (let ((r (parse-irc-line ":server 433 * clawmacs :Nickname is already in use")))
    (is string= "433"           (getf r :command))
    (is equal   '("*" "clawmacs") (getf r :params))
    (is string= "Nickname is already in use" (getf r :trailing))))

(define-test "parse-irc-line: command is uppercased"
  (let ((r (parse-irc-line ":s privmsg #chan :msg")))
    (is string= "PRIVMSG" (getf r :command))))

(define-test "parse-irc-line: empty trailing after colon"
  (let ((r (parse-irc-line "PING :")))
    (is string= ""  (getf r :trailing))))

(define-test "parse-irc-line: multiple params before trailing"
  (let ((r (parse-irc-line ":s 353 clawmacs = #chan :alice bob")))
    (is string= "353" (getf r :command))
    (is equal '("clawmacs" "=" "#chan") (getf r :params))
    (is string= "alice bob" (getf r :trailing))))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 2. irc-build-line tests
;;;; ─────────────────────────────────────────────────────────────────────────────

(define-test "irc-build-line: PONG"
  (is string= "PONG :irc.libera.chat"
      (irc-build-line "PONG" nil "irc.libera.chat")))

(define-test "irc-build-line: PRIVMSG to channel"
  (is string= "PRIVMSG #test :Hello, world!"
      (irc-build-line "PRIVMSG" '("#test") "Hello, world!")))

(define-test "irc-build-line: JOIN (no trailing)"
  (is string= "JOIN #clawmacs"
      (irc-build-line "JOIN" '("#clawmacs"))))

(define-test "irc-build-line: NICK (single param)"
  (is string= "NICK mynick"
      (irc-build-line "NICK" '("mynick"))))

(define-test "irc-build-line: USER (multiple params + trailing realname)"
  (is string= "USER bot 0 * :Clawmacs Bot"
      (irc-build-line "USER" '("bot" "0" "*") "Clawmacs Bot")))

(define-test "irc-build-line: command only"
  (is string= "QUIT"
      (irc-build-line "QUIT")))

(define-test "irc-build-line: QUIT with trailing reason"
  (is string= "QUIT :Signing off"
      (irc-build-line "QUIT" nil "Signing off")))

(define-test "irc-build-line: PRIVMSG NickServ IDENTIFY"
  (is string= "PRIVMSG NickServ :IDENTIFY s3cr3t"
      (irc-build-line "PRIVMSG" '("NickServ") "IDENTIFY s3cr3t")))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 3. prefix-nick tests
;;;; ─────────────────────────────────────────────────────────────────────────────

(define-test "prefix-nick: normal nick!user@host"
  (is string= "alice" (prefix-nick "alice!alice@libera.chat")))

(define-test "prefix-nick: nick with special chars"
  (is string= "my-bot_" (prefix-nick "my-bot_!bot@1.2.3.4")))

(define-test "prefix-nick: server name (no bang) returns nil"
  (is eq nil (prefix-nick "irc.libera.chat")))

(define-test "prefix-nick: nil prefix returns nil"
  (is eq nil (prefix-nick nil)))

(define-test "prefix-nick: empty string returns nil"
  (is eq nil (prefix-nick "")))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 4. Flood limiter queue tests (no socket required)
;;;; ─────────────────────────────────────────────────────────────────────────────

(define-test "flood queue: enqueue-raw adds to queue"
  ;; Test the internal irc-enqueue-raw function via :: access
  (let ((conn (make-irc-connection :server "localhost" :port 6667)))
    ;; Enqueue three lines
    (clawmacs/irc::irc-enqueue-raw conn "NICK testbot")
    (clawmacs/irc::irc-enqueue-raw conn "USER testbot 0 * :Test")
    (clawmacs/irc::irc-enqueue-raw conn "JOIN #test")
    ;; Check queue contents (FIFO order)
    (is = 3 (length (irc-flood-queue conn)))
    (is string= "NICK testbot" (first (irc-flood-queue conn)))
    (is string= "JOIN #test"   (third (irc-flood-queue conn)))))

(define-test "flood queue: dequeue maintains FIFO order"
  (let ((conn (make-irc-connection :server "localhost" :port 6667)))
    (clawmacs/irc::irc-enqueue-raw conn "FIRST")
    (clawmacs/irc::irc-enqueue-raw conn "SECOND")
    (clawmacs/irc::irc-enqueue-raw conn "THIRD")
    ;; Manually dequeue (simulating what flood-sender-loop does)
    (let ((q (irc-flood-queue conn)))
      (is string= "FIRST"  (first q))
      (is string= "SECOND" (second q))
      (is string= "THIRD"  (third q)))))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 5. Trigger / message body extraction tests
;;;; ─────────────────────────────────────────────────────────────────────────────

;; We test the internal %extract-message-body function via :: access.

(define-test "trigger: DM always triggers (returns text)"
  (let ((conn (make-irc-connection :nick "clawmacs")))
    (let ((result (clawmacs/irc::%extract-message-body
                    conn nil "help me please" "alice")))
      (is string= "help me please" result))))

(define-test "trigger: channel message with nick: prefix triggers"
  (let ((conn (make-irc-connection :nick "clawmacs")))
    (let ((result (clawmacs/irc::%extract-message-body
                    conn t "clawmacs: what time is it?" "alice")))
      (is string= "what time is it?" result))))

(define-test "trigger: channel message with nick mention triggers"
  (let ((conn (make-irc-connection :nick "clawmacs")))
    (let ((result (clawmacs/irc::%extract-message-body
                    conn t "hey clawmacs can you help?" "alice")))
      (is string= "hey clawmacs can you help?" result))))

(define-test "trigger: channel message without nick does not trigger"
  (let ((conn (make-irc-connection :nick "clawmacs")))
    (let ((result (clawmacs/irc::%extract-message-body
                    conn t "just chatting about stuff" "alice")))
      (is eq nil result))))

(define-test "trigger: custom trigger prefix works"
  (let ((conn (make-irc-connection :nick "clawmacs" :trigger-prefix "!")))
    (let ((result (clawmacs/irc::%extract-message-body
                    conn t "!hello there" "alice")))
      (is string= "hello there" result))))

(define-test "trigger: custom prefix, no match → nil"
  (let ((conn (make-irc-connection :nick "clawmacs" :trigger-prefix "!")))
    (let ((result (clawmacs/irc::%extract-message-body
                    conn t "regular message" "alice")))
      (is eq nil result))))

(define-test "trigger: nick: is case-insensitive"
  (let ((conn (make-irc-connection :nick "ClAmBdA")))
    (let ((result (clawmacs/irc::%extract-message-body
                    conn t "clawmacs: hello" "alice")))
      ;; "clawmacs:" is case-equal to "ClAmBdA:"? The effective trigger is "ClAmBdA:"
      ;; Our check uses STRING-EQUAL so yes, it is case-insensitive.
      (is string= "hello" result))))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 6. Response splitting tests
;;;; ─────────────────────────────────────────────────────────────────────────────

(define-test "split-response: short text returned as single chunk"
  (let ((chunks (clawmacs/irc::%split-response "Hello!" 400)))
    (is = 1 (length chunks))
    (is string= "Hello!" (first chunks))))

(define-test "split-response: long text split into multiple chunks"
  (let* ((long-text (make-string 900 :initial-element #\a))
         (chunks (clawmacs/irc::%split-response long-text 400)))
    (is = 3 (length chunks))
    ;; All chunks ≤ 400 chars
    (dolist (c chunks)
      (true (<= (length c) 400)))))

(define-test "split-response: splits at word boundary"
  (let* (;; Make text that's 410 chars, with a space at position 399
         (text (concatenate 'string
                             (make-string 399 :initial-element #\x)
                             " "
                             (make-string 10 :initial-element #\y)))
         (chunks (clawmacs/irc::%split-response text 400)))
    (is = 2 (length chunks))
    ;; First chunk should end with "x...x" (399 chars → trimmed)
    (true (every (lambda (c) (char= c #\x)) (first chunks)))))

(define-test "split-response: respects max-len parameter"
  (let ((chunks (clawmacs/irc::%split-response "abcde" 3)))
    (is = 2 (length chunks))))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 7. Struct construction tests
;;;; ─────────────────────────────────────────────────────────────────────────────

(define-test "make-irc-connection: defaults are correct"
  (let ((conn (make-irc-connection)))
    (is string= "irc.libera.chat" (irc-server conn))
    (is = 6697 (irc-port conn))
    (is eq t (irc-tls-p conn))
    (is string= "clawmacs" (irc-nick conn))
    (is eq nil (irc-running-p conn))
    (is equal '() (irc-channels conn))
    (is eq nil (irc-allowed-users conn))))

(define-test "make-irc-connection: custom values"
  (let ((conn (make-irc-connection
                :server "irc.example.com"
                :port 6667
                :tls-p nil
                :nick "mybot"
                :channels '("#test" "#general")
                :allowed-users '("alice" "bob"))))
    (is string= "irc.example.com" (irc-server conn))
    (is = 6667 (irc-port conn))
    (is eq nil (irc-tls-p conn))
    (is string= "mybot" (irc-nick conn))
    (is equal '("#test" "#general") (irc-channels conn))
    (is equal '("alice" "bob") (irc-allowed-users conn))))

(define-test "irc-connected-p: returns nil for disconnected conn"
  (let ((conn (make-irc-connection)))
    (false (irc-connected-p conn))))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 8. Allowed-users filtering test
;;;; ─────────────────────────────────────────────────────────────────────────────

(define-test "allowed-users: nil means allow all (message body returned)"
  ;; When allowed-users is nil, all users are allowed
  ;; We test this via %extract-message-body for a DM
  (let ((conn (make-irc-connection :nick "clawmacs" :allowed-users nil)))
    (let ((result (clawmacs/irc::%extract-message-body
                    conn nil "hello" "anyone")))
      (is string= "hello" result))))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 9. Round-trip: parse then build
;;;; ─────────────────────────────────────────────────────────────────────────────

(define-test "round-trip: parse PRIVMSG then rebuild"
  (let* ((original "PRIVMSG #chan :Hello, world!")
         (parsed   (parse-irc-line original))
         (rebuilt  (irc-build-line
                     (getf parsed :command)
                     (getf parsed :params)
                     (getf parsed :trailing))))
    (is string= original rebuilt)))

(define-test "round-trip: parse PONG then rebuild"
  (let* ((original "PONG :irc.libera.chat")
         (parsed   (parse-irc-line original))
         (rebuilt  (irc-build-line
                     (getf parsed :command)
                     (getf parsed :params)
                     (getf parsed :trailing))))
    (is string= original rebuilt)))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 10. Per-channel allowlist tests
;;;; ─────────────────────────────────────────────────────────────────────────────

(define-test "irc-channel-policies: default is nil"
  (let ((conn (make-irc-connection)))
    (is eq nil (irc-channel-policies conn))))

(define-test "irc-dm-allowed-users: default is nil"
  (let ((conn (make-irc-connection)))
    (is eq nil (irc-dm-allowed-users conn))))

(define-test "%effective-channel-allowed: no policy falls back to global"
  (let ((conn (make-irc-connection :allowed-users '("alice" "bob"))))
    ;; No channel-policies set → falls back to global allowed-users
    (let ((result (clawmacs/irc::%effective-channel-allowed conn "#test")))
      (is equal '("alice" "bob") result))))

(define-test "%effective-channel-allowed: channel policy overrides global"
  (let ((conn (make-irc-connection
                :allowed-users '("global-user")
                :channel-policies '(("#bots" :allowed-users nil)
                                    ("#priv" :allowed-users ("alice" "bob"))))))
    ;; #bots has explicit nil → all users allowed in #bots
    (let ((bots-allowed (clawmacs/irc::%effective-channel-allowed conn "#bots")))
      (is eq nil bots-allowed))   ; nil = open
    ;; #priv has explicit list
    (let ((priv-allowed (clawmacs/irc::%effective-channel-allowed conn "#priv")))
      (is equal '("alice" "bob") priv-allowed))
    ;; #other has no policy → falls back to global
    (let ((other-allowed (clawmacs/irc::%effective-channel-allowed conn "#other")))
      (is equal '("global-user") other-allowed))))

(define-test "%effective-dm-allowed: nil dm-allowed-users falls back to global"
  (let ((conn (make-irc-connection :allowed-users '("alice"))))
    (let ((result (clawmacs/irc::%effective-dm-allowed conn)))
      (is equal '("alice") result))))

(define-test "%effective-dm-allowed: dm-allowed-users overrides global"
  (let ((conn (make-irc-connection
                :allowed-users '("alice")
                :dm-allowed-users '("bob" "carol"))))
    (let ((result (clawmacs/irc::%effective-dm-allowed conn)))
      (is equal '("bob" "carol") result))))

(define-test "%effective-channel-allowed: case-insensitive channel name match"
  (let ((conn (make-irc-connection
                :channel-policies '(("#Bots" :allowed-users ("alice"))))))
    ;; Should match "#bots" (case-insensitive via string-equal)
    (let ((result (clawmacs/irc::%effective-channel-allowed conn "#bots")))
      (is equal '("alice") result))))

(define-test "make-irc-connection: channel-policies and dm-allowed-users stored"
  (let ((conn (make-irc-connection
                :channel-policies '(("#test" :allowed-users ("alice")))
                :dm-allowed-users '("bob"))))
    (is equal '(("#test" :allowed-users ("alice"))) (irc-channel-policies conn))
    (is equal '("bob") (irc-dm-allowed-users conn))))
