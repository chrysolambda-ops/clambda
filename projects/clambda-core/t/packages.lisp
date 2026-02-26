;;;; t/packages.lisp — Test packages for clambda-core

(defpackage #:clambda-core/tests
  (:use #:cl #:clambda)
  (:export #:run-smoke-test))

(defpackage #:clambda-core/tests/telegram
  (:use #:cl #:parachute)
  ;; Import public API symbols
  (:import-from #:clambda/telegram
                #:telegram-channel
                #:make-telegram-channel
                #:telegram-channel-token
                #:telegram-channel-allowed-users
                #:telegram-channel-polling-interval
                #:telegram-channel-running
                #:telegram-channel-last-update-id
                #:telegram-api-url
                #:allowed-user-p)
  ;; Internal helpers accessed via :: for white-box testing
  ;; (clambda/telegram::%extract-message-fields ...)
  ;; (clambda/telegram::%plist->ht ...)
  )

(defpackage #:clambda-core/tests/irc
  (:use #:cl #:parachute)
  ;; Public API
  (:import-from #:clambda/irc
                #:parse-irc-line
                #:irc-build-line
                #:prefix-nick
                #:irc-connection
                #:make-irc-connection
                #:irc-server #:irc-port #:irc-tls-p
                #:irc-nick #:irc-realname #:irc-channels
                #:irc-allowed-users #:irc-trigger-prefix
                #:irc-running-p #:irc-connected-p
                #:irc-flood-queue #:irc-flood-lock #:irc-flood-cvar
                #:*irc-send-interval*)
  ;; Internal helpers for white-box testing
  ;; clambda/irc::%strip-cr, clambda/irc::%extract-message-body, etc.
  )
