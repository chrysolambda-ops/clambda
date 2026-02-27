# Pattern: Emacs-Style Configuration (init.lisp / defcustom)

## What
User-facing configuration via a loadable Lisp file, analogous to Emacs `init.el`.
No JSON, no YAML, no DSL. Full CL in the config file.

## When to use
When building a CL application that needs user configurability and you want
to avoid external config formats. Especially appropriate for Lisp-native tools.

## Core elements

### 1. Config directory variable
```lisp
(defvar *clawmacs-home*
  (let ((env (uiop:getenv "MY_APP_HOME")))
    (if (and env (not (string= env "")))
        (uiop:ensure-directory-pathname env)
        (uiop:ensure-directory-pathname
         (merge-pathnames ".my-app/" (user-homedir-pathname)))))
  "Config directory. Set $MY_APP_HOME to override.")
```

### 2. defoption macro (defcustom analog)
```lisp
(defmacro defoption (name default &key (type t) doc)
  (let ((doc-str (or doc (format nil "Option ~A" name))))
    `(progn
       (defvar ,name ,default ,doc-str)
       (setf *option-registry*
             (cons (list ',name :default ,default :type ',type :doc ,doc-str)
                   (remove ',name *option-registry* :key #'car)))
       ',name)))
```

### 3. Hook system
```lisp
;; Hooks are plain lists of functions, stored in special variables.
(defvar *my-hook* '())

(defun add-hook (hook-var fn)
  (unless (member fn (symbol-value hook-var) :test #'equal)
    (setf (symbol-value hook-var)
          (append (symbol-value hook-var) (list fn))))
  fn)

(defun run-hook (hook-var &rest args)
  (dolist (fn (symbol-value hook-var))
    (handler-case (apply fn args)
      (error (e) (format *error-output* "Hook error: ~A~%" e)))))
```

### 4. User init package
```lisp
;; A package that gives init.lisp access to all public API without qualification.
(defpackage #:my-app-user
  (:use #:cl)
  (:import-from #:my-app/config
                #:defoption #:add-hook ...)
  (:import-from #:my-app/core
                #:make-thing ...)
  (:export ...))
```

### 5. Load function
```lisp
(defun load-user-config ()
  (let ((path (merge-pathnames "init.lisp" *my-app-home*)))
    (if (not (probe-file path))
        (progn (format t "No init.lisp, using defaults.~%") nil)
        (handler-case
            (let ((*package* (find-package '#:my-app-user)))
              (load path :verbose nil :print nil)
              (run-hook '*after-init-hook*)
              t)
          (error (e)
            (format *error-output* "init.lisp error: ~A~%" e)
            nil)))))
```

## Key design decisions

1. **No sandboxing** — init.lisp is full CL. Errors are caught but not prevented.
2. **defoption creates real DEFVAR** — options are just CL special variables; setf works normally.
3. **hook-var is a symbol** — `(add-hook '*my-hook* fn)` takes the quoted symbol so `setf` works via `symbol-value`. This is the idiomatic CL hook pattern.
4. **clawmacs-user package** — init.lisp runs in a dedicated package that imports the public API. Users don't need to write package qualifiers for common operations.
5. **Error recovery** — load errors are caught and printed; the system continues with defaults. This is the Emacs approach (init errors shown but Emacs still starts).

## Generic function for channel registration
```lisp
;; Generic: default stores config, plugins specialize to start transport
(defgeneric register-channel (type &rest args &key &allow-other-keys))

(defmethod register-channel ((type symbol) &rest args &key &allow-other-keys)
  (setf *registered-channels*
        (cons (cons type args) (remove type *registered-channels* :key #'car)))
  type)

;; Plugin adds method:
(defmethod register-channel ((type (eql :telegram)) &rest args &key token ...)
  (start-telegram-bot token)
  (call-next-method))
```

## Alternatives considered
- **JSON/YAML config** — rejected: no CL introspection, users must learn another syntax
- **s-exp config format** (not full CL) — rejected: less powerful, no functions/macros
- **Guile/Chicken embed** — not applicable
- **Quicklisp `ql:add-to-init-file`** — for library initialization, not application config

## Files in clawmacs
- `src/config.lisp` — full implementation
- `example-init.lisp` — annotated example showing all features
- `t/test-config.lisp` — 24 integration tests (all pass)
