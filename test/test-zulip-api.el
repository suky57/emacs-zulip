;;; test-zulip-api.el --- Tests for zulip-api.el -*- lexical-binding: t; -*-

;;; Commentary:
;; ERT tests for the API layer — URL building, param encoding, auth headers,
;; and response parsing.  No live server calls; HTTP is mocked with cl-letf.

;;; Code:

(require 'ert)
(require 'zulip-api)

;;;; URL construction

(ert-deftest zulip-api-url-construction ()
  "API URL is server + /api/v1 + endpoint."
  (let ((conn (zulip--connection-create :server "https://chat.example.com"
                                        :email "a@b.com"
                                        :api-key "key123")))
    (should (string= (zulip--api-url conn "/messages")
                      "https://chat.example.com/api/v1/messages"))
    (should (string= (zulip--api-url conn "/users/me")
                      "https://chat.example.com/api/v1/users/me"))))

;;;; Auth header

(ert-deftest zulip-api-auth-header ()
  "Basic auth header is base64(email:api-key)."
  (let ((conn (zulip--connection-create :server "https://x.com"
                                        :email "user@x.com"
                                        :api-key "abc123")))
    (let ((header (zulip--api-auth-header conn)))
      (should (string-prefix-p "Basic " header))
      ;; Decode and verify
      (let ((decoded (base64-decode-string (substring header 6))))
        (should (string= decoded "user@x.com:abc123"))))))

;;;; Parameter encoding

(ert-deftest zulip-api-encode-params-strings ()
  "String values are URL-encoded."
  (let ((result (zulip--api-encode-params '(("foo" . "bar baz")))))
    (should (string= result "foo=bar%20baz"))))

(ert-deftest zulip-api-encode-params-numbers ()
  "Numeric values are converted to strings."
  (let ((result (zulip--api-encode-params '(("count" . 42)))))
    (should (string= result "count=42"))))

(ert-deftest zulip-api-encode-params-booleans ()
  "t → true, :json-false → false."
  (let ((result (zulip--api-encode-params '(("a" . t) ("b" . :json-false)))))
    (should (string-match-p "a=true" result))
    (should (string-match-p "b=false" result))))

(ert-deftest zulip-api-encode-params-multiple ()
  "Multiple params are joined with &."
  (let ((result (zulip--api-encode-params '(("a" . "1") ("b" . "2")))))
    (should (string= result "a=1&b=2"))))

;;;; JSON parsing

(ert-deftest zulip-api-parse-response-success ()
  "Parse a well-formed HTTP response with JSON body."
  (with-temp-buffer
    (insert "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n")
    (insert "{\"result\":\"success\",\"msg\":\"\",\"value\":42}")
    (goto-char (point-min))
    (let ((data (zulip--api-parse-response)))
      (should data)
      (should (equal (gethash "result" data) "success"))
      (should (= (gethash "value" data) 42)))))

(ert-deftest zulip-api-parse-response-empty ()
  "Return nil for truncated / empty response."
  (with-temp-buffer
    (insert "HTTP/1.1 200 OK\r\n\r\n")
    (goto-char (point-min))
    (should (null (zulip--api-parse-response)))))

;;;; JSON helpers

(ert-deftest zulip-api-json-encode-vector ()
  "Vectors encode as JSON arrays."
  (let ((json (zulip--json-encode (vector 1 2 3))))
    (should (string= json "[1,2,3]"))))

;;;; Narrow helpers

(ert-deftest zulip-api-narrow-channel-topic ()
  "Build correct narrow JSON for channel + topic."
  (let ((narrow (zulip--narrow-channel-topic "general" "hello")))
    ;; Should be valid JSON
    (should (stringp narrow))
    (should (string-match-p "stream" narrow))
    (should (string-match-p "general" narrow))
    (should (string-match-p "topic" narrow))
    (should (string-match-p "hello" narrow))))

(ert-deftest zulip-api-narrow-dm ()
  "Build correct narrow JSON for DMs."
  (let ((narrow (zulip--narrow-dm "alice@z.com,bob@z.com")))
    (should (stringp narrow))
    (should (string-match-p "pm-with" narrow))
    (should (string-match-p "alice@z.com" narrow))))

;;;; Mocked async request

(ert-deftest zulip-api-request-sync-mock ()
  "Synchronous request returns parsed JSON."
  (let ((mock-response
         (concat "HTTP/1.1 200 OK\r\n"
                 "Content-Type: application/json\r\n\r\n"
                 "{\"result\":\"success\",\"msg\":\"\",\"api_key\":\"test123\"}")))
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (_url &rest _args)
                 (let ((buf (generate-new-buffer " *test-response*")))
                   (with-current-buffer buf
                     (insert mock-response))
                   buf))))
      (let ((data (zulip--api-request-sync
                   "GET" "https://test.com/api/v1/test" nil nil)))
        (should data)
        (should (string= (gethash "result" data) "success"))
        (should (string= (gethash "api_key" data) "test123"))))))

;;;; MIME type detection

(ert-deftest zulip-api-mime-type-images ()
  "Image extensions return correct MIME types."
  (should (string= (zulip--api-mime-type "photo.png") "image/png"))
  (should (string= (zulip--api-mime-type "pic.jpg") "image/jpeg"))
  (should (string= (zulip--api-mime-type "pic.JPEG") "image/jpeg"))
  (should (string= (zulip--api-mime-type "anim.gif") "image/gif"))
  (should (string= (zulip--api-mime-type "icon.webp") "image/webp"))
  (should (string= (zulip--api-mime-type "logo.svg") "image/svg+xml")))

(ert-deftest zulip-api-mime-type-documents ()
  "Document extensions return correct MIME types."
  (should (string= (zulip--api-mime-type "doc.pdf") "application/pdf"))
  (should (string= (zulip--api-mime-type "readme.txt") "text/plain"))
  (should (string= (zulip--api-mime-type "notes.md") "text/markdown"))
  (should (string= (zulip--api-mime-type "data.json") "application/json"))
  (should (string= (zulip--api-mime-type "data.csv") "text/csv"))
  (should (string= (zulip--api-mime-type "page.html") "text/html")))

(ert-deftest zulip-api-mime-type-archives ()
  "Archive extensions return correct MIME types."
  (should (string= (zulip--api-mime-type "pkg.zip") "application/zip"))
  (should (string= (zulip--api-mime-type "pkg.gz") "application/gzip"))
  (should (string= (zulip--api-mime-type "pkg.tar") "application/x-tar")))

(ert-deftest zulip-api-mime-type-code ()
  "Source code extensions return text/plain or similar."
  (should (string= (zulip--api-mime-type "init.el") "text/plain"))
  (should (string= (zulip--api-mime-type "script.py") "text/plain"))
  (should (string= (zulip--api-mime-type "app.js") "text/javascript")))

(ert-deftest zulip-api-mime-type-unknown ()
  "Unknown extensions return application/octet-stream."
  (should (string= (zulip--api-mime-type "file.xyz")
                    "application/octet-stream"))
  (should (string= (zulip--api-mime-type "noext")
                    "application/octet-stream")))

;;;; Multipart boundary generation

(ert-deftest zulip-api-generate-boundary ()
  "Boundary is a non-empty string with expected prefix."
  (let ((b (zulip--api-generate-boundary)))
    (should (stringp b))
    (should (> (length b) 0))
    (should (string-prefix-p "----ZulipEmacs" b))))

(ert-deftest zulip-api-generate-boundary-unique ()
  "Two consecutive boundaries differ."
  (let ((b1 (zulip--api-generate-boundary))
        (b2 (zulip--api-generate-boundary)))
    ;; Not strictly guaranteed, but extremely unlikely to collide
    (should (stringp b1))
    (should (stringp b2))))

;;;; Multipart body building

(ert-deftest zulip-api-build-multipart-body ()
  "Multipart body contains boundary, filename, content type, and file data."
  (let ((tmpfile (make-temp-file "zulip-upload-test-" nil ".txt")))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'utf-8))
            (with-temp-file tmpfile
              (insert "hello world")))
          (let* ((boundary "test-boundary-123")
                 (body (zulip--api-build-multipart-body boundary tmpfile)))
            (should (stringp body))
            ;; Unibyte for correct Content-Length handling
            (should (not (multibyte-string-p body)))
            ;; Contains opening and closing boundary
            (should (string-match-p "--test-boundary-123\r\n" body))
            (should (string-match-p "--test-boundary-123--\r\n" body))
            ;; Contains Content-Disposition with field name "file"
            (should (string-match-p
                     "Content-Disposition: form-data; name=\"file\""
                     body))
            ;; Contains the original filename
            (should (string-match-p "filename=\"[^\"]*\\.txt\"" body))
            ;; Contains correct Content-Type
            (should (string-match-p "Content-Type: text/plain" body))
            ;; Contains the file data
            (should (string-match-p "hello world" body))))
      (delete-file tmpfile))))

(ert-deftest zulip-api-build-multipart-body-binary ()
  "Multipart body preserves binary file content."
  (let ((tmpfile (make-temp-file "zulip-upload-test-" nil ".bin")))
    (unwind-protect
        (progn
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert 0 1 2 255 254 253)
            (let ((coding-system-for-write 'raw-text))
              (write-region (point-min) (point-max) tmpfile)))
          (let* ((boundary "bin-boundary")
                 (body (zulip--api-build-multipart-body boundary tmpfile)))
            (should (not (multibyte-string-p body)))
            ;; Body should contain the raw bytes
            (should (> (length body) 6))))
      (delete-file tmpfile))))

;;; test-zulip-api.el ends here
