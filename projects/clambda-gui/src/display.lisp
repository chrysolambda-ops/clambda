;;;; src/display.lisp — Display functions for clawmacs-gui panes

(in-package #:clawmacs-gui)

;;; ── Utilities ─────────────────────────────────────────────────────────────────

(defun draw-hrule (stream width &key (ink +color-label+))
  "Draw a simple horizontal divider line on STREAM at current cursor position."
  (multiple-value-bind (x y)
      (clim:stream-cursor-position stream)
    (declare (ignore x))
    (clim:draw-line* stream 0 y width y :ink ink :line-thickness 1))
  (terpri stream))

(defun wrap-write (stream text &key (max-cols 80))
  "Write TEXT to STREAM with simple word-wrapping at MAX-COLS characters.
Respects existing newlines in TEXT."
  (declare (ignore max-cols))
  ;; McCLIM's application pane already handles line wrapping based on
  ;; the pane width, so we just write the text directly.
  (write-string text stream))

;;; ── Chat pane display ─────────────────────────────────────────────────────────

(defun display-chat-pane (frame pane)
  "Display all chat messages in the chat pane.

Called by McCLIM whenever the chat-display pane needs to be redrawn."
  (clim:with-drawing-options (pane :ink clim:+white+
                                   :text-style +text-style-body+)
    ;; Render each logged message
    (dolist (msg (frame-chat-log frame))
      (display-one-message pane msg))

    ;; If streaming is active, show the in-progress buffer
    (let ((streaming (frame-streaming-buffer frame)))
      (when streaming
        (display-streaming-message pane streaming)))))

(defun display-one-message (pane msg)
  "Render a single CHAT-MESSAGE on PANE."
  (let* ((role    (chat-message-role msg))
         (content (chat-message-content msg))
         (ts      (format-timestamp (chat-message-timestamp msg)))
         (ink     (role-ink role))
         (label   (role-label role)))

    ;; Role badge + timestamp header
    (clim:with-drawing-options (pane :ink ink
                                     :text-style +text-style-label+)
      (format pane "~%[~a] ~a~%" label ts))

    ;; Tool name annotation for :tool messages
    (when (and (eq role :tool) (chat-message-tool-name msg))
      (clim:with-drawing-options (pane :ink +color-tool+
                                       :text-style +text-style-mono+)
        (format pane "  Tool: ~a~%" (chat-message-tool-name msg))))

    ;; Message body
    (clim:with-drawing-options (pane :ink clim:+white+
                                     :text-style (if (eq role :tool)
                                                     +text-style-mono+
                                                     +text-style-body+))
      (wrap-write pane content)
      (terpri pane))

    ;; Small visual gap between messages
    (terpri pane)))

(defun display-streaming-message (pane tokens-so-far)
  "Render the in-progress streaming response on PANE."
  (clim:with-drawing-options (pane :ink +color-assistant+
                                   :text-style +text-style-label+)
    (format pane "~%[AST] streaming...~%"))
  (clim:with-drawing-options (pane :ink clim:+white+
                                   :text-style +text-style-body+)
    (write-string tokens-so-far pane)
    (terpri pane)))

;;; ── Sidebar display ───────────────────────────────────────────────────────────

(defun display-sidebar-pane (frame pane)
  "Display agent info and session stats in the sidebar pane."
  (let* ((session (frame-session frame))
         (agent   (when session (session-agent session))))

    ;; Title
    (clim:with-drawing-options (pane :ink +color-user+
                                     :text-style +text-style-label+)
      (format pane "~%  CLAMBDA GUI~%"))
    (clim:with-drawing-options (pane :ink +color-label+
                                     :text-style +text-style-ui+)
      (format pane "  LLM Chat Interface~%"))
    (terpri pane)

    (if agent
        (display-agent-info pane agent)
        (clim:with-drawing-options (pane :ink +color-error+
                                         :text-style +text-style-ui+)
          (format pane "  [no agent]~%")))

    (terpri pane)

    ;; Session stats
    (when session
      (display-session-stats pane frame session))

    (terpri pane)

    ;; Command help
    (display-command-help pane)))

(defun display-agent-info (pane agent)
  "Render agent info fields on PANE."
  (flet ((field (label value-str)
           (clim:with-drawing-options (pane :ink +color-label+
                                            :text-style +text-style-ui+)
             (format pane "  ~a~%" label))
           (clim:with-drawing-options (pane :ink clim:+white+
                                            :text-style +text-style-ui+)
             (format pane "    ~a~%" value-str))))
    (field "Agent:" (agent-name agent))
    (field "Role:"  (agent-role agent))
    (field "Model:" (or (agent-model agent) "(default)"))))

(defun display-session-stats (pane frame session)
  "Render session message count and token info on PANE."
  (clim:with-drawing-options (pane :ink +color-label+
                                   :text-style +text-style-ui+)
    (format pane "  Session Stats~%"))
  (clim:with-drawing-options (pane :ink clim:+white+
                                   :text-style +text-style-ui+)
    (format pane "    msgs: ~a~%" (session-message-count session))
    (format pane "    tokens: ~a~%" (frame-token-count frame))
    (format pane "    id: ~a~%"
            (let ((id (session-id session)))
              (if (> (length id) 20)
                  (subseq id 0 20)
                  id)))))

(defun display-command-help (pane)
  "Render brief command reference on PANE."
  (clim:with-drawing-options (pane :ink +color-label+
                                   :text-style +text-style-ui+)
    (format pane "  Commands~%"))
  (clim:with-drawing-options (pane :ink +color-highlight+
                                   :text-style +text-style-ui+)
    (dolist (line '("  Send <msg>      chat"
                    "  Clear History   clear"
                    "  Switch Model    model"
                    "  Set System      system"
                    "  Quit            quit"))
      (format pane "~a~%" line))))

;;; ── Status bar display ────────────────────────────────────────────────────────

(defun display-status-pane (frame pane)
  "Display the status bar."
  (let ((busy (frame-busy-p frame)))
    (clim:with-drawing-options (pane :ink (if busy +color-tool+ +color-label+)
                                     :text-style +text-style-ui+)
      (format pane " ~:[Ready~;Working~]  |  ~a"
              busy
              (frame-status frame)))))
