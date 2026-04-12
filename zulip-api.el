;;; zulip-api.el --- HTTP helpers and API layer for emacs-zulip -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Author: emacs-zulip contributors

;;; Commentary:

;; Wraps the Zulip REST API using `url.el' (built-in).
;; All calls are async via `url-retrieve' except login / auth which uses
;; `url-retrieve-synchronously'.  JSON is parsed with the native
;; `json-parse-buffer' (Jansson) when available, falling back to `json-read'.

;;; Code:

(require 'cl-lib)
(require 'url)
(require 'json)
(require 'zulip-cache)

;;;; url.el multibyte workaround (Emacs Bug#23750)
;;
;; `url-http-create-request' concatenates multibyte header strings with
;; the (unibyte) body in `url-request-data'.  The result is a multibyte
;; string whose `string-bytes' exceeds its `length', which the function
;; then rejects with "Multibyte text in HTTP request" — before returning,
;; so a :filter-return advice cannot help.
;;
;; Fix: :around advice that, when `url-request-data' contains bytes>127,
;; substitutes an ASCII placeholder of the same length (preserving the
;; Content-length header the function computes), then splices the real
;; binary body back into the unibyte result.

(defun zulip--api-fix-multibyte-request (orig-fun &rest args)
  "Around advice for `url-http-create-request' (Emacs Bug#23750).
When `url-request-data' is a unibyte string with bytes above 127,
substitute an ASCII placeholder so the function can build headers
with a correct Content-length without hitting the multibyte check,
then splice the real binary body back."
  (let ((body url-request-data))
    (if (not (and body
                  (not (multibyte-string-p body))
                  (string-match-p "[\200-\377]" body)))
        ;; No high bytes — call normally.
        (apply orig-fun args)
      ;; Binary body: swap in same-length ASCII filler.
      (let* ((url-request-data (make-string (length body) ?X))
             (request (apply orig-fun args))
             (sep (string-search "\r\n\r\n" request)))
        (if sep
            (concat (encode-coding-string
                     (substring request 0 (+ sep 4))
                     'raw-text-unix)
                    body)
          ;; Shouldn't happen; return best-effort encoding.
          (encode-coding-string request 'raw-text-unix))))))

(with-eval-after-load 'url-http
  (advice-add 'url-http-create-request :around
              #'zulip--api-fix-multibyte-request))

;;;; Constants

(defconst zulip--api-version "v1"
  "Zulip REST API version path component.")

(defvar zulip--user-agent
  (format "ZulipEmacs/%s" (if (boundp 'zulip-version) zulip-version "0.1"))
  "User-Agent header sent with every request.")

;;;; JSON helpers — native Jansson or pure-elisp fallback

(defconst zulip--native-json-p (fboundp 'json-parse-buffer)
  "Non-nil when Emacs has native JSON (Jansson) support.")

(defun zulip--json-parse ()
  "Parse JSON starting at point.  Return hash-table (objects) / vector (arrays)."
  (if zulip--native-json-p
      (json-parse-buffer :object-type 'hash-table :array-type 'array
                         :null-object nil :false-object :json-false)
    (let ((json-object-type 'hash-table)
          (json-array-type  'vector)
          (json-false       :json-false))
      (json-read))))

(defun zulip--json-encode (obj)
  "Encode OBJ to a JSON string."
  (if zulip--native-json-p
      (json-serialize obj)
    (json-encode obj)))

;;;; URL / Auth helpers

(defun zulip--api-url (conn endpoint)
  "Build full API URL from CONN server and ENDPOINT (e.g. \"/messages\")."
  (concat (zulip--connection-server conn)
          "/api/" zulip--api-version
          endpoint))

(defun zulip--api-auth-header (conn)
  "Return the value for an Authorization: Basic header for CONN."
  (concat "Basic "
          (base64-encode-string
           (concat (zulip--connection-email conn)
                   ":"
                   (zulip--connection-api-key conn))
           t)))

(defun zulip--api-encode-params (params)
  "URL-encode alist PARAMS into an application/x-www-form-urlencoded string.
Values may be strings, numbers, t/:json-false (→ true/false), or
Lisp objects (→ json-serialized)."
  (mapconcat
   (lambda (pair)
     (concat (url-hexify-string (car pair))
             "="
             (url-hexify-string
              (let ((v (cdr pair)))
                (cond
                 ((stringp v) v)
                 ((numberp v) (number-to-string v))
                 ((eq v t) "true")
                 ((eq v :json-false) "false")
                 (t (zulip--json-encode v)))))))
   params "&"))

;;;; Response parsing

(defun zulip--api-parse-response ()
  "In the current HTTP response buffer, skip headers and parse JSON body.
Return a hash-table or nil on failure."
  (goto-char (point-min))
  (when (re-search-forward "\r?\n\r?\n" nil t)
    (condition-case nil
        (zulip--json-parse)
      (error nil))))

;;;; Core request functions

(defun zulip--api-request (conn method endpoint params callback)
  "Make an async HTTP request to the Zulip API.
CONN     — `zulip--connection'.
METHOD   — \"GET\" or \"POST\".
ENDPOINT — e.g. \"/messages\".
PARAMS   — alist of request parameters (may be nil).
CALLBACK — called with the parsed hash-table on success, nil on error.

GET params are appended as query-string; POST params go in the body."
  (let* ((url-request-method method)
         (url-request-extra-headers
          `(("Authorization" . ,(zulip--api-auth-header conn))
            ("User-Agent"    . ,zulip--user-agent)
            ,@(when (string= method "POST")
                '(("Content-Type" . "application/x-www-form-urlencoded")))))
         (url-request-data
          (when (and params (string= method "POST"))
            (zulip--api-encode-params params)))
         (full-url
          (if (and params (string= method "GET"))
              (concat (zulip--api-url conn endpoint)
                      "?" (zulip--api-encode-params params))
            (zulip--api-url conn endpoint))))
    (url-retrieve
     full-url
     (lambda (status)
       (unwind-protect
           ;; Always try to parse the response body — Zulip returns
           ;; JSON even on 4xx/5xx errors.
           (let ((data (zulip--api-parse-response))
                 (http-err (plist-get status :error)))
             (cond
              ;; HTTP error WITH a Zulip JSON body → show server message
              ((and http-err data (gethash "msg" data))
               (message "Zulip: %s error — %s"
                        endpoint (gethash "msg" data))
               (when callback (run-at-time 0 nil callback nil)))
              ;; HTTP error, no parseable body → network / TLS issue
              (http-err
               (message "Zulip: network error on %s: %S"
                        endpoint http-err)
               (when callback (run-at-time 0 nil callback nil)))
              ;; No data at all
              ((null data)
               (message "Zulip: empty response from %s" endpoint)
               (when callback (run-at-time 0 nil callback nil)))
              ;; Zulip reported success
              ((equal (gethash "result" data) "success")
               (when callback (run-at-time 0 nil callback data)))
              ;; Zulip reported an application-level error
              (t
               (message "Zulip: API error on %s — %s"
                        endpoint (gethash "msg" data "unknown error"))
               (when callback (run-at-time 0 nil callback nil)))))
         (kill-buffer (current-buffer))))
     nil t t)))

(defun zulip--api-request-sync (method url headers body)
  "Synchronous HTTP request.  Return parsed JSON hash-table or nil.
METHOD  — HTTP method string.
URL     — full URL.
HEADERS — alist of extra headers.
BODY    — request body string or nil."
  (let* ((url-request-method method)
         (url-request-extra-headers headers)
         (url-request-data body)
         (buf (url-retrieve-synchronously url t t 30)))
    (when buf
      (unwind-protect
          (with-current-buffer buf
            (zulip--api-parse-response))
        (kill-buffer buf)))))

;;;; High-level API wrappers

(defun zulip--api-fetch-api-key (server email password)
  "Fetch an API key from SERVER for EMAIL + PASSWORD.
Return (api-key . email) on success, nil on failure.
This is synchronous (login is the one allowed blocking call)."
  (let* ((url (concat server "/api/" zulip--api-version "/fetch_api_key"))
         (headers `(("User-Agent"   . ,zulip--user-agent)
                    ("Content-Type" . "application/x-www-form-urlencoded")))
         (body (zulip--api-encode-params
                `(("username" . ,email)
                  ("password" . ,password))))
         (data (zulip--api-request-sync "POST" url headers body)))
    (when (and data (equal (gethash "result" data) "success"))
      (cons (gethash "api_key" data)
            (gethash "email" data)))))

(defun zulip--api-get-server-settings (server)
  "Fetch server settings from SERVER (no auth required).  Return hash-table."
  (let* ((url (concat server "/api/" zulip--api-version "/server_settings"))
         (headers `(("User-Agent" . ,zulip--user-agent))))
    (zulip--api-request-sync "GET" url headers nil)))

(defun zulip--api-get-profile (conn callback)
  "Fetch current user's profile.  CALLBACK receives data or nil."
  (zulip--api-request conn "GET" "/users/me" nil callback))

(defun zulip--api-get-profile-sync (conn)
  "Fetch current user's profile synchronously.  Return data or nil."
  (let* ((url (zulip--api-url conn "/users/me"))
         (headers `(("Authorization" . ,(zulip--api-auth-header conn))
                    ("User-Agent"    . ,zulip--user-agent)))
         (data (zulip--api-request-sync "GET" url headers nil)))
    (when (and data (equal (gethash "result" data) "success"))
      data)))

(defun zulip--api-get-channels (conn callback)
  "Fetch subscribed channels.  CALLBACK receives data or nil."
  (zulip--api-request conn "GET" "/users/me/subscriptions" nil callback))

(defun zulip--api-get-topics (conn channel-id callback)
  "Fetch topics for CHANNEL-ID.  CALLBACK receives data or nil."
  (zulip--api-request
   conn "GET"
   (concat "/users/me/" (number-to-string channel-id) "/topics")
   nil callback))

(defun zulip--api-get-messages (conn narrow anchor num-before num-after callback)
  "Fetch messages matching NARROW (JSON string).
ANCHOR is \"newest\", \"oldest\", or an integer message-id.
NUM-BEFORE / NUM-AFTER are integers.
CALLBACK receives data or nil."
  (zulip--api-request
   conn "GET" "/messages"
   `(("narrow"         . ,narrow)
     ("anchor"         . ,(if (numberp anchor)
                              (number-to-string anchor) anchor))
     ("num_before"     . ,(number-to-string num-before))
     ("num_after"      . ,(number-to-string num-after))
     ("apply_markdown" . "true"))
   callback))

(defun zulip--api-send-message (conn type to topic content callback)
  "Send a message via CONN.
TYPE    — \"stream\" or \"direct\".
TO      — channel name (stream) or JSON user-ids array string (direct).
TOPIC   — topic string (stream) or nil (direct).
CONTENT — message body.
CALLBACK receives data or nil."
  (let ((params `(("type"    . ,type)
                  ("to"      . ,to)
                  ("content" . ,content))))
    (when topic
      (push (cons "topic" topic) params))
    (zulip--api-request conn "POST" "/messages" params callback)))

(defun zulip--api-mark-topic-read (conn channel-id topic-name callback)
  "Mark all messages in TOPIC-NAME of CHANNEL-ID as read."
  (zulip--api-request
   conn "POST" "/mark_topic_as_read"
   `(("stream_id"  . ,(number-to-string channel-id))
     ("topic_name" . ,topic-name))
   callback))

(defun zulip--api-get-users (conn callback)
  "Fetch all users in the realm.  CALLBACK receives data or nil."
  (zulip--api-request conn "GET" "/users" nil callback))

(defun zulip--api-register-queue (conn event-types callback)
  "Register an event queue for EVENT-TYPES (JSON string).
CALLBACK receives parsed register response or nil."
  (zulip--api-request
   conn "POST" "/register"
   `(("event_types"     . ,event-types)
     ("apply_markdown"  . "true")
     ("client_gravatar" . "true"))
   callback))

(defun zulip--api-get-events (conn callback)
  "Long-poll for events on CONN.  CALLBACK receives data or nil."
  (zulip--api-request
   conn "GET" "/events"
   `(("queue_id"      . ,(zulip--connection-queue-id conn))
     ("last_event_id" . ,(number-to-string
                          (zulip--connection-last-event-id conn)))
     ("dont_block"    . "false"))
   callback))

(defun zulip--api-delete-queue (conn callback)
  "Delete the event queue for CONN."
  (when (zulip--connection-queue-id conn)
    (zulip--api-request
     conn "DELETE" "/events"
     `(("queue_id" . ,(zulip--connection-queue-id conn)))
     callback)))

;;;; File Upload

(defun zulip--api-generate-boundary ()
  "Generate a unique MIME multipart boundary string."
  (format "----ZulipEmacs%s%06d"
          (format-time-string "%s" (current-time))
          (random 999999)))

(defun zulip--api-mime-type (filename)
  "Guess MIME type for FILENAME based on file extension."
  (let ((ext (downcase (or (file-name-extension filename) ""))))
    (pcase ext
      ("png"  "image/png")
      ("jpg"  "image/jpeg")
      ("jpeg" "image/jpeg")
      ("gif"  "image/gif")
      ("webp" "image/webp")
      ("svg"  "image/svg+xml")
      ("pdf"  "application/pdf")
      ("txt"  "text/plain")
      ("md"   "text/markdown")
      ("org"  "text/plain")
      ("html" "text/html")
      ("json" "application/json")
      ("csv"  "text/csv")
      ("zip"  "application/zip")
      ("gz"   "application/gzip")
      ("tar"  "application/x-tar")
      ("el"   "text/plain")
      ("py"   "text/plain")
      ("js"   "text/javascript")
      ("ts"   "text/plain")
      (_      "application/octet-stream"))))

(defun zulip--api-build-multipart-body (boundary file-path)
  "Build a multipart/form-data body with BOUNDARY for FILE-PATH.\nReturn a unibyte string suitable for `url-request-data'."
  (let* ((filename (file-name-nondirectory file-path))
         (mime-type (zulip--api-mime-type filename))
         ;; encode-coding-string always returns unibyte.
         (header (encode-coding-string
                  (concat "--" boundary "\r\n"
                          "Content-Disposition: form-data;"
                          " name=\"file\";"
                          " filename=\"" filename "\"\r\n"
                          "Content-Type: " mime-type "\r\n"
                          "\r\n")
                  'utf-8))
         (footer (encode-coding-string
                  (concat "\r\n--" boundary "--\r\n")
                  'utf-8))
         ;; Read raw bytes in a dedicated unibyte buffer.
         (file-data (with-temp-buffer
                      (set-buffer-multibyte nil)
                      (insert-file-contents-literally file-path)
                      ;; Re-assert unibyte — insert-file-contents-literally
                      ;; can flip the multibyte flag in some Emacs builds.
                      (set-buffer-multibyte nil)
                      (buffer-string))))
    ;; concat of all-unibyte strings → unibyte.
    ;; Final encode-coding-string guards against any edge case where
    ;; an intermediate value was unexpectedly multibyte (no-op when
    ;; already unibyte).
    (encode-coding-string (concat header file-data footer)
                          'no-conversion)))

(defun zulip--api-upload-file (conn file-path callback)
  "Upload FILE-PATH to CONN's Zulip server.\nCALLBACK is called with the upload URI string (e.g. \"/user_uploads/…\")\non success, or nil on failure."
  (unless (file-readable-p file-path)
    (user-error "Cannot read file: %s" file-path))
  (let* ((boundary (zulip--api-generate-boundary))
         (url-request-method "POST")
         (url-request-extra-headers
          `(("Authorization" . ,(zulip--api-auth-header conn))
            ("User-Agent"    . ,zulip--user-agent)
            ("Content-Type"  . ,(format "multipart/form-data; boundary=%s"
                                        boundary))))
         (url-request-data
          (zulip--api-build-multipart-body boundary file-path))
         (url (zulip--api-url conn "/user_uploads")))
    (url-retrieve
     url
     (lambda (status)
       (unwind-protect
           (let ((data (zulip--api-parse-response))
                 (http-err (plist-get status :error)))
             (cond
              ((and http-err data (gethash "msg" data))
               (message "Zulip: upload error — %s" (gethash "msg" data))
               (when callback (run-at-time 0 nil callback nil)))
              (http-err
               (message "Zulip: upload network error: %S" http-err)
               (when callback (run-at-time 0 nil callback nil)))
              ((null data)
               (message "Zulip: empty response from upload")
               (when callback (run-at-time 0 nil callback nil)))
              ((equal (gethash "result" data) "success")
               (when callback
                 (run-at-time 0 nil callback (gethash "uri" data))))
              (t
               (message "Zulip: upload failed — %s"
                        (gethash "msg" data "unknown error"))
               (when callback (run-at-time 0 nil callback nil)))))
         (kill-buffer (current-buffer))))
     nil t t)))

;;;; Narrow construction helpers

(defun zulip--narrow-channel-topic (channel-name topic)
  "Build a JSON narrow string for CHANNEL-NAME and TOPIC."
  (zulip--json-encode
   (vector `((operator . "stream") (operand . ,channel-name))
           `((operator . "topic")  (operand . ,topic)))))

(defun zulip--narrow-dm (emails)
  "Build a JSON narrow string for a DM with EMAILS (comma-separated)."
  (zulip--json-encode
   (vector `((operator . "pm-with") (operand . ,emails)))))

(defun zulip--narrow-is-dm ()
  "Build a JSON narrow string for all DMs."
  (zulip--json-encode
   (vector '((operator . "is") (operand . "dm")))))

(provide 'zulip-api)
;;; zulip-api.el ends here
