;;;; src/tools.lisp — Tool registry, define-tool macro, dispatch

(in-package #:clambda/tools)

;;; ── Tool result ──────────────────────────────────────────────────────────────

(defstruct (tool-result (:constructor %make-tool-result)
                        (:conc-name tr-))
  "Encapsulates the result of a tool call."
  (ok    t   :type boolean)  ; t = success, nil = error
  (value nil))               ; string output or error description

(defun tool-result-ok-p (result)
  "Return T if RESULT represents a successful tool call."
  (tr-ok result))

(defun tool-result-value (result)
  "Return the payload string for RESULT."
  (tr-value result))

(defun tool-result-ok (value)
  "Create a successful tool result with VALUE (string)."
  (%make-tool-result :ok t :value (if (stringp value) value
                                      (format nil "~a" value))))

(defun tool-result-error (message)
  "Create an error tool result with MESSAGE (string)."
  (%make-tool-result :ok nil :value (if (stringp message) message
                                        (format nil "~a" message))))

(defun format-tool-result (result)
  "Return the string value of a TOOL-RESULT, prefixed with ERROR: if failed."
  (if (tool-result-ok-p result)
      (tool-result-value result)
      (format nil "ERROR: ~a" (tool-result-value result))))

;;; ── JSON Schema helpers ──────────────────────────────────────────────────────

(defun schema-plist->ht (plist)
  "Recursively convert a JSON Schema plist to nested hash-tables.
Handles: type, properties (nested plist), required (vector), description."
  (let ((ht (make-hash-table :test #'equal)))
    (loop :for (k v) :on plist :by #'cddr
          :for key = (cl-llm/json:to-json-key k)
          :do (setf (gethash key ht)
                    (cond
                      ;; 'properties' value is a plist of property name → schema-plist
                      ((string= key "properties")
                       (let ((props-ht (make-hash-table :test #'equal)))
                         (loop :for (pk pv) :on v :by #'cddr
                               :do (setf (gethash (cl-llm/json:to-json-key pk) props-ht)
                                         (if (listp pv)
                                             (schema-plist->ht pv)
                                             pv)))
                         props-ht))
                      ;; Nested object schemas (recursively convert lists)
                      ((and (listp v) (not (null v)) (keywordp (car v)))
                       (schema-plist->ht v))
                      ;; Everything else verbatim (strings, vectors, etc.)
                      (t v))))
    ht))

;;; ── Tool entry (internal) ────────────────────────────────────────────────────

(defstruct (tool-entry (:constructor %make-tool-entry))
  "Internal: a registered tool."
  (name        "" :type string)
  (description "" :type string)
  (parameters  nil)              ; JSON Schema as plist or hash-table
  (handler     nil))             ; function (args-hash-table) → tool-result or string

;;; ── Registry ─────────────────────────────────────────────────────────────────

(defclass tool-registry ()
  ((table
    :initform (make-hash-table :test #'equal)
    :accessor registry-table
    :documentation "Hash-table: tool-name → tool-entry."))
  (:documentation "Registry of available tools for an agent."))

(defun make-tool-registry ()
  "Create a new, empty TOOL-REGISTRY."
  (make-instance 'tool-registry))

(defun register-tool! (registry name handler
                       &key (description "") parameters)
  "Register a tool in REGISTRY.

NAME — string tool name (must be unique in registry).
HANDLER — function (args-hash-table) → string or TOOL-RESULT.
DESCRIPTION — tool description string.
PARAMETERS — JSON Schema for arguments (plist or hash-table).

Returns REGISTRY (for chaining)."
  (let ((entry (%make-tool-entry
                :name        name
                :description description
                :parameters  (etypecase parameters
                               (null nil)
                               (list (schema-plist->ht parameters))
                               (hash-table parameters))
                :handler     handler)))
    (setf (gethash name (registry-table registry)) entry))
  registry)

(defun find-tool (registry name)
  "Return the TOOL-ENTRY for NAME in REGISTRY, or NIL if not found."
  (gethash name (registry-table registry)))

(defun list-tools (registry)
  "Return a list of all tool name strings in REGISTRY."
  (loop :for k :being :the :hash-keys :of (registry-table registry)
        :collect k))

;;; ── LLM schema conversion ────────────────────────────────────────────────────

(defun entry->tool-definition (entry)
  "Convert a TOOL-ENTRY to a CL-LLM TOOL-DEFINITION."
  (cl-llm/protocol:make-tool-definition
   :name        (tool-entry-name entry)
   :description (tool-entry-description entry)
   :parameters  (tool-entry-parameters entry)))

(defun tool-definitions-for-llm (registry)
  "Return a list of CL-LLM TOOL-DEFINITIONs for all tools in REGISTRY.
Pass this list to CL-LLM:CHAT's :TOOLS argument."
  (loop :for entry :being :the :hash-values :of (registry-table registry)
        :collect (entry->tool-definition entry)))

;;; ── Dispatch ─────────────────────────────────────────────────────────────────

(defun %try-tool-handler (handler args name)
  "Try calling HANDLER with ARGS.

Establishes two restarts for error recovery:

  RETRY-WITH-FIXED-INPUT (new-args)
    Retry the handler with NEW-ARGS (a hash-table) instead of ARGS.
    This is the restart invoked by the LLM auto-repair handler in the agent
    loop (or manually from a SLIME debugger).

  SKIP-TOOL-CALL ()
    Return a TOOL-RESULT-ERROR immediately and continue the agent loop.

When a handler error occurs, signals TOOL-EXECUTION-ERROR with the :INPUT
slot set to ARGS, so handlers and SLIME users can inspect the failing call."
  (restart-case
      (handler-case
          (let ((raw-result (funcall handler args)))
            (etypecase raw-result
              (tool-result raw-result)
              (string (tool-result-ok raw-result))
              (t (tool-result-ok (format nil "~a" raw-result)))))
        (error (e)
          ;; Re-signal as tool-execution-error (with input attached)
          (error 'clambda/conditions:tool-execution-error
                 :tool-name name
                 :cause e
                 :input args)))
    (clambda/conditions:retry-with-fixed-input (new-args)
      :report "Retry this tool call with fixed arguments (LLM-repaired or human-provided)."
      (%try-tool-handler handler new-args name))
    (clambda/conditions:skip-tool-call ()
      :report "Skip this tool call and return an error result."
      (tool-result-error (format nil "Tool execution skipped: ~s" name)))))

(defun dispatch-tool-call (registry tool-call)
  "Dispatch a CL-LLM TOOL-CALL through REGISTRY.

Returns a TOOL-RESULT.
Signals TOOL-NOT-FOUND if the tool isn't registered.
Signals TOOL-EXECUTION-ERROR (with RETRY-WITH-FIXED-INPUT and SKIP-TOOL-CALL
restarts) if the handler errors.

The RETRY-WITH-FIXED-INPUT restart is the key Lisp superpower: the condition
handler in the agent loop asks the LLM to provide corrected arguments, then
invokes this restart to retry without unwinding the stack."
  (let* ((name (cl-llm/protocol:tool-call-function-name tool-call))
         (raw-args (cl-llm/protocol:tool-call-function-arguments tool-call))
         (entry (find-tool registry name)))

    (unless entry
      (restart-case
          (error 'clambda/conditions:tool-not-found :name name)
        (clambda/conditions:skip-tool-call ()
          :report "Skip this tool call and return an error result."
          (return-from dispatch-tool-call
            (tool-result-error (format nil "Tool not found: ~s" name))))))

    ;; Parse arguments
    (let ((args (etypecase raw-args
                  (null (make-hash-table :test #'equal))
                  (string (if (string= raw-args "")
                              (make-hash-table :test #'equal)
                              (com.inuoe.jzon:parse raw-args)))
                  (hash-table raw-args))))

      (%try-tool-handler (tool-entry-handler entry) args name))))

;;; ── Registry operations ──────────────────────────────────────────────────────

(defun copy-tools-to-registry (source target &optional tool-names)
  "Copy tools from SOURCE registry to TARGET registry.

If TOOL-NAMES (a list of strings) is supplied, copy only those tools.
If TOOL-NAMES is NIL, copy ALL tools from SOURCE to TARGET.
Returns TARGET."
  (let ((src-table (registry-table source))
        (dst-table (registry-table target)))
    (if tool-names
        (dolist (name tool-names)
          (let ((entry (gethash name src-table)))
            (when entry
              (setf (gethash name dst-table) entry))))
        (maphash (lambda (name entry)
                   (setf (gethash name dst-table) entry))
                 src-table)))
  target)

;;; ── DEFINE-TOOL macro ────────────────────────────────────────────────────────

(defmacro define-tool (registry name description (&rest arg-specs) &body body)
  "Define and register a tool in REGISTRY.

REGISTRY — a form evaluating to a TOOL-REGISTRY.
NAME — string: the tool name sent to the LLM.
DESCRIPTION — string: tool description for the LLM.
ARG-SPECS — list of (PARAM-NAME TYPE DESCRIPTION [REQUIRED-P]) specs.
  PARAM-NAME — string or symbol (converted to string).
  TYPE — JSON Schema type string: \"string\", \"number\", \"boolean\", etc.
  DESCRIPTION — param description string.
  REQUIRED-P — boolean, default T.
BODY — the handler body. Parameters are bound as CL symbols
  (underscores converted to hyphens, upcased).

Example:
  (define-tool *registry* \"read_file\"
    \"Read the contents of a file.\"
    ((path \"string\" \"Path to the file\"))
    (uiop:read-file-string path))

The tool result is automatically wrapped in TOOL-RESULT-OK.
Signal an error or return a TOOL-RESULT-ERROR explicitly for failures."
  (let* ((ht-sym (gensym "ARGS"))
         (param-infos
          (mapcar (lambda (spec)
                    (destructuring-bind (pname ptype pdesc &optional (req t)) spec
                      (let* ((pname-str (string pname))
                             (cl-sym (intern (string-upcase
                                              (substitute #\- #\_
                                                          pname-str)))))
                        (list pname-str ptype pdesc req cl-sym))))
                  arg-specs))
         ;; Build JSON Schema
         (required-names
          (mapcar #'first
                  (remove-if-not #'fourth param-infos)))
         (properties-form
          `(list ,@(mapcan (lambda (info)
                             (destructuring-bind (pname ptype pdesc req sym) info
                               (declare (ignore sym req))
                               `(,(intern pname :keyword)
                                 (list :|type| ,ptype
                                       :|description| ,pdesc))))
                           param-infos)))
         (parameters-form
          `(list :|type| "object"
                 :|properties| ,properties-form
                 :|required| (vector ,@required-names))))
    `(register-tool!
      ,registry
      ,name
      (lambda (,ht-sym)
        (let ,(mapcar (lambda (info)
                        (destructuring-bind (pname ptype pdesc req sym) info
                          (declare (ignore ptype pdesc req))
                          `(,sym (gethash ,pname ,ht-sym))))
                      param-infos)
          ;; Auto-wrap body result in TOOL-RESULT if not already one
          (let ((raw-result (progn ,@body)))
            (etypecase raw-result
              (tool-result raw-result)
              (string      (tool-result-ok raw-result))
              (t           (tool-result-ok (format nil "~a" raw-result)))))))
      :description ,description
      :parameters  ,parameters-form)))
