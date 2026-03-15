# Copilot Instructions — emacs-zulip

## Overview

Native Zulip chat client for Emacs 27+, written in pure Emacs Lisp with **zero external dependencies** (only built-in packages: `url.el`, `json.el`, `cl-lib`, `ewoc`, `shr`). Must work in vanilla Emacs and Doom/Evil.

## Architecture & Data Flow

```
zulip.el         → entry point: login, .zuliprc parsing, connection registry
zulip-api.el     → async HTTP via url-retrieve, JSON, all /api/v1/* wrappers
zulip-events.el  → register-queue + long-poll loop, dispatches to cache & hooks
zulip-cache.el   → cl-defstruct records + hash-table stores (channels, users, messages, unread)
zulip-ui.el      → 5 ewoc-backed major modes (home, channels, topics, messages, DMs)
zulip-compose.el → composition buffer with C-c C-c / C-c C-k
zulip-doom.el    → optional SPC leader bindings (loaded via with-eval-after-load)
```

**Connection lifecycle**: `zulip-login` → `zulip--do-login` (creates `zulip--connection` struct, verifies auth synchronously) → `zulip--events-start` (registers event queue, seeds cache from `/register` snapshot) → `zulip--events-poll` (long-poll loop via `run-with-timer`, never blocks).

**Event→UI pipeline**: events arrive → `zulip--events-dispatch` updates cache → runs hooks (`zulip--event-message-hook`, `zulip--event-channel-hook`) → UI handlers refresh ewoc buffers.

## Build & Test

```sh
make compile   # byte-compile all .el files (must produce ZERO warnings)
make test      # compile + run ERT suite
make lint      # strict: byte-compile-error-on-warn = t
make clean     # remove .elc files
```

Always run `make lint` before committing — warnings are treated as errors in CI.

## Code Conventions

- **Naming**: public symbols `zulip-`, internal `zulip--`. Test helpers use `zulip-test--` prefix.
- **File headers**: `;;; file.el --- Description -*- lexical-binding: t; -*-` — lexical binding is mandatory.
- **Structs**: use `cl-defstruct` with explicit `:constructor` and `(:copier nil)`:
  ```elisp
  (cl-defstruct (zulip--channel (:constructor zulip--channel-create) (:copier nil))
    (id 0 :type integer) (name "" :type string))
  ```
- **Hash-table key rules**: `eql` test for integer-keyed maps (user/channel IDs), `equal` for string-keyed maps. Composite keys use `"channel-id:topic"` format via `zulip--message-key`.
- **Autoloads**: tag interactive entry points with `;;;###autoload` (see `zulip-login`, `zulip-home`, `zulip-channels`, `zulip-dms`).
- **Forward declarations**: use `(declare-function fn "source-file")` to avoid byte-compile warnings for cross-module calls.

## Async HTTP Pattern

All API calls use `url-retrieve` (async) with this callback structure:
```elisp
(url-retrieve url
  (lambda (status)
    (unwind-protect
        (let ((data (zulip--api-parse-response)))
          ;; handle data, call user callback via (run-at-time 0 nil callback data)
          )
      (kill-buffer (current-buffer))))  ;; always kill response buffer
  nil t t)
```
- **Callbacks are deferred** with `(run-at-time 0 nil callback data)` to avoid nested callback issues.
- `url-retrieve-synchronously` is allowed **only** during login (`zulip--api-fetch-api-key`, `zulip--api-get-profile-sync`).
- JSON parsing: `zulip--json-parse` auto-selects native Jansson (`json-parse-buffer`) or fallback (`json-read`), always returning hash-tables + vectors.

## JSON Serialization Gotcha

`json-serialize` requires **symbol** keys in alists. For narrow filters:
```elisp
(vector '((operator . "stream") (operand . ,channel-name))
        '((operator . "topic")  (operand . ,topic)))
```

## UI Pattern (ewoc)

Each mode follows: `define-derived-mode` from `special-mode` → `defvar <mode>-mode-map` (parent `special-mode-map`) → ewoc printer function → `--render` function that creates buffer, sets `zulip--current-connection` buffer-local, populates ewoc.

Evil bindings are set up lazily in `(with-eval-after-load 'evil (zulip--evil-setup))` at the bottom of `zulip-ui.el`, using `evil-define-key*` for both `normal` and `motion` states.

## Testing Pattern

ERT tests in `test/test-<module>.el`. No network calls — mock data with hash-tables:
```elisp
(defun zulip-test--make-user-data (id email name)
  (let ((ht (make-hash-table :test 'equal)))
    (puthash "user_id" id ht) (puthash "email" email ht) ...
    ht))
```
Test event dispatch by calling `zulip--events-dispatch` directly with hand-built event hash-tables, then asserting cache state. See `test/test-zulip-events.el` for the canonical pattern.
