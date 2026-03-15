;;; zulip-cache.el --- Local state management for emacs-zulip -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Author: emacs-zulip contributors

;;; Commentary:

;; Pure in-memory cache using hash-tables for O(1) lookups.
;; No SQLite, no file-based persistence, no external libraries.
;; Each server connection owns its own cache instance.

;;; Code:

(require 'cl-lib)

;;;; Data Structures

(cl-defstruct (zulip--user (:constructor zulip--user-create)
                           (:copier nil))
  "A Zulip user."
  (id 0 :type integer)
  (email "" :type string)
  (full-name "" :type string)
  (avatar-url nil :type (or string null))
  (is-bot nil :type boolean))

(cl-defstruct (zulip--channel (:constructor zulip--channel-create)
                              (:copier nil))
  "A Zulip channel (stream)."
  (id 0 :type integer)
  (name "" :type string)
  (description "" :type string)
  (invite-only nil :type boolean)
  (color nil :type (or string null)))

(cl-defstruct (zulip--topic (:constructor zulip--topic-create)
                            (:copier nil))
  "A topic within a Zulip channel."
  (name "" :type string)
  (channel-id 0 :type integer)
  (max-id 0 :type integer))

(cl-defstruct (zulip--message (:constructor zulip--message-create)
                              (:copier nil))
  "A Zulip message."
  (id 0 :type integer)
  (sender-id 0 :type integer)
  (sender-name "" :type string)
  (avatar-url nil :type (or string null))
  (content "" :type string)
  (subject "" :type string)
  (channel-id nil :type (or integer null))
  (timestamp 0 :type integer)
  (type "stream" :type string)
  (flags [] :type vector)
  (display-recipient nil))

(cl-defstruct (zulip--cache (:constructor zulip--cache-create)
                            (:copier nil))
  "In-memory cache for a single Zulip server.
Channels, users, and presence are keyed by integer ID (eql test).
Messages and unread counts are keyed by \"channel-id:topic\" (equal test)."
  (channels (make-hash-table :test 'eql) :type hash-table)
  (topics   (make-hash-table :test 'eql) :type hash-table)
  (messages (make-hash-table :test 'equal) :type hash-table)
  (users    (make-hash-table :test 'eql) :type hash-table)
  (presence (make-hash-table :test 'eql) :type hash-table)
  (unread   (make-hash-table :test 'equal) :type hash-table))

(cl-defstruct (zulip--connection (:constructor zulip--connection-create)
                                 (:copier nil))
  "A connection to a Zulip server."
  (server "" :type string)
  (email "" :type string)
  (api-key "" :type string)
  (user-id 0 :type integer)
  (queue-id nil :type (or string null))
  (last-event-id -1 :type integer)
  (event-timer nil)
  (cache (zulip--cache-create) :type zulip--cache))

;;;; Key Helpers

(defsubst zulip--message-key (channel-id topic)
  "Build hash key string from integer CHANNEL-ID and TOPIC string."
  (concat (number-to-string channel-id) ":" topic))

;;;; Cache — Put Operations

(defun zulip--cache-put-user (cache data)
  "Parse user DATA hash-table and store in CACHE.  Return `zulip--user'."
  (let* ((id (or (gethash "user_id" data) (gethash "id" data) 0))
         (user (zulip--user-create
                :id id
                :email (or (gethash "email" data) "")
                :full-name (or (gethash "full_name" data) "")
                :avatar-url (gethash "avatar_url" data)
                :is-bot (eq (gethash "is_bot" data) t))))
    (puthash id user (zulip--cache-users cache))
    user))

(defun zulip--cache-put-channel (cache data)
  "Parse channel DATA hash-table and store in CACHE.  Return `zulip--channel'."
  (let* ((id (gethash "stream_id" data))
         (chan (zulip--channel-create
                :id id
                :name (or (gethash "name" data) "")
                :description (or (gethash "description" data) "")
                :invite-only (eq (gethash "invite_only" data) t)
                :color (gethash "color" data))))
    (puthash id chan (zulip--cache-channels cache))
    chan))

(defun zulip--cache-put-topics (cache channel-id topics-vec)
  "Store TOPICS-VEC (vector of hash-tables) for CHANNEL-ID in CACHE."
  (let (result)
    (seq-do
     (lambda (tdata)
       (push (zulip--topic-create
              :name (gethash "name" tdata)
              :channel-id channel-id
              :max-id (or (gethash "max_id" tdata) 0))
             result))
     topics-vec)
    (puthash channel-id (vconcat (nreverse result))
             (zulip--cache-topics cache))))

(defun zulip--cache-put-message (cache data)
  "Parse message DATA hash-table and store in CACHE.  Return `zulip--message'.
Deduplicates by message ID."
  (let* ((id (gethash "id" data))
         (msg (zulip--message-create
               :id id
               :sender-id (or (gethash "sender_id" data) 0)
               :sender-name (or (gethash "sender_full_name" data) "")
               :avatar-url (gethash "avatar_url" data)
               :content (or (gethash "content" data) "")
               :subject (or (gethash "subject" data) "")
               :channel-id (gethash "stream_id" data)
               :timestamp (or (gethash "timestamp" data) 0)
               :type (or (gethash "type" data) "stream")
               :flags (or (gethash "flags" data) [])
               :display-recipient (gethash "display_recipient" data))))
    (when (zulip--message-channel-id msg)
      (let* ((key (zulip--message-key (zulip--message-channel-id msg)
                                      (zulip--message-subject msg)))
             (existing (gethash key (zulip--cache-messages cache)))
             (dup (and existing
                       (seq-find (lambda (m) (eql (zulip--message-id m) id))
                                 existing))))
        (unless dup
          (puthash key
                   (if existing (vconcat existing (vector msg)) (vector msg))
                   (zulip--cache-messages cache)))))
    msg))

(defun zulip--cache-store-messages (cache channel-id topic messages-vec)
  "Bulk-store MESSAGES-VEC for CHANNEL-ID + TOPIC in CACHE."
  (puthash (zulip--message-key channel-id topic)
           messages-vec
           (zulip--cache-messages cache)))

;;;; Cache — Get Operations

(defun zulip--cache-get-user (cache id)
  "Look up user by integer ID in CACHE."
  (gethash id (zulip--cache-users cache)))

(defun zulip--cache-get-channel (cache id)
  "Look up channel by integer ID in CACHE."
  (gethash id (zulip--cache-channels cache)))

(defun zulip--cache-get-topics (cache channel-id)
  "Get topics vector for CHANNEL-ID from CACHE, or nil."
  (gethash channel-id (zulip--cache-topics cache)))

(defun zulip--cache-get-messages (cache channel-id topic)
  "Get messages vector for CHANNEL-ID + TOPIC from CACHE, or nil."
  (gethash (zulip--message-key channel-id topic)
           (zulip--cache-messages cache)))

;;;; Cache — Sorting & Listing

(defun zulip--cache-channels-sorted (cache)
  "Return channels from CACHE as a list sorted alphabetically by name."
  (let (result)
    (maphash (lambda (_id ch) (push ch result))
             (zulip--cache-channels cache))
    (sort result (lambda (a b)
                   (string< (zulip--channel-name a)
                            (zulip--channel-name b))))))

;;;; Cache — Clear

(defun zulip--cache-clear-topics (cache channel-id)
  "Remove cached topics for CHANNEL-ID."
  (remhash channel-id (zulip--cache-topics cache)))

(defun zulip--cache-clear-messages (cache channel-id topic)
  "Remove cached messages for CHANNEL-ID and TOPIC."
  (remhash (zulip--message-key channel-id topic)
           (zulip--cache-messages cache)))

;;;; Unread Tracking

(defun zulip--cache-init-unread (cache unread-data)
  "Initialize unread counts from UNREAD-DATA (from /register response)."
  ;; Stream unreads
  (let ((streams (gethash "streams" unread-data)))
    (when (vectorp streams)
      (seq-do
       (lambda (entry)
         (let* ((sid (gethash "stream_id" entry))
                (topic (gethash "topic" entry))
                (ids (gethash "unread_message_ids" entry))
                (count (if (vectorp ids) (length ids) 0)))
           (puthash (zulip--message-key sid topic)
                    count (zulip--cache-unread cache))))
       streams)))
  ;; DM unreads
  (let ((pms (gethash "pms" unread-data)))
    (when (vectorp pms)
      (seq-do
       (lambda (entry)
         (let* ((other-id (gethash "other_user_id" entry))
                (ids (gethash "unread_message_ids" entry))
                (count (if (vectorp ids) (length ids) 0)))
           (puthash (concat "dm:" (number-to-string other-id))
                    count (zulip--cache-unread cache))))
       pms))))

(defun zulip--cache-unread-count (cache channel-id &optional topic)
  "Get unread count for CHANNEL-ID, optionally scoped to TOPIC."
  (if topic
      (or (gethash (zulip--message-key channel-id topic)
                   (zulip--cache-unread cache))
          0)
    (let ((total 0)
          (prefix (concat (number-to-string channel-id) ":")))
      (maphash
       (lambda (key count)
         (when (string-prefix-p prefix key)
           (cl-incf total count)))
       (zulip--cache-unread cache))
      total)))

(defun zulip--cache-increment-unread (cache channel-id topic)
  "Increment unread count for CHANNEL-ID and TOPIC by 1."
  (let* ((key (zulip--message-key channel-id topic))
         (cur (or (gethash key (zulip--cache-unread cache)) 0)))
    (puthash key (1+ cur) (zulip--cache-unread cache))))

(defun zulip--cache-clear-unread (cache channel-id topic)
  "Clear unread count for CHANNEL-ID and TOPIC."
  (remhash (zulip--message-key channel-id topic)
           (zulip--cache-unread cache)))

(provide 'zulip-cache)
;;; zulip-cache.el ends here
