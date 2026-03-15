# emacs-zulip — Native Zulip Client for Emacs

A fast, zero-dependency Zulip chat client built entirely with built-in Emacs Lisp packages.  Works in vanilla Emacs 27+ and Doom / Evil.

## Features

- **Home dashboard** — overview of recent channels, DMs, and unread counts
- **Channel / topic / message browsing** with ewoc-backed UI
- **Direct messages** — browse, read, and compose DM conversations
- **Real-time updates** via Zulip's long-polling event API
- **Message composition** with `C-c C-c` send / `C-c C-k` cancel
- **Unread tracking** — counts shown in channel, topic, and DM lists
- **HTML rendering** — messages rendered with `shr` (falls back to plain text)
- **~/.zuliprc credentials** — auto-login from standard Zulip config file
- **Multi-server** — connect to multiple Zulip instances simultaneously
- **Doom / Evil** — proper normal-state keybindings, SPC leader menu

## Requirements

- Emacs **27.1** or later (for native JSON via Jansson)
- No MELPA/ELPA packages required — everything is built-in

## Installation

### package-vc (Emacs 29+, no external tools)

```elisp
(package-vc-install "https://github.com/suky57/emacs-zulip")
```

Then add to your init file:

```elisp
(require 'zulip)
```

### use-package with :vc (Emacs 30+)

```elisp
(use-package zulip
  :vc (:url "https://github.com/suky57/emacs-zulip" :rev :newest)
  :commands (zulip-login zulip-connect zulip-home zulip-channels zulip-dms)
  :custom
  (zulip-default-server "https://your-server.zulipchat.com"))
```

### straight.el

```elisp
(straight-use-package
 '(zulip :type git :host github :repo "suky57/emacs-zulip"))
```

### Doom Emacs

In `~/.doom.d/packages.el`:

```elisp
(package! zulip :recipe (:host github :repo "suky57/emacs-zulip"))
```

In `~/.doom.d/config.el`:

```elisp
(use-package! zulip
  :commands (zulip-login zulip-connect zulip-home zulip-channels zulip-dms)
  :config
  (require 'zulip-doom))
```

### Elpaca

```elisp
(elpaca (zulip :host github :repo "suky57/emacs-zulip")
  (require 'zulip))
```

### Manual (any Emacs 27+)

```sh
git clone https://github.com/suky57/emacs-zulip ~/.emacs.d/site-lisp/emacs-zulip
```

```elisp
(add-to-list 'load-path "~/.emacs.d/site-lisp/emacs-zulip")
(require 'zulip)
```

## Quick Start

### Option A: Using ~/.zuliprc (recommended)

Create `~/.zuliprc` with your Zulip credentials:

```ini
[api]
email=you@example.com
key=your-api-key
site=https://your-server.zulipchat.com
```

Get your API key from **Settings → Personal → API key** in your Zulip instance.

Then run `M-x zulip-login` or `M-x zulip-connect` — credentials are read automatically.

### Option B: Manual entry

1. `M-x zulip-login`
2. Enter your server URL (e.g. `https://your-org.zulipchat.com`)
3. Enter your email address
4. Enter your API key — or leave blank and enter your password

### Multiple servers

To connect to several Zulip instances, use named sections in `~/.zuliprc`:

```ini
[work]
email=you@work.com
key=key1
site=https://work.zulipchat.com

[personal]
email=you@personal.com
key=key2
site=https://personal.zulipchat.com
```

- `M-x zulip-login` — choose which account to connect
- `M-x zulip-connect` — same, from `.zuliprc` only
- `C-u M-x zulip-connect` or `M-x zulip-connect-all` — connect all accounts at once
- `M-x zulip-switch-server` — switch between connected servers

## Commands

| Command               | Description                                     |
|-----------------------|-------------------------------------------------|
| `zulip-login`         | Connect (reads .zuliprc or prompts)             |
| `zulip-connect`       | Connect from .zuliprc (`C-u` = connect all)     |
| `zulip-connect-all`   | Connect all .zuliprc accounts                   |
| `zulip-home`          | Open home dashboard                             |
| `zulip-channels`      | Open channel list                               |
| `zulip-dms`           | Open DM conversations list                      |
| `zulip-switch-server` | Switch between connected servers                |
| `zulip-logout`        | Disconnect from a server                        |
| `zulip-test-connection` | Debug connectivity & auth                     |

## Keybindings

### Emacs (vanilla)

All Zulip modes derive from `special-mode`.  Standard navigation plus:

| Key   | Home / Channels / Topics / DMs | Messages         |
|-------|--------------------------------|------------------|
| `n`   | Next item                      | Next message     |
| `p`   | Previous item                  | Previous message |
| `RET` | Open item                      | —                |
| `c`   | Compose                        | Compose reply    |
| `g`   | Refresh                        | Refresh          |
| `G`   | —                              | Load older       |
| `H`   | Go home                        | Go home          |
| `C`   | *(home)* Channels              | —                |
| `D`   | *(home)* DMs                   | —                |
| `S`   | Switch server                  | —                |
| `Q`   | Logout                         | —                |
| `q`   | Quit buffer                    | Quit buffer      |

### Evil / Doom

When Evil mode is active, all Zulip buffers use **normal state** with vi-style bindings:

| Key     | Action                       |
|---------|------------------------------|
| `j / k` | Standard line movement       |
| `{ / }` | Previous / next item         |
| `l`     | Open item                    |
| `h`     | Go back / go home            |
| `RET`   | Open item                    |
| `q`     | Quit buffer                  |
| `c`     | Compose                      |
| `gr`    | Refresh                      |
| `G`     | *(messages)* Load older      |
| `C`     | *(home)* Channels            |
| `D`     | *(home)* DMs                 |
| `S`     | Switch server                |
| `ZQ`    | Logout                       |

#### Doom leader keys (with `zulip-doom.el`)

| Key         | Action       |
|-------------|--------------|
| `SPC o z`   | Zulip Home   |
| `SPC o Z`   | Zulip Login  |
| `SPC o C-z` | Zulip Connect|

### Compose Buffer

| Key       | Action       |
|-----------|--------------|
| `C-c C-c` | Send message |
| `C-c C-k` | Cancel       |

## Navigation Flow

```
Home Dashboard
  ├── Channels → Topics → Messages
  └── DMs → DM Messages
```

- `l` / `RET` drills down, `h` / `q` goes back
- `H` jumps directly to home from any view
- `S` switches between connected servers

## Configuration

```elisp
;; Pre-fill the server URL on login (if no .zuliprc)
(setq zulip-default-server "https://chat.zulip.org")

;; Path to credentials file (default "~/.zuliprc", nil to disable)
(setq zulip-rc-file "~/.zuliprc")

;; Number of messages to fetch per page (default 50)
(setq zulip-message-limit 100)

;; Disable HTML rendering (show stripped plain text)
(setq zulip-render-html nil)
```

## Architecture

```
zulip.el              ; entry point, login/logout, .zuliprc, connection management
zulip-api.el          ; HTTP layer (url.el), auth, JSON, endpoint wrappers
zulip-events.el       ; event queue registration & long-polling
zulip-cache.el        ; in-memory hash-table cache (channels, topics, messages, users)
zulip-ui.el           ; ewoc-based major modes (home, channels, topics, messages, DMs)
zulip-compose.el      ; message composition buffer
zulip-doom.el         ; optional Doom Emacs integration (SPC leader bindings)
test/                 ; ERT test suite
Makefile              ; compile, test, lint, clean
```

### Key design decisions

- **Zero external dependencies** — only built-in Emacs packages (`url.el`, `json.el`, `cl-lib`, `ewoc`, `shr`)
- **Async I/O** — all HTTP via `url-retrieve` (non-blocking); callbacks deferred to main loop with `run-at-time`
- **Hash-table cache** — O(1) lookups for channels, topics, messages, users, and presence
- **ewoc rendering** — efficient partial re-rendering for list UIs
- **Multi-instance** — each connection owns its own auth, event queue, and cache

## Development

```sh
# Byte-compile (must produce zero warnings)
make compile

# Run ERT test suite
make test

# Strict lint (warnings = errors)
make lint

# Clean .elc files
make clean
```

## License

GPL-3.0-or-later
