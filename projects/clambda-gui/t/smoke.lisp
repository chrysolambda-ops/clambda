;;;; t/smoke.lisp — Non-GUI smoke tests for clawmacs-gui

(in-package #:clawmacs-gui/tests)

;;; ── Chat message record tests ─────────────────────────────────────────────────

(defun test-chat-message ()
  "Test basic chat-message construction and accessors."
  (let ((msg (clawmacs-gui:make-chat-message :user "Hello, world!")))
    (assert (eq :user (clawmacs-gui:chat-message-role msg))
            () "Expected role :USER, got ~s" (clawmacs-gui:chat-message-role msg))
    (assert (string= "Hello, world!" (clawmacs-gui:chat-message-content msg))
            () "Expected content 'Hello, world!'")
    (assert (integerp (clawmacs-gui:chat-message-timestamp msg))
            () "Expected integer timestamp")
    (format t "  [PASS] make-chat-message~%")))

(defun test-chat-message-roles ()
  "Test all valid role keywords."
  (dolist (role '(:user :assistant :system :tool))
    (let ((msg (clawmacs-gui:make-chat-message role "test")))
      (assert (eq role (clawmacs-gui:chat-message-role msg))
              () "Role mismatch for ~s" role)))
  (format t "  [PASS] chat-message roles~%"))

(defun test-role-colors ()
  "Test that role-ink returns non-NIL for known roles."
  (dolist (role '(:user :assistant :system :tool))
    (let ((ink (clawmacs-gui:role-ink role)))
      (assert (not (null ink))
              () "role-ink returned NIL for ~s" role)))
  (format t "  [PASS] role-ink colors~%"))

(defun test-role-labels ()
  "Test role-label returns a non-empty string."
  (dolist (role '(:user :assistant :system :tool))
    (let ((label (clawmacs-gui:role-label role)))
      (assert (and (stringp label) (> (length label) 0))
              () "role-label bad for ~s: ~s" role label)))
  (format t "  [PASS] role-label~%"))

;;; ── Run all tests ─────────────────────────────────────────────────────────────

(defun run-smoke-tests ()
  "Run the non-GUI smoke test suite. Returns T on success."
  (format t "~%Running clawmacs-gui smoke tests...~%")
  (handler-case
      (progn
        (test-chat-message)
        (test-chat-message-roles)
        (test-role-colors)
        (test-role-labels)
        (format t "~%All smoke tests PASSED.~%")
        t)
    (error (e)
      (format t "~%FAILED: ~a~%" e)
      nil)))

;; Auto-run when loaded
(run-smoke-tests)
