;;; zulip-doom.el --- Doom Emacs integration for emacs-zulip -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Author: emacs-zulip contributors

;;; Commentary:

;; Optional Doom Emacs integration.  Provides SPC leader bindings.
;; Evil keybindings are set up automatically in `zulip-ui.el' via
;; `evil-define-key' — no extra config needed.
;;
;; Installation — add to ~/.doom.d/packages.el:
;;
;;   (package! zulip :recipe (:host github :repo "suky57/emacs-zulip"))
;;
;; Then add to ~/.doom.d/config.el:
;;
;;   (use-package! zulip
;;     :commands (zulip-login zulip-home zulip-channels zulip-dms)
;;     :init
;;     (require 'zulip-doom))
;;
;; NOTE: `zulip-doom' must be loaded in :init (not :config) so that
;; the SPC leader bindings are available before any zulip command is
;; invoked.  This file is intentionally lightweight — it only sets up
;; autoloads and key bindings without loading the rest of emacs-zulip.

;;; Code:

;; Lightweight autoload declarations — avoids (require 'zulip) so this
;; file can be loaded at init time without pulling in the full client.
(autoload 'zulip-home     "zulip" "Open Zulip home dashboard." t)
(autoload 'zulip-login    "zulip" "Connect to a Zulip server." t)
(autoload 'zulip-channels "zulip" "Open Zulip channel list." t)
(autoload 'zulip-dms      "zulip" "Open Zulip DM conversations." t)

(when (fboundp 'map!)
  ;; Global leader bindings
  (eval '(map! :leader
               :desc "Zulip Home"     "o z"   #'zulip-home
               :desc "Zulip Login"    "o Z"   #'zulip-login
               :desc "Zulip Channels" "o C-z" #'zulip-channels)))

(provide 'zulip-doom)
;;; zulip-doom.el ends here
