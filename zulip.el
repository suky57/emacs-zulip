;;; zulip.el --- Native Zulip client for Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Author: emacs-zulip contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: comm chat
;; URL: https://github.com/suky57/emacs-zulip

;;; Commentary:

;; A fast, zero-dependency Zulip chat client for Emacs.
;;
;; Quick start:
;;   M-x zulip-login      — connect to a Zulip server (prompts or reads ~/.zuliprc)
;;   M-x zulip-home       — open home dashboard
;;   M-x zulip-channels   — browse channels
;;   M-x zulip-dms        — browse DM conversations
;;   M-x zulip-logout     — disconnect
;;
;; Credentials can be stored in ~/.zuliprc (standard Zulip format):
;;
;;   [api]
;;   email=you@example.com
;;   key=your-api-key
;;   site=https://your-server.zulipchat.com
;;
;; Multiple servers — use named sections:
;;
;;   [work]
;;   email=you@work.com
;;   key=key1
;;   site=https://work.zulipchat.com
;;
;;   [personal]
;;   email=you@personal.com
;;   key=key2
;;   site=https://personal.zulipchat.com
;;
;; Supports multiple simultaneous server connections.
;; Works in vanilla Emacs 27+ and Doom / Evil.

;;; Code:

(require 'cl-lib)
(require 'zulip-cache)
(require 'zulip-api)
(require 'zulip-events)
(require 'zulip-ui)

;; Forward declarations
(declare-function dired-get-filename "dired")
(declare-function zulip-compose-message "zulip-compose")

;;;; Customization

(defgroup zulip nil
  "Native Zulip client for Emacs."
  :group 'comm
  :prefix "zulip-")

(defcustom zulip-default-server nil
  "Default Zulip server URL (e.g. \"https://chat.zulip.org\").
When non-nil, `zulip-login' pre-fills this value."
  :type '(choice (const nil) string)
  :group 'zulip)

(defcustom zulip-rc-file "~/.zuliprc"
  "Path to the zuliprc credentials file.
Standard INI format with [api] or named sections.
Set to nil to disable automatic credential loading."
  :type '(choice (const nil) file)
  :group 'zulip)

;;;; Version

(defconst zulip-version "0.1.0"
  "Current emacs-zulip version.")

;;;; Connection Registry

(defvar zulip--connections nil
  "List of active `zulip--connection' structs.")

(defun zulip--find-connection (server)
  "Find an existing connection for SERVER, or nil."
  (seq-find (lambda (c) (string= (zulip--connection-server c) server))
            zulip--connections))

(defun zulip--normalize-server-url (url)
  "Normalize server URL: enforce https, strip trailing slash."
  (let ((u (string-trim url)))
    ;; Force https — HTTP→HTTPS redirects strip Authorization headers
    (when (string-prefix-p "http://" u)
      (setq u (concat "https://" (substring u 7))))
    (unless (string-match-p "\\`https://" u)
      (setq u (concat "https://" u)))
    (replace-regexp-in-string "/\\'" "" u)))

;;;; ~/.zuliprc parser

(defun zulip--rc-parse (&optional file)
  "Parse FILE (default `zulip-rc-file') as INI.
Return list of alists: ((name . ((key . val) ...)) ...)."
  (let ((f (expand-file-name (or file zulip-rc-file))))
    (when (and f (file-readable-p f))
      (with-temp-buffer
        (insert-file-contents f)
        (let (sections current-section current-name)
          (goto-char (point-min))
          (while (not (eobp))
            (let ((line (string-trim
                         (buffer-substring-no-properties
                          (line-beginning-position)
                          (line-end-position)))))
              (cond
               ;; Section header: [name]
               ((string-match "\\`\\[\\([^]]+\\)\\]\\'" line)
                (when current-section
                  (push (cons current-name (nreverse current-section))
                        sections))
                (setq current-name (match-string 1 line)
                      current-section nil))
               ;; Key=value (ignore comments and blank lines)
               ((string-match "\\`\\([^#;= \t]+\\)[ \t]*=[ \t]*\\(.+\\)" line)
                (push (cons (match-string 1 line)
                            (string-trim (match-string 2 line)))
                      current-section))))
            (forward-line 1))
          (when current-section
            (push (cons current-name (nreverse current-section)) sections))
          (nreverse sections))))))

(defun zulip--rc-get-accounts ()
  "Return list of (SERVER EMAIL API-KEY) from `zulip-rc-file'."
  (let ((sections (zulip--rc-parse))
        accounts)
    (dolist (section sections)
      (let* ((data (cdr section))
             (site (cdr (assoc "site" data)))
             (email (cdr (assoc "email" data)))
             (key (cdr (assoc "key" data))))
        (when (and site email key)
          (push (list (zulip--normalize-server-url site) email key)
                accounts))))
    (nreverse accounts)))

;;;; Login — core

(defun zulip--do-login (server email api-key &optional show-home)
  "Connect to SERVER with EMAIL and API-KEY.
Verify credentials, register connection, start event loop.
When SHOW-HOME is non-nil (default for interactive), show home dashboard."
  (let ((existing (zulip--find-connection server)))
    (if existing
        (progn
          (message "Zulip: already connected to %s" server)
          (when show-home (zulip-home--render existing)))
      (let ((conn (zulip--connection-create
                   :server server
                   :email email
                   :api-key api-key
                   :cache (zulip--cache-create))))
        (message "Zulip: verifying credentials…")
        (let ((profile (zulip--api-get-profile-sync conn)))
          (unless profile
            (user-error "Zulip: auth failed on %s — API key rejected" server))
          (setf (zulip--connection-user-id conn)
                (gethash "user_id" profile))
          ;; Use the canonical email from server profile
          (let ((canonical (gethash "email" profile)))
            (when (and canonical (not (string= canonical email)))
              (setf (zulip--connection-email conn) canonical)))
          (message "Zulip: logged in as %s on %s"
                   (gethash "full_name" profile) server)
          (push conn zulip--connections)
          (zulip--setup-hooks)
          (zulip--events-start conn)
          (when show-home
            (run-with-timer
             1.5 nil
             (lambda () (zulip-home--render conn)))))))))

;;;###autoload
(defun zulip-login ()
  "Connect to a Zulip server.
If ~/.zuliprc exists with account(s), offer them as choices.
Otherwise prompt for server URL, email, and API key / password."
  (interactive)
  (let ((accounts (zulip--rc-get-accounts)))
    (cond
     ;; Single account in .zuliprc — use it directly
     ((= (length accounts) 1)
      (let ((acct (car accounts)))
        (zulip--do-login (nth 0 acct) (nth 1 acct) (nth 2 acct) t)))
     ;; Multiple accounts — let user choose
     ((> (length accounts) 1)
      (let* ((choices
              (mapcar (lambda (a)
                        (cons (format "%s (%s)" (nth 0 a) (nth 1 a)) a))
                      accounts))
             (pick (completing-read "Connect to: "
                                    (mapcar #'car choices) nil t))
             (acct (cdr (assoc pick choices))))
        (zulip--do-login (nth 0 acct) (nth 1 acct) (nth 2 acct) t)))
     ;; No .zuliprc — manual entry
     (t
      (let* ((server (zulip--normalize-server-url
                      (read-string "Zulip server URL: "
                                   zulip-default-server)))
             (email (read-string "Email: "))
             (input-key (read-string
                         "API key (leave empty to use password): "))
             api-key auth-email)
        (if (not (string= input-key ""))
            (setq api-key input-key
                  auth-email email)
          (let* ((password (read-passwd "Password: "))
                 (result (zulip--api-fetch-api-key server email password)))
            (unless result
              (user-error
               "Zulip: authentication failed — check email/password"))
            (setq api-key (car result)
                  auth-email (cdr result))))
        (zulip--do-login server (or auth-email email) api-key t))))))

;;;###autoload
(defun zulip-connect ()
  "Connect to a Zulip server using ~/.zuliprc credentials.
With a prefix argument, connect to ALL accounts in .zuliprc."
  (interactive)
  (let ((accounts (zulip--rc-get-accounts)))
    (unless accounts
      (user-error "No accounts in %s — use M-x zulip-login"
                  (or zulip-rc-file "~/.zuliprc")))
    (if current-prefix-arg
        ;; C-u: connect all
        (dolist (acct accounts)
          (condition-case err
              (zulip--do-login (nth 0 acct) (nth 1 acct) (nth 2 acct) nil)
            (error (message "Zulip: failed to connect %s: %s"
                            (nth 0 acct) (error-message-string err)))))
      ;; No prefix: pick one (or use the only one)
      (let ((acct (if (= (length accounts) 1)
                      (car accounts)
                    (let* ((choices
                            (mapcar (lambda (a)
                                      (cons (format "%s (%s)"
                                                    (nth 0 a) (nth 1 a))
                                            a))
                                    accounts))
                           (pick (completing-read "Connect to: "
                                                  (mapcar #'car choices)
                                                  nil t)))
                      (cdr (assoc pick choices))))))
        (zulip--do-login (nth 0 acct) (nth 1 acct) (nth 2 acct) t)))))

;;;###autoload
(defun zulip-connect-all ()
  "Connect to all accounts in ~/.zuliprc.
Shows the home dashboard for the last connected server."
  (interactive)
  (let ((accounts (zulip--rc-get-accounts)))
    (unless accounts
      (user-error "No accounts in %s" (or zulip-rc-file "~/.zuliprc")))
    (let ((last nil))
      (dolist (acct accounts)
        (condition-case err
            (progn
              (zulip--do-login (nth 0 acct) (nth 1 acct) (nth 2 acct) nil)
              (setq last acct))
          (error (message "Zulip: failed to connect %s: %s"
                          (nth 0 acct) (error-message-string err)))))
      (when last
        (let ((conn (zulip--find-connection (nth 0 last))))
          (when conn
            (run-with-timer
             1.5 nil
             (lambda () (zulip-home--render conn)))))))))

;;;; Logout

;;;###autoload
(defun zulip-logout ()
  "Disconnect from the current Zulip server."
  (interactive)
  (let ((conn (zulip--pick-connection "Logout from: ")))
    (when conn
      (zulip--events-stop conn)
      (setq zulip--connections (delq conn zulip--connections))
      ;; Kill related buffers (collect first to avoid mutating list mid-loop)
      (let ((to-kill (seq-filter
                      (lambda (buf)
                        (with-current-buffer buf
                          (eq zulip--current-connection conn)))
                      (buffer-list))))
        (dolist (buf to-kill)
          (kill-buffer buf)))
      (message "Zulip: disconnected from %s"
               (zulip--connection-server conn)))))

;;;; Browse Channels

;;;###autoload
(defun zulip-channels ()
  "Open the channel list for the current (or chosen) Zulip connection."
  (interactive)
  (let ((conn (or (and (bound-and-true-p zulip--current-connection)
                       zulip--current-connection)
                  (zulip--pick-connection "Show channels for: "))))
    (when conn
      (zulip-channels--render conn))))

;;;###autoload
(defun zulip-home ()
  "Open the home dashboard for the current (or chosen) Zulip connection."
  (interactive)
  (let ((conn (or (and (bound-and-true-p zulip--current-connection)
                       zulip--current-connection)
                  (zulip--pick-connection "Show home for: "))))
    (when conn
      (zulip-home--render conn))))

;;;###autoload
(defun zulip-dms ()
  "Open the DM conversations list for the current (or chosen) connection."
  (interactive)
  (let ((conn (or (and (bound-and-true-p zulip--current-connection)
                       zulip--current-connection)
                  (zulip--pick-connection "Show DMs for: "))))
    (when conn
      (zulip-dm-list--fetch-and-render conn))))

;;;; Compose

;;;###autoload
(defun zulip-compose ()
  "Compose a new Zulip message.\nPrompts for message type (channel or DM) and destination.\nWorks from any buffer — picks an active connection automatically."
  (interactive)
  (let ((conn (or (and (bound-and-true-p zulip--current-connection)
                       zulip--current-connection)
                  (zulip--pick-connection "Compose on: "))))
    (when conn
      (let ((type (completing-read "Message type: "
                                   '("Channel message" "Direct message")
                                   nil t)))
        (require 'zulip-compose)
        (if (string= type "Direct message")
            (let ((email (zulip--read-recipient-email conn)))
              (zulip-compose-message conn "direct" email nil))
          (let* ((ch (completing-read
                      "Channel: "
                      (mapcar #'zulip--channel-name
                              (zulip--cache-channels-sorted
                               (zulip--connection-cache conn)))))
                 (topic (read-string (format "Topic in #%s: " ch))))
            (zulip-compose-message conn "stream" ch topic)))))))

;;;; File Upload / Send

;;;###autoload
(defun zulip-send-file (file)
  "Upload FILE to Zulip and send it as a message.\nPrompts for destination (channel + topic, or DM).\nWhen called from `dired-mode', uses the file at point."
  (interactive
   (list (if (derived-mode-p 'dired-mode)
             (dired-get-filename)
           (read-file-name "File to upload: " nil nil t))))
  (unless (file-readable-p file)
    (user-error "Cannot read file: %s" file))
  (let ((conn (or (and (bound-and-true-p zulip--current-connection)
                       zulip--current-connection)
                  (zulip--pick-connection "Upload to: "))))
    (unless conn
      (user-error "No active Zulip connections — use M-x zulip-login"))
    (let* ((filename (file-name-nondirectory file))
           (type (completing-read
                  (format "Send \"%s\" to: " filename)
                  '("Channel" "Direct message") nil t))
           dest-type dest-to dest-topic)
      (if (string= type "Channel")
          (let* ((ch (completing-read
                      "Channel: "
                      (mapcar #'zulip--channel-name
                              (zulip--cache-channels-sorted
                               (zulip--connection-cache conn)))))
                 (topic (read-string (format "Topic in #%s: " ch))))
            (setq dest-type "stream"
                  dest-to ch
                  dest-topic topic))
        (let ((email (zulip--read-recipient-email conn)))
          (setq dest-type "direct"
                dest-to email
                dest-topic nil)))
      (message "Zulip: uploading %s…" filename)
      (zulip--api-upload-file
       conn file
       (lambda (uri)
         (if (null uri)
             (message "Zulip: upload failed for %s" filename)
           (let* ((server (zulip--connection-server conn))
                  (full-url (concat server uri))
                  (content (format "[%s](%s)" filename full-url)))
             (message "Zulip: sending %s…" filename)
             (zulip--api-send-message
              conn dest-type dest-to dest-topic content
              (lambda (data)
                (if data
                    (message "Zulip: sent %s to %s"
                             filename
                             (if dest-topic
                                 (format "#%s > %s" dest-to dest-topic)
                               dest-to))
                  (message "Zulip: failed to send %s" filename)))))))))))

;;;; Switch Server

;;;###autoload
(defun zulip-switch-server ()
  "Switch to a different connected Zulip server."
  (interactive)
  (let ((conn (zulip--pick-connection "Switch to: ")))
    (when conn
      (zulip-home--render conn))))

;;;; Internal Helpers

(defun zulip--pick-connection (prompt)
  "Let the user pick a connection with PROMPT.  Return `zulip--connection' or nil."
  (cond
   ((null zulip--connections)
    (user-error "No active Zulip connections.  Use M-x zulip-login"))
   ((= (length zulip--connections) 1)
    (car zulip--connections))
   (t
    (let* ((choices (mapcar
                     (lambda (c)
                       (cons (format "%s (%s)"
                                     (zulip--connection-server c)
                                     (zulip--connection-email c))
                             c))
                     zulip--connections))
           (pick (completing-read prompt (mapcar #'car choices) nil t)))
      (cdr (assoc pick choices))))))

(defvar zulip--hooks-installed nil
  "Non-nil after event hooks have been wired up.")

(defun zulip--setup-hooks ()
  "Install event hooks for UI refresh (idempotent)."
  (unless zulip--hooks-installed
    (add-hook 'zulip--event-message-hook #'zulip--ui-on-new-message)
    (add-hook 'zulip--event-channel-hook #'zulip--ui-on-channel-change)
    (setq zulip--hooks-installed t)))

;;;; Diagnostics

;;;###autoload
(defun zulip-test-connection ()
  "Test Zulip API connectivity and auth.  Shows results in *Messages*."
  (interactive)
  (let* ((server (zulip--normalize-server-url
                  (read-string "Server URL: " zulip-default-server)))
         (email  (read-string "Email: "))
         (key    (read-string "API key: ")))
    (message "--- Zulip connection test ---")
    (message "Server: %s" server)
    (message "Email:  %s" email)
    (message "Key:    %s...%s (length %d)"
             (substring key 0 (min 4 (length key)))
             (substring key (max 0 (- (length key) 4)))
             (length key))
    ;; Test 1: server settings (no auth)
    (message "1) GET /server_settings (no auth)...")
    (let ((settings (zulip--api-get-server-settings server)))
      (if settings
          (message "   OK — %s (Zulip %s)"
                   (or (gethash "realm_name" settings) "?")
                   (or (gethash "zulip_version" settings) "?"))
        (message "   FAIL — cannot reach server")))
    ;; Test 2: authenticated profile fetch
    (message "2) GET /users/me (with auth)...")
    (let* ((conn (zulip--connection-create
                  :server server :email email
                  :api-key key :cache (zulip--cache-create)))
           (profile (zulip--api-get-profile-sync conn)))
      (if profile
          (message "   OK — logged in as %s (id %s)"
                   (gethash "full_name" profile)
                   (gethash "user_id" profile))
        ;; Try to get the raw error
        (let* ((url (zulip--api-url conn "/users/me"))
               (headers `(("Authorization" . ,(zulip--api-auth-header conn))
                          ("User-Agent"    . ,zulip--user-agent)))
               (raw (zulip--api-request-sync "GET" url headers nil)))
          (message "   FAIL — raw response: %S" raw))))
    (message "--- end test ---")))

(provide 'zulip)
;;; zulip.el ends here
