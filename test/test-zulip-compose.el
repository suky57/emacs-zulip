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

(provide 'test-zulip-compose)
;;; test-zulip-compose.el ends here
