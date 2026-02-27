;;;; src/image.lisp — Lisp image save/restore for Clawmacs
;;;;
;;;; Genera-inspired: save the entire running Clawmacs system — config, agents,
;;;; tool registries, loaded channels, everything — as a single executable file.
;;;; Restore it instantly with zero dependency resolution at startup.
;;;;
;;;; HOW IT WORKS
;;;;
;;;; `sb-ext:save-lisp-and-die` saves the entire SBCL Lisp image to a file.
;;;; The file includes:
;;;;   - All loaded code (clawmacs-core, cl-llm, dexador, jzon, ...)
;;;;   - All global state (registered agents, channels, options)
;;;;   - Your init.lisp configuration (since it was already loaded)
;;;;
;;;; When you run the saved image, it calls CLAMBDA-MAIN as the toplevel,
;;;; which re-establishes runtime connections (channels, SWANK server, etc.)
;;;; and resumes normal operation — no startup time for compilation or loading.
;;;;
;;;; USAGE
;;;;
;;;;   ;; Save (from a running Clawmacs REPL or SWANK session):
;;;;   (save-clawmacs-image)            ; → ./clawmacs.core
;;;;   (save-clawmacs-image #P"/opt/clawmacs/clawmacs-bot")  ; custom path
;;;;
;;;;   ;; Restore:
;;;;   ./clawmacs.core          ; runs clawmacs-main as the toplevel
;;;;
;;;;   ;; Or explicitly:
;;;;   sbcl --core clawmacs.core
;;;;
;;;; WHY THIS IS A SUPERPOWER
;;;;
;;;; - Zero cold-start: no dependency loading, no compilation (< 100ms)
;;;; - Distribute as a single binary with all config baked in
;;;; - "Fork" a running agent: save → copy to another host → run → instant clone
;;;; - Checkpoint before risky operations → restore on failure
;;;; - Like Docker, but the entire Lisp runtime. Lispier.
;;;;
;;;; OpenClaw (Node.js) cannot do this. Node has no equivalent to
;;;; sb-ext:save-lisp-and-die — there is no way to save the entire runtime
;;;; state of a V8 engine as a portable executable.
;;;;
;;;; NOTE: Long-running background threads (Telegram polling, IRC reader,
;;;; SWANK) will NOT survive the save/restore boundary. CLAMBDA-MAIN
;;;; re-establishes them on resume. Transient session state (in-memory
;;;; message histories) IS preserved if sessions are in global variables.
;;;; For persistent sessions, call SAVE-SESSION before saving the image.

(in-package #:clawmacs/image)

;;;; ── Toplevel for saved images ───────────────────────────────────────────────

(defun clawmacs-main ()
  "Toplevel function for saved Clawmacs images.

Called automatically when a saved image starts. Performs:
  1. Re-establish the LD_LIBRARY_PATH for CFFI (dexador/SSL)
  2. Print a startup banner
  3. Re-start SWANK server (if *SWANK-PORT* is set)
  4. Re-start channels (if registered, using START-ALL-CHANNELS)
  5. Run *AFTER-INIT-HOOK* to let user code re-initialise
  6. Drop into a REPL (or block forever if started as a daemon)

The image retains all registered agents, tool definitions, and config
from the original session when it was saved."
  ;; 1. Announce startup
  (format t "~&~%╔══════════════════════════════════════════╗~%~
               ║  Clawmacs — Lisp Agent Platform          ║~%~
               ║  Restored from saved image               ║~%~
               ╚══════════════════════════════════════════╝~%~%")

  ;; 2. Set LD_LIBRARY_PATH so CFFI/dexador can find libcrypto
  ;;    (the saved image may be run from a different shell environment)
  (let ((existing (uiop:getenv "LD_LIBRARY_PATH"))
        (needed "/lib/x86_64-linux-gnu"))
    (unless (and existing (search needed existing))
      (setf (uiop:getenv "LD_LIBRARY_PATH")
            (if (and existing (> (length existing) 0))
                (concatenate 'string needed ":" existing)
                needed))))

  ;; 3. Re-start SWANK (if was running before save)
  (handler-case
      (when (find-package '#:clawmacs/swank)
        (let ((swank-fn (find-symbol "START-SWANK" '#:clawmacs/swank)))
          (when swank-fn
            (funcall swank-fn))))
    (error (e)
      (format *error-output*
              "~&[clawmacs/image] Could not start SWANK on resume: ~a~%" e)))

  ;; 4. Re-start channels (Telegram, IRC, etc.)
  ;;    start-all-channels is safe to call even if nothing is registered
  (handler-case
      (when (find-package '#:clawmacs/telegram)
        (let ((fn (find-symbol "START-ALL-CHANNELS" '#:clawmacs/telegram)))
          (when fn (funcall fn))))
    (error (e)
      (format *error-output*
              "~&[clawmacs/image] Could not restart channels on resume: ~a~%" e)))

  ;; 5. Run after-init hooks (so user code can re-initialise live state)
  (handler-case
      (when (find-package '#:clawmacs/config)
        (let ((fn (find-symbol "RUN-HOOK" '#:clawmacs/config)))
          (when fn (funcall fn '*after-init-hook*))))
    (error (e)
      (format *error-output*
              "~&[clawmacs/image] Error in after-init hooks on resume: ~a~%" e)))

  ;; 6. Show what's loaded and start REPL
  (format t "~&[clawmacs] Image restored. ~
               ~@[Registered agents: ~a~]~%"
          (handler-case
              (when (find-package '#:clawmacs/registry)
                (let ((fn (find-symbol "LIST-AGENTS" '#:clawmacs/registry)))
                  (when fn
                    (length (funcall fn)))))
            (error () nil)))

  ;; Drop into SBCL REPL
  (sb-impl::toplevel-init))

;;;; ── Save function ───────────────────────────────────────────────────────────

(defun save-clawmacs-image (&optional (path "clawmacs.core"))
  "Save the entire running Clawmacs system as a SBCL core/executable file.

PATH — pathname or string for the output file.
       Default: \"clawmacs.core\" in the current directory.
       For a self-contained executable, use a path without extension.

The saved image includes:
  - All loaded systems (clawmacs-core, cl-llm, all dependencies)
  - All registered agents, channel configs, user options
  - Your init.lisp settings (already evaluated)
  - The full Quicklisp distribution (loaded at save time)

When run, CLAMBDA-MAIN is invoked as the toplevel, which:
  - Re-starts SWANK (if configured)
  - Re-connects channels (Telegram, IRC, etc.)
  - Runs *AFTER-INIT-HOOK*
  - Drops into a REPL

NOTE: This function DOES NOT RETURN — SBCL exits after saving.
Start a new Clawmacs instance to use the saved image.

Example:
  (save-clawmacs-image)                           ; → ./clawmacs.core
  (save-clawmacs-image #P\"/usr/local/bin/clawmacs\") ; → standalone executable

To run the saved image:
  ./clawmacs.core
  ;; or: sbcl --core clawmacs.core"
  (let ((path-str (if (pathnamep path)
                      (namestring path)
                      (string path))))
    (format t "~&[clawmacs/image] Saving Clawmacs image to: ~a~%" path-str)
    (format t "~&[clawmacs/image] This process will exit after saving.~%")
    (finish-output)

    ;; Save as executable with clawmacs-main as the entry point
    (sb-ext:save-lisp-and-die
     path-str
     :toplevel     #'clawmacs-main
     :executable   t
     :compression  t
     :save-runtime-options t)))
