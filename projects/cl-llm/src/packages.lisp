;;;; src/packages.lisp — Package definitions for cl-llm

(defpackage #:cl-llm/conditions
  (:use #:cl)
  (:export
   ;; Base condition
   #:llm-error
   ;; HTTP-level errors
   #:http-error
   #:http-error-status
   #:http-error-body
   ;; API-level errors
   #:api-error
   #:api-error-type
   #:api-error-code
   #:api-error-message
   ;; Parse errors
   #:parse-error*
   #:parse-error-raw
   ;; Stream errors
   #:stream-error*
   #:stream-error-chunk
   ;; Retryable errors
   #:retryable-error
   #:retryable-error-attempt))

(defpackage #:cl-llm/json
  (:use #:cl)
  (:import-from #:alexandria #:plist-hash-table #:hash-table-plist)
  (:export
   #:encode
   #:decode
   #:decode-string
   #:to-json-key
   #:from-json-key
   #:object->plist
   #:plist->object))

(defpackage #:cl-llm/protocol
  (:use #:cl)
  (:export
   ;; Message constructors
   #:message
   #:system-message
   #:user-message
   #:assistant-message
   #:tool-message
   ;; Message accessors
   #:message-role
   #:message-content
   #:message-tool-calls
   #:message-tool-call-id
   ;; Tool definition
   #:tool-definition
   #:make-tool-definition
   #:tool-definition-name
   #:tool-definition-description
   #:tool-definition-parameters
   ;; Tool call (from response)
   #:tool-call
   #:tool-call-id
   #:tool-call-function-name
   #:tool-call-function-arguments
   ;; Request options
   #:request-options
   #:make-request-options
   ;; Response
   #:completion-response
   #:response-id
   #:response-model
   #:response-choices
   #:response-usage
   #:choice-message
   #:choice-finish-reason
   #:usage-prompt-tokens
   #:usage-completion-tokens
   #:usage-total-tokens))

(defpackage #:cl-llm/http
  (:use #:cl)
  (:import-from #:cl-llm/conditions
                #:http-error #:http-error-status #:http-error-body
                #:retryable-error)
  (:export
   #:post-json
   #:post-json-stream
   #:make-headers
   #:make-anthropic-headers
   ;; Retry configuration
   #:*max-retries*
   #:*retry-base-delay-seconds*))

(defpackage #:cl-llm/client
  (:use #:cl)
  (:import-from #:cl-llm/conditions
                #:llm-error #:api-error #:parse-error*)
  (:import-from #:cl-llm/protocol
                #:message #:system-message #:user-message
                #:assistant-message #:tool-message
                #:tool-definition #:tool-call
                #:completion-response)
  (:export
   ;; Client struct
   #:client
   #:make-client
   #:make-anthropic-client
   #:client-base-url
   #:client-api-key
   #:client-model
   #:client-default-options
   #:client-api-type
   ;; Main API
   #:chat
   #:chat-stream
   ;; Convenience
   #:simple-chat
   #:with-client))

(defpackage #:cl-llm/streaming
  (:use #:cl)
  (:import-from #:cl-llm/conditions
                #:stream-error*)
  (:export
   #:parse-sse-line
   #:parse-anthropic-sse-line
   #:parse-sse-stream
   #:make-chunk-collector
   #:stream-to-string))

(defpackage #:cl-llm/tools
  (:use #:cl)
  (:import-from #:cl-llm/protocol
                #:tool-definition #:make-tool-definition #:tool-call)
  (:export
   #:define-tool
   #:tool-registry
   #:make-registry
   #:register-tool
   #:find-tool
   #:dispatch-tool-call
   #:make-tool-result-message
   #:tool-schema))

;; Top-level convenience package
(defpackage #:cl-llm
  (:use #:cl)
  (:import-from #:cl-llm/client
                #:client #:make-client #:make-anthropic-client
                #:client-base-url #:client-api-key #:client-model #:client-api-type
                #:chat #:chat-stream #:simple-chat #:with-client)
  (:import-from #:cl-llm/protocol
                #:message #:system-message #:user-message
                #:assistant-message #:tool-message
                #:tool-definition #:tool-call
                #:message-role #:message-content
                #:message-tool-calls #:message-tool-call-id
                #:tool-call-id #:tool-call-function-name
                #:tool-call-function-arguments
                #:completion-response
                #:response-id #:response-model
                #:response-choices #:response-usage
                #:choice-message #:choice-finish-reason
                #:usage-prompt-tokens #:usage-completion-tokens
                #:usage-total-tokens
                #:make-request-options)
  (:import-from #:cl-llm/conditions
                #:llm-error #:http-error #:api-error
                #:parse-error* #:stream-error*
                #:retryable-error #:retryable-error-attempt)
  (:import-from #:cl-llm/http
                #:*max-retries* #:*retry-base-delay-seconds*)
  (:import-from #:cl-llm/tools
                #:define-tool #:tool-registry #:make-registry
                #:register-tool #:find-tool #:dispatch-tool-call
                #:make-tool-result-message #:tool-schema)
  (:import-from #:cl-llm/streaming
                #:stream-to-string)
  (:export
   ;; Client
   #:client #:make-client #:make-anthropic-client
   #:client-base-url #:client-api-key #:client-model #:client-api-type
   #:chat #:chat-stream #:simple-chat #:with-client
   ;; Messages
   #:message #:system-message #:user-message
   #:assistant-message #:tool-message
   #:message-role #:message-content
   #:message-tool-calls #:message-tool-call-id
   ;; Tool calls
   #:tool-call #:tool-definition
   #:tool-call-id #:tool-call-function-name
   #:tool-call-function-arguments
   ;; Response
   #:completion-response
   #:response-id #:response-model
   #:response-choices #:response-usage
   #:choice-message #:choice-finish-reason
   #:usage-prompt-tokens #:usage-completion-tokens
   #:usage-total-tokens
   ;; Options
   #:make-request-options
   ;; Conditions
   #:llm-error #:http-error #:api-error
   #:parse-error* #:stream-error*
   #:retryable-error #:retryable-error-attempt
   ;; Retry config
   #:*max-retries* #:*retry-base-delay-seconds*
   ;; Tools
   #:define-tool #:tool-registry #:make-registry
   #:register-tool #:find-tool #:dispatch-tool-call
   #:make-tool-result-message #:tool-schema
   ;; Streaming
   #:stream-to-string))
