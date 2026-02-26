;;;; src/builtins.lisp — Built-in tools: exec, read-file, write-file

(in-package #:clambda/builtins)

;;; ── exec helper ──────────────────────────────────────────────────────────────

(defun run-shell-command (command &key workdir)
  "Run COMMAND in a shell. Return (values stdout stderr exit-code)."
  (let ((cmd (if workdir
                 (format nil "cd ~s && ~a" workdir command)
                 command)))
    (multiple-value-bind (stdout stderr exit-code)
        (uiop:run-program (list "/bin/bash" "-c" cmd)
                          :output '(:string :stripped nil)
                          :error-output '(:string :stripped nil)
                          :ignore-error-status t)
      (values stdout stderr exit-code))))

;;; ── Register all built-ins ───────────────────────────────────────────────────

(defun register-builtin-tools (registry &key workdir)
  "Register all built-in tools in REGISTRY.
WORKDIR — optional default working directory for exec.
Returns REGISTRY."

  ;; ── exec ──────────────────────────────────────────────────────────────────
  (clambda/tools:register-tool!
   registry
   "exec"
   (lambda (args)
     (let ((command (gethash "command" args))
           (cwd     (or (gethash "workdir" args) workdir)))
       (cond
         ((or (null command) (string= command ""))
          (clambda/tools:tool-result-error "No command provided"))
         (t
          (handler-case
              (multiple-value-bind (stdout stderr exit-code)
                  (run-shell-command command :workdir cwd)
                (let ((combined (concatenate
                                 'string stdout
                                 (if (and stderr (not (string= stderr "")))
                                     (format nil "~%[stderr]~%~a" stderr)
                                     ""))))
                  (clambda/tools:tool-result-ok
                   (format nil "exit-code: ~a~%~a" exit-code combined))))
            (error (e)
              (clambda/tools:tool-result-error
               (format nil "exec failed: ~a" e))))))))
   :description "Execute a shell command and return its output."
   :parameters '(:|type| "object"
                 :|properties|
                 (:|command| (:|type| "string" :|description| "Shell command to run")
                  :|workdir| (:|type| "string" :|description| "Optional working directory"))
                 :|required| #("command")))

  ;; ── read-file ──────────────────────────────────────────────────────────────
  (clambda/tools:register-tool!
   registry
   "read_file"
   (lambda (args)
     (let ((path (gethash "path" args)))
       (cond
         ((or (null path) (string= path ""))
          (clambda/tools:tool-result-error "No path provided"))
         (t
          (handler-case
              (clambda/tools:tool-result-ok (uiop:read-file-string path))
            (error (e)
              (clambda/tools:tool-result-error
               (format nil "read-file failed: ~a" e))))))))
   :description "Read the contents of a file and return it as text."
   :parameters '(:|type| "object"
                 :|properties|
                 (:|path| (:|type| "string" :|description| "Path to the file to read"))
                 :|required| #("path")))

  ;; ── write-file ─────────────────────────────────────────────────────────────
  (clambda/tools:register-tool!
   registry
   "write_file"
   (lambda (args)
     (let ((path    (gethash "path" args))
           (content (gethash "content" args)))
       (cond
         ((or (null path) (null content))
          (clambda/tools:tool-result-error "path and content are required"))
         (t
          (handler-case
              (progn
                (ensure-directories-exist path)
                (with-open-file (out path
                                     :direction :output
                                     :if-exists :supersede
                                     :if-does-not-exist :create)
                  (write-string content out))
                (clambda/tools:tool-result-ok
                 (format nil "Written ~a bytes to ~a" (length content) path)))
            (error (e)
              (clambda/tools:tool-result-error
               (format nil "write-file failed: ~a" e))))))))
   :description "Write text content to a file, creating it if needed."
   :parameters '(:|type| "object"
                 :|properties|
                 (:|path|    (:|type| "string" :|description| "Path to write to")
                  :|content| (:|type| "string" :|description| "Content to write"))
                 :|required| #("path" "content")))

  ;; ── list-directory ────────────────────────────────────────────────────────
  (clambda/tools:register-tool!
   registry
   "list_directory"
   (lambda (args)
     (let ((path (or (gethash "path" args) ".")))
       (handler-case
           (let* ((truepath (uiop:ensure-directory-pathname path))
                  (entries (uiop:directory-files truepath))
                  (subdirs (uiop:subdirectories truepath)))
             (clambda/tools:tool-result-ok
              (with-output-to-string (s)
                (dolist (d subdirs)
                  (format s "[dir]  ~a~%"
                          (file-namestring (directory-namestring d))))
                (dolist (f entries)
                  (format s "[file] ~a~%" (file-namestring f))))))
         (error (e)
           (clambda/tools:tool-result-error
            (format nil "list-directory failed: ~a" e))))))
   :description "List the contents of a directory."
   :parameters '(:|type| "object"
                 :|properties|
                 (:|path| (:|type| "string" :|description| "Directory path (default: .)"))
                 :|required| #()))

  registry)

(defun make-builtin-registry (&key workdir)
  "Create a new TOOL-REGISTRY pre-loaded with built-in tools.
WORKDIR — optional default working directory for exec."
  (register-builtin-tools (clambda/tools:make-tool-registry) :workdir workdir))
