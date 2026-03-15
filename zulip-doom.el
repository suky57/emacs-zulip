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
;;     :config
;;     (require 'zulip-doom))

;;; Code:

(require 'zulip)

(when (fboundp 'map!)
  ;; Global leader bindings
  (eval '(map! :leader
               :desc "Zulip Home"    "o z" #'zulip-home
               :desc "Zulip Login"   "o Z" #'zulip-login
               :desc "Zulip Connect" "o C-z" #'zulip-connect)))

(provide 'zulip-doom)
;;; zulip-doom.el ends here
