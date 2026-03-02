;;;; src/client.lisp — Main client and chat functions

(in-package #:cl-llm/client)

;;; ── Client struct ────────────────────────────────────────────────────────────

(defstruct (client (:constructor %make-client))
  "An LLM API client."
  (base-url        nil :type string)
  (api-key         "not-needed" :type string)
  (model           nil :type (or null string))
  (default-options nil)   ; instance of request-options or nil
  (api-type        :openai :type (member :openai :anthropic :claude-cli :codex-cli :codex-oauth)))

(defun make-client (&key base-url api-key model default-options (api-type :openai))
  "Create a new LLM client.

BASE-URL is the endpoint root, e.g. \"http://localhost:11434/v1\".
API-KEY defaults to \"not-needed\" (suitable for local models).
MODEL is the default model name.
DEFAULT-OPTIONS is an optional REQUEST-OPTIONS struct.
API-TYPE is :OPENAI (default), :ANTHROPIC, :CLAUDE-CLI, :CODEX-CLI, or :CODEX-OAUTH."
  (assert (or base-url (member api-type '(:claude-cli :codex-cli :codex-oauth))) ()
          "BASE-URL is required (unless api-type is :claude-cli, :codex-cli, or :codex-oauth)")
  (%make-client
   :base-url        (if base-url
                        (string-right-trim "/" base-url)
                        (cond ((eq api-type :codex-cli) "cli://codex")
                              ((eq api-type :codex-oauth) "bridge://codex-oauth")
                              (t "cli://claude")))
   :api-key         (or api-key "not-needed")
   :model           model
   :default-options default-options
   :api-type        api-type))

(defun make-claude-cli-client (&key model)
  "Create a client that routes calls through the claude CLI (OAuth auth).

MODEL — default model, e.g. \"claude-opus-4-6\".

This client does NOT make HTTP requests. It shells out to:
  env -u ANTHROPIC_API_KEY claude --print --model MODEL --output-format json -p PROMPT

Requires the claude CLI to be installed and authenticated via claude.ai OAuth."
  (%make-client
   :base-url "cli://claude"
   :api-key  "not-needed"
   :model    model
   :api-type :claude-cli))

(defun make-codex-cli-client (&key model)
  "Create a client that routes calls through the codex CLI (OAuth auth).

MODEL — default model, e.g. \"gpt-5-codex\".

Requires the codex CLI to be installed and authenticated via:
  codex login"
  (%make-client
   :base-url "cli://codex"
   :api-key  "not-needed"
   :model    model
   :api-type :codex-cli))

(defun make-codex-oauth-client (&key model (base-url "bridge://codex-oauth"))
  "Create a client that uses browser-link OAuth state with a subscription bridge runtime.

Runtime path does NOT call api.openai.com /chat/completions.
Primary transport is Codex CLI subscription path; interim fallback is Claude CLI
with an explicit warning."
  (%make-client
   :base-url base-url
   :api-key  "oauth"
   :model    model
   :api-type :codex-oauth))

(defun make-anthropic-client (&key api-key model)
  "Create a client configured for the Anthropic Messages API.

API-KEY — your Anthropic API key (starts with sk-ant-).
MODEL   — default model, e.g. \"claude-opus-4-6\"."
  (%make-client
   :base-url "https://api.anthropic.com"
   :api-key  (or api-key "not-needed")
   :model    model
   :api-type :anthropic))

;;; Predefined providers
(defun make-ollama-client (&key (host "http://localhost:11434") model)
  (make-client :base-url (format nil "~a/v1" host)
               :api-key "ollama-local"
               :model model))

(defun make-openrouter-client (api-key &key model)
  (make-client :base-url "https://openrouter.ai/api/v1"
               :api-key api-key
               :model model))

(defun make-lm-studio-client (&key (host "http://localhost:1234") model)
  (make-client :base-url (format nil "~a/v1" host)
               :api-key "lm-studio"
               :model model))

;;; ── Helpers ──────────────────────────────────────────────────────────────────

(defun chat-url (client)
  (if (eq (client-api-type client) :anthropic)
      (format nil "~a/v1/messages" (client-base-url client))
      (format nil "~a/chat/completions" (client-base-url client))))

(defun effective-options (client options)
  "Merge client defaults with per-request options."
  ;; Per-request wins; client default fills in.
  ;; Simple approach: prefer options when provided, else client defaults.
  (or options (client-default-options client)))

;;; ── Main chat function ────────────────────────────────────────────────────────

(defun chat (client messages
             &key model options tools)
  "Send a chat completion request.

CLIENT — a CLIENT struct.
MESSAGES — list of MESSAGE structs (use SYSTEM-MESSAGE, USER-MESSAGE, etc.).
MODEL — override client's default model.
OPTIONS — a REQUEST-OPTIONS struct (optional).
TOOLS — list of TOOL-DEFINITION structs (optional).

Returns a COMPLETION-RESPONSE."
  (let* ((api-type        (client-api-type client))
         (effective-model (or model (client-model client)))
         (effective-opts  (effective-options client options)))

    ;; Dispatch to CLI/bridge backends
    (when (member api-type '(:claude-cli :codex-cli :codex-oauth))
      (when tools
        (format *error-output*
                "~&[cl-llm/client] WARNING: tool calling not supported in ~A mode — tools ignored~%"
                api-type))
      (return-from chat
        (cond
          ((eq api-type :claude-cli)
           (cl-llm/claude-cli:claude-cli-chat
            messages
            :model         effective-model
            :system-prompt nil
            :max-tokens    (when effective-opts
                             (cl-llm/protocol:request-options-max-tokens effective-opts))))
          ((eq api-type :codex-cli)
           (cl-llm/codex-cli:codex-cli-chat
            messages
            :model         effective-model
            :system-prompt nil
            :max-tokens    (when effective-opts
                             (cl-llm/protocol:request-options-max-tokens effective-opts))))
          (t
           (cl-llm/codex-oauth-bridge:codex-oauth-bridge-chat
            messages
            :model         effective-model
            :system-prompt nil
            :max-tokens    (when effective-opts
                             (cl-llm/protocol:request-options-max-tokens effective-opts)))))))

    ;; HTTP backends (:openai / :anthropic)
    (let* ((anthropic-p  (eq api-type :anthropic))
           (effective-api-key (client-api-key client))
           (request-ht   (if anthropic-p
                             (cl-llm/protocol::build-anthropic-request-ht
                              effective-model messages effective-opts tools)
                             (cl-llm/protocol::build-request-ht
                              effective-model messages effective-opts tools)))
           (body-str     (com.inuoe.jzon:stringify request-ht))
           (response-str (cl-llm/http:post-json
                          (chat-url client)
                          effective-api-key
                          body-str
                          :anthropic-p anthropic-p)))
      (if anthropic-p
          (cl-llm/protocol::parse-anthropic-response response-str)
          (cl-llm/protocol::parse-response response-str)))))

;;; ── Streaming chat ───────────────────────────────────────────────────────────

(defun chat-stream (client messages callback
                    &key model options tools)
  "Send a streaming chat completion request.

CALLBACK is called with each TEXT-DELTA string as it arrives.
Returns the full accumulated text string when done."
  (let* ((api-type        (client-api-type client))
         (effective-model (or model (client-model client)))
         (effective-opts  (effective-options client options)))

    ;; Dispatch to CLI/bridge backends (non-streaming: callback called once)
    (when (member api-type '(:claude-cli :codex-cli :codex-oauth))
      (when tools
        (format *error-output*
                "~&[cl-llm/client] WARNING: tool calling not supported in ~A mode — tools ignored~%"
                api-type))
      (return-from chat-stream
        (cond
          ((eq api-type :claude-cli)
           (cl-llm/claude-cli:claude-cli-chat-stream
            messages callback
            :model         effective-model
            :system-prompt nil
            :max-tokens    (when effective-opts
                             (cl-llm/protocol:request-options-max-tokens effective-opts))))
          ((eq api-type :codex-cli)
           (cl-llm/codex-cli:codex-cli-chat-stream
            messages callback
            :model         effective-model
            :system-prompt nil
            :max-tokens    (when effective-opts
                             (cl-llm/protocol:request-options-max-tokens effective-opts))))
          (t
           (cl-llm/codex-oauth-bridge:codex-oauth-bridge-chat-stream
            messages callback
            :model         effective-model
            :system-prompt nil
            :max-tokens    (when effective-opts
                             (cl-llm/protocol:request-options-max-tokens effective-opts)))))))

    ;; HTTP backends (:openai / :anthropic)
    (let* ((anthropic-p     (eq api-type :anthropic))
           (effective-api-key (client-api-key client))
           (request-ht      (if anthropic-p
                                (cl-llm/protocol::build-anthropic-request-ht
                                 effective-model messages effective-opts tools)
                                (cl-llm/protocol::build-request-ht
                                 effective-model messages effective-opts tools)))
           ;; Add stream:true
           (_ (setf (gethash "stream" request-ht) t))
           (body-str        (com.inuoe.jzon:stringify request-ht))
           (accumulated     (make-string-output-stream)))
      (declare (ignore _))
      (cl-llm/http:post-json-stream
       (chat-url client)
       effective-api-key
       body-str
       (lambda (line)
         (if anthropic-p
             (cl-llm/streaming:parse-anthropic-sse-line
              line
              (lambda (delta)
                (when delta
                  (write-string delta accumulated)
                  (when callback
                    (funcall callback delta)))))
             (cl-llm/streaming:parse-sse-line
              line
              (lambda (delta)
                (when delta
                  (write-string delta accumulated)
                  (when callback
                    (funcall callback delta)))))))
       :anthropic-p anthropic-p)
      (get-output-stream-string accumulated))))

;;; ── Convenience ──────────────────────────────────────────────────────────────

(defun simple-chat (client prompt &key model system)
  "Simplest possible chat: send PROMPT, get back the response string.
Optionally provide a SYSTEM message and MODEL override."
  (let ((messages (if system
                      (list (cl-llm/protocol:system-message system)
                            (cl-llm/protocol:user-message prompt))
                      (list (cl-llm/protocol:user-message prompt)))))
    (let* ((response (chat client messages :model model))
           (choice   (first (cl-llm/protocol::response-choices response)))
           (msg      (when choice (cl-llm/protocol::choice-message choice))))
      (when msg
        (cl-llm/protocol:message-content msg)))))

(defmacro with-client ((var &rest make-client-args) &body body)
  "Bind VAR to a new client for the duration of BODY."
  `(let ((,var (make-client ,@make-client-args)))
     ,@body))
