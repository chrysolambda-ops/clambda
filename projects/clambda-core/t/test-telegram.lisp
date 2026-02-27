;;;; t/test-telegram.lisp — Unit tests for clambda/telegram
;;;;
;;;; Tests that do NOT hit the Telegram API or the LLM.
;;;; All tests use locally constructed data structures and pure functions.
;;;;
;;;; To run:
;;;;   (asdf:test-system :clambda-core)
;;;;
;;;; For a live integration test (real bot token required):
;;;;   1. Set your token:
;;;;        (clambda/config:register-channel :telegram :token "TOKEN")
;;;;   2. Start polling:
;;;;        (clambda/telegram:start-telegram)
;;;;   3. Send a message to your bot in Telegram. Watch the REPL for output.
;;;;   4. Stop:
;;;;        (clambda/telegram:stop-telegram)

(in-package #:clambda-core/tests/telegram)

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 1. URL Construction
;;;; ─────────────────────────────────────────────────────────────────────────────

(define-test "telegram-api-url: basic format"
  (is string=
      "https://api.telegram.org/bot123:ABC/getUpdates"
      (telegram-api-url "123:ABC" "getUpdates")))

(define-test "telegram-api-url: sendMessage method"
  (is string=
      "https://api.telegram.org/botTOKEN/sendMessage"
      (telegram-api-url "TOKEN" "sendMessage")))

(define-test "telegram-api-url: getMe method"
  (is string=
      "https://api.telegram.org/botMY_TOKEN/getMe"
      (telegram-api-url "MY_TOKEN" "getMe")))

(define-test "telegram-api-url: token is embedded verbatim"
  ;; Tokens contain digits:letters — ensure no escaping
  (let ((url (telegram-api-url "1234567890:AAFzABC_defGHI-jkl" "getMe")))
    (true (search "bot1234567890:AAFzABC_defGHI-jkl" url))))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 2. Allowlist Logic
;;;; ─────────────────────────────────────────────────────────────────────────────

(define-test "allowed-user-p: nil allowlist permits all users"
  (let ((chan (make-telegram-channel :token "T")))
    ;; No allowed-users set → everyone is permitted
    (true  (allowed-user-p chan 12345))
    (true  (allowed-user-p chan 99999))
    (true  (allowed-user-p chan 0))))

(define-test "allowed-user-p: allowlist permits listed users"
  (let ((chan (make-telegram-channel :token "T" :allowed-users '(111 222 333))))
    (true (allowed-user-p chan 111))
    (true (allowed-user-p chan 222))
    (true (allowed-user-p chan 333))))

(define-test "allowed-user-p: allowlist rejects unlisted users"
  (let ((chan (make-telegram-channel :token "T" :allowed-users '(111 222))))
    (false (allowed-user-p chan 999))
    (false (allowed-user-p chan 0))
    (false (allowed-user-p chan 333))))

(define-test "allowed-user-p: single-element allowlist"
  (let ((chan (make-telegram-channel :token "T" :allowed-users '(42))))
    (true  (allowed-user-p chan 42))
    (false (allowed-user-p chan 43))))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 3. Internal Helper: %plist->ht
;;;; ─────────────────────────────────────────────────────────────────────────────

(define-test "%plist->ht: keyword keys become lowercase strings"
  (let ((ht (clambda/telegram::%plist->ht '(:chat_id 123 :text "hello"))))
    (is eql 123    (gethash "chat_id" ht))
    (is string= "hello" (gethash "text" ht))))

(define-test "%plist->ht: empty plist → empty hash-table"
  (let ((ht (clambda/telegram::%plist->ht '())))
    (is = 0 (hash-table-count ht))))

(define-test "%plist->ht: mixed case keyword → lowercased"
  (let ((ht (clambda/telegram::%plist->ht '(:ParseMode "Markdown"))))
    (true (gethash "parsemode" ht))))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 4. Message Field Extraction
;;;; ─────────────────────────────────────────────────────────────────────────────

(defun %make-update (update-id &key text chat-id user-id first-name)
  "Build a fake Telegram update hash-table for testing.
Mirrors the structure of a real Telegram API update object."
  (let ((update (make-hash-table :test 'equal)))
    (setf (gethash "update_id" update) update-id)
    (when (or text chat-id user-id)
      (let ((msg   (make-hash-table :test 'equal))
            (chat  (make-hash-table :test 'equal))
            (from  (make-hash-table :test 'equal)))
        (when text      (setf (gethash "text" msg) text))
        (when chat-id   (setf (gethash "id" chat) chat-id))
        (when user-id   (setf (gethash "id" from) user-id))
        (when first-name (setf (gethash "first_name" from) first-name))
        (setf (gethash "chat" msg) chat)
        (setf (gethash "from" msg) from)
        (setf (gethash "message" update) msg)))
    update))

(define-test "%extract-message-fields: text message returns all fields"
  (let ((update (%make-update 1
                               :text "Hello bot!"
                               :chat-id 9001
                               :user-id 42
                               :first-name "Alice")))
    (multiple-value-bind (text chat-id user-id name)
        (clambda/telegram::%extract-message-fields update)
      (is string= "Hello bot!" text)
      (is eql 9001 chat-id)
      (is eql 42   user-id)
      (is string= "Alice" name))))

(define-test "%extract-message-fields: no message → all nil"
  ;; An update with no 'message' key (e.g. channel_post)
  (let ((update (make-hash-table :test 'equal)))
    (setf (gethash "update_id" update) 99)
    (multiple-value-bind (text chat-id user-id name)
        (clambda/telegram::%extract-message-fields update)
      (false text)
      (false chat-id)
      (false user-id)
      (false name))))

(define-test "%extract-message-fields: photo message has no text → nil text"
  ;; Photo updates have a 'message' but no 'text' key
  (let ((update (make-hash-table :test 'equal))
        (msg    (make-hash-table :test 'equal))
        (chat   (make-hash-table :test 'equal))
        (from   (make-hash-table :test 'equal)))
    (setf (gethash "id" chat)       100)
    (setf (gethash "id" from)       200)
    ;; No "text" key in msg → photo message
    (setf (gethash "chat" msg)      chat)
    (setf (gethash "from" msg)      from)
    (setf (gethash "message" update) msg)
    (multiple-value-bind (text chat-id user-id _name)
        (clambda/telegram::%extract-message-fields update)
      (declare (ignore _name))
      (false text)           ; text is nil → process-update ignores this
      (is eql 100 chat-id)
      (is eql 200 user-id))))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 5. make-telegram-channel Constructor
;;;; ─────────────────────────────────────────────────────────────────────────────

(define-test "make-telegram-channel: token stored correctly"
  (let ((chan (make-telegram-channel :token "MYTOKEN")))
    (is string= "MYTOKEN" (telegram-channel-token chan))))

(define-test "make-telegram-channel: default allowed-users is nil"
  (let ((chan (make-telegram-channel :token "T")))
    (false (telegram-channel-allowed-users chan))))

(define-test "make-telegram-channel: allowed-users stored"
  (let ((chan (make-telegram-channel :token "T" :allowed-users '(1 2 3))))
    (is equal '(1 2 3) (telegram-channel-allowed-users chan))))

(define-test "make-telegram-channel: default polling-interval is 1"
  (let ((chan (make-telegram-channel :token "T")))
    (is = 1 (telegram-channel-polling-interval chan))))

(define-test "make-telegram-channel: custom polling-interval stored"
  (let ((chan (make-telegram-channel :token "T" :polling-interval 5)))
    (is = 5 (telegram-channel-polling-interval chan))))

(define-test "make-telegram-channel: not running by default"
  (let ((chan (make-telegram-channel :token "T")))
    (false (telegram-channel-running chan))))

(define-test "make-telegram-channel: last-update-id starts at 0"
  (let ((chan (make-telegram-channel :token "T")))
    (is = 0 (telegram-channel-last-update-id chan))))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 6. process-update: allowlist rejection (mock — no LLM call)
;;;; ─────────────────────────────────────────────────────────────────────────────
;;;
;;; For the full process-update flow (find-or-create-session + run-agent +
;;; sendMessage), a real LLM endpoint and bot token are required.
;;; This test verifies only that messages from non-allowlisted users
;;; do NOT trigger session creation.

(define-test "process-update: rejected user does not create a session"
  (let* ((chan    (make-telegram-channel :token "T"
                                          :allowed-users '(111)))
         (update (%make-update 42
                                :text "Hello"
                                :chat-id 999
                                :user-id 999))) ; 999 not in allowlist
    ;; process-update should silently ignore this update
    ;; and NOT create a session entry
    (process-update chan update)
    ;; Sessions table should still be empty
    (is = 0 (hash-table-count (clambda/telegram::telegram-channel-sessions chan)))))

(define-test "process-update: non-text update does not create a session"
  (let* ((chan   (make-telegram-channel :token "T"))
         (update (%make-update 99)))  ; no message key at all
    (process-update chan update)
    (is = 0 (hash-table-count (clambda/telegram::telegram-channel-sessions chan)))))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 7. Streaming configuration
;;;; ─────────────────────────────────────────────────────────────────────────────

(define-test "*telegram-streaming*: default is T"
  (true clambda/telegram:*telegram-streaming*))

(define-test "*telegram-stream-debounce-ms*: default is 500"
  (is = 500 clambda/telegram:*telegram-stream-debounce-ms*))

(define-test "streaming vars can be rebound dynamically"
  (let ((clambda/telegram:*telegram-streaming* nil))
    (false clambda/telegram:*telegram-streaming*))
  ;; After let exits, original value is restored
  (true clambda/telegram:*telegram-streaming*))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 8. %split-telegram-text helper
;;;; ─────────────────────────────────────────────────────────────────────────────

(define-test "%split-telegram-text: short text is single chunk"
  (let ((chunks (clambda/telegram::%split-telegram-text "Hello!" 4096)))
    (is = 1 (length chunks))
    (is string= "Hello!" (first chunks))))

(define-test "%split-telegram-text: text exactly at limit is single chunk"
  (let* ((text (make-string 4096 :initial-element #\a))
         (chunks (clambda/telegram::%split-telegram-text text 4096)))
    (is = 1 (length chunks))))

(define-test "%split-telegram-text: text over limit is split"
  (let* ((text (make-string 5000 :initial-element #\x))
         (chunks (clambda/telegram::%split-telegram-text text 4096)))
    (is = 2 (length chunks))
    ;; First chunk ≤ 4096
    (true (<= (length (first chunks)) 4096))
    ;; All content preserved
    (is = 5000 (reduce #'+ chunks :key #'length))))

(define-test "%split-telegram-text: splits at newline boundary"
  (let* (;; 4000 x chars + newline + 200 y chars = 4201 total
         (text (concatenate 'string
                             (make-string 4000 :initial-element #\x)
                             (string #\Newline)
                             (make-string 200 :initial-element #\y)))
         (chunks (clambda/telegram::%split-telegram-text text 4096)))
    ;; Should split after the newline, not at hard 4096
    (is = 2 (length chunks))
    (true (<= (length (first chunks)) 4096))))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 9. %current-time-ms helper
;;;; ─────────────────────────────────────────────────────────────────────────────

(define-test "%current-time-ms: returns a non-negative integer"
  (let ((t1 (clambda/telegram::%current-time-ms)))
    (true (integerp t1))
    (true (>= t1 0))))

(define-test "%current-time-ms: monotonically non-decreasing"
  (let* ((t1 (clambda/telegram::%current-time-ms))
         (t2 (clambda/telegram::%current-time-ms)))
    (true (>= t2 t1))))
