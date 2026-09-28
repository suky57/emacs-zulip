;;; zulip-channel-width.el --- Wider description column in emacs-zulip  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Uwe Brauer

;; Author: Uwe Brauer oub@mat.ucm.es
;; Maintainer: Uwe Brauer oub@mat.ucm.es
;; Created: 28 Sep 2026
;; Version: 1.0
;; Keywords:

 
;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; A copy of the GNU General Public License can be obtained from this
;; program's author (send electronic mail to oub@mat.ucm.es) or from
;; the Free Software Foundation, Inc., 675 Mass Ave, Cambridge, MA
;; 02139, USA.



;; emacs-zulip (github.com/suky57/emacs-zulip) truncates channel
;; descriptions to a hard-coded 35 characters in `zulip--channel-printer'
;; (zulip-ui.el).  This redefines that function with a configurable width.

(defvar my/zulip-channel-description-width nil
  "Maximum width of channel descriptions in the channel list.
nil means no truncation: the description runs to the window edge
\(the buffer uses `truncate-lines', so long lines are cut off visually).")

(with-eval-after-load 'zulip-ui
  (defun zulip--channel-printer (chan)
    "Ewoc printer for a `zulip--channel' CHAN (wider description column)."
    (let* ((name (zulip--channel-name chan))
           (private (zulip--channel-invite-only chan))
           (desc (zulip--channel-description chan))
           (cache (zulip--connection-cache zulip--current-connection))
           (unread (zulip--cache-unread-count cache (zulip--channel-id chan)))
           (priv-str (if private
                         (propertize " [P]" 'face 'zulip-channel-private)
                       ""))
           (unread-str (if (> unread 0)
                           (propertize (format " (%d)" unread) 'face 'zulip-unread)
                         ""))
           (name-str (propertize (concat "# " name) 'face 'zulip-channel-name))
           (col1 (concat "  " name-str priv-str unread-str)))
      (insert col1)
      (when (and desc (not (string= desc "")))
        (let ((pad (max 2 (- 45 (string-width col1)))))
          (insert (make-string pad ?\s)
                  (propertize (if my/zulip-channel-description-width
                                  (truncate-string-to-width
                                   desc my/zulip-channel-description-width)
                                desc)
                              'face 'zulip-description)))))))

(provide 'zulip-channel-width)
;;; zulip-channel-width.el ends here
