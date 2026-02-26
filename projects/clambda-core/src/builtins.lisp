;;;; src/builtins.lisp — Built-in tools: exec, read-file, write-file, web-fetch

(in-package #:clambda/builtins)

;;; ── web-fetch helpers ────────────────────────────────────────────────────────

(defparameter *web-fetch-default-max-chars* 50000
  "Default maximum characters returned by the web-fetch tool.")

(defun strip-html-tags (html)
  "Remove HTML tags from HTML string. Returns plain text (best-effort).
Also collapses whitespace and decodes basic HTML entities."
  ;; Remove <script>...</script> and <style>...</style> blocks first
  (let* ((s html)
         ;; Remove script blocks
         (s (cl-ppcre:regex-replace-all
             "(?si)<script[^>]*>.*?</script>" s ""))
         ;; Remove style blocks
         (s (cl-ppcre:regex-replace-all
             "(?si)<style[^>]*>.*?</style>" s ""))
         ;; Replace block-level tags with newlines
         (s (cl-ppcre:regex-replace-all
             "(?i)</(p|div|h[1-6]|li|tr|br|hr|blockquote|pre|section|article|header|footer|main|nav)[^>]*>" s (format nil "~%")))
         (s (cl-ppcre:regex-replace-all
             "(?i)<(br|hr)[^>]*/>" s (format nil "~%")))
         ;; Remove all remaining tags
         (s (cl-ppcre:regex-replace-all "<[^>]+>" s ""))
         ;; Decode common HTML entities
         (s (cl-ppcre:regex-replace-all "&nbsp;" s " "))
         (s (cl-ppcre:regex-replace-all "&amp;" s "&"))
         (s (cl-ppcre:regex-replace-all "&lt;" s "<"))
         (s (cl-ppcre:regex-replace-all "&gt;" s ">"))
         (s (cl-ppcre:regex-replace-all "&quot;" s "\""))
         (s (cl-ppcre:regex-replace-all "&#39;" s "'"))
         ;; Collapse runs of whitespace / blank lines
         (s (cl-ppcre:regex-replace-all "[ \\t]+" s " "))
         (s (cl-ppcre:regex-replace-all "(\\n[ \\t]*){3,}" s (format nil "~%~%"))))
    (string-trim '(#\Space #\Newline #\Return #\Tab) s)))

(defun fetch-url (url &key (max-chars *web-fetch-default-max-chars*))
  "Fetch URL via dexador and return text content.
HTML is stripped to plain text. Content is truncated to MAX-CHARS.
Returns (values text-string content-type-string status-code)."
  ;; dexador:get returns (values body status headers uri)
  (multiple-value-bind (body status headers)
      (dexador:get url
                   :headers '(("User-Agent"
                               . "Mozilla/5.0 (compatible; clambda-agent/0.1)"))
                   :force-string t)
    (let* ((content-type (or (gethash "content-type" headers) "text/html"))
           (html-p        (search "html" content-type :test #'char-equal))
           (text          (if html-p (strip-html-tags body) body))
           (truncated     (if (and max-chars (> (length text) max-chars))
                              (concatenate 'string
                                           (subseq text 0 max-chars)
                                           (format nil "~%...[truncated at ~a chars]"
                                                   max-chars))
                              text)))
      (values truncated content-type status))))

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

  ;; ── web-fetch ─────────────────────────────────────────────────────────────
  (clambda/tools:register-tool!
   registry
   "web_fetch"
   (lambda (args)
     (let* ((url       (gethash "url" args))
            (max-chars (or (gethash "max_chars" args)
                           *web-fetch-default-max-chars*)))
       (cond
         ((or (null url) (string= url ""))
          (clambda/tools:tool-result-error "No URL provided"))
         (t
          (handler-case
              (multiple-value-bind (text content-type status)
                  (fetch-url url :max-chars (if (numberp max-chars)
                                                max-chars
                                                *web-fetch-default-max-chars*))
                (declare (ignore content-type))
                (if (and status (>= status 400))
                    (clambda/tools:tool-result-error
                     (format nil "HTTP ~a fetching ~a" status url))
                    (clambda/tools:tool-result-ok text)))
            (dexador:http-request-failed (e)
              (clambda/tools:tool-result-error
               (format nil "HTTP error fetching ~a: ~a" url e)))
            (error (e)
              (clambda/tools:tool-result-error
               (format nil "web-fetch failed for ~a: ~a" url e))))))))
   :description "Fetch a URL and return its text content. HTML is stripped to plain text."
   :parameters '(:|type| "object"
                 :|properties|
                 (:|url|       (:|type| "string"
                                :|description| "URL to fetch")
                  :|max_chars| (:|type| "integer"
                                :|description| "Maximum characters to return (default: 50000)"))
                 :|required| #("url")))

  registry)

(defun make-builtin-registry (&key workdir)
  "Create a new TOOL-REGISTRY pre-loaded with built-in tools.
WORKDIR — optional default working directory for exec."
  (register-builtin-tools (clambda/tools:make-tool-registry) :workdir workdir))
