;;; test-zulip-cache.el --- Tests for zulip-cache.el -*- lexical-binding: t; -*-

;;; Commentary:
;; ERT tests for the in-memory cache layer.

;;; Code:

(require 'ert)
(require 'zulip-cache)

;;;; Helpers

(defun zulip-test--make-user-data (id email name)
  "Build a mock user hash-table."
  (let ((ht (make-hash-table :test 'equal)))
    (puthash "user_id" id ht)
    (puthash "email" email ht)
    (puthash "full_name" name ht)
    (puthash "avatar_url" nil ht)
    (puthash "is_bot" :json-false ht)
    ht))

(defun zulip-test--make-channel-data (id name &optional desc)
  "Build a mock channel hash-table."
  (let ((ht (make-hash-table :test 'equal)))
    (puthash "stream_id" id ht)
    (puthash "name" name ht)
    (puthash "description" (or desc "") ht)
    (puthash "invite_only" :json-false ht)
    ht))

(defun zulip-test--make-message-data (id sender-id content topic channel-id ts)
  "Build a mock message hash-table."
  (let ((ht (make-hash-table :test 'equal)))
    (puthash "id" id ht)
    (puthash "sender_id" sender-id ht)
    (puthash "sender_full_name" "Test User" ht)
    (puthash "content" content ht)
    (puthash "subject" topic ht)
    (puthash "stream_id" channel-id ht)
    (puthash "timestamp" ts ht)
    (puthash "type" "stream" ht)
    (puthash "flags" [] ht)
    ht))

;;;; User tests

(ert-deftest zulip-cache-put-get-user ()
  "Store and retrieve a user."
  (let ((cache (zulip--cache-create)))
    (zulip--cache-put-user cache (zulip-test--make-user-data 42 "a@b.com" "Alice"))
    (let ((user (zulip--cache-get-user cache 42)))
      (should user)
      (should (= (zulip--user-id user) 42))
      (should (string= (zulip--user-email user) "a@b.com"))
      (should (string= (zulip--user-full-name user) "Alice")))))

(ert-deftest zulip-cache-user-overwrite ()
  "Storing a user with the same ID overwrites the old one."
  (let ((cache (zulip--cache-create)))
    (zulip--cache-put-user cache (zulip-test--make-user-data 1 "old@x.com" "Old"))
    (zulip--cache-put-user cache (zulip-test--make-user-data 1 "new@x.com" "New"))
    (let ((user (zulip--cache-get-user cache 1)))
      (should (string= (zulip--user-email user) "new@x.com")))))

;;;; Channel tests

(ert-deftest zulip-cache-put-get-channel ()
  "Store and retrieve a channel."
  (let ((cache (zulip--cache-create)))
    (zulip--cache-put-channel cache (zulip-test--make-channel-data 10 "general" "Main"))
    (let ((ch (zulip--cache-get-channel cache 10)))
      (should ch)
      (should (= (zulip--channel-id ch) 10))
      (should (string= (zulip--channel-name ch) "general"))
      (should (string= (zulip--channel-description ch) "Main")))))

(ert-deftest zulip-cache-channels-sorted ()
  "Channels are returned sorted by name."
  (let ((cache (zulip--cache-create)))
    (zulip--cache-put-channel cache (zulip-test--make-channel-data 3 "zeta"))
    (zulip--cache-put-channel cache (zulip-test--make-channel-data 1 "alpha"))
    (zulip--cache-put-channel cache (zulip-test--make-channel-data 2 "beta"))
    (let ((sorted (zulip--cache-channels-sorted cache)))
      (should (= (length sorted) 3))
      (should (string= (zulip--channel-name (nth 0 sorted)) "alpha"))
      (should (string= (zulip--channel-name (nth 1 sorted)) "beta"))
      (should (string= (zulip--channel-name (nth 2 sorted)) "zeta")))))

;;;; Topic tests

(ert-deftest zulip-cache-put-get-topics ()
  "Store and retrieve topics for a channel."
  (let ((cache (zulip--cache-create))
        (topics (vector
                 (let ((ht (make-hash-table :test 'equal)))
                   (puthash "name" "greetings" ht)
                   (puthash "max_id" 100 ht)
                   ht)
                 (let ((ht (make-hash-table :test 'equal)))
                   (puthash "name" "bugs" ht)
                   (puthash "max_id" 200 ht)
                   ht))))
    (zulip--cache-put-topics cache 10 topics)
    (let ((result (zulip--cache-get-topics cache 10)))
      (should (vectorp result))
      (should (= (length result) 2))
      (should (string= (zulip--topic-name (aref result 0)) "greetings")))))

;;;; Message tests

(ert-deftest zulip-cache-put-get-message ()
  "Store and retrieve messages by channel + topic."
  (let ((cache (zulip--cache-create)))
    (zulip--cache-put-message
     cache (zulip-test--make-message-data 1 42 "Hello" "greetings" 10 1000))
    (zulip--cache-put-message
     cache (zulip-test--make-message-data 2 42 "World" "greetings" 10 1001))
    (let ((msgs (zulip--cache-get-messages cache 10 "greetings")))
      (should (vectorp msgs))
      (should (= (length msgs) 2))
      (should (string= (zulip--message-content (aref msgs 0)) "Hello")))))

(ert-deftest zulip-cache-message-dedup ()
  "Duplicate message IDs are not stored twice."
  (let ((cache (zulip--cache-create)))
    (zulip--cache-put-message
     cache (zulip-test--make-message-data 1 42 "Hello" "topic" 10 1000))
    (zulip--cache-put-message
     cache (zulip-test--make-message-data 1 42 "Hello edited" "topic" 10 1000))
    (let ((msgs (zulip--cache-get-messages cache 10 "topic")))
      (should (= (length msgs) 1)))))

(ert-deftest zulip-cache-clear-messages ()
  "Clearing messages removes them from cache."
  (let ((cache (zulip--cache-create)))
    (zulip--cache-put-message
     cache (zulip-test--make-message-data 1 42 "Hi" "topic" 10 1000))
    (zulip--cache-clear-messages cache 10 "topic")
    (should (null (zulip--cache-get-messages cache 10 "topic")))))

;;;; Message key tests

(ert-deftest zulip-cache-message-key ()
  "Message key is channel-id:topic."
  (should (string= (zulip--message-key 42 "hello") "42:hello")))

;;;; Unread tracking tests

(ert-deftest zulip-cache-unread-basic ()
  "Increment and clear unread counts."
  (let ((cache (zulip--cache-create)))
    (should (= (zulip--cache-unread-count cache 10 "topic") 0))
    (zulip--cache-increment-unread cache 10 "topic")
    (zulip--cache-increment-unread cache 10 "topic")
    (should (= (zulip--cache-unread-count cache 10 "topic") 2))
    (zulip--cache-clear-unread cache 10 "topic")
    (should (= (zulip--cache-unread-count cache 10 "topic") 0))))

(ert-deftest zulip-cache-unread-channel-total ()
  "Channel-level unread sums all topics."
  (let ((cache (zulip--cache-create)))
    (zulip--cache-increment-unread cache 10 "a")
    (zulip--cache-increment-unread cache 10 "a")
    (zulip--cache-increment-unread cache 10 "b")
    (should (= (zulip--cache-unread-count cache 10) 3))))

(ert-deftest zulip-cache-init-unread ()
  "Initialize unread from register response data."
  (let ((cache (zulip--cache-create))
        (data (make-hash-table :test 'equal)))
    (let ((entry1 (make-hash-table :test 'equal))
          (entry2 (make-hash-table :test 'equal)))
      (puthash "stream_id" 10 entry1)
      (puthash "topic" "hello" entry1)
      (puthash "unread_message_ids" [1 2 3] entry1)
      (puthash "stream_id" 10 entry2)
      (puthash "topic" "world" entry2)
      (puthash "unread_message_ids" [4 5] entry2)
      (puthash "streams" (vector entry1 entry2) data))
    (zulip--cache-init-unread cache data)
    (should (= (zulip--cache-unread-count cache 10 "hello") 3))
    (should (= (zulip--cache-unread-count cache 10 "world") 2))
    (should (= (zulip--cache-unread-count cache 10) 5))))

;;;; Users-sorted

(ert-deftest zulip-cache-users-sorted ()
  "Non-bot users are returned sorted by full name."
  (let ((cache (zulip--cache-create)))
    (zulip--cache-put-user cache (zulip-test--make-user-data 1 "z@x.com" "Zara"))
    (zulip--cache-put-user cache (zulip-test--make-user-data 2 "a@x.com" "Alice"))
    (zulip--cache-put-user cache (zulip-test--make-user-data 3 "m@x.com" "Milo"))
    (let ((sorted (zulip--cache-users-sorted cache)))
      (should (= (length sorted) 3))
      (should (string= (zulip--user-full-name (nth 0 sorted)) "Alice"))
      (should (string= (zulip--user-full-name (nth 1 sorted)) "Milo"))
      (should (string= (zulip--user-full-name (nth 2 sorted)) "Zara")))))

(ert-deftest zulip-cache-users-sorted-excludes-bots ()
  "Bot users are excluded from the sorted list."
  (let ((cache (zulip--cache-create))
        (bot-data (let ((ht (make-hash-table :test 'equal)))
                    (puthash "user_id" 99 ht)
                    (puthash "email" "bot@x.com" ht)
                    (puthash "full_name" "Notification Bot" ht)
                    (puthash "avatar_url" nil ht)
                    (puthash "is_bot" t ht)
                    ht)))
    (zulip--cache-put-user cache (zulip-test--make-user-data 1 "a@x.com" "Alice"))
    (zulip--cache-put-user cache bot-data)
    (let ((sorted (zulip--cache-users-sorted cache)))
      (should (= (length sorted) 1))
      (should (string= (zulip--user-full-name (car sorted)) "Alice")))))

(provide 'test-zulip-cache)
;;; test-zulip-cache.el ends here
