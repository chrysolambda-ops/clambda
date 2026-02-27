;;;; src/colors.lisp — Color palette and text-style helpers for clawmacs-gui

(in-package #:clawmacs-gui)

;;; ── Color palette ────────────────────────────────────────────────────────────

;;; Dark background theme
(defparameter +bg-main+
  (clim:make-rgb-color 0.07 0.07 0.12)
  "Main chat background — near-black blue-tinted.")

(defparameter +bg-sidebar+
  (clim:make-rgb-color 0.10 0.10 0.18)
  "Sidebar background — slightly lighter.")

(defparameter +bg-status+
  (clim:make-rgb-color 0.05 0.05 0.10)
  "Status bar background — darkest.")

(defparameter +bg-input+
  (clim:make-rgb-color 0.12 0.12 0.20)
  "Input area background.")

;;; Text colors by role
(defparameter +color-system+
  (clim:make-rgb-color 0.55 0.55 0.65)
  "Gray — system messages.")

(defparameter +color-user+
  (clim:make-rgb-color 0.45 0.70 1.00)
  "Sky blue — user messages.")

(defparameter +color-assistant+
  (clim:make-rgb-color 0.40 0.90 0.50)
  "Mint green — assistant messages.")

(defparameter +color-tool+
  (clim:make-rgb-color 1.00 0.80 0.20)
  "Amber — tool calls and results.")

(defparameter +color-error+
  (clim:make-rgb-color 1.00 0.35 0.35)
  "Red — error messages.")

(defparameter +color-label+
  (clim:make-rgb-color 0.70 0.70 0.80)
  "Muted blue-white — labels and metadata.")

(defparameter +color-highlight+
  (clim:make-rgb-color 1.00 1.00 0.60)
  "Pale yellow — highlights and status.")

;;; ── Role → color / label mapping ─────────────────────────────────────────────

(defun role-ink (role)
  "Return the CLIM ink (color) for message ROLE keyword."
  (case role
    (:system    +color-system+)
    (:user      +color-user+)
    (:assistant +color-assistant+)
    (:tool      +color-tool+)
    (t          clim:+white+)))

(defun role-label (role)
  "Return a short display label string for message ROLE keyword."
  (case role
    (:system    "SYS")
    (:user      "YOU")
    (:assistant "AST")
    (:tool      "TOOL")
    (t          "???")))

(defun role-from-message (msg)
  "Convert a CL-LLM message's role symbol to our :ROLE keyword."
  (let* ((raw-role (message-role msg))
         (name     (if (symbolp raw-role)
                       (string-downcase (symbol-name raw-role))
                       (string-downcase (string raw-role)))))
    (cond
      ((string= name "system")    :system)
      ((string= name "user")      :user)
      ((string= name "assistant") :assistant)
      ((string= name "tool")      :tool)
      (t                          :user))))

;;; ── Text styles ──────────────────────────────────────────────────────────────

(defparameter +text-style-body+
  (clim:make-text-style :sans-serif :roman 13)
  "Body text style for chat messages.")

(defparameter +text-style-label+
  (clim:make-text-style :sans-serif :bold 11)
  "Label style for role headers.")

(defparameter +text-style-mono+
  (clim:make-text-style :fix :roman 12)
  "Monospace style for tool calls and code.")

(defparameter +text-style-ui+
  (clim:make-text-style :sans-serif :roman 11)
  "UI element text style for sidebar and status.")
