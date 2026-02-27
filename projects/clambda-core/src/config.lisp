;;;; src/config.lisp — Emacs-style configuration system for Clawmacs
;;;;
;;;; This module provides the Clawmacs equivalent of Emacs init.el:
;;;;   - Config directory: ~/.clawmacs/ (or $CLAWMACS_HOME)
;;;;   - Entry point: ~/.clawmacs/init.lisp  — loaded at startup
;;;;   - defoption macro: defcustom analog with type/doc/registry
;;;;   - Hook system: add-hook, remove-hook, run-hook + standard hooks
;;;;   - register-channel generic: declare channels from init.lisp
;;;;   - define-user-tool: register user tools from init.lisp
;;;;
;;;; Design: no sandboxing, no JSON, no YAML. Full CL. Trust the user.
;;;; Errors in init.lisp are caught and reported clearly, not propagated.

(in-package #:clawmacs/config)

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 1. Config Directory
;;;; ─────────────────────────────────────────────────────────────────────────────

(defvar *clawmacs-home*
  (let ((env (uiop:getenv "CLAWMACS_HOME")))
    (if (and env (not (string= env "")))
        (uiop:ensure-directory-pathname env)
        (uiop:ensure-directory-pathname
         (merge-pathnames ".clawmacs/" (user-homedir-pathname)))))
  "The Clawmacs configuration directory pathname.
Defaults to ~/.clawmacs/ or $CLAWMACS_HOME if set.
Settable from init.lisp or startup code.")

(defun clawmacs-home ()
  "Return the resolved Clawmacs configuration directory pathname.
This is the value of *CLAMBDA-HOME*."
  *clawmacs-home*)

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 2. Options Registry (defoption / defcustom analog)
;;;; ─────────────────────────────────────────────────────────────────────────────

(defvar *option-registry* '()
  "Alist of (SYMBOL . PLIST) for all options defined with DEFOPTION.
Each entry: (symbol :default VAL :type TYPE :doc DOCSTRING).
Options are setf-able from init.lisp.")

(defmacro defoption (name default &key (type t) doc)
  "Define a configurable Clawmacs option variable. Analog of Emacs `defcustom`.

NAME    — a symbol, typically *earmuff-style*.
DEFAULT — the initial value expression.
:TYPE   — a CL type specifier (documentation only; not enforced at runtime).
:DOC    — documentation string.

The variable is defined with DEFVAR and registered in *OPTION-REGISTRY*.
Users can freely SETF it from init.lisp.

Example:
  (defoption *default-model* \"google/gemma-3-4b\"
    :type string
    :doc \"Default LLM model used when no model is specified.\")

  ;; In init.lisp:
  (setf *default-model* \"anthropic/claude-sonnet-4\")"
  (let ((doc-str (or doc
                     (format nil "Clawmacs option ~A (default: ~S)." name default))))
    `(progn
       (defvar ,name ,default ,doc-str)
       ;; Register (or update) in the options registry
       (setf *option-registry*
             (cons (list ',name :default ,default :type ',type :doc ,doc-str)
                   (remove ',name *option-registry* :key #'car)))
       ',name)))

(defun describe-options ()
  "Print all known Clawmacs options with current values and documentation.
Useful from init.lisp or the REPL to discover what's configurable."
  (format t "~&Clawmacs Options (~A defined):~2%" (length *option-registry*))
  (dolist (entry (reverse *option-registry*))
    (destructuring-bind (sym &key default type doc) entry
      (declare (ignore default))
      (format t "  ~A~%    Type:    ~A~%    Current: ~S~%    Doc:     ~A~2%"
              sym type (symbol-value sym) doc))))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 3. Built-in Options
;;;; ─────────────────────────────────────────────────────────────────────────────
;;;
;;; These are the standard options users are most likely to want to set.
;;; All are setf-able from init.lisp.

(defoption *default-model* "google/gemma-3-4b"
  :type string
  :doc "Default LLM model identifier used when no model is specified on an agent.")

(defoption *default-max-turns* 10
  :type integer
  :doc "Default maximum number of turns per agent loop run.")

(defoption *default-stream* nil
  :type boolean
  :doc "If T, use streaming mode by default for LLM calls.")

(defoption *log-level* :info
  :type keyword
  :doc "Logging verbosity level. One of: :debug :info :warn :error :none.")

(defoption *startup-message* nil
  :type (or string null)
  :doc "If non-nil, print this message to *standard-output* after init.lisp loads.")

(defoption *fallback-models* nil
  :type list
  :doc "Fallback model strings tried when the primary model fails with retryable errors.")

(defoption *heartbeat-interval* nil
  :type (or null integer)
  :doc "Seconds between heartbeat checks for registered agents. NIL disables heartbeats.")

(defoption *workspace-inject-files* '("AGENTS.md" "SOUL.md" "USER.md" "TOOLS.md" "IDENTITY.md")
  :type list
  :doc "Workspace files auto-injected into agent system prompts.")

(defoption *workspace-inject-refresh-interval* 60
  :type integer
  :doc "Seconds between workspace injection refresh checks.")

(defoption *model-supports-vision* nil
  :type boolean
  :doc "If T, enable vision-capable image analysis tool path.")

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 4. Hook System
;;;; ─────────────────────────────────────────────────────────────────────────────
;;;
;;; Hooks are named lists of functions. Standard hook variables are defined here.
;;; Users add/remove functions with add-hook / remove-hook.
;;; run-hook calls all functions in order, catching and reporting errors.

;;; Standard hook variables

(defvar *after-init-hook* '()
  "Functions called after init.lisp has been loaded successfully.
Each function is called with no arguments.
Use this to run code that depends on all init.lisp settings being in place.")

(defvar *before-agent-turn-hook* '()
  "Functions called before each agent turn (each call to AGENT-TURN).
Each function receives two arguments: (SESSION USER-MESSAGE-STRING).
Return value is ignored.")

(defvar *after-tool-call-hook* '()
  "Functions called after a tool call completes.
Each function receives two arguments: (TOOL-NAME RESULT-STRING).
Return value is ignored.")

(defvar *channel-message-hook* '()
  "Functions called when a message arrives on any registered channel.
Each function receives two arguments: (CHANNEL MESSAGE).
Return value is ignored.")

;;; Hook management

(defun add-hook (hook-var fn)
  "Add function FN to the hook named by HOOK-VAR (a symbol naming a hook variable).
FN is appended (runs last). If FN is already in the hook, it is not duplicated.

HOOK-VAR should be a quoted symbol:
  (add-hook '*after-init-hook* #'my-startup-function)

Returns FN."
  (check-type hook-var symbol)
  (let ((hooks (symbol-value hook-var)))
    (unless (member fn hooks :test #'equal)
      (setf (symbol-value hook-var) (append hooks (list fn)))))
  fn)

(defun remove-hook (hook-var fn)
  "Remove function FN from the hook named by HOOK-VAR.
If FN is not in the hook, this is a no-op.

  (remove-hook '*after-init-hook* #'my-startup-function)

Returns FN."
  (check-type hook-var symbol)
  (setf (symbol-value hook-var)
        (remove fn (symbol-value hook-var) :test #'equal))
  fn)

(defun run-hook (hook-var)
  "Run all functions in the hook named by HOOK-VAR (no arguments passed).
Functions are called in order. Each function is called with zero arguments.
Errors in hook functions are caught, reported to *ERROR-OUTPUT*, and
execution continues with the next hook function.

  (run-hook '*after-init-hook*)"
  (check-type hook-var symbol)
  (dolist (fn (symbol-value hook-var))
    (handler-case
        (funcall fn)
      (error (e)
        (format *error-output*
                "~&[clawmacs/config] Hook ~A: error in ~A: ~A~%"
                hook-var fn e)))))

(defun run-hook-with-args (hook-var &rest args)
  "Run all functions in the hook named by HOOK-VAR, passing ARGS to each.
Functions are called in order. Each receives all ARGS.
Errors are caught per-function and reported to *ERROR-OUTPUT*.

  (run-hook-with-args '*channel-message-hook* channel message)"
  (check-type hook-var symbol)
  (dolist (fn (symbol-value hook-var))
    (handler-case
        (apply fn args)
      (error (e)
        (format *error-output*
                "~&[clawmacs/config] Hook ~A: error in ~A: ~A~%"
                hook-var fn e)))))

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 5. Channel Registration
;;;; ─────────────────────────────────────────────────────────────────────────────

(defvar *registered-channels* '()
  "Alist of (CHANNEL-TYPE-KEYWORD . ARGS-PLIST) for all registered channels.
Populated by REGISTER-CHANNEL calls in init.lisp.
Channel plugin modules add methods to the REGISTER-CHANNEL generic
to actually start the channel; the default method just stores the config here.")

(defgeneric register-channel (type &rest args &key &allow-other-keys)
  (:documentation
   "Register a channel of TYPE (a keyword) with configuration ARGS.

Channel plugins define methods on this generic to start their transport.
The default method stores the config in *REGISTERED-CHANNELS* for later use.

Examples:
  ;; Telegram bot
  (register-channel :telegram
    :token \"BOT_TOKEN\"
    :allowed-users '(12345678))

  ;; IRC
  (register-channel :irc
    :server \"irc.libera.chat\" :port 6697
    :tls t :nick \"clawmacs\" :channels '(\"#clawmacs\"))

  ;; REPL (always available; no config needed)
  (register-channel :repl)"))

(defmethod register-channel ((type symbol) &rest args &key &allow-other-keys)
  "Default REGISTER-CHANNEL method: store channel config in *REGISTERED-CHANNELS*.
Prints a notice if no plugin has been loaded for this channel type.
Channel plugins should :CALL-NEXT-METHOD after starting the channel."
  (setf *registered-channels*
        (cons (cons type args)
              (remove type *registered-channels* :key #'car)))
  (format t "~&[clawmacs/config] Channel ~A registered~@[ (no plugin loaded for ~A)~].~%"
          type
          (unless (eq type :repl) type))
  type)

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 6. User-Facing Tool Registration
;;;; ─────────────────────────────────────────────────────────────────────────────
;;;
;;; Users can define tools from init.lisp using define-user-tool.
;;; Tools are registered into *USER-TOOL-REGISTRY*, a global registry
;;; that can be merged into an agent's registry at startup.

(defvar *user-tool-registry* (make-tool-registry)
  "Global tool registry populated by define-user-tool calls in init.lisp.
Merge this into your agent's registry at startup:

  ;; At agent creation time:
  (let ((registry (make-builtin-registry)))
    ;; Merge user tools
    (clawmacs/config:merge-user-tools! registry)
    (make-agent :tool-registry registry ...))")

(defun %params-list->schema (params)
  "Convert a parameters list to a JSON Schema plist suitable for schema-plist->ht.

PARAMS is a list of plists, each with keys:
  :name        (string) — parameter name
  :type        (string) — JSON Schema type: \"string\", \"number\", \"boolean\", etc.
  :description (string) — parameter description
  :required    (boolean, default T)

Returns a plist:
  (:type \"object\" :properties (...) :required #(...))"
  (let ((properties '())
        (required-names '()))
    (dolist (p params)
      (let* ((pname    (getf p :name))
             (ptype    (getf p :type "string"))
             (pdesc    (getf p :description ""))
             (req      (if (null (getf p :required)) t (getf p :required))))
        (setf properties
              (append properties
                      (list (intern pname :keyword)
                            (list :|type| ptype :|description| pdesc))))
        (when req
          (push pname required-names))))
    (list :|type| "object"
          :|properties| properties
          :|required| (coerce (nreverse required-names) 'vector))))

(defun register-user-tool! (name description parameters function)
  "Register a user-defined tool in *USER-TOOL-REGISTRY*.

NAME        — string: the tool name sent to the LLM.
DESCRIPTION — string: what the tool does.
PARAMETERS  — list of (:name NAME :type TYPE :description DESC [:required T]) plists.
FUNCTION    — a function designator: (lambda (args-ht) ...) → string or TOOL-RESULT.

Returns the updated *USER-TOOL-REGISTRY*."
  (let ((schema (when parameters (%params-list->schema parameters))))
    (register-tool! *user-tool-registry* name function
                    :description (or description "")
                    :parameters  schema))
  *user-tool-registry*)

(defmacro define-user-tool (name &key description parameters function)
  "Define and register a user tool in *USER-TOOL-REGISTRY*.

NAME        — a symbol; its downcased string is used as the tool name.
:DESCRIPTION — string describing the tool.
:PARAMETERS  — a list of parameter plists:
               '((:name \"input\" :type \"string\" :description \"The input\"))
               Each plist may also have :required T/NIL (default T).
:FUNCTION    — a function designator evaluated at runtime.

The tool is registered against the global *USER-TOOL-REGISTRY*.

Example:
  (defun my-tool-handler (args)
    (let ((input (gethash \"input\" args)))
      (format nil \"You said: ~A\" input)))

  (define-user-tool my-custom-tool
    :description \"Does something cool\"
    :parameters '((:name \"input\" :type \"string\" :description \"The input\"))
    :function #'my-tool-handler)"
  (let ((name-str (string-downcase (symbol-name name))))
    `(register-user-tool! ,name-str ,description ,parameters ,function)))

(defun merge-user-tools! (target-registry)
  "Merge all tools from *USER-TOOL-REGISTRY* into TARGET-REGISTRY.
Call this when building an agent to include user-defined tools.
Returns TARGET-REGISTRY."
  (let ((src-table (clawmacs/tools::registry-table *user-tool-registry*))
        (dst-table (clawmacs/tools::registry-table target-registry)))
    (maphash (lambda (name entry)
               (setf (gethash name dst-table) entry))
             src-table))
  target-registry)

;;;; ─────────────────────────────────────────────────────────────────────────────
;;;; § 7. Init.lisp Loading
;;;; ─────────────────────────────────────────────────────────────────────────────

(defvar *user-config-loaded* nil
  "T if init.lisp was successfully loaded, NIL otherwise.")

(defun user-config-loaded-p ()
  "Return T if init.lisp has been loaded, NIL otherwise."
  *user-config-loaded*)

(defun %init-lisp-path ()
  "Return the pathname of the user's init.lisp."
  (merge-pathnames "init.lisp" *clawmacs-home*))

(defun load-user-config ()
  "Find and load ~/.clawmacs/init.lisp (or $CLAWMACS_HOME/init.lisp).

The file is loaded with *PACKAGE* bound to CLAWMACS-USER so all public
Clawmacs symbols are available without qualification.

Error handling:
  - If init.lisp does not exist: prints a notice and returns NIL.
  - If init.lisp has a load error: prints a clear error message to
    *ERROR-OUTPUT* and returns NIL. Does NOT propagate the error.

After successful load:
  - *USER-CONFIG-LOADED* is set to T
  - *AFTER-INIT-HOOK* is run
  - *STARTUP-MESSAGE* is printed (if non-nil)

Returns: T on success, NIL if not found or errored.

Example startup:
  (clawmacs/config:load-user-config)
  (let ((agent (make-agent :model *default-model* ...)))
    ...)"
  (let ((path (%init-lisp-path)))
    (cond
      ;; No init.lisp found
      ((not (probe-file path))
       (format t "~&[clawmacs] No init.lisp at ~A — running with defaults.~%"
               (namestring path))
       nil)

      ;; Load it
      (t
       (format t "~&[clawmacs] Loading ~A ...~%" (namestring path))
       (handler-case
           (let ((*package* (find-package '#:clawmacs-user)))
             (load path :verbose nil :print nil)
             ;; Success
             (setf *user-config-loaded* t)
             (format t "~&[clawmacs] init.lisp loaded.~%")
             ;; Print startup message if set
             (when *startup-message*
               (format t "~&~A~%" *startup-message*))
             ;; Run after-init hooks
             (run-hook '*after-init-hook*)
             t)

         ;; Catch load errors — report clearly, don't crash
         (error (e)
           (format *error-output*
                   "~&[clawmacs] ERROR loading ~A:~%~
                    ~%  ~A~%~
                    ~%  Fix the error and call (clawmacs/config:load-user-config) again.~%"
                   (namestring path) e)
           nil))))))
