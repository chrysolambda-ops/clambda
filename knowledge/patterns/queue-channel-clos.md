# Pattern: Thread-safe Queue Channel (CLOS + bordeaux-threads)

## Problem
Need an in-memory message queue that supports blocking receive with timeout, non-blocking poll, and cooperative close semantics.

## Solution

Use a CLOS class with three slots: a list queue, a bt lock, and a bt condition variable.

```lisp
(defclass queue-channel ()
  ((queue :initform '()   :accessor queue-channel-queue)
   (lock  :initform (bt:make-lock "q-lock") :accessor queue-channel-lock)
   (cvar  :initform (bt:make-condition-variable :name "q-cvar")
          :accessor queue-channel-cvar)
   (open-p :initform t :accessor channel-open-p)))

;;; Send — append to tail under lock, notify one waiter
(defmethod channel-send ((ch queue-channel) message)
  (bt:with-lock-held ((queue-channel-lock ch))
    (setf (queue-channel-queue ch)
          (nconc (queue-channel-queue ch) (list message)))
    (bt:condition-notify (queue-channel-cvar ch))))

;;; Receive — block until item available (with optional timeout)
(defmethod channel-receive ((ch queue-channel) &key timeout)
  (bt:with-lock-held ((queue-channel-lock ch))
    (loop
      (when (queue-channel-queue ch)
        (return (pop (queue-channel-queue ch))))
      (unless (channel-open-p ch)
        (error 'channel-closed-error :channel ch))
      (if timeout
          (bt:condition-wait (queue-channel-cvar ch)
                             (queue-channel-lock ch)
                             :timeout timeout)
          (bt:condition-wait (queue-channel-cvar ch)
                             (queue-channel-lock ch))))))

;;; Poll — non-blocking, returns NIL if empty
(defmethod channel-poll ((ch queue-channel))
  (bt:with-lock-held ((queue-channel-lock ch))
    (when (queue-channel-queue ch)
      (pop (queue-channel-queue ch)))))

;;; Close — set open-p and notify blocked receivers
(defmethod channel-close ((ch queue-channel))
  (bt:with-lock-held ((queue-channel-lock ch))
    (setf (channel-open-p ch) nil)
    (bt:condition-notify (queue-channel-cvar ch))))
```

## Key Rules

1. **All queue mutations under the lock.** Both `nconc` (send) and `pop` (receive) must be inside `bt:with-lock-held`.
2. **`bt:condition-wait` releases the lock.** The lock is re-acquired on wake-up before the loop condition is re-checked.
3. **No `bt:condition-broadcast`.** bordeaux-threads v0.9.4 only has `bt:condition-notify`. For close, one notify is sufficient (receivers check `open-p` and either exit or error).
4. **FIFO via `nconc`.** Use `(nconc queue (list item))` to append; `(pop queue)` to dequeue from head.

## When to Use

- In-memory message passing between threads.
- Testing agent loops without network I/O.
- The queue-channel of the clawmacs/channels protocol.

## Alternatives

- `sb-concurrency:queue` (SBCL-specific, lock-free) — faster for high-throughput, but not portable.
- `bt:semaphore` — simpler for producer/consumer but loses message payloads.
