;;; zulip-quote-reply.el --- Quote-reply for emacs-zulip  -*- lexical-binding: t; -*-

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

;; Adds a Gnus-like "reply with quote" to emacs-zulip
;; (github.com/suky57/emacs-zulip), which only offers a plain reply (`c').
;;
;; In a messages buffer, put point on a message and press `R' or `F'.  A compose
;; buffer opens with the message quoted in Zulip's own quote syntax, the
;; same that the web interface produces with "Quote message":
;;
;;   @_**Sender Name|123** [said](https://…/#narrow/near/456):
;;   ```quote
;;   original text
;;   ```
;;
;; The original text is fetched from the server as Markdown (not the
;; rendered HTML that emacs-zulip keeps), so math, code and mentions in the
;; quote stay intact.

;;; Code:

(require 'zulip-ui)
(require 'zulip-api)

(defun my/zulip-messages-quote-reply ()
  "Reply to the message at point, quoting it."
  (interactive)
  (let* ((node (and zulip--ewoc (ewoc-locate zulip--ewoc)))
         (msg (and node (ewoc-data node))))
    (unless (zulip--message-p msg)
      (user-error "No message at point"))
    (let* ((conn zulip--current-connection)
           (server (zulip--connection-server conn))
           (id (zulip--message-id msg))
           (sender-id (zulip--message-sender-id msg))
           (sender-name (zulip--message-sender-name msg)))
      ;; Open the normal compose buffer for this topic / DM.  It becomes the
      ;; current buffer; remember it for the asynchronous callback.
      (zulip-messages-compose)
      (let ((buf (current-buffer)))
        (message "Zulip: fetching message for quoting…")
        (zulip--api-request
         conn "GET" (format "/messages/%d" id)
         '(("apply_markdown" . "false"))
         (lambda (data)
           (if (not data)
               (message "Zulip: could not fetch the message to quote")
             (let* ((m (gethash "message" data))
                    (content (or (and m (gethash "content" m))
                                 (gethash "raw_content" data) ; older servers
                                 "")))
               (when (buffer-live-p buf)
                 (with-current-buffer buf
                   (goto-char (point-max))
                   (insert (format "@_**%s|%d** [said](%s/#narrow/near/%d):\n"
                                   sender-name sender-id server id)
                           "```quote\n" (string-trim content) "\n```\n\n"))
                 (message "Zulip: quote inserted"))))))))))

(with-eval-after-load 'zulip-ui
  (define-key zulip-messages-mode-map (kbd "R") #'my/zulip-messages-quote-reply)
  (define-key zulip-messages-mode-map (kbd "F") #'my/zulip-messages-quote-reply))

(provide 'zulip-quote-reply)
;;; zulip-quote-reply.el ends here
