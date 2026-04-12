;;; zulip-ui.el --- UI modes and rendering for emacs-zulip -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Author: emacs-zulip contributors

;;; Commentary:

;; Ewoc-backed major modes for browsing Zulip:
;;   `zulip-home-mode'     — dashboard: unread conversations, channels, DMs
;;   `zulip-channels-mode' — browse subscribed channels
;;   `zulip-topics-mode'   — browse topics within a channel
;;   `zulip-messages-mode' — read messages in a topic or DM
;;   `zulip-dm-list-mode'  — browse DM conversations
;;
;; Evil integration follows evil-collection best practices:
;;   - All modes start in Evil normal state (not motion/emacs)
;;   - `evil-define-key' adds j/k/l/h/gr/q bindings in normal state
;;   - Emacs keymaps remain as fallback for vanilla Emacs users

;;; Code:

(require 'cl-lib)
(require 'ewoc)
(require 'shr)
(require 'url)
(require 'zulip-cache)
(require 'zulip-api)

;;;; Forward declarations

(declare-function zulip-compose-message "zulip-compose")
(declare-function zulip--events-start   "zulip-events")
(declare-function zulip-switch-server   "zulip")
(declare-function zulip-logout          "zulip")
(declare-function evil-define-key*      "evil-core")
(declare-function evil-set-initial-state "evil-core")

;;;; Customizable rendering

(defcustom zulip-render-html t
  "When non-nil and libxml is available, render message HTML with shr.
Otherwise fall back to plain-text tag stripping."
  :type 'boolean
  :group 'zulip)

(defcustom zulip-message-limit 50
  "Number of messages to fetch per page."
  :type 'integer
  :group 'zulip)

;;;; Buffer-local state

(defvar-local zulip--current-connection nil
  "The `zulip--connection' for the current buffer.")

(defvar-local zulip--ewoc nil
  "The ewoc instance for the current buffer.")

(defvar-local zulip--channel-id nil
  "Current channel ID (topics / messages modes).")

(defvar-local zulip--channel-name nil
  "Current channel name (topics / messages modes).")

(defvar-local zulip--topic-name nil
  "Current topic name (messages mode).")

(defvar-local zulip--messages-oldest-id nil
  "ID of the oldest loaded message (for pagination).")

(defvar-local zulip--messages-loading nil
  "Non-nil while a message fetch is in flight.")

(defvar-local zulip--dm-emails nil
  "Comma-separated emails for current DM conversation.")

;;;; Faces

(defface zulip-channel-name
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for channel names."
  :group 'zulip)

(defface zulip-channel-private
  '((t :inherit font-lock-warning-face))
  "Face for private channel indicator."
  :group 'zulip)

(defface zulip-topic-name
  '((t :inherit font-lock-function-name-face))
  "Face for topic names."
  :group 'zulip)

(defface zulip-sender-name
  '((t :inherit font-lock-constant-face :weight bold))
  "Face for message sender names."
  :group 'zulip)

(defface zulip-timestamp
  '((t :inherit font-lock-comment-face))
  "Face for timestamps."
  :group 'zulip)

(defface zulip-unread
  '((t :inherit warning :weight bold))
  "Face for unread counts."
  :group 'zulip)

(defface zulip-description
  '((t :inherit font-lock-doc-face))
  "Face for channel descriptions."
  :group 'zulip)

(defface zulip-separator
  '((t :inherit shadow))
  "Face for visual separators."
  :group 'zulip)

(defface zulip-section-heading
  '((t :inherit outline-1 :weight bold :height 1.1))
  "Face for section headings in home view."
  :group 'zulip)

(defface zulip-dm-name
  '((t :inherit font-lock-string-face :weight bold))
  "Face for DM conversation names."
  :group 'zulip)

;;;; Timestamp formatting

(defun zulip--format-timestamp (unix-time)
  "Format UNIX-TIME integer into a human-readable string."
  (let* ((time     (seconds-to-time unix-time))
         (today    (format-time-string "%Y-%m-%d"))
         (msg-date (format-time-string "%Y-%m-%d" time))
         (msg-year (format-time-string "%Y" time))
         (cur-year (format-time-string "%Y")))
    (cond
     ((string= today msg-date)
      (format-time-string "%H:%M" time))
     ((string= msg-year cur-year)
      (format-time-string "%b %d %H:%M" time))
     (t
      (format-time-string "%b %d, %Y %H:%M" time)))))

;;;; Key hint helper

(defsubst zulip--refresh-key-hint ()
  "Return \"gr\" when Evil is loaded, \"g\" otherwise.
Evil uses `g' as a prefix key, so refresh is bound to `gr'."
  (if (featurep 'evil) "gr" "g"))

;;;; HTML rendering

(defun zulip--insert-content (html)
  "Insert rendered message content from HTML into current buffer."
  (if (and zulip-render-html
           (fboundp 'libxml-parse-html-region))
      (let ((dom (with-temp-buffer
                   (insert html)
                   (libxml-parse-html-region (point-min) (point-max)))))
        (let ((shr-use-fonts nil)
              (shr-width (min 80 (- (window-width) 4)))
              (shr-base (when (bound-and-true-p zulip--current-connection)
                          (url-generic-parse-url
                           (zulip--connection-server
                            zulip--current-connection)))))
          (shr-insert-document dom)))
    (insert (zulip--strip-html html))))

(defun zulip--strip-html (html)
  "Strip HTML tags from HTML, preserving basic structure."
  (with-temp-buffer
    (insert html)
    (goto-char (point-min))
    (while (re-search-forward "<br[^>]*>" nil t) (replace-match "\n"))
    (goto-char (point-min))
    (while (re-search-forward "</p>" nil t) (replace-match "\n"))
    (goto-char (point-min))
    (while (re-search-forward "<[^>]+>" nil t) (replace-match ""))
    (goto-char (point-min))
    (while (re-search-forward "&amp;" nil t) (replace-match "&"))
    (goto-char (point-min))
    (while (re-search-forward "&lt;" nil t) (replace-match "<"))
    (goto-char (point-min))
    (while (re-search-forward "&gt;" nil t) (replace-match ">"))
    (goto-char (point-min))
    (while (re-search-forward "&quot;" nil t) (replace-match "\""))
    (goto-char (point-min))
    (while (re-search-forward "&#39;" nil t) (replace-match "'"))
    (goto-char (point-min))
    (while (re-search-forward "\n\\{3,\\}" nil t) (replace-match "\n\n"))
    (string-trim (buffer-string))))

;; ═══════════════════════════════════════════════════════════════════════
;;  HOME / DASHBOARD MODE
;; ═══════════════════════════════════════════════════════════════════════

(cl-defstruct (zulip--home-entry (:constructor zulip--home-entry-create)
                                 (:copier nil))
  "A navigable entry in the home dashboard."
  (type nil)         ; section-header, channel-topic, dm, channel
  (label "")
  (channel-id nil)
  (channel-name nil)
  (topic nil)
  (emails nil)
  (unread 0)
  (timestamp 0))

(defvar zulip-home-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "RET") #'zulip-home-open-at-point)
    (define-key map (kbd "C")   #'zulip-home-channels)
    (define-key map (kbd "D")   #'zulip-home-dms)
    (define-key map (kbd "c")   #'zulip-home-compose)
    (define-key map (kbd "g")   #'zulip-home-refresh)
    (define-key map (kbd "n")   #'zulip-home-next)
    (define-key map (kbd "p")   #'zulip-home-prev)
    (define-key map (kbd "q")   #'quit-window)
    (define-key map (kbd "S")   #'zulip-switch-server)
    (define-key map (kbd "Q")   #'zulip-logout)
    map)
  "Keymap for `zulip-home-mode'.")

(define-derived-mode zulip-home-mode special-mode "Zulip-Home"
  "Major mode for the Zulip home dashboard.
\\{zulip-home-mode-map}"
  (setq truncate-lines t
        buffer-read-only t))

(defun zulip--home-printer (entry)
  "Ewoc printer for a `zulip--home-entry' ENTRY."
  (pcase (zulip--home-entry-type entry)
    ('section-header
     (insert "\n  "
             (propertize (zulip--home-entry-label entry)
                         'face 'zulip-section-heading)
             "\n"))
    ('channel-topic
     (let* ((unread (zulip--home-entry-unread entry))
            (unread-str (if (> unread 0)
                            (propertize (format " (%d)" unread)
                                        'face 'zulip-unread)
                          ""))
            (ts (zulip--home-entry-timestamp entry))
            (ts-str (if (> ts 0)
                        (propertize (concat "  " (zulip--format-timestamp ts))
                                    'face 'zulip-timestamp)
                      "")))
       (insert "    "
               (propertize (concat "# " (zulip--home-entry-channel-name entry))
                           'face 'zulip-channel-name)
               " > "
               (propertize (or (zulip--home-entry-topic entry) "")
                           'face 'zulip-topic-name)
               unread-str ts-str)))
    ('dm
     (let* ((unread (zulip--home-entry-unread entry))
            (unread-str (if (> unread 0)
                            (propertize (format " (%d)" unread)
                                        'face 'zulip-unread)
                          ""))
            (ts (zulip--home-entry-timestamp entry))
            (ts-str (if (> ts 0)
                        (propertize (concat "  " (zulip--format-timestamp ts))
                                    'face 'zulip-timestamp)
                      "")))
       (insert "    "
               (propertize (zulip--home-entry-label entry)
                           'face 'zulip-dm-name)
               unread-str ts-str)))
    ('channel
     (let* ((unread (zulip--home-entry-unread entry))
            (unread-str (if (> unread 0)
                            (propertize (format " (%d)" unread)
                                        'face 'zulip-unread)
                          "")))
       (insert "    "
               (propertize (concat "# " (zulip--home-entry-label entry))
                           'face 'zulip-channel-name)
               unread-str)))))

(defun zulip-home--buffer-name (conn)
  "Buffer name for home dashboard of CONN."
  (format "*zulip: %s*" (zulip--connection-server conn)))

(defun zulip-home--render (conn)
  "Create or refresh the home dashboard buffer for CONN."
  (let* ((buf-name (zulip-home--buffer-name conn))
         (buf (get-buffer-create buf-name))
         (cache (zulip--connection-cache conn)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (zulip-home-mode)
        (setq zulip--current-connection conn)
        (setq header-line-format
              (format " Zulip: %s (%s)"
                      (zulip--connection-server conn)
                      (zulip--connection-email conn)))
        (setq zulip--ewoc
              (ewoc-create #'zulip--home-printer
                           ""
                           (concat "\n"
                                   (propertize
                                    (concat "  [RET] Open  [C] Channels  "
                                            "[D] DMs  [c] Compose  "
                                            (format "[%s] Refresh  [q] Quit"
                                                    (zulip--refresh-key-hint)))
                                    'face 'zulip-separator))))
        ;; --- Section: Unread conversations ---
        (let ((unreads (zulip--home-collect-unreads cache conn)))
          (when unreads
            (ewoc-enter-last zulip--ewoc
                             (zulip--home-entry-create
                              :type 'section-header
                              :label "Unread conversations"))
            (dolist (entry unreads)
              (ewoc-enter-last zulip--ewoc entry))))
        ;; --- Section: Channels ---
        (ewoc-enter-last zulip--ewoc
                         (zulip--home-entry-create
                          :type 'section-header
                          :label "Channels"))
        (dolist (ch (zulip--cache-channels-sorted cache))
          (let ((unread (zulip--cache-unread-count
                         cache (zulip--channel-id ch))))
            (ewoc-enter-last zulip--ewoc
                             (zulip--home-entry-create
                              :type 'channel
                              :label (zulip--channel-name ch)
                              :channel-id (zulip--channel-id ch)
                              :channel-name (zulip--channel-name ch)
                              :unread unread))))
        ;; Position on first navigable item
        (goto-char (point-min))
        (zulip-home-next)))
    (switch-to-buffer buf)))

(defun zulip--home-collect-unreads (cache _conn)
  "Collect unread channel-topic and DM entries from CACHE."
  (let (entries)
    ;; Stream unreads
    (maphash
     (lambda (key count)
       (when (and (> count 0) (not (string-prefix-p "dm:" key)))
         (let* ((colon-pos (string-match ":" key))
                (ch-id (string-to-number (substring key 0 colon-pos)))
                (topic (substring key (1+ colon-pos)))
                (ch (zulip--cache-get-channel cache ch-id)))
           (when ch
             (push (zulip--home-entry-create
                    :type 'channel-topic
                    :label (concat (zulip--channel-name ch) " > " topic)
                    :channel-id ch-id
                    :channel-name (zulip--channel-name ch)
                    :topic topic
                    :unread count)
                   entries)))))
     (zulip--cache-unread cache))
    ;; DM unreads
    (maphash
     (lambda (key count)
       (when (and (> count 0) (string-prefix-p "dm:" key))
         (let* ((uid (string-to-number (substring key 3)))
                (user (zulip--cache-get-user cache uid))
                (name (if user (zulip--user-full-name user)
                        (format "User %d" uid))))
           (push (zulip--home-entry-create
                  :type 'dm
                  :label name
                  :emails (if user (zulip--user-email user)
                            (number-to-string uid))
                  :unread count)
                 entries))))
     (zulip--cache-unread cache))
    ;; Sort by unread count descending
    (sort entries (lambda (a b) (> (zulip--home-entry-unread a)
                                   (zulip--home-entry-unread b))))))

;;; Home interactive commands

(defun zulip-home-open-at-point ()
  "Open the item at point in the home dashboard."
  (interactive)
  (let ((node (and zulip--ewoc (ewoc-locate zulip--ewoc))))
    (when node
      (let ((entry (ewoc-data node)))
        (pcase (zulip--home-entry-type entry)
          ('channel-topic
           (zulip-messages--fetch-and-render
            zulip--current-connection
            (zulip--home-entry-channel-id entry)
            (zulip--home-entry-channel-name entry)
            (zulip--home-entry-topic entry)))
          ('channel
           (zulip-topics--fetch-and-render
            zulip--current-connection
            (zulip--home-entry-channel-id entry)
            (or (zulip--home-entry-channel-name entry)
                (zulip--home-entry-label entry))))
          ('dm
           (zulip-dm--fetch-and-render
            zulip--current-connection
            (zulip--home-entry-label entry)
            (zulip--home-entry-emails entry)))
          ('section-header nil))))))

(defun zulip-home-channels ()
  "Open the full channels list."
  (interactive)
  (zulip-channels--render zulip--current-connection))

(defun zulip-home-dms ()
  "Open the DM conversations list."
  (interactive)
  (zulip-dm-list--fetch-and-render zulip--current-connection))

(defun zulip--read-recipient-email (conn)
  "Read recipient for DM with completion from cached users of CONN.
Offers non-bot users as \"Full Name <email>\" candidates.
Falls back to `read-string' when the user cache is empty."
  (let* ((cache (zulip--connection-cache conn))
         (self-id (zulip--connection-user-id conn))
         (candidates nil))
    (maphash
     (lambda (_id user)
       (unless (or (eql (zulip--user-id user) self-id)
                   (zulip--user-is-bot user))
         (push (format "%s <%s>"
                       (zulip--user-full-name user)
                       (zulip--user-email user))
               candidates)))
     (zulip--cache-users cache))
    (if candidates
        (let* ((sorted (sort candidates #'string<))
               (chosen (completing-read "Recipient: " sorted nil t)))
          (if (string-match "<\\([^>]+\\)>" chosen)
              (match-string 1 chosen)
            chosen))
      (read-string "Recipient email (no users cached): "))))

(defun zulip--read-topic (conn channel-name)
  "Read a topic name for CHANNEL-NAME on CONN with completion.
Offers existing cached topics as candidates but allows free-form
input for new topics.  Falls back to plain `read-string' when no
topics are cached."
  (let* ((cache (zulip--connection-cache conn))
         (ch (zulip--cache-find-channel-by-name cache channel-name))
         (topics (when ch
                   (zulip--cache-get-topics cache (zulip--channel-id ch))))
         (candidates (when (vectorp topics)
                       (mapcar #'zulip--topic-name (append topics nil)))))
    (if candidates
        (completing-read (format "Topic in #%s: " channel-name)
                         candidates nil nil)
      (read-string (format "Topic in #%s (new): " channel-name)))))

(defun zulip-home-compose ()
  "Start composing a new message."
  (interactive)
  (let ((type (completing-read "Message type: "
                               '("Channel message" "Direct message")
                               nil t)))
    (require 'zulip-compose)
    (if (string= type "Direct message")
        (let ((email (zulip--read-recipient-email
                      zulip--current-connection)))
          (zulip-compose-message zulip--current-connection
                                 "direct" email nil))
      (let* ((ch (completing-read "Channel: "
                                  (mapcar #'zulip--channel-name
                                          (zulip--cache-channels-sorted
                                           (zulip--connection-cache
                                            zulip--current-connection)))))
             (topic (zulip--read-topic zulip--current-connection ch)))
        (zulip-compose-message zulip--current-connection
                               "stream" ch topic)))))

(defun zulip-home-refresh ()
  "Refresh the home dashboard."
  (interactive)
  (zulip-home--render zulip--current-connection))

(defun zulip-home-next ()
  "Move to next navigable item (skip section headers)."
  (interactive)
  (when zulip--ewoc
    (let ((node (ewoc-locate zulip--ewoc)))
      (when node
        (let ((next (ewoc-next zulip--ewoc node)))
          (while (and next
                      (eq (zulip--home-entry-type (ewoc-data next))
                          'section-header))
            (setq next (ewoc-next zulip--ewoc next)))
          (when next (ewoc-goto-node zulip--ewoc next)))))))

(defun zulip-home-prev ()
  "Move to previous navigable item (skip section headers)."
  (interactive)
  (when zulip--ewoc
    (let ((node (ewoc-locate zulip--ewoc)))
      (when node
        (let ((prev (ewoc-prev zulip--ewoc node)))
          (while (and prev
                      (eq (zulip--home-entry-type (ewoc-data prev))
                          'section-header))
            (setq prev (ewoc-prev zulip--ewoc prev)))
          (when prev (ewoc-goto-node zulip--ewoc prev)))))))

;; ═══════════════════════════════════════════════════════════════════════
;;  CHANNELS MODE
;; ═══════════════════════════════════════════════════════════════════════

(defvar zulip-channels-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "RET") #'zulip-channels-open-topic)
    (define-key map (kbd "c")   #'zulip-channels-compose)
    (define-key map (kbd "g")   #'zulip-channels-refresh)
    (define-key map (kbd "n")   #'zulip-channels-next)
    (define-key map (kbd "p")   #'zulip-channels-prev)
    (define-key map (kbd "q")   #'quit-window)
    (define-key map (kbd "S")   #'zulip-switch-server)
    (define-key map (kbd "Q")   #'zulip-logout)
    (define-key map (kbd "H")   #'zulip-channels-go-home)
    map)
  "Keymap for `zulip-channels-mode'.")

(define-derived-mode zulip-channels-mode special-mode "Zulip-Channels"
  "Major mode for browsing Zulip channels.
\\{zulip-channels-mode-map}"
  (setq truncate-lines t
        buffer-read-only t))

(defun zulip--channel-printer (chan)
  "Ewoc printer for a `zulip--channel' CHAN."
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
                (propertize (truncate-string-to-width desc 35)
                            'face 'zulip-description))))))

(defun zulip-channels--buffer-name (conn)
  "Buffer name for channels list of CONN."
  (format "*zulip-channels: %s*" (zulip--connection-server conn)))

(defun zulip-channels--render (conn)
  "Create or refresh the channels buffer for CONN."
  (let* ((buf-name (zulip-channels--buffer-name conn))
         (buf (get-buffer-create buf-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (zulip-channels-mode)
        (setq zulip--current-connection conn)
        (setq header-line-format
              (format " Zulip Channels: %s"
                      (zulip--connection-server conn)))
        (setq zulip--ewoc
              (ewoc-create #'zulip--channel-printer
                           (propertize "  Channels\n" 'face 'bold)
                           (concat "\n"
                                   (propertize
                                    (format "  [RET] Topics  [c] Compose  [%s] Refresh  [H] Home  [q] Quit"
                                            (zulip--refresh-key-hint))
                                    'face 'zulip-separator))))
        (dolist (ch (zulip--cache-channels-sorted
                     (zulip--connection-cache conn)))
          (ewoc-enter-last zulip--ewoc ch))
        (goto-char (point-min))
        (forward-line 2)))
    (switch-to-buffer buf)))

;;; Channels interactive commands

(defun zulip-channels-open-topic ()
  "Open the topic list for the channel at point."
  (interactive)
  (let ((node (ewoc-locate zulip--ewoc)))
    (when node
      (let ((chan (ewoc-data node)))
        (zulip-topics--fetch-and-render
         zulip--current-connection
         (zulip--channel-id chan)
         (zulip--channel-name chan))))))

(defun zulip-channels-compose ()
  "Compose a new message in the channel at point."
  (interactive)
  (let ((node (ewoc-locate zulip--ewoc)))
    (when node
      (let* ((chan (ewoc-data node))
             (topic (zulip--read-topic zulip--current-connection
                                       (zulip--channel-name chan))))
        (require 'zulip-compose)
        (zulip-compose-message zulip--current-connection
                               "stream"
                               (zulip--channel-name chan)
                               topic)))))

(defun zulip-channels-refresh ()
  "Refresh the channels list from server."
  (interactive)
  (let ((conn zulip--current-connection))
    (zulip--api-get-channels
     conn
     (lambda (data)
       (when data
         (let ((cache (zulip--connection-cache conn))
               (subs (gethash "subscriptions" data)))
           (when (vectorp subs)
             (clrhash (zulip--cache-channels cache))
             (seq-do (lambda (s) (zulip--cache-put-channel cache s)) subs))
           (zulip-channels--render conn)))))))

(defun zulip-channels-next ()
  "Move to next channel."
  (interactive)
  (when zulip--ewoc
    (let* ((node (ewoc-locate zulip--ewoc))
           (next (and node (ewoc-next zulip--ewoc node))))
      (when next (ewoc-goto-node zulip--ewoc next)))))

(defun zulip-channels-prev ()
  "Move to previous channel."
  (interactive)
  (when zulip--ewoc
    (let* ((node (ewoc-locate zulip--ewoc))
           (prev (and node (ewoc-prev zulip--ewoc node))))
      (when prev (ewoc-goto-node zulip--ewoc prev)))))

(defun zulip-channels-go-home ()
  "Go back to the home dashboard."
  (interactive)
  (zulip-home--render zulip--current-connection))

;; ═══════════════════════════════════════════════════════════════════════
;;  TOPICS MODE
;; ═══════════════════════════════════════════════════════════════════════

(defvar zulip-topics-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "RET") #'zulip-topics-open-messages)
    (define-key map (kbd "c")   #'zulip-topics-compose)
    (define-key map (kbd "g")   #'zulip-topics-refresh)
    (define-key map (kbd "n")   #'zulip-topics-next)
    (define-key map (kbd "p")   #'zulip-topics-prev)
    (define-key map (kbd "q")   #'quit-window)
    (define-key map (kbd "H")   #'zulip-topics-go-home)
    map)
  "Keymap for `zulip-topics-mode'.")

(define-derived-mode zulip-topics-mode special-mode "Zulip-Topics"
  "Major mode for browsing topics within a Zulip channel.
\\{zulip-topics-mode-map}"
  (setq truncate-lines t
        buffer-read-only t))

(defun zulip--topic-printer (topic)
  "Ewoc printer for a `zulip--topic' TOPIC."
  (let* ((name (zulip--topic-name topic))
         (cache (zulip--connection-cache zulip--current-connection))
         (unread (zulip--cache-unread-count cache
                                            (zulip--topic-channel-id topic)
                                            name))
         (unread-str (if (> unread 0)
                         (propertize (format " (%d)" unread) 'face 'zulip-unread)
                       "")))
    (insert "  "
            (propertize name 'face 'zulip-topic-name)
            unread-str)))

(defun zulip-topics--buffer-name (channel-name)
  "Buffer name for topics list of CHANNEL-NAME."
  (format "*zulip-topics: #%s*" channel-name))

(defun zulip-topics--fetch-and-render (conn channel-id channel-name)
  "Fetch and display topics for CHANNEL-ID / CHANNEL-NAME on CONN."
  (message "Zulip: loading topics for #%s..." channel-name)
  (zulip--api-get-topics
   conn channel-id
   (lambda (data)
     (if (null data)
         (message "Zulip: failed to load topics for #%s" channel-name)
       (let* ((topics-raw (gethash "topics" data))
              (cache (zulip--connection-cache conn)))
         (when (vectorp topics-raw)
           (zulip--cache-put-topics cache channel-id topics-raw))
         (zulip-topics--render conn channel-id channel-name))))))

(defun zulip-topics--render (conn channel-id channel-name)
  "Render topics buffer for CHANNEL-ID / CHANNEL-NAME on CONN."
  (let* ((buf-name (zulip-topics--buffer-name channel-name))
         (buf (get-buffer-create buf-name))
         (cache (zulip--connection-cache conn))
         (topics (zulip--cache-get-topics cache channel-id)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (zulip-topics-mode)
        (setq zulip--current-connection conn
              zulip--channel-id channel-id
              zulip--channel-name channel-name)
        (setq header-line-format
              (format " #%s -- Topics" channel-name))
        (setq zulip--ewoc
              (ewoc-create #'zulip--topic-printer
                           (propertize (format "  #%s\n" channel-name) 'face 'bold)
                           (concat "\n"
                                   (propertize
                                    (format "  [RET] Messages  [c] Compose  [%s] Refresh  [H] Home  [q] Back"
                                            (zulip--refresh-key-hint))
                                    'face 'zulip-separator))))
        (when (vectorp topics)
          (let ((sorted (sort (append topics nil)
                             (lambda (a b)
                               (> (zulip--topic-max-id a)
                                  (zulip--topic-max-id b))))))
            (seq-do (lambda (tp) (ewoc-enter-last zulip--ewoc tp)) sorted)))
        (goto-char (point-min))
        (forward-line 2)))
    (switch-to-buffer buf)))

;;; Topics interactive commands

(defun zulip-topics-open-messages ()
  "Open messages for the topic at point."
  (interactive)
  (let ((node (ewoc-locate zulip--ewoc)))
    (when node
      (let ((topic (ewoc-data node)))
        (zulip-messages--fetch-and-render
         zulip--current-connection
         zulip--channel-id
         zulip--channel-name
         (zulip--topic-name topic))))))

(defun zulip-topics-compose ()
  "Compose a message in the topic at point."
  (interactive)
  (let ((node (ewoc-locate zulip--ewoc)))
    (when node
      (let ((topic (ewoc-data node)))
        (require 'zulip-compose)
        (zulip-compose-message zulip--current-connection
                               "stream"
                               zulip--channel-name
                               (zulip--topic-name topic))))))

(defun zulip-topics-refresh ()
  "Refresh the topic list."
  (interactive)
  (zulip-topics--fetch-and-render
   zulip--current-connection
   zulip--channel-id
   zulip--channel-name))

(defun zulip-topics-next ()
  "Move to next topic."
  (interactive)
  (when zulip--ewoc
    (let* ((node (ewoc-locate zulip--ewoc))
           (next (and node (ewoc-next zulip--ewoc node))))
      (when next (ewoc-goto-node zulip--ewoc next)))))

(defun zulip-topics-prev ()
  "Move to previous topic."
  (interactive)
  (when zulip--ewoc
    (let* ((node (ewoc-locate zulip--ewoc))
           (prev (and node (ewoc-prev zulip--ewoc node))))
      (when prev (ewoc-goto-node zulip--ewoc prev)))))

(defun zulip-topics-go-home ()
  "Go back to the home dashboard."
  (interactive)
  (zulip-home--render zulip--current-connection))

;; ═══════════════════════════════════════════════════════════════════════
;;  MESSAGES MODE
;; ═══════════════════════════════════════════════════════════════════════

(defvar zulip-messages-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "c")   #'zulip-messages-compose)
    (define-key map (kbd "g")   #'zulip-messages-refresh)
    (define-key map (kbd "G")   #'zulip-messages-load-more)
    (define-key map (kbd "n")   #'zulip-messages-next)
    (define-key map (kbd "p")   #'zulip-messages-prev)
    (define-key map (kbd "q")   #'quit-window)
    (define-key map (kbd "H")   #'zulip-messages-go-home)
    map)
  "Keymap for `zulip-messages-mode'.")

(define-derived-mode zulip-messages-mode special-mode "Zulip-Messages"
  "Major mode for reading Zulip messages.
\\{zulip-messages-mode-map}"
  (setq truncate-lines nil
        word-wrap t
        buffer-read-only t))

(defun zulip--message-printer (msg)
  "Ewoc printer for a `zulip--message' MSG."
  (let* ((name (zulip--message-sender-name msg))
         (time (zulip--format-timestamp (zulip--message-timestamp msg)))
         (content (zulip--message-content msg))
         (width (max 40 (- (window-width) 2)))
         (time-len (length time))
         (name-col (- width time-len)))
    ;; Separator line
    (insert (propertize (make-string (min width 78) ?-) 'face 'zulip-separator)
            "\n")
    ;; Sender + timestamp
    (insert "  "
            (propertize name 'face 'zulip-sender-name)
            (make-string (max 1 (- name-col (length name) 2)) ?\s)
            (propertize time 'face 'zulip-timestamp)
            "\n")
    ;; Content
    (let ((start (point)))
      (insert "  ")
      (zulip--insert-content content)
      ;; Indent every line of content
      (save-excursion
        (goto-char start)
        (forward-line 1)
        (while (< (point) (point-max))
          (unless (looking-at-p "  ")
            (insert "  "))
          (forward-line 1))))
    (insert "\n")))

(defun zulip-messages--buffer-name (channel-name topic)
  "Buffer name for messages in CHANNEL-NAME > TOPIC."
  (format "*zulip: #%s > %s*" channel-name topic))

(defun zulip-messages--fetch-and-render (conn channel-id channel-name topic)
  "Fetch and display messages for CHANNEL-ID/CHANNEL-NAME > TOPIC."
  (message "Zulip: loading messages for #%s > %s..." channel-name topic)
  ;; Mark topic as read
  (zulip--api-mark-topic-read conn channel-id topic (lambda (_) nil))
  (zulip--cache-clear-unread (zulip--connection-cache conn) channel-id topic)
  ;; Fetch messages
  (let ((narrow (zulip--narrow-channel-topic channel-name topic)))
    (zulip--api-get-messages
     conn narrow "newest" zulip-message-limit 0
     (lambda (data)
       (if (null data)
           (message "Zulip: failed to load messages")
         (let* ((msgs-raw (gethash "messages" data))
                (cache (zulip--connection-cache conn))
                (parsed (when (vectorp msgs-raw)
                          (vconcat
                           (mapcar
                            (lambda (m) (zulip--cache-put-message cache m))
                            msgs-raw)))))
           (when parsed
             (zulip--cache-store-messages cache channel-id topic parsed))
           (zulip-messages--render conn channel-id channel-name topic)))))))

(defun zulip-messages--render (conn channel-id channel-name topic)
  "Render messages buffer for CHANNEL-ID/CHANNEL-NAME > TOPIC."
  (let* ((buf-name (zulip-messages--buffer-name channel-name topic))
         (buf (get-buffer-create buf-name))
         (cache (zulip--connection-cache conn))
         (msgs (zulip--cache-get-messages cache channel-id topic)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (zulip-messages-mode)
        (setq zulip--current-connection conn
              zulip--channel-id channel-id
              zulip--channel-name channel-name
              zulip--topic-name topic
              zulip--messages-loading nil
              zulip--dm-emails nil)
        (setq header-line-format
              (format " #%s > %s" channel-name topic))
        (setq zulip--ewoc
              (ewoc-create #'zulip--message-printer
                           ""
                           (concat "\n"
                                   (propertize
                                    (format "  [c] Reply  [G] Load more  [%s] Refresh  [H] Home  [q] Back"
                                            (zulip--refresh-key-hint))
                                    'face 'zulip-separator))))
        (when (vectorp msgs)
          (seq-do (lambda (m) (ewoc-enter-last zulip--ewoc m)) msgs)
          (when (> (length msgs) 0)
            (setq zulip--messages-oldest-id
                  (zulip--message-id (aref msgs 0)))))
        ;; Scroll to bottom
        (goto-char (point-max))
        (forward-line -2)))
    (switch-to-buffer buf)))

;;; Messages interactive commands

(defun zulip-messages-compose ()
  "Compose a reply in the current topic or DM."
  (interactive)
  (require 'zulip-compose)
  (if zulip--dm-emails
      (zulip-compose-message zulip--current-connection
                             "direct" zulip--dm-emails nil)
    (zulip-compose-message zulip--current-connection
                           "stream"
                           zulip--channel-name
                           zulip--topic-name)))

(defun zulip-messages-refresh ()
  "Refresh messages from server."
  (interactive)
  (if zulip--dm-emails
      (zulip-dm--fetch-and-render
       zulip--current-connection
       (or zulip--channel-name "DM")
       zulip--dm-emails)
    (progn
      (zulip--cache-clear-messages
       (zulip--connection-cache zulip--current-connection)
       zulip--channel-id zulip--topic-name)
      (zulip-messages--fetch-and-render
       zulip--current-connection
       zulip--channel-id
       zulip--channel-name
       zulip--topic-name))))

(defun zulip-messages-load-more ()
  "Load older messages (pagination)."
  (interactive)
  (when (and zulip--messages-oldest-id (not zulip--messages-loading))
    (setq zulip--messages-loading t)
    (message "Zulip: loading older messages...")
    (let ((conn zulip--current-connection)
          (ch-id zulip--channel-id)
          (ch-name zulip--channel-name)
          (topic zulip--topic-name)
          (anchor zulip--messages-oldest-id)
          (dm-emails zulip--dm-emails))
      (let ((narrow (if dm-emails
                        (zulip--narrow-dm dm-emails)
                      (zulip--narrow-channel-topic ch-name topic))))
        (zulip--api-get-messages
         conn narrow anchor zulip-message-limit 0
         (lambda (data)
           (setq zulip--messages-loading nil)
           (when data
             (let* ((msgs-raw (gethash "messages" data))
                    (cache (zulip--connection-cache conn)))
               (when (and (vectorp msgs-raw) (> (length msgs-raw) 0))
                 ;; Filter out the anchor message to avoid duplication
                 (let* ((filtered (seq-filter
                                   (lambda (m)
                                     (not (eql (gethash "id" m) anchor)))
                                   msgs-raw))
                        (new-msgs (vconcat
                                   (mapcar
                                    (lambda (m)
                                      (zulip--cache-put-message cache m))
                                    filtered)))
                       (existing (or (and ch-id topic
                                          (zulip--cache-get-messages
                                           cache ch-id topic))
                                     [])))
                   (when (and ch-id topic)
                     (zulip--cache-store-messages
                      cache ch-id topic (vconcat new-msgs existing)))
                   (if dm-emails
                       (zulip-dm--fetch-and-render conn ch-name dm-emails)
                     (zulip-messages--render
                      conn ch-id ch-name topic))))))))))))

(defun zulip-messages-next ()
  "Move to next message."
  (interactive)
  (when zulip--ewoc
    (let* ((node (ewoc-locate zulip--ewoc))
           (next (and node (ewoc-next zulip--ewoc node))))
      (when next (ewoc-goto-node zulip--ewoc next)))))

(defun zulip-messages-prev ()
  "Move to previous message."
  (interactive)
  (when zulip--ewoc
    (let* ((node (ewoc-locate zulip--ewoc))
           (prev (and node (ewoc-prev zulip--ewoc node))))
      (when prev (ewoc-goto-node zulip--ewoc prev)))))

(defun zulip-messages-go-home ()
  "Go back to the home dashboard."
  (interactive)
  (zulip-home--render zulip--current-connection))

;; ═══════════════════════════════════════════════════════════════════════
;;  DM LIST MODE
;; ═══════════════════════════════════════════════════════════════════════

(cl-defstruct (zulip--dm-entry (:constructor zulip--dm-entry-create)
                               (:copier nil))
  "A DM conversation entry."
  (name "" :type string)
  (emails "" :type string)
  (last-msg-id 0 :type integer)
  (timestamp 0 :type integer))

(defvar zulip-dm-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "RET") #'zulip-dm-list-open)
    (define-key map (kbd "c")   #'zulip-dm-list-compose)
    (define-key map (kbd "g")   #'zulip-dm-list-refresh)
    (define-key map (kbd "n")   #'zulip-dm-list-next)
    (define-key map (kbd "p")   #'zulip-dm-list-prev)
    (define-key map (kbd "q")   #'quit-window)
    (define-key map (kbd "H")   #'zulip-dm-list-go-home)
    map)
  "Keymap for `zulip-dm-list-mode'.")

(define-derived-mode zulip-dm-list-mode special-mode "Zulip-DMs"
  "Major mode for browsing DM conversations.
\\{zulip-dm-list-mode-map}"
  (setq truncate-lines t
        buffer-read-only t))

(defun zulip--dm-entry-printer (entry)
  "Ewoc printer for a `zulip--dm-entry' ENTRY."
  (let* ((ts (zulip--dm-entry-timestamp entry))
         (ts-str (if (> ts 0)
                     (propertize (concat "  " (zulip--format-timestamp ts))
                                 'face 'zulip-timestamp)
                   "")))
    (insert "  "
            (propertize (zulip--dm-entry-name entry)
                        'face 'zulip-dm-name)
            ts-str)))

(defun zulip-dm-list--buffer-name (conn)
  "Buffer name for DM list of CONN."
  (format "*zulip-dms: %s*" (zulip--connection-server conn)))

(defun zulip-dm-list--fetch-and-render (conn)
  "Fetch recent DMs and render the DM list for CONN."
  (message "Zulip: loading DM conversations...")
  (let ((narrow (zulip--narrow-is-dm)))
    (zulip--api-get-messages
     conn narrow "newest" 50 0
     (lambda (data)
       (if (null data)
           (message "Zulip: failed to load DMs")
         (let ((msgs (gethash "messages" data))
               (my-id (zulip--connection-user-id conn))
               (seen (make-hash-table :test 'equal))
               entries)
           (when (vectorp msgs)
             (seq-do
              (lambda (m)
                (let* ((dr (gethash "display_recipient" m))
                       (others (when (vectorp dr)
                                 (seq-filter
                                  (lambda (u)
                                    (not (eql (gethash "id" u) my-id)))
                                  dr)))
                       (key (when (vectorp dr)
                              (mapconcat
                               (lambda (u)
                                 (number-to-string (gethash "id" u)))
                               (sort (append dr nil)
                                     (lambda (a b)
                                       (< (gethash "id" a)
                                          (gethash "id" b))))
                               ","))))
                  (when (and key (not (gethash key seen)))
                    (puthash key t seen)
                    (push (zulip--dm-entry-create
                           :name (if others
                                     (mapconcat
                                      (lambda (u)
                                        (gethash "full_name" u))
                                      others ", ")
                                   "Self")
                           :emails (if others
                                       (mapconcat
                                        (lambda (u)
                                          (gethash "email" u))
                                        others ",")
                                     "")
                           :last-msg-id (gethash "id" m)
                           :timestamp (gethash "timestamp" m))
                          entries))))
              msgs))
           (zulip-dm-list--render conn (nreverse entries))))))))

(defun zulip-dm-list--render (conn entries)
  "Render DM list buffer for CONN with ENTRIES."
  (let* ((buf-name (zulip-dm-list--buffer-name conn))
         (buf (get-buffer-create buf-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (zulip-dm-list-mode)
        (setq zulip--current-connection conn)
        (setq header-line-format " Direct Messages")
        (setq zulip--ewoc
              (ewoc-create #'zulip--dm-entry-printer
                           (propertize "  Direct Messages\n" 'face 'bold)
                           (concat "\n"
                                   (propertize
                                    (format "  [RET] Open  [c] New DM  [%s] Refresh  [H] Home  [q] Back"
                                            (zulip--refresh-key-hint))
                                    'face 'zulip-separator))))
        (dolist (entry entries)
          (ewoc-enter-last zulip--ewoc entry))
        (goto-char (point-min))
        (forward-line 2)))
    (switch-to-buffer buf)))

;;; DM list interactive commands

(defun zulip-dm-list-open ()
  "Open the DM conversation at point."
  (interactive)
  (let ((node (and zulip--ewoc (ewoc-locate zulip--ewoc))))
    (when node
      (let ((entry (ewoc-data node)))
        (zulip-dm--fetch-and-render
         zulip--current-connection
         (zulip--dm-entry-name entry)
         (zulip--dm-entry-emails entry))))))

(defun zulip-dm-list-compose ()
  "Compose a new DM."
  (interactive)
  (let ((email (zulip--read-recipient-email zulip--current-connection)))
    (require 'zulip-compose)
    (zulip-compose-message zulip--current-connection
                           "direct" email nil)))

(defun zulip-dm-list-refresh ()
  "Refresh the DM list."
  (interactive)
  (zulip-dm-list--fetch-and-render zulip--current-connection))

(defun zulip-dm-list-next ()
  "Move to next DM."
  (interactive)
  (when zulip--ewoc
    (let* ((node (ewoc-locate zulip--ewoc))
           (next (and node (ewoc-next zulip--ewoc node))))
      (when next (ewoc-goto-node zulip--ewoc next)))))

(defun zulip-dm-list-prev ()
  "Move to previous DM."
  (interactive)
  (when zulip--ewoc
    (let* ((node (ewoc-locate zulip--ewoc))
           (prev (and node (ewoc-prev zulip--ewoc node))))
      (when prev (ewoc-goto-node zulip--ewoc prev)))))

(defun zulip-dm-list-go-home ()
  "Go back to home."
  (interactive)
  (zulip-home--render zulip--current-connection))

;; ═══════════════════════════════════════════════════════════════════════
;;  DM MESSAGES VIEW
;; ═══════════════════════════════════════════════════════════════════════

(defun zulip-dm--buffer-name (name)
  "Buffer name for DM with NAME."
  (format "*zulip-dm: %s*" name))

(defun zulip-dm--fetch-and-render (conn name emails)
  "Fetch and display DM messages with EMAILS on CONN.  NAME is display label."
  (message "Zulip: loading DM with %s..." name)
  ;; Clear DM unread counts for the other user(s)
  (let ((cache (zulip--connection-cache conn)))
    (dolist (email (split-string emails "," t " "))
      (maphash
       (lambda (_id user)
         (when (string= (zulip--user-email user) email)
           (let ((key (concat "dm:" (number-to-string (zulip--user-id user)))))
             (remhash key (zulip--cache-unread cache)))))
       (zulip--cache-users cache))))
  (let ((narrow (zulip--narrow-dm emails)))
    (zulip--api-get-messages
     conn narrow "newest" zulip-message-limit 0
     (lambda (data)
       (if (null data)
           (message "Zulip: failed to load DM")
         (let* ((msgs-raw (gethash "messages" data))
                (cache (zulip--connection-cache conn))
                (parsed (when (vectorp msgs-raw)
                          (vconcat
                           (mapcar
                            (lambda (m) (zulip--cache-put-message cache m))
                            msgs-raw)))))
           (zulip-dm--render conn name emails parsed)))))))

(defun zulip-dm--render (conn name emails msgs)
  "Render DM buffer for CONN with NAME, EMAILS, and MSGS vector."
  (let* ((buf-name (zulip-dm--buffer-name name))
         (buf (get-buffer-create buf-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (zulip-messages-mode)
        (setq zulip--current-connection conn
              zulip--dm-emails emails
              zulip--channel-name name
              zulip--channel-id nil
              zulip--topic-name nil
              zulip--messages-loading nil)
        (setq header-line-format
              (format " DM: %s" name))
        (setq zulip--ewoc
              (ewoc-create #'zulip--message-printer
                           ""
                           (concat "\n"
                                   (propertize
                                    (format "  [c] Reply  [G] Load more  [%s] Refresh  [H] Home  [q] Back"
                                            (zulip--refresh-key-hint))
                                    'face 'zulip-separator))))
        (when (vectorp msgs)
          (seq-do (lambda (m) (ewoc-enter-last zulip--ewoc m)) msgs)
          (when (> (length msgs) 0)
            (setq zulip--messages-oldest-id
                  (zulip--message-id (aref msgs 0)))))
        (goto-char (point-max))
        (forward-line -2)))
    (switch-to-buffer buf)))

;;;; Live-update hook handlers

(defun zulip--ui-on-new-message (conn msg-data)
  "Handle a new message event from CONN with MSG-DATA.
If the messages buffer for this topic is open, append the message."
  (let* ((ch-id (gethash "stream_id" msg-data))
         (topic (gethash "subject" msg-data))
         (ch (and ch-id (zulip--cache-get-channel
                         (zulip--connection-cache conn) ch-id)))
         (ch-name (and ch (zulip--channel-name ch)))
         (buf-name (when (and ch-name topic)
                     (zulip-messages--buffer-name ch-name topic))))
    (when buf-name
      (let ((buf (get-buffer buf-name)))
        (when (and buf (buffer-live-p buf))
          (with-current-buffer buf
            (when (and zulip--ewoc zulip--current-connection)
              (let* ((cache (zulip--connection-cache conn))
                     (msg (zulip--cache-put-message cache msg-data))
                     (inhibit-read-only t))
                (ewoc-enter-last zulip--ewoc msg)
                (when (>= (window-end nil t) (- (point-max) 2))
                  (goto-char (point-max))
                  (forward-line -2))))))))))

(defun zulip--ui-on-channel-change (conn)
  "Handle channel list change for CONN -- refresh if buffer exists."
  (let ((buf (get-buffer (zulip-channels--buffer-name conn))))
    (when (and buf (buffer-live-p buf))
      (zulip-channels--render conn))))

;;;; Evil compatibility — proper normal-state keybindings
;;
;; Following evil-collection best practices:
;;   - Set initial state to `normal' (not motion/emacs)
;;   - Use `evil-define-key*' for both normal AND motion states
;;     (Doom evil-collection may override derived modes to motion)
;;   - The Emacs mode-map bindings remain as fallback for vanilla Emacs
;;
;; Placed after all mode-map definitions to avoid forward-reference warnings.

(defun zulip--evil-setup ()
  "Set up Evil keybindings for all Zulip modes.
Called via `with-eval-after-load' when Evil is available."
  ;; All Zulip modes start in normal state
  (dolist (mode '(zulip-home-mode
                  zulip-channels-mode
                  zulip-topics-mode
                  zulip-messages-mode
                  zulip-dm-list-mode))
    (evil-set-initial-state mode 'normal))

  ;; Home mode
  (dolist (state '(normal motion))
    (evil-define-key* state zulip-home-mode-map
      "}"        #'zulip-home-next
      "{"        #'zulip-home-prev
      (kbd "RET") #'zulip-home-open-at-point
      "l"        #'zulip-home-open-at-point
      "q"        #'quit-window
      "gr"       #'zulip-home-refresh
      "C"        #'zulip-home-channels
      "D"        #'zulip-home-dms
      "c"        #'zulip-home-compose
      "S"        #'zulip-switch-server
      "ZQ"       #'zulip-logout))

  ;; Channels mode
  (dolist (state '(normal motion))
    (evil-define-key* state zulip-channels-mode-map
      "}"        #'zulip-channels-next
      "{"        #'zulip-channels-prev
      (kbd "RET") #'zulip-channels-open-topic
      "l"        #'zulip-channels-open-topic
      "h"        #'zulip-channels-go-home
      "q"        #'quit-window
      "gr"       #'zulip-channels-refresh
      "c"        #'zulip-channels-compose
      "H"        #'zulip-channels-go-home
      "S"        #'zulip-switch-server
      "ZQ"       #'zulip-logout))

  ;; Topics mode
  (dolist (state '(normal motion))
    (evil-define-key* state zulip-topics-mode-map
      "}"        #'zulip-topics-next
      "{"        #'zulip-topics-prev
      (kbd "RET") #'zulip-topics-open-messages
      "l"        #'zulip-topics-open-messages
      "h"        #'zulip-topics-go-home
      "q"        #'quit-window
      "gr"       #'zulip-topics-refresh
      "c"        #'zulip-topics-compose
      "H"        #'zulip-topics-go-home))

  ;; Messages mode (also used for DM messages)
  (dolist (state '(normal motion))
    (evil-define-key* state zulip-messages-mode-map
      "}"        #'zulip-messages-next
      "{"        #'zulip-messages-prev
      "q"        #'quit-window
      "gr"       #'zulip-messages-refresh
      "c"        #'zulip-messages-compose
      "G"        #'zulip-messages-load-more
      "H"        #'zulip-messages-go-home))

  ;; DM list mode
  (dolist (state '(normal motion))
    (evil-define-key* state zulip-dm-list-mode-map
      "}"        #'zulip-dm-list-next
      "{"        #'zulip-dm-list-prev
      (kbd "RET") #'zulip-dm-list-open
      "l"        #'zulip-dm-list-open
      "h"        #'zulip-dm-list-go-home
      "q"        #'quit-window
      "gr"       #'zulip-dm-list-refresh
      "c"        #'zulip-dm-list-compose
      "H"        #'zulip-dm-list-go-home)))

(with-eval-after-load 'evil
  (zulip--evil-setup))

(provide 'zulip-ui)
;;; zulip-ui.el ends here