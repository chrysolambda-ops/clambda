# Contributing

## Style Guide (Common Lisp)

- Define packages first in `src/packages.lisp`.
- Export/import deliberately; do not rely on implicit symbol visibility.
- Prefer clear condition messages (`define-condition` + `:report`).
- Keep functions small and composable.
- Use `handler-case` / `handler-bind` for recoverable failures.
- For structs, set `:conc-name` intentionally to avoid accessor name collisions.

See also:
- `knowledge/cl-style-guide.md`
- `knowledge/mistakes/recent.md`

## Local Setup

```bash
export LD_LIBRARY_PATH="/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH"
```

Quicklisp must be installed (`~/quicklisp/setup.lisp`).

## Running Tests

```bash
cd projects/clawmacs-core
sbcl --load ~/quicklisp/setup.lisp \
     --eval '(asdf:test-system :clawmacs-core/tests)' \
     --quit
```

Targeted Layer 9 tests:

```bash
sbcl --load ~/quicklisp/setup.lisp \
     --eval '(asdf:load-system :clawmacs-core/tests)' \
     --eval '(parachute:test :clawmacs-core/tests/superpowers)' \
     --quit
```

## Adding a Channel

1. Add package in `src/packages.lisp`.
2. Implement module in `src/<channel>.lisp`.
3. Specialize `clawmacs/config:register-channel` with `(defmethod ... ((type (eql :your-channel)) ...))`.
4. Export lifecycle functions (`start-...`, `stop-...`).
5. Add tests under `t/test-<channel>.lisp`.
6. Wire file into `clawmacs-core.asd` and test system.

## Adding a Tool

1. Register in a registry (`register-tool!` or `define-tool`).
2. Provide JSON-schema parameters.
3. Return string or `tool-result`.
4. Ensure failures are human-readable (error messages should tell the operator what failed and why).
5. Add tests.
