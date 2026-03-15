;;; zulip-compose.el --- Message composition for emacs-zulip -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Author: emacs-zulip contributors

;;; Commentary:

;; Provides `zulip-compose-message' for drafting and sending messages.
;; The compose buffer uses a header area (read-only, showing destination)
;; followed by a separator line and the editable message body.
;; C-c C-c sends; C-c C-k cancels.

;;; Code:

(require 'cl-lib)
(require 'zulip-cache)
(require 'zulip-api)

;;;; Hook

(defvar zulip-after-send-message-hook nil
  "Hook run after a message is sent successfully.
Each function is called with (CONN TYPE TO TOPIC).")

;;;; Buffer-local state

(defvar-local zulip--compose-connection nil
  "The `zulip--connection' for this compose buffer.")

(defvar-local zulip--compose-type nil
  "Message type: \"stream\" or \"direct\".")

(defvar-local zulip--compose-to nil
  "Destination: channel name (stream) or user emails (direct).")

(defvar-local zulip--compose-topic nil
  "Topic name (stream) or nil (direct).")

(defvar-local zulip--compose-body-start nil
  "Buffer position where the editable body begins.")

;;;; Compose Mode

(defvar zulip-compose-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map text-mode-map)
    (define-key map (kbd "C-c C-c") #'zulip-compose-send)
    (define-key map (kbd "C-c C-k") #'zulip-compose-cancel)
    map)
  "Keymap for `zulip-compose-mode'.")

(define-derived-mode zulip-compose-mode text-mode "Zulip-Compose"
  "Major mode for composing Zulip messages.

\\<zulip-compose-mode-map>\
\\[zulip-compose-send]  Send message
\\[zulip-compose-cancel]  Cancel"
  (setq header-line-format
        (propertize " C-c C-c: Send  |  C-c C-k: Cancel"
                    'face 'bold)))

;;;; Entry point

;;;###autoload
(defun zulip-compose-message (conn type to &optional topic)
  "Open a compose buffer for CONN.
TYPE  — \"stream\" or \"direct\".
TO    — channel name (stream) or comma-separated emails (direct).
TOPIC — topic string (stream only, prompted if nil)."
  (interactive)
  ;; Prompt for topic if needed
  (when (and (string= type "stream") (null topic))
    (setq topic (read-string (format "Topic in #%s: " to))))
  ;; Create compose buffer
  (let* ((label (if (string= type "stream")
                    (format "#%s > %s" to topic)
                  (format "DM → %s" to)))
         (buf-name (format "*zulip-compose: %s*" label))
         (buf (get-buffer-create buf-name)))
    (with-current-buffer buf
      (erase-buffer)
      (zulip-compose-mode)
      (setq zulip--compose-connection conn
            zulip--compose-type type
            zulip--compose-to to
            zulip--compose-topic topic)
      ;; Insert read-only header
      (let ((inhibit-read-only t))
        (insert (propertize (concat "To: " label "\n")
                            'face 'bold
                            'read-only t
                            'front-sticky '(read-only)
                            'rear-nonsticky '(read-only)))
        (insert (propertize (make-string 50 ?─)
                            'face 'shadow
                            'read-only t
                            'front-sticky '(read-only)
                            'rear-nonsticky '(read-only)))
        (insert (propertize "\n"
                            'read-only t
                            'rear-nonsticky '(read-only))))
      (setq zulip--compose-body-start (point))
      (goto-char (point-max)))
    (switch-to-buffer-other-window buf)))

;;;; Send / Cancel

(defun zulip-compose-send ()
  "Send the composed message."
  (interactive)
  (unless zulip--compose-connection
    (user-error "No Zulip connection for this compose buffer"))
  (let ((content (string-trim
                  (buffer-substring-no-properties
                   zulip--compose-body-start (point-max)))))
    (when (string= content "")
      (user-error "Cannot send empty message"))
    (message "Zulip: sending…")
    (let ((conn  zulip--compose-connection)
          (type  zulip--compose-type)
          (to    zulip--compose-to)
          (topic zulip--compose-topic)
          (buf   (current-buffer)))
      (zulip--api-send-message
       conn type to topic content
       (lambda (data)
         (if data
             (progn
               (message "Zulip: message sent")
               (when (buffer-live-p buf)
                 (kill-buffer buf))
               (run-hook-with-args 'zulip-after-send-message-hook
                                   conn type to topic))
           (message "Zulip: failed to send message")))))))

(defun zulip-compose-cancel ()
  "Cancel composing and close the buffer."
  (interactive)
  (when (yes-or-no-p "Discard this message? ")
    (kill-buffer (current-buffer))))

(provide 'zulip-compose)
;;; zulip-compose.el ends here
