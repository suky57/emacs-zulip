;;; zulip-events.el --- Real-time event system for emacs-zulip -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Author: emacs-zulip contributors

;;; Commentary:

;; Implements Zulip's register-queue / get-events long-polling API.
;; Events are dispatched to the in-memory cache and hooks notify the UI layer.
;; Polling uses `run-with-timer' — never blocks the UI thread.

;;; Code:

(require 'cl-lib)
(require 'zulip-cache)
(require 'zulip-api)

;;;; Configuration

(defvar zulip--event-retry-interval 5
  "Seconds to wait before retrying after an event-poll failure.")

;;;; Hooks — UI layer connects to these for live refresh

(defvar zulip--event-message-hook nil
  "Hook run when a new message arrives.
Each function is called with (CONN MSG-DATA) where MSG-DATA is a hash-table.")

(defvar zulip--event-channel-hook nil
  "Hook run when the channel list changes.
Each function is called with (CONN).")

(defvar zulip--event-presence-hook nil
  "Hook run when presence information changes.
Each function is called with (CONN USER-ID STATUS).")

;;;; Queue Registration

(defun zulip--events-register (conn callback)
  "Register an event queue for CONN; populate initial cache.
CALLBACK is called with the register response data (or nil on failure)."
  (zulip--api-register-queue
   conn
   "[\"message\",\"stream\",\"subscription\",\"realm_user\",\"presence\",\"update_message\",\"update_message_flags\"]"
   (lambda (data)
     (when data
       (setf (zulip--connection-queue-id conn)
             (gethash "queue_id" data))
       (setf (zulip--connection-last-event-id conn)
             (gethash "last_event_id" data))
       ;; --- Seed cache from the register snapshot ---
       (let ((cache (zulip--connection-cache conn)))
         ;; Subscriptions → channels
         (let ((subs (gethash "subscriptions" data)))
           (when (vectorp subs)
             (seq-do (lambda (s) (zulip--cache-put-channel cache s)) subs)))
         ;; Realm users
         (let ((members (gethash "realm_users" data)))
           (when (vectorp members)
             (seq-do (lambda (u) (zulip--cache-put-user cache u)) members)))
         ;; Unread counts
         (let ((unread (gethash "unread_msgs" data)))
           (when unread
             (zulip--cache-init-unread cache unread)))
         ;; Presence
         (let ((presences (gethash "presences" data)))
           (when presences
             (zulip--events--seed-presence cache presences)))))
     (when callback (funcall callback data)))))

(defun zulip--events--seed-presence (cache presences)
  "Seed CACHE presence from the PRESENCES hash-table (email → data)."
  ;; Build reverse email→user-id map for O(1) lookup
  (let ((email-to-id (make-hash-table :test 'equal)))
    (maphash
     (lambda (_id user)
       (puthash (zulip--user-email user) (zulip--user-id user) email-to-id))
     (zulip--cache-users cache))
    (maphash
     (lambda (email pdata)
       (let ((agg (gethash "aggregated" pdata)))
         (when agg
           (let ((status (or (gethash "status" agg) "offline"))
                 (uid (gethash email email-to-id)))
             (when uid
               (puthash uid status (zulip--cache-presence cache)))))))
     presences)))

;;;; Long-Polling Loop

(defun zulip--events-poll (conn)
  "Long-poll for events on CONN.  Reschedules itself via timer."
  (when (zulip--connection-queue-id conn)
    (zulip--api-get-events
     conn
     (lambda (data)
       (if data
           (let ((events (gethash "events" data)))
             ;; Check for BAD_EVENT_QUEUE_ID — need to re-register
             (if (equal (gethash "result" data) "error")
                 (progn
                   (message "Zulip: event queue expired, re-registering…")
                   (setf (zulip--connection-queue-id conn) nil)
                   (zulip--events-register
                    conn
                    (lambda (reg-data)
                      (when reg-data
                        (zulip--events-poll conn)))))
               ;; Normal event processing
               (when (vectorp events)
                 (seq-do (lambda (ev) (zulip--events-dispatch conn ev))
                         events))
               ;; Poll again immediately (server blocks until events arrive)
               (when (zulip--connection-queue-id conn)
                 (setf (zulip--connection-event-timer conn)
                       (run-with-timer 0.1 nil #'zulip--events-poll conn)))))
         ;; Error / nil → back off and retry
         (when (zulip--connection-queue-id conn)
           (setf (zulip--connection-event-timer conn)
                 (run-with-timer zulip--event-retry-interval nil
                                 #'zulip--events-poll conn))))))))

;;;; Event Dispatch

(defun zulip--events-dispatch (conn event)
  "Route EVENT hash-table to the correct handler for CONN."
  (let ((type  (gethash "type" event))
        (id    (gethash "id" event))
        (cache (zulip--connection-cache conn)))
    ;; Advance last-event-id
    (when (and id (numberp id)
               (> id (zulip--connection-last-event-id conn)))
      (setf (zulip--connection-last-event-id conn) id))
    (cond
     ;; ---------- message ----------
     ((string= type "message")
      (let ((msg (gethash "message" event)))
        (when msg
          (zulip--cache-put-message cache msg)
          ;; Bump unread unless it's our own message
          (let ((sid (gethash "stream_id" msg))
                (topic (gethash "subject" msg))
                (sender (gethash "sender_id" msg)))
            (when (and sid topic
                       (not (eql sender (zulip--connection-user-id conn))))
              (zulip--cache-increment-unread cache sid topic)))
          (run-hook-with-args 'zulip--event-message-hook conn msg))))

     ;; ---------- stream (server-side channel create/delete/update) ----------
     ((string= type "stream")
      (zulip--events--handle-stream cache event)
      (run-hook-with-args 'zulip--event-channel-hook conn))

     ;; ---------- subscription (user subscribe/unsubscribe) ----------
     ((string= type "subscription")
      (zulip--events--handle-subscription cache event)
      (run-hook-with-args 'zulip--event-channel-hook conn))

     ;; ---------- realm_user ----------
     ((string= type "realm_user")
      (zulip--events--handle-realm-user cache event))

     ;; ---------- presence ----------
     ((string= type "presence")
      (let ((user-id  (gethash "user_id" event))
            (presence (gethash "presence" event)))
        (when (and user-id presence)
          (let ((agg (gethash "aggregated" presence)))
            (when agg
              (let ((status (or (gethash "status" agg) "offline")))
                (puthash user-id status (zulip--cache-presence cache))
                (run-hook-with-args 'zulip--event-presence-hook
                                    conn user-id status)))))))

     ;; ---------- update_message (edit) ----------
     ((string= type "update_message")
      (zulip--events--handle-update-message cache event))

     ;; ---------- update_message_flags (read/star) ----------
     ((string= type "update_message_flags")
      (zulip--events--handle-flags conn cache event)))))

;;;; Sub-dispatchers

(defun zulip--events--handle-stream (cache event)
  "Handle a stream (channel) EVENT against CACHE."
  (let ((op      (gethash "op" event))
        (streams (gethash "streams" event)))
    (when (vectorp streams)
      (seq-do
       (lambda (s)
         (pcase op
           ("create" (zulip--cache-put-channel cache s))
           ("delete" (remhash (gethash "stream_id" s)
                              (zulip--cache-channels cache)))))
       streams))))

(defun zulip--events--handle-subscription (cache event)
  "Handle a subscription EVENT against CACHE."
  (let ((op   (gethash "op" event))
        (subs (gethash "subscriptions" event)))
    (when (vectorp subs)
      (seq-do
       (lambda (s)
         (pcase op
           ("add"    (zulip--cache-put-channel cache s))
           ("remove" (remhash (gethash "stream_id" s)
                              (zulip--cache-channels cache)))))
       subs))))

(defun zulip--events--handle-realm-user (cache event)
  "Handle a realm_user EVENT against CACHE."
  (let ((op     (gethash "op" event))
        (person (gethash "person" event)))
    (when person
      (pcase op
        ("add" (zulip--cache-put-user cache person))
        ("update"
         (let* ((uid (gethash "user_id" person))
                (existing (zulip--cache-get-user cache uid)))
           (when existing
             (let ((new-name (gethash "full_name" person)))
               (when new-name
                 (setf (zulip--user-full-name existing) new-name)))
             (let ((new-avatar (gethash "avatar_url" person)))
               (when new-avatar
                 (setf (zulip--user-avatar-url existing) new-avatar))))))))))

(defun zulip--events--handle-update-message (cache event)
  "Handle an update_message EVENT (edit) against CACHE."
  (let ((msg-id      (gethash "message_id" event))
        (new-content (gethash "rendered_content" event))
        (new-subject (gethash "subject" event)))
    (when msg-id
      (maphash
       (lambda (_key msgs)
         (seq-do
          (lambda (m)
            (when (eql (zulip--message-id m) msg-id)
              (when new-content
                (setf (zulip--message-content m) new-content))
              (when new-subject
                (setf (zulip--message-subject m) new-subject))))
          msgs))
       (zulip--cache-messages cache)))))

(defun zulip--events--handle-flags (_conn cache event)
  "Handle an update_message_flags EVENT for CACHE.
When messages are marked as read, decrement unread counts."
  (let ((op       (gethash "op" event))        ; "add" or "remove"
        (flag     (gethash "flag" event))       ; "read", "starred", etc.
        (msg-details (gethash "message_details" event))) ; hash: id → details
    ;; We only care about the "read" flag being added
    (when (and (equal op "add") (equal flag "read"))
      (cond
       ;; Modern Zulip (5.0+) sends message_details with stream_id/topic
       (msg-details
        (maphash
         (lambda (_id detail)
           (let ((mtype (gethash "type" detail)))
             (cond
              ((equal mtype "stream")
               (let* ((sid (gethash "stream_id" detail))
                      (topic (gethash "topic" detail))
                      (key (zulip--message-key sid topic))
                      (cur (gethash key (zulip--cache-unread cache) 0)))
                 (if (<= cur 1)
                     (remhash key (zulip--cache-unread cache))
                   (puthash key (1- cur) (zulip--cache-unread cache)))))
              ((equal mtype "private")
               ;; DM: decrement by sender
               (let* ((uid (gethash "user_id" detail))
                      ;; For DMs the "user_id" in details is the sender
                      (dm-key (when uid
                                (concat "dm:" (number-to-string uid))))
                      (cur (and dm-key
                                (gethash dm-key (zulip--cache-unread cache) 0))))
                 (when (and cur (> cur 0))
                   (if (<= cur 1)
                       (remhash dm-key (zulip--cache-unread cache))
                     (puthash dm-key (1- cur)
                              (zulip--cache-unread cache)))))))))
         msg-details))
       ;; Older Zulip or "all" read: just clear matching unreads
       ((and (equal (gethash "all" event) t))
        (clrhash (zulip--cache-unread cache)))))))

;;;; Start / Stop

(defun zulip--events-start (conn)
  "Register an event queue for CONN and begin long-polling."
  (zulip--events-register
   conn
   (lambda (data)
     (if data
         (progn
           (message "Zulip: connected to %s" (zulip--connection-server conn))
           (zulip--events-poll conn))
       (message "Zulip: failed to register event queue")))))

(defun zulip--events-stop (conn)
  "Stop long-polling and delete the server-side queue for CONN."
  (when (zulip--connection-event-timer conn)
    (cancel-timer (zulip--connection-event-timer conn))
    (setf (zulip--connection-event-timer conn) nil))
  (zulip--api-delete-queue conn (lambda (_) nil))
  (setf (zulip--connection-queue-id conn) nil))

(provide 'zulip-events)
;;; zulip-events.el ends here
