;;; test-zulip-compose.el --- Tests for zulip-compose.el -*- lexical-binding: t; -*-

;;; Commentary:
;; ERT tests for the compose module — keymap bindings and attach flow.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'zulip-compose)
(require 'zulip-cache)

;;;; Keymap bindings

(ert-deftest zulip-compose-keymap-send ()
  "C-c C-c is bound to `zulip-compose-send'."
  (should (eq (lookup-key zulip-compose-mode-map (kbd "C-c C-c"))
              #'zulip-compose-send)))

(ert-deftest zulip-compose-keymap-cancel ()
  "C-c C-k is bound to `zulip-compose-cancel'."
  (should (eq (lookup-key zulip-compose-mode-map (kbd "C-c C-k"))
              #'zulip-compose-cancel)))

(ert-deftest zulip-compose-keymap-attach ()
  "C-c C-a is bound to `zulip-compose-attach-file'."
  (should (eq (lookup-key zulip-compose-mode-map (kbd "C-c C-a"))
              #'zulip-compose-attach-file)))

;;;; Compose buffer setup

(ert-deftest zulip-compose-buffer-stream ()
  "Composing a stream message sets buffer-local state correctly."
  (let* ((conn (zulip--connection-create
                :server "https://test.zulip.com"
                :email "test@test.com"
                :api-key "key"
                :cache (zulip--cache-create)))
         (buf (progn
                (zulip-compose-message conn "stream" "general" "hello")
                (current-buffer))))
    (unwind-protect
        (with-current-buffer buf
          (should (string= zulip--compose-type "stream"))
          (should (string= zulip--compose-to "general"))
          (should (string= zulip--compose-topic "hello"))
          (should (eq zulip--compose-connection conn))
          (should (integerp zulip--compose-body-start))
          (should (> zulip--compose-body-start (point-min))))
      (kill-buffer buf))))

(ert-deftest zulip-compose-buffer-direct ()
  "Composing a direct message sets buffer-local state correctly."
  (let* ((conn (zulip--connection-create
                :server "https://test.zulip.com"
                :email "test@test.com"
                :api-key "key"
                :cache (zulip--cache-create)))
         (buf (progn
                (zulip-compose-message conn "direct" "alice@z.com" nil)
                (current-buffer))))
    (unwind-protect
        (with-current-buffer buf
          (should (string= zulip--compose-type "direct"))
          (should (string= zulip--compose-to "alice@z.com"))
          (should (null zulip--compose-topic)))
      (kill-buffer buf))))

;;;; Attach — error handling

(ert-deftest zulip-compose-attach-no-connection ()
  "Attach errors when no connection is set."
  (with-temp-buffer
    (zulip-compose-mode)
    (setq zulip--compose-connection nil)
    (should-error (zulip-compose-attach-file "/tmp/nofile.txt")
                  :type 'user-error)))

(ert-deftest zulip-compose-attach-unreadable-file ()
  "Attach errors for non-existent files."
  (with-temp-buffer
    (zulip-compose-mode)
    (setq zulip--compose-connection
          (zulip--connection-create
           :server "https://test.zulip.com"
           :email "t@t.com"
           :api-key "k"
           :cache (zulip--cache-create)))
    (should-error
     (zulip-compose-attach-file "/tmp/nonexistent-zulip-test-file-12345")
     :type 'user-error)))

;;;; @-mention completion

(defun zulip-test--compose-connection-with-users (users)
  "Create a `zulip--connection' with USERS for compose testing.
Each element of USERS is (id email full-name &optional is-bot)."
  (let* ((cache (zulip--cache-create))
         (conn  (zulip--connection-create
                 :server "https://test.zulip.com"
                 :email "test@test.com"
                 :api-key "key"
                 :user-id 99
                 :cache cache)))
    (dolist (u users)
      (let ((ht (make-hash-table :test 'equal)))
        (puthash "user_id" (nth 0 u) ht)
        (puthash "email" (nth 1 u) ht)
        (puthash "full_name" (nth 2 u) ht)
        (puthash "avatar_url" nil ht)
        (puthash "is_bot" (if (nth 3 u) t :json-false) ht)
        (zulip--cache-put-user cache ht)))
    conn))

(ert-deftest zulip-compose-mention-candidates-basic ()
  "Mention candidates include user names and wildcards."
  (let* ((conn (zulip-test--compose-connection-with-users
                '((1 "alice@z.com" "Alice")
                  (2 "bob@z.com" "Bob"))))
         (cands (zulip-compose--mention-candidates
                 (zulip--connection-cache conn))))
    ;; Two users + 4 wildcards
    (should (= (length cands) 6))
    (should (member "Alice" cands))
    (should (member "Bob" cands))
    (should (member "all" cands))
    (should (member "everyone" cands))
    (should (member "channel" cands))
    (should (member "topic" cands))))

(ert-deftest zulip-compose-mention-candidates-sorted ()
  "User names in mention candidates are sorted alphabetically."
  (let* ((conn (zulip-test--compose-connection-with-users
                '((1 "zara@z.com" "Zara")
                  (2 "alice@z.com" "Alice")
                  (3 "milo@z.com" "Milo"))))
         (cands (zulip-compose--mention-candidates
                 (zulip--connection-cache conn))))
    ;; First 3 should be sorted user names
    (should (string= (nth 0 cands) "Alice"))
    (should (string= (nth 1 cands) "Milo"))
    (should (string= (nth 2 cands) "Zara"))))

(ert-deftest zulip-compose-mention-candidates-excludes-bots ()
  "Bot users are excluded from mention candidates."
  (let* ((conn (zulip-test--compose-connection-with-users
                '((1 "alice@z.com" "Alice" nil)
                  (2 "bot@z.com" "Notification Bot" t))))
         (cands (zulip-compose--mention-candidates
                 (zulip--connection-cache conn))))
    ;; Only Alice + 4 wildcards
    (should (= (length cands) 5))
    (should (member "Alice" cands))
    (should-not (cl-find "Notification Bot" cands :test #'string=))))

(ert-deftest zulip-compose-mention-candidates-user-id-property ()
  "Each user candidate carries a `zulip-user-id' text property."
  (let* ((conn (zulip-test--compose-connection-with-users
                '((42 "alice@z.com" "Alice"))))
         (cands (zulip-compose--mention-candidates
                 (zulip--connection-cache conn)))
         (alice (cl-find "Alice" cands :test #'string=)))
    (should alice)
    (should (= (get-text-property 0 'zulip-user-id alice) 42))))

(ert-deftest zulip-compose-mention-exit-wraps-syntax ()
  "Exit function wraps completed text in @**...**  syntax."
  (with-temp-buffer
    ;; Simulate what completion does: buffer has "@Alice" with point after it
    (insert "@Alice")
    ;; The exit function receives just the candidate and status
    (zulip-compose--mention-exit "Alice" 'finished)
    (should (string= (buffer-string) "@**Alice** "))))

(ert-deftest zulip-compose-mention-exit-noop-on-exact ()
  "Exit function does nothing when status is not `finished'."
  (with-temp-buffer
    (insert "@Ali")
    (zulip-compose--mention-exit "Ali" 'sole)
    ;; Should be unchanged
    (should (string= (buffer-string) "@Ali"))))

(ert-deftest zulip-compose-mention-capf-triggers ()
  "CAPF returns completion data when point is after @ in body area."
  (let* ((conn (zulip-test--compose-connection-with-users
                '((1 "alice@z.com" "Alice")))))
    (with-temp-buffer
      (zulip-compose-mode)
      (setq zulip--compose-connection conn
            zulip--compose-body-start (point-min))
      (insert "@Al")
      (let ((result (zulip-compose--mention-capf)))
        (should result)
        ;; result is (start end candidates :exclusive no :exit-function fn)
        (should (= (nth 0 result) 2))   ; after @
        (should (= (nth 1 result) 4))   ; end of "Al"
        (should (listp (nth 2 result)))))))

(ert-deftest zulip-compose-mention-capf-no-trigger-before-body ()
  "CAPF returns nil for @ signs before the body-start marker."
  (let ((conn (zulip-test--compose-connection-with-users
               '((1 "alice@z.com" "Alice")))))
    (with-temp-buffer
      (zulip-compose-mode)
      (setq zulip--compose-connection conn)
      (insert "To: test@example.com\n---\n")
      (setq zulip--compose-body-start (point))
      ;; Move to the header area and check
      (goto-char 10) ; inside "test@example.com"
      (should-not (zulip-compose--mention-capf)))))

(provide 'test-zulip-compose)
;;; test-zulip-compose.el ends here
