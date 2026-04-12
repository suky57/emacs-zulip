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
(autoload 'zulip-home          "zulip" "Open Zulip home dashboard." t)
(autoload 'zulip-login         "zulip" "Connect to a Zulip server." t)
(autoload 'zulip-connect       "zulip" "Connect using .zuliprc." t)
(autoload 'zulip-channels      "zulip" "Open Zulip channel list." t)
(autoload 'zulip-dms           "zulip" "Open Zulip DM conversations." t)
(autoload 'zulip-compose       "zulip" "Compose a new Zulip message." t)
(autoload 'zulip-send-file     "zulip" "Upload a file to Zulip." t)
(autoload 'zulip-switch-server "zulip" "Switch Zulip server." t)
(autoload 'zulip-logout        "zulip" "Disconnect from Zulip." t)

(when (fboundp 'map!)
  ;; SPC o z as the Zulip prefix — all commands under one roof
  (eval '(map! :leader
               (:prefix ("o z" . "Zulip")
                :desc "Home"          "h" #'zulip-home
                :desc "Login"         "l" #'zulip-login
                :desc "Connect"       "c" #'zulip-connect
                :desc "Channels"      "C" #'zulip-channels
                :desc "DMs"           "d" #'zulip-dms
                :desc "Compose"       "m" #'zulip-compose
                :desc "Send file"     "a" #'zulip-send-file
                :desc "Switch server" "s" #'zulip-switch-server
                :desc "Logout"        "q" #'zulip-logout))))

(provide 'zulip-doom)
;;; zulip-doom.el ends here
