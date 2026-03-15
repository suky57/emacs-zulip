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

;;; test-zulip-api.el ends here
