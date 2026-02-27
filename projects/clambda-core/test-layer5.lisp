;;;; test-layer5.lisp — Layer 5 Phase 1 feature tests
;;;; Tests: session persistence, memory system, web-fetch, structured logging

(load "~/quicklisp/setup.lisp")
(asdf:clear-source-registry)
(asdf:initialize-source-registry)
(ql:quickload '(:clawmacs-core :cl-llm) :silent t)

(defpackage #:layer5-test
  (:use #:cl))
(in-package #:layer5-test)

(defvar *pass* 0)
(defvar *fail* 0)

(defmacro check (label form &optional expected)
  `(handler-case
       (let ((result ,form))
         (if (or (null ',expected) result)
             (progn
               (incf *pass*)
               (format t "  PASS  ~a~%" ,label))
             (progn
               (incf *fail*)
               (format t "  FAIL  ~a — got: ~a~%" ,label result))))
     (error (e)
       (incf *fail*)
       (format t "  FAIL  ~a — error: ~a~%" ,label e))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Task 1.0: *on-stream-delta* re-exported from clawmacs package
;;; ─────────────────────────────────────────────────────────────────────────────

(format t "~%=== Task 1.0: *on-stream-delta* re-export ===~%")

(check "*on-stream-delta* exported from clawmacs"
       (find-symbol "*ON-STREAM-DELTA*" :clawmacs))

(check "*on-stream-delta* is same object as clawmacs/loop version"
       (eq (find-symbol "*ON-STREAM-DELTA*" :clawmacs)
           (find-symbol "*ON-STREAM-DELTA*" :clawmacs/loop)))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Task 1.1: Session persistence (save/load)
;;; ─────────────────────────────────────────────────────────────────────────────

(format t "~%=== Task 1.1: Session Persistence ===~%")

(let* ((client (cl-llm:make-client
                :base-url "http://192.168.1.189:1234/v1"
                :api-key "not-needed"
                :model "google/gemma-3-4b"))
       (agent  (clawmacs:make-agent
                :name "test-agent"
                :client client
                :model "google/gemma-3-4b"))
       (session (clawmacs:make-session :agent agent))
       (tmpfile (format nil "/tmp/test-session-~a.json"
                        (random 99999))))

  ;; Add some messages
  (clawmacs:session-add-message session (cl-llm/protocol:user-message "Hello!"))
  (clawmacs:session-add-message session (cl-llm/protocol:assistant-message "Hi there!"))
  (clawmacs:session-add-message session (cl-llm/protocol:user-message "How are you?"))

  (check "session has 3 messages before save"
         (= 3 (clawmacs:session-message-count session)))

  ;; Save
  (check "save-session returns path"
         (stringp (clawmacs:save-session session tmpfile)))

  (check "session file exists"
         (probe-file tmpfile))

  ;; Load
  (let ((restored (clawmacs:load-session agent tmpfile)))
    (check "load-session returns a session"
           (typep restored 'clawmacs/session:session))

    (check "restored session has same ID"
           (string= (clawmacs:session-id session)
                    (clawmacs:session-id restored)))

    (check "restored session has 3 messages"
           (= 3 (clawmacs:session-message-count restored)))

    (check "first message is user role"
           (eq :user (cl-llm/protocol:message-role
                      (first (clawmacs:session-messages restored)))))

    (check "first message content correct"
           (string= "Hello!"
                    (cl-llm/protocol:message-content
                     (first (clawmacs:session-messages restored))))))

  ;; Cleanup
  (ignore-errors (delete-file tmpfile)))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Task 1.2: Memory system
;;; ─────────────────────────────────────────────────────────────────────────────

(format t "~%=== Task 1.2: Memory System ===~%")

(let* ((workspace "/home/slime/.openclaw/workspace-gensym")
       (mem (clawmacs:load-workspace-memory workspace)))

  (check "load-workspace-memory returns workspace-memory"
         (typep mem 'clawmacs/memory:workspace-memory))

  (check "workspace-memory has entries"
         (> (length (clawmacs:workspace-memory-entries mem)) 0))

  (check "workspace-memory path is set"
         (> (length (clawmacs/memory:workspace-memory-path mem)) 0))

  ;; Check priority files loaded first
  (let ((first-entry (first (clawmacs:workspace-memory-entries mem))))
    (check "first entry has a name"
           (> (length (clawmacs:memory-entry-name first-entry)) 0))
    (check "first entry has content"
           (> (length (clawmacs:memory-entry-content first-entry)) 0))
    (format t "       (first loaded: ~a)~%"
            (clawmacs:memory-entry-name first-entry)))

  ;; Search
  (let ((results (clawmacs:search-memory mem "Gensym")))
    (check "search returns results for 'Gensym'"
           (> (length results) 0))
    (format t "       (search 'Gensym': ~a matches)~%"
            (length results)))

  ;; Context string
  (let ((ctx (clawmacs:memory-context-string mem)))
    (check "memory-context-string is non-empty"
           (> (length ctx) 0))
    (check "context string contains '# Workspace Memory' header"
           (search "# Workspace Memory" ctx))
    (format t "       (context string length: ~a chars)~%"
            (length ctx))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Task 1.3: Web Fetch built-in
;;; ─────────────────────────────────────────────────────────────────────────────

(format t "~%=== Task 1.3: Web Fetch Built-in ===~%")

;; Test the HTML stripping function directly
(let* ((html "<html><head><title>Test</title><style>.x{}</style></head>
<body><h1>Hello World</h1><p>This is a <b>test</b> page.</p>
<script>alert('hi')</script></body></html>")
       (stripped (clawmacs/builtins::strip-html-tags html)))
  (check "strip-html-tags removes tags"
         (not (search "<html>" stripped)))
  (check "strip-html-tags removes script content"
         (not (search "alert" stripped)))
  (check "strip-html-tags removes style content"
         (not (search ".x{}" stripped)))
  (check "strip-html-tags keeps text content"
         (search "Hello World" stripped))
  (format t "       stripped: ~s~%" stripped))

;; Test web-fetch tool is registered in builtin registry
(let ((registry (clawmacs:make-builtin-registry)))
  (check "web_fetch tool is registered"
         (clawmacs:find-tool registry "web_fetch"))
  (check "exec tool is registered"
         (clawmacs:find-tool registry "exec"))
  (check "read_file tool is registered"
         (clawmacs:find-tool registry "read_file")))

;; Test actual HTTP fetch (httpbin.org is reliable for testing)
(format t "       Testing HTTP fetch (httpbin.org/get)...~%")
(handler-case
    (multiple-value-bind (text ct status)
        (clawmacs/builtins::fetch-url "http://httpbin.org/get" :max-chars 500)
      (check "HTTP fetch returns status 200"
             (= status 200))
      (check "HTTP fetch returns non-empty text"
             (> (length text) 0))
      (format t "       (fetched ~a chars, content-type: ~a)~%" (length text) ct))
  (error (e)
    (incf *fail*)
    (format t "  FAIL  HTTP fetch failed (network?): ~a~%" e)))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Task 1.4: Structured Logging
;;; ─────────────────────────────────────────────────────────────────────────────

(format t "~%=== Task 1.4: Structured Logging ===~%")

(let ((logfile "/tmp/test-clawmacs-log.jsonl"))
  (ignore-errors (delete-file logfile))

  (clawmacs:with-logging (logfile)
    (clawmacs:log-llm-request "test-agent" "gemma-3-4b" 3 :tools-count 4)
    (clawmacs:log-tool-call   "test-agent" "exec" "ls -la")
    (clawmacs:log-tool-result "test-agent" "exec" t 1024)
    (clawmacs:log-error-event "test-agent" "tool_error" "Something went wrong"
                             :context "exec tool")
    (clawmacs:log-event "custom_event" "key" "value" "count" 42))

  (check "log file was created"
         (probe-file logfile))

  (let ((contents (uiop:read-file-string logfile)))
    (check "log file has 5 entries (5 newlines)"
           (= 5 (count #\Newline contents)))

    (check "log contains llm_request event"
           (search "llm_request" contents))
    (check "log contains tool_call event"
           (search "tool_call" contents))
    (check "log contains tool_result event"
           (search "tool_result" contents))
    (check "log contains error event"
           (search "error" contents))
    (check "log contains timestamp field"
           (search "timestamp" contents))
    (check "log contains agent field"
           (search "test-agent" contents))

    ;; Verify each line is valid JSON
    (let ((lines (remove-if #'(lambda (s) (string= s ""))
                            (cl-ppcre:split "\\n" contents))))
      (check "all 5 log lines parse as valid JSON"
             (= 5 (loop :for line :in lines
                        :count (handler-case
                                   (progn (com.inuoe.jzon:parse line) t)
                                 (error () nil)))))
      (format t "       (log file: ~a lines, ~a bytes)~%"
              (length lines) (length contents))))

  ;; Cleanup
  (ignore-errors (delete-file logfile)))

;; Test with-logging disabling
(let ((logfile "/tmp/test-clawmacs-log-disabled.jsonl"))
  (ignore-errors (delete-file logfile))
  (clawmacs:with-logging (logfile :enabled nil)
    (clawmacs:log-event "should-not-appear" "x" 1))
  (check "logging disabled: no file created"
         (not (probe-file logfile))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Summary
;;; ─────────────────────────────────────────────────────────────────────────────

(format t "~%~%=== RESULTS ===~%")
(format t "PASS: ~a~%" *pass*)
(format t "FAIL: ~a~%" *fail*)
(format t "~%")

(uiop:quit (if (zerop *fail*) 0 1))
