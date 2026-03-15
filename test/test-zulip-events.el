;;; test-zulip-events.el --- Tests for zulip-events.el -*- lexical-binding: t; -*-

;;; Commentary:
;; ERT tests for event dispatch — verifies that incoming events
;; correctly update the in-memory cache.  No network calls.

;;; Code:

(require 'ert)
(require 'zulip-cache)
(require 'zulip-events)

;;;; Helpers

(defun zulip-test--make-conn ()
  "Create a test connection with empty cache."
  (zulip--connection-create
   :server "https://test.zulip.com"
   :email "test@test.com"
   :api-key "testkey"
   :user-id 99
   :last-event-id 0
   :cache (zulip--cache-create)))

(defun zulip-test--make-event (type id &rest props)
  "Build an event hash-table with TYPE, ID, and PROPS (key val …)."
  (let ((ht (make-hash-table :test 'equal)))
    (puthash "type" type ht)
    (puthash "id" id ht)
    (let ((rest props))
      (while rest
        (puthash (car rest) (cadr rest) ht)
        (setq rest (cddr rest))))
    ht))

(defun zulip-test--make-msg-event (msg-id sender-id content topic channel-id)
  "Build a message event hash-table."
  (let ((msg (make-hash-table :test 'equal)))
    (puthash "id" msg-id msg)
    (puthash "sender_id" sender-id msg)
    (puthash "sender_full_name" "Sender" msg)
    (puthash "content" content msg)
    (puthash "subject" topic msg)
    (puthash "stream_id" channel-id msg)
    (puthash "timestamp" 1000 msg)
    (puthash "type" "stream" msg)
    (puthash "flags" [] msg)
    (zulip-test--make-event "message" 1 "message" msg)))

;;;; Event ID tracking

(ert-deftest zulip-events-advances-last-event-id ()
  "Dispatching an event advances last-event-id."
  (let ((conn (zulip-test--make-conn)))
    (zulip--events-dispatch conn (zulip-test--make-event "heartbeat" 5))
    (should (= (zulip--connection-last-event-id conn) 5))))

(ert-deftest zulip-events-does-not-regress-event-id ()
  "A lower event ID does not overwrite a higher one."
  (let ((conn (zulip-test--make-conn)))
    (setf (zulip--connection-last-event-id conn) 10)
    (zulip--events-dispatch conn (zulip-test--make-event "heartbeat" 3))
    (should (= (zulip--connection-last-event-id conn) 10))))

;;;; Message events

(ert-deftest zulip-events-message-stored ()
  "A message event stores the message in cache."
  (let ((conn (zulip-test--make-conn)))
    (zulip--events-dispatch
     conn (zulip-test--make-msg-event 100 42 "Hello!" "greetings" 10))
    (let ((msgs (zulip--cache-get-messages
                 (zulip--connection-cache conn) 10 "greetings")))
      (should msgs)
      (should (= (length msgs) 1))
      (should (string= (zulip--message-content (aref msgs 0)) "Hello!")))))

(ert-deftest zulip-events-message-increments-unread ()
  "A message from another user increments unread count."
  (let ((conn (zulip-test--make-conn)))
    ;; user-id is 99, sender is 42 (different)
    (zulip--events-dispatch
     conn (zulip-test--make-msg-event 100 42 "Hi" "topic" 10))
    (should (= (zulip--cache-unread-count
                (zulip--connection-cache conn) 10 "topic")
               1))))

(ert-deftest zulip-events-own-message-no-unread ()
  "A message from ourselves does not increment unread."
  (let ((conn (zulip-test--make-conn)))
    ;; user-id is 99, sender is also 99
    (zulip--events-dispatch
     conn (zulip-test--make-msg-event 100 99 "My msg" "topic" 10))
    (should (= (zulip--cache-unread-count
                (zulip--connection-cache conn) 10 "topic")
               0))))

;;;; Stream events

(ert-deftest zulip-events-stream-create ()
  "A stream create event adds a channel."
  (let ((conn (zulip-test--make-conn))
        (stream-data (make-hash-table :test 'equal)))
    (puthash "stream_id" 20 stream-data)
    (puthash "name" "new-channel" stream-data)
    (puthash "description" "Fresh" stream-data)
    (let ((event (zulip-test--make-event
                  "stream" 2 "op" "create"
                  "streams" (vector stream-data))))
      (zulip--events-dispatch conn event))
    (let ((ch (zulip--cache-get-channel
               (zulip--connection-cache conn) 20)))
      (should ch)
      (should (string= (zulip--channel-name ch) "new-channel")))))

(ert-deftest zulip-events-stream-delete ()
  "A stream delete event removes the channel."
  (let* ((conn (zulip-test--make-conn))
         (cache (zulip--connection-cache conn))
         (ch-data (make-hash-table :test 'equal)))
    ;; Seed a channel
    (puthash "stream_id" 20 ch-data)
    (puthash "name" "doomed" ch-data)
    (puthash "description" "" ch-data)
    (zulip--cache-put-channel cache ch-data)
    (should (zulip--cache-get-channel cache 20))
    ;; Dispatch delete
    (let ((del-data (make-hash-table :test 'equal)))
      (puthash "stream_id" 20 del-data)
      (zulip--events-dispatch
       conn (zulip-test--make-event
             "stream" 3 "op" "delete"
             "streams" (vector del-data))))
    (should-not (zulip--cache-get-channel cache 20))))

;;;; Subscription events

(ert-deftest zulip-events-subscription-add ()
  "A subscription add event adds a channel."
  (let ((conn (zulip-test--make-conn))
        (sub (make-hash-table :test 'equal)))
    (puthash "stream_id" 30 sub)
    (puthash "name" "subscribed-ch" sub)
    (puthash "description" "" sub)
    (zulip--events-dispatch
     conn (zulip-test--make-event
           "subscription" 4 "op" "add"
           "subscriptions" (vector sub)))
    (should (zulip--cache-get-channel
             (zulip--connection-cache conn) 30))))

(ert-deftest zulip-events-subscription-remove ()
  "A subscription remove event removes the channel."
  (let* ((conn (zulip-test--make-conn))
         (cache (zulip--connection-cache conn))
         (seed (make-hash-table :test 'equal)))
    (puthash "stream_id" 30 seed)
    (puthash "name" "bye" seed)
    (puthash "description" "" seed)
    (zulip--cache-put-channel cache seed)
    (let ((rm (make-hash-table :test 'equal)))
      (puthash "stream_id" 30 rm)
      (zulip--events-dispatch
       conn (zulip-test--make-event
             "subscription" 5 "op" "remove"
             "subscriptions" (vector rm))))
    (should-not (zulip--cache-get-channel cache 30))))

;;;; Realm user events

(ert-deftest zulip-events-realm-user-add ()
  "A realm_user add event stores the user."
  (let ((conn (zulip-test--make-conn))
        (person (make-hash-table :test 'equal)))
    (puthash "user_id" 50 person)
    (puthash "email" "new@z.com" person)
    (puthash "full_name" "New User" person)
    (zulip--events-dispatch
     conn (zulip-test--make-event
           "realm_user" 6 "op" "add" "person" person))
    (let ((u (zulip--cache-get-user
              (zulip--connection-cache conn) 50)))
      (should u)
      (should (string= (zulip--user-full-name u) "New User")))))

(ert-deftest zulip-events-realm-user-update ()
  "A realm_user update event patches an existing user."
  (let* ((conn (zulip-test--make-conn))
         (cache (zulip--connection-cache conn))
         (seed (make-hash-table :test 'equal)))
    (puthash "user_id" 50 seed)
    (puthash "email" "u@z.com" seed)
    (puthash "full_name" "Old Name" seed)
    (zulip--cache-put-user cache seed)
    ;; Update name
    (let ((person (make-hash-table :test 'equal)))
      (puthash "user_id" 50 person)
      (puthash "full_name" "New Name" person)
      (zulip--events-dispatch
       conn (zulip-test--make-event
             "realm_user" 7 "op" "update" "person" person)))
    (should (string= (zulip--user-full-name
                       (zulip--cache-get-user cache 50))
                      "New Name"))))

;;;; Presence events

(ert-deftest zulip-events-presence ()
  "A presence event updates the cache."
  (let* ((conn (zulip-test--make-conn))
         (cache (zulip--connection-cache conn))
         (agg (make-hash-table :test 'equal))
         (pres (make-hash-table :test 'equal)))
    (puthash "status" "active" agg)
    (puthash "aggregated" agg pres)
    (zulip--events-dispatch
     conn (zulip-test--make-event
           "presence" 8 "user_id" 50 "presence" pres))
    (should (string= (gethash 50 (zulip--cache-presence cache))
                      "active"))))

;;;; Update-message events

(ert-deftest zulip-events-update-message ()
  "An update_message event patches message content."
  (let* ((conn (zulip-test--make-conn))
         (cache (zulip--connection-cache conn)))
    ;; Seed a message
    (zulip--events-dispatch
     conn (zulip-test--make-msg-event 100 42 "Original" "topic" 10))
    ;; Edit it
    (zulip--events-dispatch
     conn (zulip-test--make-event
           "update_message" 9
           "message_id" 100
           "rendered_content" "Edited"))
    (let* ((msgs (zulip--cache-get-messages cache 10 "topic"))
           (msg (and msgs (aref msgs 0))))
      (should msg)
      (should (string= (zulip--message-content msg) "Edited")))))

;;;; Update-message-flags events

(ert-deftest zulip-events-flags-read-decrements-unread ()
  "An update_message_flags 'read' event decrements unread count."
  (let* ((conn (zulip-test--make-conn))
         (cache (zulip--connection-cache conn)))
    ;; Seed 3 unreads for topic
    (zulip--cache-increment-unread cache 10 "topic")
    (zulip--cache-increment-unread cache 10 "topic")
    (zulip--cache-increment-unread cache 10 "topic")
    (should (= (zulip--cache-unread-count cache 10 "topic") 3))
    ;; Mark one as read via message_details
    (let* ((detail (make-hash-table :test 'equal))
           (details (make-hash-table :test 'equal)))
      (puthash "type" "stream" detail)
      (puthash "stream_id" 10 detail)
      (puthash "topic" "topic" detail)
      (puthash "200" detail details)
      (zulip--events-dispatch
       conn (zulip-test--make-event
             "update_message_flags" 10
             "op" "add" "flag" "read"
             "messages" (vector 200)
             "message_details" details)))
    (should (= (zulip--cache-unread-count cache 10 "topic") 2))))

(ert-deftest zulip-events-flags-read-all-clears-unread ()
  "An update_message_flags with all=true clears all unreads."
  (let* ((conn (zulip-test--make-conn))
         (cache (zulip--connection-cache conn)))
    (zulip--cache-increment-unread cache 10 "a")
    (zulip--cache-increment-unread cache 20 "b")
    (should (= (zulip--cache-unread-count cache 10 "a") 1))
    ;; Mark all as read
    (zulip--events-dispatch
     conn (zulip-test--make-event
           "update_message_flags" 11
           "op" "add" "flag" "read"
           "messages" []
           "all" t))
    (should (= (zulip--cache-unread-count cache 10 "a") 0))
    (should (= (zulip--cache-unread-count cache 20 "b") 0))))

;;; test-zulip-events.el ends here
