# Pattern: Workspace Memory Injection

## Problem

Agents lose context between sessions. Workspace `.md` files contain
persistent knowledge (SOUL.md, TEAM.md, daily notes, etc.) that should
be available at every session start without re-fetching.

## Solution

Load priority `.md` files from the workspace directory into a
`workspace-memory` struct, then render them as a context string injected
at the top of the agent's system prompt.

Key design decisions:
- **Priority ordering**: SOUL.md, AGENTS.md, ROADMAP.md loaded first so
  the most important context appears early in the prompt
- **Per-entry truncation**: cap each file at 50K chars to avoid any single
  runaway file
- **Total budget**: stop loading after 200K chars to stay within context windows
- **Separators**: `---` between entries for readability

## Code

```lisp
;; Load memory
(let* ((mem (clambda:load-workspace-memory "/path/to/workspace"
                                           :subdirs '("memory" "knowledge")))
       (ctx (clambda:memory-context-string mem)))

  ;; Inject into system prompt
  (setf (clambda/agent:agent-system-prompt agent)
        (concatenate 'string ctx base-prompt))

  ;; Or search for specific context
  (let ((hits (clambda:search-memory mem "CLOS")))
    (dolist (hit hits)
      (format t "Found in ~a: ~a~%"
              (clambda:memory-entry-name (car hit))
              (cdr hit)))))
```

## UIOP Pathname Note

Always handle both string and pathname inputs:

```lisp
(uiop:ensure-directory-pathname
 (if (stringp path)
     (uiop:parse-native-namestring path)
     path))
```

`uiop:ensure-directory-pathname` does NOT accept pathnames that are already
directory pathnames through `parse-native-namestring` (which expects a string).

## When To Use

- Session initialization for any agent with a workspace directory
- Loading SOUL.md, TEAM.md, daily notes into context
- Implementing the OpenClaw-style memory system in Clambda
