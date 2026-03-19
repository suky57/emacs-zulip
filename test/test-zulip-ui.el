;;; test-zulip-ui.el --- Tests for zulip-ui.el -*- lexical-binding: t; -*-

;;; Commentary:
;; ERT tests for the UI layer — recipient completion, key hints.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'zulip-cache)
(require 'zulip-ui)

;;;; Helpers

(defun zulip-test--make-connection-with-users (self-id users)
  "Create a `zulip--connection' with SELF-ID and USERS alist.
Each element of USERS is (id email full-name &optional is-bot)."
  (let* ((cache (zulip--cache-create))
         (conn  (zulip--connection-create
                 :server "https://test.zulip.com"
                 :email "self@test.com"
                 :api-key "key"
                 :user-id self-id
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

;;;; zulip--read-recipient-email

(ert-deftest zulip-ui-read-recipient-picks-email ()
  "Selecting a user from the completion list returns their email."
  (let* ((conn (zulip-test--make-connection-with-users
                100
                '((1 "alice@z.com" "Alice")
                  (2 "bob@z.com"   "Bob")
                  (100 "self@test.com" "Self")))))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt candidates &rest _)
                 ;; Simulate choosing Alice
                 (car (seq-filter (lambda (c) (string-match-p "Alice" c))
                                  candidates)))))
      (should (string= (zulip--read-recipient-email conn) "alice@z.com")))))

(ert-deftest zulip-ui-read-recipient-excludes-self ()
  "The current user is excluded from completion candidates."
  (let* ((conn (zulip-test--make-connection-with-users
                100
                '((1 "alice@z.com" "Alice")
                  (100 "self@test.com" "Self"))))
         (offered-candidates nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt candidates &rest _)
                 (setq offered-candidates candidates)
                 (car candidates))))
      (zulip--read-recipient-email conn)
      (should (= (length offered-candidates) 1))
      (should (string-match-p "Alice" (car offered-candidates))))))

(ert-deftest zulip-ui-read-recipient-excludes-bots ()
  "Bot users are excluded from completion candidates."
  (let* ((conn (zulip-test--make-connection-with-users
                100
                '((1 "alice@z.com" "Alice" nil)
                  (2 "bot@z.com" "Notification Bot" t))))
         (offered-candidates nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt candidates &rest _)
                 (setq offered-candidates candidates)
                 (car candidates))))
      (zulip--read-recipient-email conn)
      (should (= (length offered-candidates) 1))
      (should (string-match-p "Alice" (car offered-candidates))))))

(ert-deftest zulip-ui-read-recipient-fallback-empty-cache ()
  "When no users are cached, falls back to read-string."
  (let* ((conn (zulip-test--make-connection-with-users 100 nil)))
    (cl-letf (((symbol-function 'read-string)
               (lambda (_prompt) "manual@z.com")))
      (should (string= (zulip--read-recipient-email conn) "manual@z.com")))))

(ert-deftest zulip-ui-read-recipient-candidates-sorted ()
  "Completion candidates are sorted alphabetically."
  (let* ((conn (zulip-test--make-connection-with-users
                100
                '((1 "zara@z.com" "Zara")
                  (2 "alice@z.com" "Alice")
                  (3 "milo@z.com" "Milo"))))
         (offered-candidates nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt candidates &rest _)
                 (setq offered-candidates candidates)
                 (car candidates))))
      (zulip--read-recipient-email conn)
      (should (string-match-p "Alice" (nth 0 offered-candidates)))
      (should (string-match-p "Milo"  (nth 1 offered-candidates)))
      (should (string-match-p "Zara"  (nth 2 offered-candidates))))))

;;;; zulip--refresh-key-hint

(ert-deftest zulip-ui-refresh-hint-no-evil ()
  "Without Evil loaded, hint is \"g\"."
  (cl-letf (((symbol-function 'featurep)
             (lambda (f) (if (eq f 'evil) nil (featurep f)))))
    (should (string= (zulip--refresh-key-hint) "g"))))

(ert-deftest zulip-ui-refresh-hint-with-evil ()
  "With Evil loaded, hint is \"gr\"."
  (cl-letf (((symbol-function 'featurep)
             (lambda (f) (if (eq f 'evil) t (featurep f)))))
    (should (string= (zulip--refresh-key-hint) "gr"))))

(provide 'test-zulip-ui)
;;; test-zulip-ui.el ends here
