;;;; t/test-browser.lisp — Tests for clawmacs/browser (Layer 7)
;;;;
;;;; Tests are split into two groups:
;;;;   1. Unit tests — no browser/subprocess required (config, registry, protocol)
;;;;   2. Integration tests — require playwright bridge + chromium
;;;;      (skipped automatically if bridge script is missing)

(in-package #:clawmacs-core/tests/browser)

;;; ── Config tests ─────────────────────────────────────────────────────────────

(define-test "config: *browser-headless* defaults to T"
  (is eq t clawmacs/browser:*browser-headless*))

(define-test "config: *browser-playwright-path* defaults to node"
  (is string= "node" clawmacs/browser:*browser-playwright-path*))

(define-test "config: *browser-bridge-script* is a string"
  (is eq t (stringp clawmacs/browser:*browser-bridge-script*)))

;;; ── Lifecycle: not running ────────────────────────────────────────────────────

(define-test "lifecycle: browser-running-p returns NIL when not launched"
  (false (browser-running-p)))

(define-test "lifecycle: browser-close is safe when not running"
  ;; Should not signal an error
  (finish (browser-close)))

;;; ── Tool registry ────────────────────────────────────────────────────────────

(define-test "registry: make-browser-registry returns a tool-registry"
  (let ((reg (make-browser-registry)))
    (is eq t (typep reg 'clawmacs/tools:tool-registry))))

(define-test "registry: browser registry has 6 tools"
  (let ((reg (make-browser-registry)))
    (is = 6 (length (clawmacs/tools:list-tools reg)))))

(define-test "registry: browser_navigate tool is registered"
  (let ((reg (make-browser-registry)))
    (true (clawmacs/tools:find-tool reg "browser_navigate"))))

(define-test "registry: browser_snapshot tool is registered"
  (let ((reg (make-browser-registry)))
    (true (clawmacs/tools:find-tool reg "browser_snapshot"))))

(define-test "registry: browser_screenshot tool is registered"
  (let ((reg (make-browser-registry)))
    (true (clawmacs/tools:find-tool reg "browser_screenshot"))))

(define-test "registry: browser_click tool is registered"
  (let ((reg (make-browser-registry)))
    (true (clawmacs/tools:find-tool reg "browser_click"))))

(define-test "registry: browser_type tool is registered"
  (let ((reg (make-browser-registry)))
    (true (clawmacs/tools:find-tool reg "browser_type"))))

(define-test "registry: browser_evaluate tool is registered"
  (let ((reg (make-browser-registry)))
    (true (clawmacs/tools:find-tool reg "browser_evaluate"))))

(define-test "registry: register-browser-tools adds to existing registry"
  (let* ((reg (clawmacs/tools:make-tool-registry))
         (result (register-browser-tools reg)))
    ;; Returns the same registry
    (is eq reg result)
    ;; Has 6 tools
    (is = 6 (length (clawmacs/tools:list-tools reg)))))

;;; ── Protocol helpers (unit test via mock process) ────────────────────────────
;;;
;;; We test the JSON command/response protocol by using a tiny inline Node.js
;;; process that echoes back ok responses.

(defvar *mock-bridge-script* "
const readline = require('readline');
const rl = readline.createInterface({ input: process.stdin, terminal: false });
rl.on('line', (line) => {
  try {
    const req = JSON.parse(line.trim());
    // Echo back a success response
    console.log(JSON.stringify({ id: req.id, ok: true, result: req.command }));
  } catch(e) {
    console.log(JSON.stringify({ id: '?', ok: false, error: e.message }));
  }
});
")

(define-test "protocol: JSON round-trip via mock subprocess"
  ;; Write mock script to temp file
  (let* ((script-path (uiop:with-temporary-file (:pathname p :type "js" :keep t)
                        (alexandria:write-string-into-file *mock-bridge-script* p :if-exists :supersede)
                        p))
         (proc (uiop:launch-program
                (list "node" (namestring script-path))
                :input :stream :output :stream :error-output nil))
         (stdin  (uiop:process-info-input proc))
         (stdout (uiop:process-info-output proc)))
    (unwind-protect
         (let* ((req (com.inuoe.jzon:stringify
                      (let ((ht (make-hash-table :test #'equal)))
                        (setf (gethash "id" ht) "test1"
                              (gethash "command" ht) "navigate")
                        ht)))
                (_ (progn
                     (write-string req stdin)
                     (write-char #\Newline stdin)
                     (finish-output stdin)))
                (resp-line (read-line stdout nil nil))
                (resp      (com.inuoe.jzon:parse resp-line :key-fn #'identity)))
           (declare (ignore _))
           ;; Response should be ok with result = command name
           (true (gethash "ok" resp))
           (is string= "test1" (gethash "id" resp))
           (is string= "navigate" (gethash "result" resp)))
      ;; Cleanup
      (ignore-errors (uiop:terminate-process proc :urgent t))
      (ignore-errors (uiop:wait-process proc))
      (ignore-errors (delete-file script-path)))))

;;; ── Integration tests (live browser) ─────────────────────────────────────────
;;;
;;; These tests require:
;;;   1. Node.js in PATH
;;;   2. playwright npm package installed (browser/ directory)
;;;   3. Chromium installed (npx playwright install chromium)
;;;
;;; They are skipped automatically if the bridge script cannot be found.

(defun bridge-available-p ()
  "Return T if the playwright bridge script exists and node is available."
  (and (probe-file clawmacs/browser:*browser-bridge-script*)
       (zerop (nth-value 2 (uiop:run-program '("node" "--version")
                                             :ignore-error-status t)))))

(define-test "integration: browser lifecycle"
  ;; Requires: node, playwright npm package, chromium.
  ;; Automatically a no-op if bridge script is missing.
  (when (bridge-available-p)
    ;; Launch
    (is eq t (browser-launch :headless t))
    (true (browser-running-p))
    ;; Navigate to a data: URL (no network required)
    (finish (browser-navigate "data:text/html,<html><body><h1>Hello Clawmacs</h1></body></html>"))
    ;; Snapshot — should return the accessibility tree as a string
    (let ((tree (browser-snapshot)))
      (is eq t (stringp tree))
      (true (> (length tree) 0)))
    ;; Evaluate JS — returns a JS result
    (let ((result (browser-evaluate "document.querySelector('h1').textContent")))
      (is string= "Hello Clawmacs" result))
    ;; Screenshot (base64, no path)
    (let ((img (browser-screenshot)))
      (is eq t (stringp img))
      (true (> (length img) 100))) ; real screenshots are large
    ;; Close
    (is eq t (browser-close))
    (false (browser-running-p)))
  ;; When bridge not available, just report pass
  (unless (bridge-available-p)
    (true t))) ; vacuously true — bridge not installed
