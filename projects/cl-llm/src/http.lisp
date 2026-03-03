;;;; src/http.lisp — HTTP transport layer with retry/backoff

(in-package #:cl-llm/http)

;;; ── Retry configuration ──────────────────────────────────────────────────────

(defvar *max-retries* 3
  "Maximum number of retry attempts for transient HTTP errors (429, 5xx).
Set to 0 to disable retries.")

(defvar *retry-base-delay-seconds* 1
  "Base delay in seconds for exponential backoff.
Delay for attempt N = base * 2^(N-1): 1s, 2s, 4s, ...")

;;; ── Transient status codes ───────────────────────────────────────────────────

(defun transient-status-p (status)
  "Return T if STATUS is a transient HTTP error code worth retrying."
  (member status '(429 500 502 503 504)))

;;; ── Helpers ──────────────────────────────────────────────────────────────────

(defun make-headers (api-key &optional extra)
  "Build the Authorization + Content-Type headers (OpenAI style Bearer token)."
  (append
   (list (cons "Content-Type"  "application/json")
         (cons "Authorization" (format nil "Bearer ~a" api-key)))
   extra))

(defun make-anthropic-headers (api-key)
  "Build Anthropic API headers (x-api-key, anthropic-version)."
  (list (cons "Content-Type"      "application/json")
        (cons "x-api-key"         api-key)
        (cons "anthropic-version" "2023-06-01")))

(defun sleep-backoff (attempt)
  "Sleep for base * 2^(attempt-1) seconds (exponential backoff)."
  (let ((delay (* *retry-base-delay-seconds* (expt 2 (1- attempt)))))
    (sleep delay)))

;;; ── post-json with retry ─────────────────────────────────────────────────────

(defun post-json (url api-key body-string
                  &key (max-retries *max-retries*)
                       (base-delay *retry-base-delay-seconds*)
                       (anthropic-p nil))
  "POST body-string as JSON to URL, return response body string.

Retries on transient errors (429, 500, 502, 503, 504) with exponential
backoff. Signals RETRYABLE-ERROR with a RETRY restart before each retry;
signals HTTP-ERROR on final failure.

MAX-RETRIES  — max retry count (default: *MAX-RETRIES*).
BASE-DELAY   — base delay in seconds (default: *RETRY-BASE-DELAY-SECONDS*)."
  (declare (ignore base-delay)) ; we use *retry-base-delay-seconds* internally
  (let ((headers (if anthropic-p
                     (make-anthropic-headers api-key)
                     (make-headers api-key))))
  (loop
    :for attempt :from 1 :to (1+ max-retries)
    :do
       (handler-case
           (return
             (dexador:post url
                           :headers headers
                           :content body-string
                           :connect-timeout 30
                           :read-timeout 120))
         (dexador:http-request-failed (e)
           (let ((status (dexador:response-status e))
                 (body   (dexador:response-body e)))
             (cond
               ;; Transient and we have retries left
               ((and (transient-status-p status)
                     (< attempt (1+ max-retries)))
                ;; Signal RETRYABLE-ERROR — caller can invoke RETRY restart
                ;; or just let it proceed with the automatic retry.
                (restart-case
                    (signal 'retryable-error
                            :status  status
                            :body    body
                            :attempt attempt)
                  (retry ()
                    :report "Retry this HTTP request."
                    nil))   ; restart taken → nil (outer loop continues)
                ;; Automatic backoff before next attempt
                (sleep-backoff attempt))
               ;; Not transient, or no retries left → propagate
               (t
                (error 'http-error
                       :status status
                       :body   body)))))))))

;;; ── post-json-stream with retry ──────────────────────────────────────────────

(defun post-json-stream (url api-key body-string callback
                         &key (max-retries *max-retries*)
                              (base-delay *retry-base-delay-seconds*)
                              (anthropic-p nil))
  "POST body-string as JSON to URL with stream:true.
Calls CALLBACK with each SSE line as it arrives.
Returns when the stream ends.

Retries on transient errors before the stream opens (connection-level).
Signals RETRYABLE-ERROR with RETRY restart; HTTP-ERROR on final failure.

MAX-RETRIES  — max retry count (default: *MAX-RETRIES*).
BASE-DELAY   — base delay in seconds (default: *RETRY-BASE-DELAY-SECONDS*)."
  (declare (ignore base-delay))
  (let ((headers (if anthropic-p
                     (make-anthropic-headers api-key)
                     (make-headers api-key))))
  (loop
    :for attempt :from 1 :to (1+ max-retries)
    :do
       (handler-case
           (return
             ;; With :want-stream t, dexador returns the response body as a
             ;; Gray stream in the first return value.
             (let ((stream (dexador:post url
                                         :headers headers
                                         :content body-string
                                         :want-stream t
                                         :connect-timeout 30
                                         :read-timeout 120)))
               (unwind-protect
                    (loop :for line := (read-line stream nil nil)
                          :while line
                          :do (funcall callback line))
                 (close stream))))
         (dexador:http-request-failed (e)
           (let* ((status (dexador:response-status e))
                  (raw-body (dexador:response-body e))
                  (body (etypecase raw-body
                          (string raw-body)
                          (stream
                           (let ((s (make-string-output-stream)))
                             (ignore-errors
                               (loop :for line := (read-line raw-body nil nil)
                                     :while line
                                     :do (write-line line s)))
                             (ignore-errors (close raw-body))
                             (get-output-stream-string s)))
                          (null ""))))
             (cond
               ((and (transient-status-p status)
                     (< attempt (1+ max-retries)))
                (restart-case
                    (signal 'retryable-error
                            :status  status
                            :body    body
                            :attempt attempt)
                  (retry ()
                    :report "Retry this streaming HTTP request."
                    nil))
                (sleep-backoff attempt))
               (t
                (error 'http-error
                       :status status
                       :body   body)))))))))
