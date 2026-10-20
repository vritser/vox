;;; vox-backend.el --- Backend contracts and safe configuration -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Shared contracts.  Backends emit data; only sinks may modify user buffers.

;;; Code:
(require 'cl-lib)
(require 'json)
(require 'auth-source)
(require 'subr-x)
(require 'url-parse)

(defgroup vox nil "Native streaming speech input." :group 'multimedia :prefix "vox-")
(defvar vox--backends (make-hash-table :test #'eq))

(defun vox-register-backend (name methods)
  "Register NAME with METHODS, a plist of functions and capabilities.
Required methods are :connect, :finish, :cancel and :close.  An external
recorder backend must also implement :send-pcm.  Connect receives SESSION,
ON-READY (no arguments), ON-EVENT (one normalized plist), and ON-ERROR
(one sanitized string).  Other methods receive SESSION, plus PCM for send."
  (dolist (key '(:connect :finish :cancel :close))
    (unless (functionp (plist-get methods key))
      (error "Missing backend method %s" key)))
  (when (and (plist-get methods :needs-external-audio)
             (not (functionp (plist-get methods :send-pcm))))
    (error "External-audio backend requires :send-pcm"))
  (puthash name methods vox--backends))

(defun vox-backend-methods (name)
  "Return registered methods for NAME, or fail before starting a session."
  (or (gethash name vox--backends) (user-error "Unknown Vox backend: %s" name)))

(defun vox-json-encode (object)
  "Encode OBJECT as JSON, with explicit :null and :false values."
  (let ((json-null :null) (json-false :false) (json-encoding-pretty-print nil))
    (json-encode object)))

(defun vox-json-read (string)
  "Read JSON STRING into plists, lists, and explicit :null/:false values."
  (json-parse-string string :object-type 'plist :array-type 'list
                     :null-object :null :false-object :false))

(defun vox-secret (host environment)
  "Resolve secret for HOST, preferring auth-source over ENVIRONMENT.
Use an auth-source entry with user `apikey'.  Never print the returned value."
  (let* ((auth-source-debug nil)
         (entry (car (auth-source-search :host host :user "apikey"
                                         :require '(:secret) :max 1)))
         (secret (plist-get entry :secret))
         (value (condition-case nil
                    (if (functionp secret) (funcall secret) secret)
                  (error nil))))
    (setq value (or value (getenv environment)))
    (unless (and (stringp value) (not (string-empty-p value))
                 (not (string-match-p "[\r\n]" value)))
      (user-error "Vox credential unavailable; configure auth-source or %s" environment))
    value))

(defun vox-check-endpoint (url official-hosts)
  "Validate WSS URL; ask before sending data outside OFFICIAL-HOSTS.
Confirmation applies to this connection only.  Reject userinfo, fragments,
control characters, and unresolved template placeholders."
  (unless (and (stringp url)
               (not (string-match-p "[\x00-\x20{}]" url)))
    (user-error "Invalid Vox endpoint"))
  (let* ((parsed (url-generic-parse-url url)) (host (url-host parsed)))
    (unless (and (equal (url-type parsed) "wss") host
                 (not (url-user parsed)) (not (url-password parsed))
                 (not (url-target parsed)))
      (user-error "Vox requires an authenticated wss:// endpoint"))
    (unless (and (member (downcase host) official-hosts)
                 (memq (url-portspec parsed) '(nil 443)))
      (unless (and (not noninteractive)
                   (yes-or-no-p (format "Send Vox audio and credentials to custom host %s? " host)))
        (user-error "Custom Vox endpoint was not approved"))))
  url)

(provide 'vox-backend)
;;; vox-backend.el ends here
