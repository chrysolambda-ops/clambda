;;;; src/browser.lisp — Layer 7: Browser Control
;;;;
;;;; Provides browser automation for Clawmacs agents via a Playwright subprocess.
;;;; Communicates with browser/playwright-bridge.js over JSON-over-stdin/stdout.
;;;;
;;;; Architecture:
;;;;   1. (browser-launch) starts the Node.js bridge as a subprocess via uiop:launch-program
;;;;   2. Each command is written as a JSON line to the bridge's stdin
;;;;   3. Responses are read from the bridge's stdout (one JSON line per command)
;;;;   4. Synchronous protocol: one request → wait for response → return result
;;;;
;;;; Prerequisites:
;;;;   cd browser/ && npm install
;;;;   npx playwright install chromium      (one-time, ~200MB download)
;;;;
;;;; Config (set in init.lisp):
;;;;   (setf *browser-headless* t)
;;;;   (setf *browser-playwright-path* "/usr/bin/node")
;;;;   (setf *browser-bridge-script* "/path/to/playwright-bridge.js")

(in-package #:clawmacs/browser)

;;; ── Config options ───────────────────────────────────────────────────────────

(defoption *browser-headless* t
  :type boolean
  :doc "Run browser in headless mode (no visible window). Default: T.")

(defoption *browser-playwright-path* "node"
  :type string
  :doc "Path to the Node.js executable for the Playwright bridge.")

(defoption *browser-bridge-script*
    (namestring
     (or (ignore-errors
          (asdf:system-relative-pathname :clawmacs-core "browser/playwright-bridge.js"))
         #p"browser/playwright-bridge.js"))
  :type string
  :doc "Path to the playwright-bridge.js script.")

;;; ── State ────────────────────────────────────────────────────────────────────

(defvar *browser-process* nil
  "The currently running playwright-bridge subprocess, or NIL.")

(defvar *browser-stdin* nil
  "Stream to write commands to the bridge subprocess.")

(defvar *browser-stdout* nil
  "Stream to read responses from the bridge subprocess.")

(defvar *browser-lock* (bt:make-lock "browser-lock")
  "Mutex protecting browser state (single request at a time).")

(defvar *browser-request-counter* 0
  "Monotonically increasing request ID counter.")

;;; ── Protocol helpers ─────────────────────────────────────────────────────────

(defun %next-id ()
  "Return a fresh string request ID."
  (incf *browser-request-counter*)
  (format nil "br~d" *browser-request-counter*))

(defun %send-command (command &optional params)
  "Write a JSON command to the bridge stdin. PARAMS is a plist."
  (let* ((id (%next-id))
         (obj (make-hash-table :test #'equal)))
    (setf (gethash "id" obj) id
          (gethash "command" obj) command)
    (when params
      (let ((ht (make-hash-table :test #'equal)))
        (loop for (k v) on params by #'cddr
              do (setf (gethash (string-downcase (string k)) ht) v))
        (setf (gethash "params" obj) ht)))
    (write-string (com.inuoe.jzon:stringify obj) *browser-stdin*)
    (write-char #\Newline *browser-stdin*)
    (finish-output *browser-stdin*)
    id))

(defun %read-response (expected-id)
  "Read one JSON line from the bridge stdout and return the parsed object.
   Skips lines that don't match EXPECTED-ID (e.g., debug output)."
  (loop
    (let ((line (read-line *browser-stdout* nil nil)))
      (when (null line)
        (error "Browser bridge closed unexpectedly."))
      (let ((trimmed (string-trim '(#\Space #\Tab #\Return) line)))
        (when (> (length trimmed) 0)
          (let ((resp (com.inuoe.jzon:parse trimmed :key-fn #'identity)))
            (when (equal (gethash "id" resp) expected-id)
              (return resp))))))))

(defun %call (command &optional params)
  "Send COMMAND with PARAMS, wait for response, return result or signal error."
  (unless *browser-process*
    (error "Browser not launched. Call (browser-launch) first."))
  (bt:with-lock-held (*browser-lock*)
    (let* ((id (%send-command command params))
           (resp (%read-response id)))
      (if (gethash "ok" resp)
          (gethash "result" resp)
          (error "Browser error from ~a: ~a"
                 command
                 (gethash "error" resp "unknown error"))))))

;;; ── Public API ───────────────────────────────────────────────────────────────

(defun browser-launch (&key (headless *browser-headless*))
  "Launch the Playwright bridge subprocess and open a browser.
   If the browser is already running, this is a no-op.
   
   Requires: node, playwright npm package, and installed Chromium browser.
   Run `npx playwright install chromium` once to install the browser."
  (when *browser-process*
    (warn "Browser already running; ignoring launch request.")
    (return-from browser-launch nil))
  (let ((bridge (or *browser-bridge-script*
                    (error "No bridge script path configured. Set *browser-bridge-script*.")))
        (node   *browser-playwright-path*))
    ;; Verify the bridge script exists
    (unless (probe-file bridge)
      (error "playwright-bridge.js not found at: ~a~%~
              Run: cd browser/ && npm install" bridge))
    (let ((proc (uiop:launch-program
                 (list node bridge)
                 :input  :stream
                 :output :stream
                 :error-output nil)))
      (setf *browser-process* proc
            *browser-stdin*   (uiop:process-info-input proc)
            *browser-stdout*  (uiop:process-info-output proc)))
    ;; Send the launch command with headless flag
    (%call "launch" (list :headless headless))
    t))

(defun browser-navigate (url)
  "Navigate the browser to URL. Waits for DOMContentLoaded.
   Returns NIL on success; signals an error on failure."
  (%call "navigate" (list :url url))
  url)

(defun browser-snapshot ()
  "Return the accessibility tree of the current page as a text string.
   This is the primary tool for agents to understand page structure."
  (%call "snapshot"))

(defun browser-screenshot (&optional path)
  "Take a screenshot of the current page.
   If PATH is supplied, saves to that file and returns the path.
   If PATH is NIL, returns a base64-encoded PNG string."
  (%call "screenshot" (when path (list :path path))))

(defun browser-click (selector)
  "Click the element matching CSS SELECTOR.
   Waits up to 10 seconds for the element to be visible."
  (%call "click" (list :selector selector))
  selector)

(defun browser-type (selector text)
  "Clear SELECTOR's input and type TEXT into it."
  (%call "type" (list :selector selector :text text))
  text)

(defun browser-evaluate (js)
  "Evaluate the JavaScript string JS in the current page context.
   Returns the serialized result (strings, numbers, lists, hash-tables)."
  (%call "evaluate" (list :js js)))

(defun browser-close ()
  "Close the browser and shut down the bridge subprocess.
   Safe to call even if the browser is not running."
  (when *browser-process*
    (ignore-errors (%call "close"))
    (ignore-errors (uiop:terminate-process *browser-process* :urgent nil))
    (ignore-errors (uiop:wait-process *browser-process*))
    (setf *browser-process* nil
          *browser-stdin*   nil
          *browser-stdout*  nil))
  t)

(defun browser-running-p ()
  "Return T if the browser bridge subprocess is currently running."
  (and *browser-process* t))

;;; ── Tool registration ────────────────────────────────────────────────────────

(defun register-browser-tools (registry)
  "Register browser automation tools into REGISTRY.
   Call (browser-launch) before the agent uses any of these tools."
  (clawmacs/tools:register-tool!
   registry "browser_navigate"
   (lambda (params)
     (let ((url (gethash "url" params)))
       (unless url (error "browser_navigate requires 'url'"))
       (browser-navigate url)
       (format nil "Navigated to: ~a" url)))
   :description "Navigate the browser to a URL. Returns confirmation."
   :parameters (clawmacs/tools:schema-plist->ht
                '(:type "object"
                  :properties (:url (:type "string"
                                     :description "The URL to navigate to"))
                  :required ("url"))))

  (clawmacs/tools:register-tool!
   registry "browser_snapshot"
   (lambda (_params)
     (declare (ignore _params))
     (let ((tree (browser-snapshot)))
       (or tree "No accessibility tree available (page may be empty)")))
   :description "Get the accessibility tree of the current browser page as text. Use this to understand the page structure before clicking or typing."
   :parameters (clawmacs/tools:schema-plist->ht
                '(:type "object" :properties ())))

  (clawmacs/tools:register-tool!
   registry "browser_screenshot"
   (lambda (params)
     (let ((path (gethash "path" params nil)))
       (let ((result (browser-screenshot path)))
         (if path
             (format nil "Screenshot saved to: ~a" result)
             (format nil "Screenshot taken (~a bytes base64)" (length result))))))
   :description "Take a screenshot of the current browser page. Optionally save to a file path."
   :parameters (clawmacs/tools:schema-plist->ht
                '(:type "object"
                  :properties (:path (:type "string"
                                      :description "Optional file path to save the screenshot")))))

  (clawmacs/tools:register-tool!
   registry "browser_click"
   (lambda (params)
     (let ((selector (gethash "selector" params)))
       (unless selector (error "browser_click requires 'selector'"))
       (browser-click selector)
       (format nil "Clicked: ~a" selector)))
   :description "Click an element in the browser by CSS selector."
   :parameters (clawmacs/tools:schema-plist->ht
                '(:type "object"
                  :properties (:selector (:type "string"
                                          :description "CSS selector for the element to click"))
                  :required ("selector"))))

  (clawmacs/tools:register-tool!
   registry "browser_type"
   (lambda (params)
     (let ((selector (gethash "selector" params))
           (text     (gethash "text" params "")))
       (unless selector (error "browser_type requires 'selector'"))
       (browser-type selector text)
       (format nil "Typed ~s into ~a" text selector)))
   :description "Type text into an input element in the browser by CSS selector."
   :parameters (clawmacs/tools:schema-plist->ht
                '(:type "object"
                  :properties (:selector (:type "string"
                                          :description "CSS selector for the input element")
                               :text (:type "string"
                                      :description "Text to type"))
                  :required ("selector" "text"))))

  (clawmacs/tools:register-tool!
   registry "browser_evaluate"
   (lambda (params)
     (let ((js (gethash "js" params)))
       (unless js (error "browser_evaluate requires 'js'"))
       (let ((result (browser-evaluate js)))
         (format nil "~a" result))))
   :description "Evaluate JavaScript in the current browser page and return the result."
   :parameters (clawmacs/tools:schema-plist->ht
                '(:type "object"
                  :properties (:js (:type "string"
                                    :description "JavaScript expression to evaluate"))
                  :required ("js"))))

  registry)

(defun make-browser-registry ()
  "Create a new tool registry populated with all browser tools."
  (let ((registry (clawmacs/tools:make-tool-registry)))
    (register-browser-tools registry)
    registry))

;;; ── register-channel integration ─────────────────────────────────────────────

(defmethod clawmacs/config:register-channel ((type (eql :browser)) &rest args
                                            &key headless &allow-other-keys)
  "Register browser configuration. Call (browser-launch) to start.
   Example: (register-channel :browser :headless nil)"
  (when headless
    (setf *browser-headless* headless))
  (call-next-method))
