;;;; src/builtins.lisp — Built-in tools: exec, read-file, write-file, web-fetch

(in-package #:clawmacs/builtins)

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
                               . "Mozilla/5.0 (compatible; clawmacs-agent/0.1)"))
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

;;; ── TTS helpers ──────────────────────────────────────────────────────────────

(defvar *tts-command* :auto
  "TTS command to use. :auto = probe at runtime. NIL = disabled.
String = explicit command (e.g. \"espeak-ng\").")

(defun find-tts-command ()
  "Probe for an available TTS binary. Returns a command string or NIL."
  (loop :for candidate :in '("espeak-ng" "espeak" "piper" "say")
        :when (handler-case
                  (zerop (nth-value 2
                           (uiop:run-program
                            (list "/bin/bash" "-c"
                                  (format nil "command -v ~a" candidate))
                            :ignore-error-status t
                            :output nil
                            :error-output nil)))
                (error () nil))
        :return candidate))

(defun tts-speak (text)
  "Speak TEXT using the first available TTS engine.
Returns a TOOL-RESULT-OK with a status message, or TOOL-RESULT-OK
with 'TTS not available' if no engine is found (graceful no-op)."
  (let* ((cmd (if (eq *tts-command* :auto)
                  (find-tts-command)
                  *tts-command*)))
    (if cmd
        (handler-case
            (progn
              (uiop:run-program (list "/bin/bash" "-c"
                                     (format nil "~a ~s" cmd text))
                                :ignore-error-status t
                                :output nil
                                :error-output nil)
              (let ((preview (if (> (length text) 60)
                                 (concatenate 'string (subseq text 0 60) "...")
                                 text)))
                (clawmacs/tools:tool-result-ok
                 (format nil "Spoke via ~a: ~s" cmd preview))))
          (error (e)
            (clawmacs/tools:tool-result-error
             (format nil "TTS error using ~a: ~a" cmd e))))
        (clawmacs/tools:tool-result-ok
         "TTS not available: no espeak-ng/espeak/piper/say found on PATH. Text not spoken."))))

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
  (clawmacs/tools:register-tool!
   registry
   "exec"
   (lambda (args)
     (let ((command (gethash "command" args))
           (cwd     (or (gethash "workdir" args) workdir)))
       (cond
         ((or (null command) (string= command ""))
          (clawmacs/tools:tool-result-error "No command provided"))
         (t
          (handler-case
              (multiple-value-bind (stdout stderr exit-code)
                  (run-shell-command command :workdir cwd)
                (let ((combined (concatenate
                                 'string stdout
                                 (if (and stderr (not (string= stderr "")))
                                     (format nil "~%[stderr]~%~a" stderr)
                                     ""))))
                  (clawmacs/tools:tool-result-ok
                   (format nil "exit-code: ~a~%~a" exit-code combined))))
            (error (e)
              (clawmacs/tools:tool-result-error
               (format nil "exec failed: ~a" e))))))))
   :description "Execute a shell command and return its output."
   :parameters '(:|type| "object"
                 :|properties|
                 (:|command| (:|type| "string" :|description| "Shell command to run")
                  :|workdir| (:|type| "string" :|description| "Optional working directory"))
                 :|required| #("command")))

  ;; ── read-file ──────────────────────────────────────────────────────────────
  (clawmacs/tools:register-tool!
   registry
   "read_file"
   (lambda (args)
     (let ((path (gethash "path" args)))
       (cond
         ((or (null path) (string= path ""))
          (clawmacs/tools:tool-result-error "No path provided"))
         (t
          (handler-case
              (clawmacs/tools:tool-result-ok (uiop:read-file-string path))
            (error (e)
              (clawmacs/tools:tool-result-error
               (format nil "read-file failed: ~a" e))))))))
   :description "Read the contents of a file and return it as text."
   :parameters '(:|type| "object"
                 :|properties|
                 (:|path| (:|type| "string" :|description| "Path to the file to read"))
                 :|required| #("path")))

  ;; ── write-file ─────────────────────────────────────────────────────────────
  (clawmacs/tools:register-tool!
   registry
   "write_file"
   (lambda (args)
     (let ((path    (gethash "path" args))
           (content (gethash "content" args)))
       (cond
         ((or (null path) (null content))
          (clawmacs/tools:tool-result-error "path and content are required"))
         (t
          (handler-case
              (progn
                (ensure-directories-exist path)
                (with-open-file (out path
                                     :direction :output
                                     :if-exists :supersede
                                     :if-does-not-exist :create)
                  (write-string content out))
                (clawmacs/tools:tool-result-ok
                 (format nil "Written ~a bytes to ~a" (length content) path)))
            (error (e)
              (clawmacs/tools:tool-result-error
               (format nil "write-file failed: ~a" e))))))))
   :description "Write text content to a file, creating it if needed."
   :parameters '(:|type| "object"
                 :|properties|
                 (:|path|    (:|type| "string" :|description| "Path to write to")
                  :|content| (:|type| "string" :|description| "Content to write"))
                 :|required| #("path" "content")))

  ;; ── list-directory ────────────────────────────────────────────────────────
  (clawmacs/tools:register-tool!
   registry
   "list_directory"
   (lambda (args)
     (let ((path (or (gethash "path" args) ".")))
       (handler-case
           (let* ((truepath (uiop:ensure-directory-pathname path))
                  (entries (uiop:directory-files truepath))
                  (subdirs (uiop:subdirectories truepath)))
             (clawmacs/tools:tool-result-ok
              (with-output-to-string (s)
                (dolist (d subdirs)
                  (format s "[dir]  ~a~%"
                          (file-namestring (directory-namestring d))))
                (dolist (f entries)
                  (format s "[file] ~a~%" (file-namestring f))))))
         (error (e)
           (clawmacs/tools:tool-result-error
            (format nil "list-directory failed: ~a" e))))))
   :description "List the contents of a directory."
   :parameters '(:|type| "object"
                 :|properties|
                 (:|path| (:|type| "string" :|description| "Directory path (default: .)"))
                 :|required| #()))

  ;; ── web-fetch ─────────────────────────────────────────────────────────────
  (clawmacs/tools:register-tool!
   registry
   "web_fetch"
   (lambda (args)
     (let* ((url       (gethash "url" args))
            (max-chars (or (gethash "max_chars" args)
                           *web-fetch-default-max-chars*)))
       (cond
         ((or (null url) (string= url ""))
          (clawmacs/tools:tool-result-error "No URL provided"))
         (t
          (handler-case
              (multiple-value-bind (text content-type status)
                  (fetch-url url :max-chars (if (numberp max-chars)
                                                max-chars
                                                *web-fetch-default-max-chars*))
                (declare (ignore content-type))
                (if (and status (>= status 400))
                    (clawmacs/tools:tool-result-error
                     (format nil "HTTP ~a fetching ~a" status url))
                    (clawmacs/tools:tool-result-ok text)))
            (dexador:http-request-failed (e)
              (clawmacs/tools:tool-result-error
               (format nil "HTTP error fetching ~a: ~a" url e)))
            (error (e)
              (clawmacs/tools:tool-result-error
               (format nil "web-fetch failed for ~a: ~a" url e))))))))
   :description "Fetch a URL and return its text content. HTML is stripped to plain text."
   :parameters '(:|type| "object"
                 :|properties|
                 (:|url|       (:|type| "string"
                                :|description| "URL to fetch")
                  :|max_chars| (:|type| "integer"
                                :|description| "Maximum characters to return (default: 50000)"))
                 :|required| #("url")))

  ;; ── tts ───────────────────────────────────────────────────────────────────
  (clawmacs/tools:register-tool!
   registry
   "tts"
   (lambda (args)
     (let ((text (gethash "text" args)))
       (cond
         ((or (null text) (string= text ""))
          (clawmacs/tools:tool-result-error "No text provided"))
         (t
          (tts-speak text)))))
   :description
   "Convert text to speech using the system TTS (espeak-ng, espeak, piper, or say).
Returns a confirmation or 'TTS not available' if no TTS engine is installed."
   :parameters '(:|type| "object"
                 :|properties|
                 (:|text| (:|type| "string"
                           :|description| "The text to speak aloud"))
                 :|required| #("text")))

  ;; ── memory-search ────────────────────────────────────────────────────────
  (clawmacs/tools:register-tool!
   registry
   "memory_search"
   (lambda (args)
     (let* ((query (gethash "query" args))
            (max-results (or (gethash "max_results" args) 5)))
       (if (or (null query) (string= query ""))
           (clawmacs/tools:tool-result-error "No query provided")
           (handler-case
               (let ((hits (clawmacs/memory::memory-search query
                                                          :max-results (if (numberp max-results)
                                                                           max-results
                                                                           5))))
                 (clawmacs/tools:tool-result-ok
                  (if hits
                      (with-output-to-string (s)
                        (dolist (h hits)
                          (format s "[~a] ~a~%~a~%~%"
                                  (getf h :score)
                                  (getf h :file)
                                  (getf h :excerpt))))
                      "No memory matches.")))
             (error (e)
               (clawmacs/tools:tool-result-error
                (format nil "memory_search failed: ~a" e)))))))
   :description "Search MEMORY.md and memory/*.md files in the workspace."
   :parameters '(:|type| "object"
                 :|properties|
                 (:|query| (:|type| "string" :|description| "Search query")
                  :|max_results| (:|type| "integer" :|description| "Maximum results (default 5)"))
                 :|required| #("query")))

  ;; ── send-message (inter-agent) ───────────────────────────────────────────
  (clawmacs/tools:register-tool!
   registry
   "send_message"
   (lambda (args)
     (let ((target (gethash "target" args))
           (message (gethash "message" args)))
       (if (or (null target) (null message)
               (string= target "") (string= message ""))
           (clawmacs/tools:tool-result-error "target and message are required")
           (if (clawmacs/registry:send-to-agent target message)
               (clawmacs/tools:tool-result-ok
                (format nil "Sent message to agent ~a" target))
               (clawmacs/tools:tool-result-error
                (format nil "Agent not found: ~a" target))))))
   :description "Send a message to another registered agent."
   :parameters '(:|type| "object"
                 :|properties|
                 (:|target| (:|type| "string" :|description| "Target agent name")
                  :|message| (:|type| "string" :|description| "Message to send"))
                 :|required| #("target" "message")))

  registry)

(defun make-builtin-registry (&key workdir)
  "Create a new TOOL-REGISTRY pre-loaded with built-in tools.
WORKDIR — optional default working directory for exec."
  (register-builtin-tools (clawmacs/tools:make-tool-registry) :workdir workdir))
