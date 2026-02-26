;;;; src/memory.lisp — Workspace memory system for clambda-core
;;;;
;;;; Reads .md files from a workspace directory and provides them as
;;;; structured "memory entries" that can be injected into an agent's
;;;; system prompt.
;;;;
;;;; Usage:
;;;;   (let ((mem (clambda/memory:load-workspace-memory "/path/to/workspace")))
;;;;     (clambda/memory:memory-context-string mem))
;;;;
;;;; The context string can be prepended to an agent's system prompt:
;;;;   (setf (clambda/agent:agent-system-prompt agent)
;;;;         (concatenate 'string
;;;;                      (clambda/memory:memory-context-string mem)
;;;;                      base-prompt))

(in-package #:clambda/memory)

;;; ── Data types ───────────────────────────────────────────────────────────────

(defstruct (memory-entry (:constructor %make-memory-entry))
  "A single piece of memory loaded from a workspace file."
  (name    "" :type string)   ; file name without directory (e.g. "SOUL.md")
  (path    "" :type string)   ; absolute path to the file
  (content "" :type string))  ; file contents as a string

(defstruct (workspace-memory (:constructor %make-workspace-memory))
  "Collection of memory entries loaded from a workspace."
  (path    "" :type string)  ; workspace root path
  (entries nil :type list))  ; list of MEMORY-ENTRY structs

;;; ── Priority filenames ───────────────────────────────────────────────────────
;;; These files are loaded first (in this order) if present.
;;; Other .md files are loaded after.

(defparameter *priority-files*
  '("SOUL.md" "AGENTS.md" "IDENTITY.md" "TEAM.md" "ROADMAP.md"
    "MEMORY.md" "README.md")
  "Filenames loaded first (if present) to ensure key context appears early.")

;;; ── File loading ─────────────────────────────────────────────────────────────

(defun read-md-file (path)
  "Read the .md file at PATH and return its contents as a string.
Returns NIL if the file cannot be read."
  (handler-case
      (uiop:read-file-string path)
    (error () nil)))

(defun md-file-p (pathname)
  "Return T if PATHNAME ends in .md (case-insensitive)."
  (let ((type (pathname-type pathname)))
    (and type (string-equal type "md"))))

(defun find-md-files (dir-path)
  "Return a list of absolute pathnames for .md files in DIR-PATH.
DIR-PATH may be a string or pathname. Non-recursive: top level only."
  (let* ((truepath  (uiop:ensure-directory-pathname
                     (if (stringp dir-path)
                         (uiop:parse-native-namestring dir-path)
                         dir-path)))
         (all-files (uiop:directory-files truepath)))
    (remove-if-not #'md-file-p all-files)))

(defun load-entry (pathname)
  "Load PATHNAME as a MEMORY-ENTRY. Returns NIL on error."
  (let ((content (read-md-file pathname)))
    (when content
      (%make-memory-entry
       :name    (file-namestring pathname)
       :path    (namestring pathname)
       :content content))))

;;; ── Main loader ──────────────────────────────────────────────────────────────

(defun load-workspace-memory (workspace-path
                               &key (max-entry-chars 50000)
                                    (max-total-chars  200000)
                                    subdirs)
  "Load .md files from WORKSPACE-PATH and return a WORKSPACE-MEMORY.

Files are loaded in priority order (SOUL.md, AGENTS.md, etc.) then
alphabetically for any remaining .md files.

MAX-ENTRY-CHARS — truncate any single file at this length (default 50000).
MAX-TOTAL-CHARS — stop loading more files once total exceeds this (default 200000).
SUBDIRS — list of relative subdirectory paths to also scan
          (e.g. '(\"memory\" \"knowledge\")).

Returns a WORKSPACE-MEMORY struct."
  (let* (;; Accept string or pathname; ensure it's a directory pathname
         (base-dir  (uiop:ensure-directory-pathname
                     (if (stringp workspace-path)
                         (uiop:parse-native-namestring workspace-path)
                         workspace-path)))
         (all-mds   (find-md-files (namestring base-dir)))
         ;; Also scan subdirs if requested
         (sub-mds   (when subdirs
                      (loop :for sd :in subdirs
                            :append (find-md-files
                                     (namestring
                                      (uiop:ensure-directory-pathname
                                       (merge-pathnames sd base-dir)))))))
         (all-paths (append all-mds sub-mds))
         ;; Sort: priority first, then alphabetical
         (sorted    (sort-by-priority all-paths))
         (entries   nil)
         (total     0))

    (dolist (p sorted)
      (when (>= total max-total-chars)
        (return))
      (let ((entry (load-entry p)))
        (when entry
          ;; Truncate if needed
          (when (> (length (memory-entry-content entry)) max-entry-chars)
            (setf (memory-entry-content entry)
                  (concatenate 'string
                               (subseq (memory-entry-content entry) 0 max-entry-chars)
                               (format nil "~%...[truncated]"))))
          (incf total (length (memory-entry-content entry)))
          (push entry entries))))

    (%make-workspace-memory
     :path    (namestring base-dir)
     :entries (nreverse entries))))

(defun sort-by-priority (pathnames)
  "Sort PATHNAMES so that *priority-files* appear first (in order), rest alphabetically."
  (let ((priority-set (make-hash-table :test #'equal)))
    (loop :for name :in *priority-files*
          :for i :from 0
          :do (setf (gethash name priority-set) i))
    (sort (copy-list pathnames)
          (lambda (a b)
            (let ((ai (gethash (file-namestring a) priority-set))
                  (bi (gethash (file-namestring b) priority-set)))
              (cond
                ;; Both priority: lower index first
                ((and ai bi) (< ai bi))
                ;; Only a is priority: a first
                (ai t)
                ;; Only b is priority: b first
                (bi nil)
                ;; Neither: alphabetical
                (t  (string< (file-namestring a)
                             (file-namestring b)))))))))

;;; ── Search ───────────────────────────────────────────────────────────────────

(defun search-memory (workspace-memory query)
  "Search WORKSPACE-MEMORY for entries containing QUERY (case-insensitive substring).

Returns a list of (MEMORY-ENTRY . matching-excerpt) pairs where
the excerpt is a snippet around the first match."
  (let ((q (string-downcase query))
        (results nil))
    (dolist (entry (workspace-memory-entries workspace-memory))
      (let* ((lower  (string-downcase (memory-entry-content entry)))
             (pos    (search q lower)))
        (when pos
          ;; Extract ±100 chars around the match
          (let* ((start  (max 0 (- pos 100)))
                 (end    (min (length (memory-entry-content entry))
                              (+ pos (length query) 100)))
                 (excerpt (subseq (memory-entry-content entry) start end)))
            (push (cons entry excerpt) results)))))
    (nreverse results)))

;;; ── Context string ───────────────────────────────────────────────────────────

(defun memory-context-string (workspace-memory &key (separator "---"))
  "Render WORKSPACE-MEMORY as a string suitable for injection into a system prompt.

Each memory entry is formatted as:
  ## filename
  <content>
  ---

SEPARATOR — string printed between entries (default: \"---\").

Returns the full context string, or empty string if no entries."
  (if (null (workspace-memory-entries workspace-memory))
      ""
      (with-output-to-string (s)
        (format s "# Workspace Memory~%~%")
        (dolist (entry (workspace-memory-entries workspace-memory))
          (format s "## ~a~%~%" (memory-entry-name entry))
          (write-string (memory-entry-content entry) s)
          (format s "~%~%~a~%~%" separator)))))
