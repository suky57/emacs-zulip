;;; test-zulip.el --- Tests for zulip.el -*- lexical-binding: t; -*-

;;; Commentary:
;; ERT tests for the entry-point module — .zuliprc parsing, URL normalization,
;; and connection management.

;;; Code:

(require 'ert)
(require 'zulip)

;;;; URL normalization

(ert-deftest zulip-normalize-url-https ()
  "HTTPS URL passes through (minus trailing slash)."
  (should (string= (zulip--normalize-server-url "https://chat.example.com/")
                    "https://chat.example.com")))

(ert-deftest zulip-normalize-url-http-to-https ()
  "HTTP is rewritten to HTTPS."
  (should (string= (zulip--normalize-server-url "http://chat.example.com")
                    "https://chat.example.com")))

(ert-deftest zulip-normalize-url-bare-host ()
  "Bare hostname gets https:// prepended."
  (should (string= (zulip--normalize-server-url "chat.example.com")
                    "https://chat.example.com")))

(ert-deftest zulip-normalize-url-strips-whitespace ()
  "Leading/trailing whitespace is stripped."
  (should (string= (zulip--normalize-server-url "  https://x.com/  ")
                    "https://x.com")))

;;;; .zuliprc parser

(ert-deftest zulip-rc-parse-single-section ()
  "Parse a standard [api] section."
  (let ((tmpfile (make-temp-file "zuliprc")))
    (unwind-protect
        (progn
          (with-temp-file tmpfile
            (insert "[api]\n"
                    "email=user@example.com\n"
                    "key=abc123\n"
                    "site=https://chat.example.com\n"))
          (let ((sections (zulip--rc-parse tmpfile)))
            (should (= (length sections) 1))
            (should (string= (car (car sections)) "api"))
            (let ((data (cdr (car sections))))
              (should (string= (cdr (assoc "email" data)) "user@example.com"))
              (should (string= (cdr (assoc "key" data)) "abc123"))
              (should (string= (cdr (assoc "site" data))
                               "https://chat.example.com")))))
      (delete-file tmpfile))))

(ert-deftest zulip-rc-parse-multiple-sections ()
  "Parse multiple named sections."
  (let ((tmpfile (make-temp-file "zuliprc")))
    (unwind-protect
        (progn
          (with-temp-file tmpfile
            (insert "[work]\n"
                    "email=a@work.com\n"
                    "key=workkey\n"
                    "site=https://work.zulip.com\n"
                    "\n"
                    "[personal]\n"
                    "email=b@home.com\n"
                    "key=homekey\n"
                    "site=https://home.zulip.com\n"))
          (let ((sections (zulip--rc-parse tmpfile)))
            (should (= (length sections) 2))
            (should (string= (car (nth 0 sections)) "work"))
            (should (string= (car (nth 1 sections)) "personal"))))
      (delete-file tmpfile))))

(ert-deftest zulip-rc-parse-comments-and-blanks ()
  "Comments and blank lines are ignored."
  (let ((tmpfile (make-temp-file "zuliprc")))
    (unwind-protect
        (progn
          (with-temp-file tmpfile
            (insert "# This is a comment\n"
                    "[api]\n"
                    "; another comment\n"
                    "email=user@x.com\n"
                    "\n"
                    "key=k\n"
                    "site=https://x.com\n"))
          (let* ((sections (zulip--rc-parse tmpfile))
                 (data (cdr (car sections))))
            (should (= (length sections) 1))
            (should (string= (cdr (assoc "email" data)) "user@x.com"))
            (should (string= (cdr (assoc "key" data)) "k"))))
      (delete-file tmpfile))))

(ert-deftest zulip-rc-parse-missing-file ()
  "Return nil for nonexistent file."
  (should (null (zulip--rc-parse "/tmp/nonexistent-zuliprc-12345"))))

(ert-deftest zulip-rc-get-accounts-basic ()
  "Get accounts extracts (server email key) triples."
  (let ((tmpfile (make-temp-file "zuliprc")))
    (unwind-protect
        (progn
          (with-temp-file tmpfile
            (insert "[api]\n"
                    "email=me@z.com\n"
                    "key=mykey\n"
                    "site=https://z.com\n"))
          (let ((zulip-rc-file tmpfile))
            (let ((accounts (zulip--rc-get-accounts)))
              (should (= (length accounts) 1))
              (should (equal (car accounts)
                             '("https://z.com" "me@z.com" "mykey"))))))
      (delete-file tmpfile))))

(ert-deftest zulip-rc-get-accounts-normalizes-url ()
  "Account URLs are normalized (http→https, trailing slash removed)."
  (let ((tmpfile (make-temp-file "zuliprc")))
    (unwind-protect
        (progn
          (with-temp-file tmpfile
            (insert "[api]\n"
                    "email=me@z.com\n"
                    "key=k\n"
                    "site=http://z.com/\n"))
          (let ((zulip-rc-file tmpfile))
            (let ((accounts (zulip--rc-get-accounts)))
              (should (string= (nth 0 (car accounts)) "https://z.com")))))
      (delete-file tmpfile))))

(ert-deftest zulip-rc-get-accounts-skips-incomplete ()
  "Sections missing email/key/site are skipped."
  (let ((tmpfile (make-temp-file "zuliprc")))
    (unwind-protect
        (progn
          (with-temp-file tmpfile
            (insert "[good]\n"
                    "email=a@b.com\n"
                    "key=k\n"
                    "site=https://b.com\n"
                    "\n"
                    "[bad]\n"
                    "email=c@d.com\n"
                    "; missing key and site\n"))
          (let ((zulip-rc-file tmpfile))
            (let ((accounts (zulip--rc-get-accounts)))
              (should (= (length accounts) 1))
              (should (string= (nth 1 (car accounts)) "a@b.com")))))
      (delete-file tmpfile))))

;;;; Connection registry

(ert-deftest zulip-find-connection-found ()
  "Find existing connection by server URL."
  (let* ((conn (zulip--connection-create :server "https://x.com"
                                         :email "a@x.com"
                                         :api-key "k"))
         (zulip--connections (list conn)))
    (should (eq (zulip--find-connection "https://x.com") conn))))

(ert-deftest zulip-find-connection-not-found ()
  "Return nil for unknown server."
  (let ((zulip--connections nil))
    (should (null (zulip--find-connection "https://x.com")))))

(provide 'test-zulip)
;;; test-zulip.el ends here
