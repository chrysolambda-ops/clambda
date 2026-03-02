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

(defun %url-p (s)
  (and (stringp s)
       (> (length s) 0)
       (or (search "http://" s :test #'char-equal)
           (search "https://" s :test #'char-equal))))

(defun %image-path-or-url-p (s)
  (and (stringp s)
       (> (length s) 0)
       (or (%url-p s)
           (probe-file s))))

(defun %read-file-octets (path)
  (with-open-file (in path :direction :input :element-type '(unsigned-byte 8))
    (let* ((size (file-length in))
           (buf (make-array size :element-type '(unsigned-byte 8))))
      (read-sequence buf in)
      buf)))

(defun %path->mime-type (path)
  (let ((type (and path (pathname-type path))))
    (cond
      ((and type (string-equal type "png")) "image/png")
      ((and type (or (string-equal type "jpg") (string-equal type "jpeg"))) "image/jpeg")
      ((and type (string-equal type "gif")) "image/gif")
      ((and type (string-equal type "webp")) "image/webp")
      (t "image/png"))))

(defun %encode-image-base64 (path)
  (when (and path (probe-file path))
    (cl-base64:usb8-array-to-base64-string (%read-file-octets path))))

(defun %config-value (name)
  (ignore-errors
    (let* ((pkg (find-package '#:clawmacs/config))
           (sym (and pkg (find-symbol name pkg))))
      (and sym (boundp sym) (symbol-value sym)))))

(defun %resolve-vision-client-settings ()
  (let ((vision-base (%config-value "*VISION-BASE-URL*"))
        (vision-model (%config-value "*VISION-MODEL*"))
        (default-model (%config-value "*DEFAULT-MODEL*"))
        (telegram-base (ignore-errors
                         (let* ((pkg (find-package '#:clawmacs/telegram))
                                (sym (and pkg (find-symbol "*TELEGRAM-LLM-BASE-URL*" pkg))))
                           (and sym (boundp sym) (symbol-value sym))))))
    (values (or vision-base telegram-base "http://192.168.1.189:1234/v1")
            (or vision-model default-model))))

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

  ;; ── web-search (Gemini Search Grounding) ─────────────────────────────────
  (clawmacs/tools:register-tool!
   registry
   "web_search"
   (lambda (args)
     (let* ((query (gethash "query" args))
            (api-key (%config-value "*GEMINI-API-KEY*")))
       (cond
         ((or (null query) (string= query ""))
          (clawmacs/tools:tool-result-error "No query provided"))
         ((or (null api-key) (string= api-key ""))
          (clawmacs/tools:tool-result-error
           "web_search requires a Gemini API key. Set *gemini-api-key* in init.lisp."))
         (t
          (handler-case
              (let* ((endpoint
                       (format nil
                               "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=~a"
                               api-key))
                     (body
                       (with-output-to-string (s)
                         (com.inuoe.jzon:stringify
                          (let ((ht (make-hash-table :test #'equal)))
                            (setf (gethash "contents" ht)
                                  (vector
                                   (let ((c (make-hash-table :test #'equal)))
                                     (setf (gethash "parts" c)
                                           (vector
                                            (let ((p (make-hash-table :test #'equal)))
                                              (setf (gethash "text" p) query)
                                              p)))
                                     c)))
                            (setf (gethash "tools" ht)
                                  (vector
                                   (let ((t- (make-hash-table :test #'equal)))
                                     (setf (gethash "google_search" t-)
                                           (make-hash-table :test #'equal))
                                     t-)))
                            ht)
                          :stream s)))
                     (raw-response
                       (dexador:post endpoint
                                     :content body
                                     :headers '(("Content-Type" . "application/json"))
                                     :force-string t))
                     (parsed (com.inuoe.jzon:parse raw-response))
                     ;; Extract text from candidates[0].content.parts[0].text
                     (candidates (gethash "candidates" parsed))
                     (first-candidate (and candidates (> (length candidates) 0)
                                           (aref candidates 0)))
                     (content (and first-candidate
                                   (gethash "content" first-candidate)))
                     (parts (and content (gethash "parts" content)))
                     (text (and parts (> (length parts) 0)
                                (gethash "text" (aref parts 0))))
                     ;; Extract grounding metadata (citations)
                     (grounding-meta (and first-candidate
                                          (gethash "groundingMetadata" first-candidate)))
                     (chunks (and grounding-meta
                                  (gethash "groundingChunks" grounding-meta))))
                (clawmacs/tools:tool-result-ok
                 (with-output-to-string (out)
                   (when text (write-string text out))
                   (when (and chunks (> (length chunks) 0))
                     (format out "~%~%Sources:~%")
                     (loop :for i :below (length chunks)
                           :for chunk = (aref chunks i)
                           :for web = (gethash "web" chunk)
                           :when web
                             :do (format out "  [~a] ~a~@[ — ~a~]~%"
                                         (1+ i)
                                         (or (gethash "uri" web) "")
                                         (gethash "title" web)))))))
            (dexador:http-request-failed (e)
              (clawmacs/tools:tool-result-error
               (format nil "Gemini API request failed: ~a" e)))
            (error (e)
              (clawmacs/tools:tool-result-error
               (format nil "web_search failed: ~a" e))))))))
   :description
   "Search the web using the Gemini API with Google Search grounding.
Returns an AI-synthesized answer with citations. Requires *gemini-api-key* to be set."
   :parameters '(:|type| "object"
                 :|properties|
                 (:|query| (:|type| "string"
                            :|description| "Search query"))
                 :|required| #("query")))

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

  ;; ── image-analyze (vision) ──────────────────────────────────────────
  (clawmacs/tools:register-tool!
   registry
   "image_analyze"
   (lambda (args)
     (let ((image (gethash "image" args))
           (prompt (or (gethash "prompt" args)
                       "Describe this image in detail.")))
       (cond
         ((or (null image) (string= image ""))
          (clawmacs/tools:tool-result-error "image is required"))
         ((not (and (boundp 'clawmacs/config::*model-supports-vision*)
                    clawmacs/config::*model-supports-vision*))
          (clawmacs/tools:tool-result-error
           "Image analysis disabled: set clawmacs/config::*model-supports-vision* to T and configure a vision-capable model."))
         ((not (%image-path-or-url-p image))
          (clawmacs/tools:tool-result-error
           (format nil "Image not found or invalid URL/path: ~a" image)))
         (t
          (handler-case
              (multiple-value-bind (base-url model)
                  (%resolve-vision-client-settings)
                (unless (and model (not (string= model "")))
                  (error "No vision/default model configured. Set *vision-model* or *default-model*."))
                (let* ((client (cl-llm:make-client :base-url base-url
                                                   :api-key "lm-studio"
                                                   :model model))
                       (image-url (if (%url-p image)
                                      image
                                      (let ((encoded (%encode-image-base64 image)))
                                        (unless encoded
                                          (error "Failed to encode image: ~a" image))
                                        (format nil "data:~a;base64,~a"
                                                (%path->mime-type image)
                                                encoded))))
                       (content (list
                                 (let ((txt (make-hash-table :test #'equal)))
                                   (setf (gethash "type" txt) "text")
                                   (setf (gethash "text" txt) prompt)
                                   txt)
                                 (let ((img (make-hash-table :test #'equal))
                                       (img-url (make-hash-table :test #'equal)))
                                   (setf (gethash "type" img) "image_url")
                                   (setf (gethash "url" img-url) image-url)
                                   (setf (gethash "image_url" img) img-url)
                                   img)))
                       (response (cl-llm:chat client
                                              (list (cl-llm:user-message content))
                                              :model model))
                       (choice (first (cl-llm:response-choices response)))
                       (msg (and choice (cl-llm:choice-message choice)))
                       (answer (and msg (cl-llm:message-content msg))))
                  (if answer
                      (clawmacs/tools:tool-result-ok answer)
                      (clawmacs/tools:tool-result-error "Vision model returned no content."))))
            (error (e)
              (clawmacs/tools:tool-result-error
               (format nil "image_analyze failed: ~a" e))))))))
   :description "Analyze an image using a vision-capable model."
   :parameters '(:|type| "object"
                 :|properties|
                 (:|image| (:|type| "string" :|description| "Image file path or URL")
                  :|prompt| (:|type| "string" :|description| "Analysis prompt (default: describe the image)"))
                 :|required| #("image")))

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

  ;; OpenClaw-compatible alias
  (clawmacs/tools:register-tool!
   registry
   "message"
   (lambda (args)
     (let ((target (or (gethash "target" args) (gethash "agent" args)))
           (text (or (gethash "message" args) (gethash "text" args))))
       (if (or (null target) (null text)
               (string= target "") (string= text ""))
           (clawmacs/tools:tool-result-error "target/agent and message/text are required")
           (if (clawmacs/registry:send-to-agent target text)
               (clawmacs/tools:tool-result-ok (format nil "Sent message to ~a" target))
               (clawmacs/tools:tool-result-error (format nil "Agent not found: ~a" target))))))
   :description "OpenClaw-style message tool alias for inter-agent delivery."
   :parameters '(:|type| "object"
                 :|properties|
                 (:|target| (:|type| "string")
                  :|agent| (:|type| "string")
                  :|message| (:|type| "string")
                  :|text| (:|type| "string"))
                 :|required| #()))

  ;; OpenClaw-compatible file tool aliases
  (clawmacs/tools:register-tool! registry "read"
                                 (lambda (args)
                                   (let ((path (or (gethash "path" args)
                                                   (gethash "file_path" args))))
                                     (if (or (null path) (string= path ""))
                                         (clawmacs/tools:tool-result-error "path is required")
                                         (handler-case
                                             (clawmacs/tools:tool-result-ok (uiop:read-file-string path))
                                           (error (e)
                                             (clawmacs/tools:tool-result-error
                                              (format nil "read failed: ~a" e)))))))
                                 :description "Alias of read_file"
                                 :parameters '(:|type| "object" :|properties| (:|path| (:|type| "string") :|file_path| (:|type| "string")) :|required| #()))
  (clawmacs/tools:register-tool! registry "write"
                                 (lambda (args)
                                   (let ((path (or (gethash "path" args) (gethash "file_path" args)))
                                         (content (gethash "content" args)))
                                     (if (or (null path) (null content))
                                         (clawmacs/tools:tool-result-error "path/file_path and content are required")
                                         (handler-case
                                             (progn
                                               (ensure-directories-exist path)
                                               (with-open-file (out path :direction :output :if-exists :supersede :if-does-not-exist :create)
                                                 (write-string content out))
                                               (clawmacs/tools:tool-result-ok (format nil "Wrote ~a bytes" (length content))))
                                           (error (e)
                                             (clawmacs/tools:tool-result-error (format nil "write failed: ~a" e)))))))
                                 :description "Alias of write_file"
                                 :parameters '(:|type| "object" :|properties| (:|path| (:|type| "string") :|file_path| (:|type| "string") :|content| (:|type| "string")) :|required| #("content")))

  ;; Session + subagent parity tools (minimal but functional)
  (clawmacs/tools:register-tool!
   registry "sessions_list"
   (lambda (_args)
     (declare (ignore _args))
     (let ((sessions (clawmacs/http-server:list-http-sessions)))
       (clawmacs/tools:tool-result-ok
        (with-output-to-string (s)
          (format s "Sessions: ~a~%" (length sessions))
          (dolist (sess sessions)
            (format s "- ~a (~a msgs)~%"
                    (clawmacs/session:session-id sess)
                    (length (clawmacs/session:session-messages sess))))))))
   :description "List active API sessions."
   :parameters '(:|type| "object" :|properties| () :|required| #()))

  (clawmacs/tools:register-tool!
   registry "session_status"
   (lambda (_args)
     (declare (ignore _args))
     (clawmacs/tools:tool-result-ok
      (format nil "agents=~a sessions=~a tasks=~a"
              (length (clawmacs/registry:list-agents))
              (length (clawmacs/http-server:list-http-sessions))
              (length (clawmacs/cron:list-tasks)))))
   :description "Return compact runtime/session status summary."
   :parameters '(:|type| "object" :|properties| () :|required| #()))

  (clawmacs/tools:register-tool!
   registry "sessions_spawn"
   (lambda (args)
     (let* ((agent-name (gethash "agent" args))
            (session-id (or (gethash "session_id" args)
                            (format nil "tool-session-~a" (get-universal-time))))
            (entry (and agent-name (clawmacs/registry:find-agent agent-name)))
            (agent (typecase entry
                     (clawmacs/registry:agent-spec (clawmacs/registry:instantiate-agent-spec entry))
                     (clawmacs/agent:agent entry)
                     (t nil))))
       (if (null agent)
           (clawmacs/tools:tool-result-error "agent is required and must exist")
           (progn
             (clawmacs/http-server:http-session-create session-id agent)
             (clawmacs/tools:tool-result-ok (format nil "spawned ~a for ~a" session-id agent-name))))))
   :description "Create a named session for an agent."
   :parameters '(:|type| "object" :|properties| (:|agent| (:|type| "string") :|session_id| (:|type| "string")) :|required| #("agent")))

  (clawmacs/tools:register-tool!
   registry "sessions_send"
   (lambda (args)
     (let* ((session-id (gethash "session_id" args))
            (text (or (gethash "message" args) (gethash "text" args)))
            (sess (and session-id (clawmacs/http-server:http-session-get session-id))))
       (cond
         ((null session-id) (clawmacs/tools:tool-result-error "session_id required"))
         ((null text) (clawmacs/tools:tool-result-error "message/text required"))
         ((null sess) (clawmacs/tools:tool-result-error (format nil "session not found: ~a" session-id)))
         (t (clawmacs/tools:tool-result-ok
             (clawmacs/loop:run-agent sess text :options (clawmacs/loop:make-loop-options :max-turns 6)))))))
   :description "Send a message to an existing session and return response text."
   :parameters '(:|type| "object" :|properties| (:|session_id| (:|type| "string") :|message| (:|type| "string") :|text| (:|type| "string")) :|required| #("session_id")))

  (clawmacs/tools:register-tool!
   registry "subagents"
   (lambda (args)
     (let ((action (or (gethash "action" args) "list"))
           (target (gethash "target" args)))
       (cond
         ((string= action "list")
          (let ((hs (clawmacs/subagents:list-subagents)))
            (clawmacs/tools:tool-result-ok
             (with-output-to-string (s)
               (format s "Subagents: ~a~%" (length hs))
               (dolist (h hs)
                 (format s "- ~a : ~a~%"
                         (clawmacs/subagents:subagent-handle-id h)
                         (clawmacs/subagents:subagent-handle-status h)))))))
         ((string= action "kill")
          (let ((h (and target (clawmacs/subagents:find-subagent target))))
            (if h
                (progn
                  (clawmacs/subagents:subagent-kill h)
                  (clawmacs/tools:tool-result-ok (format nil "killed ~a" target)))
                (clawmacs/tools:tool-result-error "subagent not found"))))
         ((string= action "steer")
          (let* ((h (and target (clawmacs/subagents:find-subagent target)))
                 (msg (or (gethash "message" args) (gethash "text" args))))
            (cond
              ((null h) (clawmacs/tools:tool-result-error "subagent not found"))
              ((null msg) (clawmacs/tools:tool-result-error "message/text required for steer"))
              ((eq (clawmacs/subagents:subagent-status h) :running)
               (clawmacs/tools:tool-result-error "subagent is still running; steer after completion"))
              (t
               (clawmacs/tools:tool-result-ok
                (clawmacs/loop:run-agent (clawmacs/subagents:subagent-handle-session h)
                                         msg
                                         :options (clawmacs/loop:make-loop-options :max-turns 6)))))))
         (t (clawmacs/tools:tool-result-error "unsupported action (supported: list, kill, steer)")))))
   :description "Subagents control tool: action=list|kill|steer"
   :parameters '(:|type| "object" :|properties| (:|action| (:|type| "string") :|target| (:|type| "string") :|message| (:|type| "string") :|text| (:|type| "string")) :|required| #()))

  ;; ── eval-lisp (Emacs scratch buffer) ────────────────────────────────────────
  (clawmacs/tools:register-tool!
   registry
   "eval_lisp"
   (lambda (args)
     (let ((code (gethash "code" args)))
       (if (or (null code) (string= code ""))
           (clawmacs/tools:tool-result-error "No code provided")
           (handler-case
               (let* ((output
                        (with-output-to-string (*standard-output*)
                          (let* ((forms (with-input-from-string (in code)
                                          (loop :for form = (read in nil '#:eof)
                                                :until (eq form '#:eof)
                                                :collect form)))
                                 (results (mapcar #'eval forms)))
                            (format t "~{~s~^~%~}" results))))
                      (trimmed (string-trim '(#\Space #\Newline #\Return #\Tab) output)))
                 (clawmacs/tools:tool-result-ok
                  (if (string= trimmed "") "nil" trimmed)))
             (error (e)
               (clawmacs/tools:tool-result-error
                (format nil "eval error: ~a" e)))))))
   :description
   "Execute arbitrary Common Lisp code in the running SBCL image. Like the Emacs scratch buffer.
Input: code — string containing Lisp forms to evaluate.
Output: printed result values.
Examples: (+ 1 2) → 3, (clawmacs/config:*default-model*) → current model string."
   :parameters '(:|type| "object"
                 :|properties|
                 (:|code| (:|type| "string" :|description| "Common Lisp forms to evaluate"))
                 :|required| #("code")))

  ;; ── describe-variable (M-x describe-variable) ───────────────────────────────
  (clawmacs/tools:register-tool!
   registry
   "describe_variable"
   (lambda (args)
     (let ((name (gethash "name" args)))
       (if (or (null name) (string= name ""))
           (clawmacs/tools:tool-result-error "No variable name provided")
           (handler-case
               (let* ((sym (read-from-string name))
                      (pkg (symbol-package sym))
                      (pkg-name (if pkg (package-name pkg) "uninterned")))
                 (if (boundp sym)
                     (let* ((val (symbol-value sym))
                            (doc (documentation sym 'variable))
                            (typ (type-of val)))
                       (clawmacs/tools:tool-result-ok
                        (format nil "Variable: ~a~%Package:  ~a~%Type:     ~a~%Value:    ~s~%~@[Doc: ~a~%~]"
                                sym pkg-name typ val doc)))
                     (clawmacs/tools:tool-result-error
                      (format nil "~a is not bound" name))))
             (error (e)
               (clawmacs/tools:tool-result-error
                (format nil "describe-variable error: ~a" e)))))))
   :description
   "Like M-x describe-variable in Emacs. Shows current value, type, package, and documentation for a symbol.
Input: name — symbol name string (e.g. \"clawmacs/config:*default-model*\").
Output: value, type, package, docstring."
   :parameters '(:|type| "object"
                 :|properties|
                 (:|name| (:|type| "string" :|description| "Symbol name (e.g. \"clawmacs/config:*default-model*\")"))
                 :|required| #("name")))

  ;; ── describe-function (M-x describe-function) ──────────────────────────────
  (clawmacs/tools:register-tool!
   registry
   "describe_function"
   (lambda (args)
     (let ((name (gethash "name" args)))
       (if (or (null name) (string= name ""))
           (clawmacs/tools:tool-result-error "No function name provided")
           (handler-case
               (let* ((sym (read-from-string name))
                      (pkg (symbol-package sym))
                      (pkg-name (if pkg (package-name pkg) "uninterned")))
                 (if (fboundp sym)
                     (let* ((fn     (symbol-function sym))
                            (doc    (documentation sym 'function))
                            (llist  (handler-case
                                        (sb-introspect:function-lambda-list fn)
                                      (error () '(:unknown))))
                            (srcs   (handler-case
                                        (sb-introspect:find-definition-sources-by-name
                                         sym :function)
                                      (error () nil)))
                            (src-file (when srcs
                                        (handler-case
                                            (sb-introspect:definition-source-pathname
                                             (first srcs))
                                          (error () nil)))))
                       (clawmacs/tools:tool-result-ok
                        (format nil "Function: ~a~%Package:  ~a~%Lambda list: ~s~%~@[Source: ~a~%~]~@[Doc: ~a~%~]"
                                sym pkg-name llist src-file doc)))
                     (clawmacs/tools:tool-result-error
                      (format nil "~a is not a function" name))))
             (error (e)
               (clawmacs/tools:tool-result-error
                (format nil "describe-function error: ~a" e)))))))
   :description
   "Like M-x describe-function in Emacs. Shows arglist, docstring, and source file for a function.
Input: name — function name string (e.g. \"clawmacs/loop:run-agent\").
Output: lambda list, documentation, source file."
   :parameters '(:|type| "object"
                 :|properties|
                 (:|name| (:|type| "string" :|description| "Function name (e.g. \"clawmacs/loop:run-agent\")"))
                 :|required| #("name")))

  ;; ── apropos-search (M-x apropos) ────────────────────────────────────────────
  (clawmacs/tools:register-tool!
   registry
   "apropos_search"
   (lambda (args)
     (let* ((query   (gethash "query" args))
            (pkg-str (gethash "package" args))
            (pkg     (when pkg-str
                       (find-package (string-upcase pkg-str)))))
       (if (or (null query) (string= query ""))
           (clawmacs/tools:tool-result-error "No query provided")
           (handler-case
               (let* ((syms (apropos-list query pkg))
                      (limit 50)
                      (shown (if (> (length syms) limit)
                                 (subseq syms 0 limit)
                                 syms)))
                 (clawmacs/tools:tool-result-ok
                  (with-output-to-string (s)
                    (format s "~a matches for ~s~@[ in ~a~]:~%"
                            (length syms) query pkg-str)
                    (dolist (sym shown)
                      (let* ((kind (cond
                                     ((fboundp sym) (if (macro-function sym) "macro" "function"))
                                     ((boundp sym)  "variable")
                                     ((find-class sym nil) "class")
                                     (t "symbol")))
                             (pkg  (symbol-package sym))
                             (qname (if pkg
                                        (format nil "~a:~a"
                                                (package-name pkg)
                                                (symbol-name sym))
                                        (symbol-name sym))))
                        (format s "  ~a  [~a]~%" qname kind)))
                    (when (> (length syms) limit)
                      (format s "  ... (~a more)~%" (- (length syms) limit))))))
             (error (e)
               (clawmacs/tools:tool-result-error
                (format nil "apropos error: ~a" e)))))))
   :description
   "Like M-x apropos in Emacs. Searches for symbols matching a string pattern.
Input: query — search string. Optional: package — restrict to a package name.
Output: list of matching symbols with their types (function, variable, class, etc.)."
   :parameters '(:|type| "object"
                 :|properties|
                 (:|query|   (:|type| "string" :|description| "Pattern to search for")
                  :|package| (:|type| "string" :|description| "Optional package name to restrict search"))
                 :|required| #("query")))

  ;; ── clawmacs-help ────────────────────────────────────────────────────────────
  (clawmacs/tools:register-tool!
   registry
   "clawmacs_help"
   (let ((topics
          (let ((ht (make-hash-table :test #'equal)))
            (setf (gethash "overview" ht)
                  "# Clawmacs — AI Agent Platform in Common Lisp

Clawmacs is a libre AI agent platform written in pure Common Lisp (SBCL).
It is a ground-up rewrite of OpenClaw — the language it was always meant to be written in.

## What Makes Clawmacs Special
- Pure Common Lisp (SBCL) — no Python, no Node, no JavaScript runtime
- Emacs-inspired: configured via ~/.clawmacs/init.lisp (real Lisp, not JSON/YAML)
- Local-first: LM Studio, Ollama, cloud fallback via OpenRouter
- Condition system: live error recovery without crashing
- SWANK/SLIME: connect with M-x slime-connect for live inspection and hot reload
- Multi-channel: Telegram, IRC, HTTP API
- Lisp introspection superpowers: eval_lisp, describe_variable, describe_function, apropos_search
- AGPL-3.0 licensed

## Topics
Use clawmacs_help with topic: tools, commands, config, agents, lisp, channels")
            (setf (gethash "tools" ht)
                  "# Clawmacs Built-in Tools

## Shell & Files
- exec — Run shell commands (bash)
- read_file — Read file contents
- write_file — Write text to a file
- list_directory — List directory contents

## Web
- web_fetch — Fetch a URL, strip HTML to plain text
- web_search — Google Search via Gemini API (requires *gemini-api-key*)

## Media
- tts — Text to speech (espeak-ng, espeak, piper, or say)
- image_analyze — Analyze images with a vision model

## Memory
- memory_search — Search MEMORY.md and memory/*.md in workspace

## Lisp Introspection (Clawmacs Superpower)
- eval_lisp — Execute any CL code in the running image
- describe_variable — Like M-x describe-variable: value, type, doc
- describe_function — Like M-x describe-function: arglist, doc, source
- apropos_search — Like M-x apropos: find symbols by pattern

## Inter-Agent
- send_message — Send a message to another registered agent

## Help
- clawmacs_help — This help system (topic: tools, commands, config, agents, lisp, channels)")
            (setf (gethash "commands" ht)
                  "# Telegram Bot Commands

- /new or /reset — Start a fresh conversation (clears history)
- /status — Show session info: model, uptime, message count, tokens
- /model — Show current model
- /model <name> — Switch to a different model (e.g. /model anthropic/claude-opus-4-6)
- /help — Show command list

Any other message is sent to the AI agent.")
            (setf (gethash "config" ht)
                  "# Clawmacs Configuration

Config file: ~/.clawmacs/init.lisp (loaded at startup, full Common Lisp)

## Key Config Variables
- *default-model* — LLM model identifier
- *default-max-turns* — max agent loop turns per message (default: 10)
- *default-context-window* — context window size for compaction
- *compaction-enabled* — whether to compact history when full
- *workspace-inject-files* — list of files injected into system prompt
- *heartbeat-interval* — seconds between agent heartbeats

## Channel Registration
In init.lisp:
  (register-channel :telegram :token \"TOKEN\" :allowed-users '(12345))
  (register-channel :irc :server \"irc.example.com\" :port 6697 :tls t :nick \"bot\")

## LLM Provider
  (setf clawmacs/telegram:*telegram-llm-base-url* \"https://openrouter.ai/api/v1\")
  (setf clawmacs/telegram:*telegram-llm-api-key* \"sk-or-...\")
  (setf *default-model* \"anthropic/claude-opus-4-6\")

## Useful eval_lisp Examples
  (eval_lisp \"clawmacs/config:*default-model*\")     ; check current model
  (eval_lisp \"(clawmacs/telegram:telegram-running-p)\") ; check Telegram status
  (eval_lisp \"(describe-options)\")                   ; list all config options")
            (setf (gethash "agents" ht)
                  "# Clawmacs Agent System

## Architecture
- Agent — struct with name, model, client, tool registry, system prompt
- Session — per-conversation state: message history, token count, agent
- Agent Loop — multi-turn LLM conversation with tool calling

## Defining Agents (init.lisp)
  (define-agent my-agent
    :display-name \"My Agent\"
    :model \"anthropic/claude-opus-4-6\"
    :workspace \"~/.clawmacs/agents/my-agent/\"
    :client (make-client :base-url \"https://openrouter.ai/api/v1\"
                         :api-key \"sk-or-...\"))

## Workspace Files
Each agent has a workspace directory with:
- AGENTS.md  — role definition and session checklist
- SOUL.md    — personality and principles
- TOOLS.md   — tool-specific notes
- IDENTITY.md — name, role, emoji
- USER.md    — notes about the human
- HEARTBEAT.md — heartbeat config
- MEMORY.md  — long-term memory

These are injected into the system prompt automatically.

## Agent Loop
run-agent: user message → LLM → tool calls → results → LLM → ... → final response
Max turns controlled by *default-max-turns* (default: 10).")
            (setf (gethash "lisp" ht)
                  "# Lisp Introspection in Clawmacs

Clawmacs agents can introspect and modify their own running Lisp image.
This is a superpower that OpenClaw doesn't have.

## eval_lisp — Execute Lisp code
  (+ 1 2)                                          ; → 3
  clawmacs/config:*default-model*                  ; → current model
  (clawmacs/telegram:telegram-running-p)           ; → T if bot is running
  (mapcar #'car clawmacs/registry:*agent-registry*) ; → list of agent names
  (ql:quickload :my-library)                       ; load a Quicklisp library
  (load \"~/.clawmacs/init.lisp\")                  ; hot-reload config

## describe_variable — Inspect a variable
  name: \"clawmacs/config:*default-model*\"
  → shows current value, type, package, docstring

## describe_function — Inspect a function
  name: \"clawmacs/loop:run-agent\"
  → shows lambda list, docstring, source file

## apropos_search — Find symbols by pattern
  query: \"telegram\"     ; → all symbols containing 'telegram'
  package: \"clawmacs/telegram\"  ; restrict to that package

## Practical Uses
- Check config: (eval_lisp \"clawmacs/config:*default-model*\")
- List tools: (eval_lisp \"(clawmacs/tools:list-tools clawmacs/builtins:*default-registry*)\")
- Hot-patch: (eval_lisp \"(setf clawmacs/config:*default-max-turns* 20)\")
- Debug: (eval_lisp \"(describe 'clawmacs/loop:run-agent)\")")
            (setf (gethash "channels" ht)
                  "# Clawmacs Channels

## Telegram (Layer 6b)
Long-polling bot. One session per chat_id.
Config: register-channel :telegram
Start: (clawmacs/telegram:start-telegram)
Status: (clawmacs/telegram:telegram-running-p)
Commands: /new /status /model /help

## IRC (Layer 6c)
Raw IRC protocol over TCP/TLS (usocket + cl+ssl).
Config: register-channel :irc
Start: (clawmacs/irc:start-irc)
Status: (clawmacs/irc:irc-running-p)
Trigger: prefix with bot nick or set :trigger-prefix

## HTTP API (Layer 8b)
Hunchentoot server. REST API for agent control.
Start: (clawmacs/http-server:start-server)
Default port: 7070
Auth: set *api-token* in init.lisp

## SWANK/SLIME (Lisp Superpowers P0)
Connect with M-x slime-connect, host localhost, port 4006.
Gives live SLIME inspection, hot reload, debugging of running bot.
Start: (clawmacs/swank:start-swank)")
            ht)))
     (lambda (args)
       (let* ((topic (or (gethash "topic" args) "overview"))
              (text  (or (gethash topic topics)
                         (gethash "overview" topics))))
         (clawmacs/tools:tool-result-ok text))))
   :description
   "Get help about Clawmacs capabilities and commands.
No topic or topic='overview': general overview. Topics: tools, commands, config, agents, lisp, channels."
   :parameters '(:|type| "object"
                 :|properties|
                 (:|topic| (:|type| "string"
                            :|description| "Help topic: overview (default), tools, commands, config, agents, lisp, channels"))
                 :|required| #()))

  registry)

(defun make-builtin-registry (&key workdir)
  "Create a new TOOL-REGISTRY pre-loaded with built-in tools.
WORKDIR — optional default working directory for exec."
  (register-builtin-tools (clawmacs/tools:make-tool-registry) :workdir workdir))
