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
(require 'url-util)

(defgroup vox nil "Native streaming speech input." :group 'multimedia :prefix "vox-")
(defvar vox--backends (make-hash-table :test #'eq))

(cl-defstruct (vox-backend (:constructor vox--make-backend))
  "Connection configuration; credentials are resolved only when connecting."
  name type host endpoint models key resource-id)

(defun vox--backend-id (value &optional what)
  "Return a validated, copied string for identifier VALUE.
WHAT names the field in the error message, defaulting to \"identifier\"."
  (let ((text (cond ((stringp value) value)
                    ((and value (symbolp value)) (symbol-name value)))))
    (unless (and text (not (string-empty-p (string-trim text)))
                 (not (string-match-p "[\x00-\x1f\x7f-\x9f]" text)))
      (user-error "Invalid Vox %s" (or what "identifier")))
    (copy-sequence text)))

(defun vox--backend-host-p (host)
  "Whether HOST is a bare DNS hostname with an optional numeric port."
  (and (stringp host)
       (string-match
        "\\`\\([A-Za-z0-9.-]+\\)\\(?::\\([0-9]+\\)\\)?\\'" host)
       (let ((name (match-string 1 host)) (port (match-string 2 host)))
         (and (<= (length name) 253)
              (cl-every
               (lambda (label)
                 (and (<= 1 (length label) 63)
                      (string-match-p
                       "\\`[A-Za-z0-9]\\(?:[A-Za-z0-9-]*[A-Za-z0-9]\\)?\\'"
                       label)))
               (split-string name "\\." nil))
              (or (null port) (<= 1 (string-to-number port) 65535))))))

(defun vox--backend-endpoint-p (endpoint)
  "Whether ENDPOINT is an absolute path and optional query, not an authority."
  (and (stringp endpoint) (string-prefix-p "/" endpoint)
       (not (string-prefix-p "//" endpoint))
       (not (string-match-p "[\x00-\x20\x7f-\x9f#{}\\\\]" endpoint))
       (not (string-match-p "%\\(?:[^[:xdigit:]]\\|[[:xdigit:]][^[:xdigit:]]\\|[[:xdigit:]]?\\'\\)"
                            endpoint))))

(defun vox-backend-snapshot (backend)
  "Validate and copy BACKEND so later external mutation cannot affect it.
Registered protocol symbols remain symbols.  A literal key string is copied,
key functions retain identity, and neither is invoked here.  Configuration
records contain no resolved key."
  (if (symbolp backend)
      backend
    (unless (vox-backend-p backend)
      (user-error "Invalid Vox backend configuration"))
    (unless (and (symbolp (vox-backend-type backend))
                 (vox-backend-type backend))
      (user-error "Invalid Vox backend type"))
    (unless (stringp (vox-backend-name backend))
      (user-error "Invalid Vox backend name"))
    (unless (vox--backend-host-p (vox-backend-host backend))
      (user-error "Invalid Vox backend host"))
    (unless (vox--backend-endpoint-p (vox-backend-endpoint backend))
      (user-error "Invalid Vox backend endpoint"))
    (let ((key (vox-backend-key backend)))
      (unless (or (null key)
                  (and (stringp key)
                       (not (string-empty-p key))
                       (not (string-match-p "[\x00-\x1f\x7f-\x9f]" key)))
                  (functionp key))
        (user-error "Invalid Vox backend key")))
    (unless (and (proper-list-p (vox-backend-models backend))
                 (vox-backend-models backend))
      (user-error "Invalid Vox backend models"))
    (let ((name (vox--backend-id (vox-backend-name backend) "backend name"))
          (models (mapcar (lambda (model)
                            (vox--backend-id model "model identifier"))
                          (vox-backend-models backend)))
          (key (vox-backend-key backend))
          (resource (vox-backend-resource-id backend)))
      (unless (= (length models) (length (delete-dups (copy-sequence models))))
        (user-error "Duplicate Vox model identifier"))
      (when (or resource (eq (vox-backend-type backend) 'doubao))
        (unless (and (stringp resource)
                     (string-match-p "\\`[A-Za-z0-9._-]+\\'" resource))
          (user-error "Invalid Vox backend resource identifier")))
      (vox--make-backend
       :name name
       :type (vox-backend-type backend)
       :host (copy-sequence (vox-backend-host backend))
       :endpoint (copy-sequence (vox-backend-endpoint backend))
       :models models
       :key (if (stringp key) (copy-sequence key) key)
       :resource-id (and resource (copy-sequence resource))))))

;;;###autoload
(cl-defun vox-make-qwen
    (name &key (host "dashscope.aliyuncs.com")
          (endpoint "/api-ws/v1/realtime")
          (models '(qwen3-asr-flash-realtime)) key)
  "Make a Qwen configuration named NAME without resolving credentials.
NAME is a display string.  HOST and ENDPOINT select the WSS destination.
MODELS lists allowed model IDs.  KEY is nil for auth-source lookup, a literal
key string, or a zero-argument function.

(fn NAME &key HOST ENDPOINT MODELS KEY)"
  (vox-backend-snapshot
   (vox--make-backend :name name :type 'qwen :host host :endpoint endpoint
                      :models models :key key)))

;;;###autoload
(cl-defun vox-make-doubao
    (name &key (host "openspeech.bytedance.com")
          (endpoint "/api/v3/sauc/bigmodel_async") (models '(bigmodel))
          key (resource-id "volc.seedasr.sauc.duration"))
  "Make a Doubao configuration named NAME without resolving credentials.
NAME is a display string.  HOST and ENDPOINT select the WSS destination;
MODELS lists allowed model IDs.  KEY is nil for auth-source lookup, a literal
key string, or a zero-argument function.  RESOURCE-ID selects the billing
resource.

(fn NAME &key HOST ENDPOINT MODELS KEY RESOURCE-ID)"
  (vox-backend-snapshot
   (vox--make-backend :name name :type 'doubao :host host :endpoint endpoint
                      :models models :key key :resource-id resource-id)))

(defvar vox-backend (vox-make-qwen "Qwen")
  "Backend configuration object or registered backend symbol to use.
Set this in Lisp initialization code with `vox-make-qwen' or `vox-make-doubao',
or to `cli' for the self-recording CLI.  This is a plain variable, not a
Customize option; use `vox-model' or `vox-select-model' for the model.")

(defcustom vox-model nil
  "Selected model ID, as a symbol or string, or nil for the backend's first model."
  :type '(choice (const :tag "First backend model" nil) string symbol)
  :group 'vox)

(defun vox--backend-model (configuration model)
  "Resolve MODEL against validated CONFIGURATION's allowed models."
  (let ((selected (vox--backend-id
                   (or model (car (vox-backend-models configuration)))
                   "model identifier")))
    (unless (member selected (vox-backend-models configuration))
      (user-error
       "Vox model %s is not configured; add it to the backend's :models"
       selected))
    selected))

(defun vox--backend-copy-methods (value)
  "Copy method metadata VALUE while preserving function identity."
  (cond ((functionp value) value)
        ((stringp value) (copy-sequence value))
        ((consp value) (cons (vox--backend-copy-methods (car value))
                             (vox--backend-copy-methods (cdr value))))
        ((vectorp value) (apply #'vector (mapcar #'vox--backend-copy-methods value)))
        (t value)))

(defun vox-register-backend (name methods)
  "Register NAME with METHODS, a plist of functions and capabilities.
Required methods are :connect, :finish, :cancel and :close.  An external
recorder backend must also implement :send-pcm.  Connect receives SESSION,
ON-READY (no arguments), ON-EVENT (one normalized plist), and ON-ERROR
(one sanitized string).  Other methods receive SESSION, plus PCM for send.
`vox-backend-methods' adds :configuration and :model only for configuration
objects and the built-in `qwen'/`doubao' symbols; external names keep this
plist unchanged."
  (dolist (key '(:connect :finish :cancel :close))
    (unless (functionp (plist-get methods key))
      (error "Missing backend method %s" key)))
  (when (and (plist-get methods :needs-external-audio)
             (not (functionp (plist-get methods :send-pcm))))
    (error "External-audio backend requires :send-pcm"))
  (puthash name methods vox--backends))

(cl-defun vox-backend-methods (backend &optional (model vox-model))
  "Return fresh registered methods for BACKEND, capturing selected MODEL.
MODEL defaults to `vox-model'.  Configuration objects and built-in protocol
symbols carry a validated detached :configuration and a copied :model string.
Other registered symbols ignore MODEL.  This operation never resolves
credentials."
  (let* ((configuration
          (cond ((vox-backend-p backend) (vox-backend-snapshot backend))
                ((eq backend 'qwen) (vox-make-qwen "Qwen"))
                ((eq backend 'doubao) (vox-make-doubao "Doubao"))))
         (type (if configuration (vox-backend-type configuration) backend))
         (registered (and (symbolp type) (gethash type vox--backends))))
    (unless registered (user-error "Unknown Vox backend"))
    (let ((methods (vox--backend-copy-methods registered)))
      (when configuration
        (setq methods (plist-put methods :configuration configuration)
              methods (plist-put methods :model
                                 (vox--backend-model configuration model))))
      methods)))

(defun vox-backend-url (configuration model)
  "Build a WSS URL from CONFIGURATION and selected MODEL, without approval.
For Qwen, replace every decoded model query parameter with MODEL.  Other
query parameters retain their original encoding and order.  Doubao keeps
its configured endpoint; its adapter sends the model in JSON instead."
  (setq configuration (vox-backend-snapshot configuration))
  (unless (vox-backend-p configuration)
    (user-error "Invalid Vox backend configuration"))
  (let ((selected (vox--backend-model configuration model))
        (endpoint (vox-backend-endpoint configuration)))
    (when (eq (vox-backend-type configuration) 'qwen)
      (let* ((query-start (string-match "?" endpoint))
             (path (if query-start (substring endpoint 0 query-start) endpoint))
             (query (and query-start (substring endpoint (1+ query-start))))
             (parts (and query (split-string query "&" t))))
        (setq parts
              (cl-remove-if
               (lambda (part)
                 (equal (url-unhex-string
                         (car (split-string part "="))) "model"))
               parts))
        (setq endpoint
              (concat path "?" (mapconcat #'identity
                                         (append parts (list (concat "model="
                                                                     (url-hexify-string selected))))
                                         "&")))))
    (concat "wss://" (vox-backend-host configuration) endpoint)))

(defvar vox--auth-source-host nil
  "Host of the backend whose `:key' function is being resolved.")

(defun vox-backend-secret (configuration host)
  "Resolve CONFIGURATION's credential lazily for HOST, without caching it.
A string key is returned as the literal credential.  A function key is called
only here, after endpoint approval, with `vox--auth-source-host' bound to HOST.
A nil key reads auth-source for HOST.  Key-function errors are sanitized; quit
propagates."
  (setq configuration (vox-backend-snapshot configuration))
  (unless (and (vox-backend-p configuration) (vox--backend-host-p host))
    (user-error "Invalid Vox backend configuration"))
  (let* ((key (vox-backend-key configuration))
         (value
          (cond ((stringp key) key)
                (key (let ((vox--auth-source-host host))
                       (condition-case nil (funcall key)
                         (error (user-error "Vox credential unavailable")))))
                ;; Keep the host in the hint, but not foreign error text.
                (t (condition-case nil (vox-api-key-from-auth-source host)
                     (error
                      (user-error
                       "No Vox auth-source API key for %s; configure auth-source or :key"
                       host)))))))
    (unless (and (stringp value) (not (string-empty-p value))
                 (not (string-match-p "[\x00-\x1f\x7f-\x9f]" value)))
      (user-error "Vox credential is empty or contains control characters"))
    value))

(defun vox-json-encode (object)
  "Encode OBJECT as JSON, with explicit :null and :false values."
  (let ((json-null :null) (json-false :false) (json-encoding-pretty-print nil))
    (json-encode object)))

(defun vox-json-read (string)
  "Read JSON STRING into plists, lists, and explicit :null/:false values."
  (json-parse-string string :object-type 'plist :array-type 'list
                     :null-object :null :false-object :false))

(defun vox--auth-source-value (host user)
  "Return the auth-source secret for HOST and USER, or nil.
USER defaults to \"apikey\".  A function secret is invoked and its errors are
ignored.  Auth-source diagnostics stay disabled."
  (let* ((auth-source-debug nil)
         (entry (car (auth-source-search :host host :user (or user "apikey")
                                         :require '(:secret) :max 1)))
         (secret (plist-get entry :secret)))
    (condition-case nil
        (if (functionp secret) (funcall secret) secret)
      (error nil))))

(defun vox-api-key-from-auth-source (&optional host user)
  "Return the auth-source API key for HOST, defaulting to the connecting host.
USER defaults to \"apikey\".  A nil `:key' uses this same lookup for the
connecting host; pass this function explicitly only to select a different host
or user.  Signal `user-error' when no usable key is stored.  Vox itself never
reads environment variables."
  (let ((host (or host vox--auth-source-host)))
    (unless (and (stringp host) (not (string-empty-p host)))
      (user-error "No Vox host for auth-source lookup"))
    (let ((value (vox--auth-source-value host user)))
      (unless (and (stringp value) (not (string-empty-p value)))
        (user-error "No Vox auth-source API key for %s" host))
      value)))

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
