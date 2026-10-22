;;; vox-doctor.el --- Read-only environment and configuration check -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; A diagnostic command that changes nothing.  It resolves no credentials,
;; starts no capture or device listing, opens no connection, and writes no
;; file.  Checks are pure reads of Emacs capabilities and Vox configuration.
;; The rendered report is a memory-only buffer, like the event log.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'url-parse)
(require 'vox-core)
(require 'vox-audio)
(require 'vox-device)
;; Resolving a configuration object consults the protocol registry, so the
;; built-in adapters must be registered even when only this module is loaded.
(require 'vox-backend-qwen)
(require 'vox-backend-doubao)
(require 'vox-backend-cli)

(defgroup vox-doctor nil
  "Read-only Vox environment and configuration self-check."
  :group 'vox :prefix "vox-doctor-")

(defconst vox-doctor--statuses '(fail warn skip ok)
  "Accepted check statuses, most severe first.")

(defconst vox-doctor--status-labels
  '((fail . "FAIL") (warn . "WARN") (skip . "SKIP") (ok . "OK"))
  "Display label for each check status.")

(defconst vox-doctor--status-faces
  '((fail . error) (warn . warning) (skip . shadow) (ok . success))
  "Face used for each check status label.")

(defmacro vox-doctor--check (id &rest body)
  "Run BODY as check ID, converting an error into a failed result.
ID is a quoted symbol.  This keeps one broken probe from hiding others."
  (declare (indent 1) (debug t))
  `(condition-case err
       (progn ,@body)
     (error (vox-doctor--result ,id 'fail (error-message-string err)))))

(defun vox-doctor--result (id status summary &optional hint)
  "Return a check result for ID with STATUS, SUMMARY and optional HINT.
STATUS must be one of `vox-doctor--statuses'."
  (unless (memq status vox-doctor--statuses)
    (error "Invalid Vox doctor status: %s" status))
  (list :id id :status status :summary summary :hint hint))

(defun vox-doctor--context ()
  "Return selection context without side effects.
Collect the validated directory and selection errors instead of signaling,
so the report can show both the directory and the selection state."
  (let (candidates selection methods configuration
        candidates-error selection-error)
    (condition-case err
        (setq candidates (vox--backend-candidates))
      (error (setq candidates-error (error-message-string err))))
    (condition-case err
        (let ((resolved (vox--resolve-selection)))
          (setq selection resolved
                methods (vox-backend-methods (car resolved) (cdr resolved))
                configuration (plist-get methods :configuration)))
      (error (setq selection-error (error-message-string err))))
    (list :candidates candidates :candidates-error candidates-error
          :selection selection :selection-error selection-error
          :methods methods :configuration configuration)))

(defun vox-doctor--emacs ()
  "Check the running Emacs version."
  (vox-doctor--check 'emacs
    (if (version< emacs-version "28.1")
        (vox-doctor--result 'emacs 'fail
                            (format "Emacs %s is older than 28.1" emacs-version)
                            "Install Emacs 28.1 or newer.")
      (vox-doctor--result 'emacs 'ok
                          (format "Emacs %s (requires 28.1 or newer)"
                                  emacs-version)))))

(defun vox-doctor--websocket ()
  "Check whether websocket.el can be loaded."
  (vox-doctor--check 'websocket
    (if (require 'websocket nil t)
        (vox-doctor--result
         'websocket 'ok
         (if (boundp 'websocket-version)
             (format "websocket.el %s loaded" (symbol-value 'websocket-version))
           "websocket.el loaded"))
      (vox-doctor--result 'websocket 'fail
                          "websocket.el is not available on `load-path'"
                          "Install the websocket package or check `load-path'."))))

(defun vox-doctor--tls ()
  "Check native GnuTLS support for WSS connections."
  (vox-doctor--check 'tls
    (if (and (fboundp 'gnutls-available-p) (gnutls-available-p))
        (vox-doctor--result 'tls 'ok "native GnuTLS is available")
      (vox-doctor--result 'tls 'fail
                          "native GnuTLS is unavailable"
                          "Use an Emacs build with GnuTLS; cloud WSS needs it."))))

(defun vox-doctor--zlib (context)
  "Check native zlib support, required by Doubao responses.
CONTEXT is the selection context from `vox-doctor--context'."
  (vox-doctor--check 'zlib
    (let* ((configuration (plist-get context :configuration))
           (doubao (and configuration
                        (eq (vox-backend-type configuration) 'doubao))))
      (cond
       ((and (fboundp 'zlib-available-p) (zlib-available-p))
        (vox-doctor--result 'zlib 'ok "native zlib is available"))
       (doubao
        (vox-doctor--result 'zlib 'fail
                            "native zlib is unavailable for the Doubao backend"
                            "Use an Emacs build with zlib or select another backend."))
       (t
        (vox-doctor--result 'zlib 'warn
                            "native zlib is unavailable; Doubao would fail"
                            "Only the Doubao backend needs native zlib."))))))

(defun vox-doctor--ffmpeg (context)
  "Check the FFmpeg executable needed by Vox-owned capture.
CONTEXT is the selection context from `vox-doctor--context'."
  (vox-doctor--check 'ffmpeg
    (let* ((methods (plist-get context :methods))
           (selection (plist-get context :selection))
           (external (plist-get methods :needs-external-audio))
           (cli (eq (car-safe selection) 'cli)))
      (cond
       ((not (and (stringp vox-audio-program)
                  (not (string-empty-p vox-audio-program))))
        (vox-doctor--result 'ffmpeg 'fail
                            "`vox-audio-program' is not a nonempty string"
                            "Set it to the FFmpeg executable name."))
       ((executable-find vox-audio-program)
        (vox-doctor--result 'ffmpeg 'ok
                            (format "`%s' found on `exec-path'"
                                    (file-name-nondirectory vox-audio-program))))
       (cli
        (vox-doctor--result 'ffmpeg 'skip
                            "not required by the selected self-recording backend"))
       (external
        (vox-doctor--result 'ffmpeg 'fail
                            (format "`%s' was not found"
                                    (file-name-nondirectory vox-audio-program))
                            "Install FFmpeg or set `vox-audio-program'."))
       (t
        (vox-doctor--result 'ffmpeg 'warn
                            (format "`%s' was not found"
                                    (file-name-nondirectory vox-audio-program))
                            "Cloud recording is unavailable until FFmpeg is installed."))))))

(defun vox-doctor--backends (context)
  "Check the `vox-backends' directory in CONTEXT."
  (vox-doctor--check 'backends
    (if-let* ((reason (plist-get context :candidates-error)))
        (vox-doctor--result 'backends 'fail reason
                            "Fix the failing entry position in `vox-backends'.")
      (let ((candidates (plist-get context :candidates)))
        (vox-doctor--result 'backends 'ok
                            (format "%d unique backend(s) configured"
                                    (length candidates)))))))

(defun vox-doctor--selection (context)
  "Check the resolved `vox-selection' in CONTEXT."
  (vox-doctor--check 'selection
    (if-let* ((reason (plist-get context :selection-error)))
        (vox-doctor--result 'selection 'fail reason
                            "Update `vox-selection' or run M-x vox-select.")
      (let ((backend (car (plist-get context :selection)))
            (model (cdr (plist-get context :selection)))
            (configuration (plist-get context :configuration)))
        (cond
         ((vox-backend-p backend)
          (vox-doctor--result
           'selection 'ok
           (format "%s / %s" (vox-backend-name configuration) model)))
         ((eq backend 'cli)
          (vox-doctor--result 'selection 'ok "cli (no remote model)"))
         (t
          (vox-doctor--result
           'selection 'ok
           (format "%s (registered protocol, first model)" backend))))))))

(defun vox-doctor--endpoint (context)
  "Check the selected endpoint host in CONTEXT.
This never approves a custom host or opens a connection."
  (vox-doctor--check 'endpoint
    (let ((configuration (plist-get context :configuration)))
      (if (null configuration)
          (vox-doctor--result 'endpoint 'skip
                              "not applicable to the selected backend")
        (let* ((model (cdr (plist-get context :selection)))
               (url (vox-backend-url configuration model))
               (host (url-host (url-generic-parse-url url)))
               (type (vox-backend-type configuration))
               (official (pcase type
                           ('qwen '("dashscope.aliyuncs.com"
                                    "dashscope-intl.aliyuncs.com"))
                           ('doubao '("openspeech.bytedance.com")))))
          (if (and official (member host official))
              (vox-doctor--result 'endpoint 'ok
                                  (format "official host %s over WSS" host))
            (vox-doctor--result
             'endpoint 'warn
             (format "custom host %s needs per-connection confirmation" host)
             "Custom endpoints are trusted only after explicit approval.")))))))

(defun vox-doctor--key (context)
  "Report the credential source kind in CONTEXT without resolving it."
  (vox-doctor--check 'key
    (let ((configuration (plist-get context :configuration)))
      (if (null configuration)
          (vox-doctor--result 'key 'skip
                              "no remote credential for the selected backend")
        (let ((key (vox-backend-key configuration)))
          (cond
           ((null key)
            (vox-doctor--result
             'key 'ok "auth-source (login apikey) for the connection host"))
           ((stringp key)
            (vox-doctor--result
             'key 'warn "literal key string in `vox-backends'; value not shown"
             "Prefer auth-source or a `:key' function."))
           ((functionp key)
            (vox-doctor--result
             'key 'ok "credential function; not called by this check"))
           (t
            (vox-doctor--result 'key 'fail "invalid `:key' source"))))))))

(defun vox-doctor--input ()
  "Check `vox-audio-input' shape without showing device values."
  (vox-doctor--check 'input
    (cond
     ((null vox-audio-input)
      (vox-doctor--result
       'input 'skip "unset; first interactive start selects one input"
       "Run M-x vox-select-input-device or set `vox-audio-input'."))
     ((not (and (listp vox-audio-input)
                (cl-every #'stringp vox-audio-input)))
      (vox-doctor--result 'input 'fail
                          "`vox-audio-input' must be a list of strings"))
     (t
      (vox-doctor--result
       'input 'ok
       (format "%d argv item(s) configured (values not shown)"
               (length vox-audio-input)))))))

(defun vox-doctor--stop (context)
  "Check the effective stop mode and its options in CONTEXT.
Mirrors `vox-core-start': a self-recording backend always runs manually."
  (vox-doctor--check 'stop
    (let* ((methods (plist-get context :methods))
           (external (plist-get methods :needs-external-audio))
           (effective (if (and (eq vox-stop-mode 'silence) external)
                          'silence 'manual)))
      (cond
       ((not (memq vox-stop-mode '(silence manual)))
        (vox-doctor--result 'stop 'fail
                            "`vox-stop-mode' must be `silence' or `manual'"
                            "Reset it to a supported symbol."))
       ((eq effective 'manual)
        (vox-doctor--result
         'stop 'ok
         (if external "manual stop"
           "manual stop (self-recording backend ignores local silence)")))
       (t
        (condition-case err
            (progn
              (vox-activity-create vox-silence-threshold vox-silence-seconds)
              (vox-doctor--result
               'stop 'ok
               (format "silence after %.2fs at threshold %.3g"
                       vox-silence-seconds vox-silence-threshold)))
          (error
           (vox-doctor--result
            'stop 'fail (error-message-string err)
            "Fix `vox-silence-seconds' or `vox-silence-threshold'."))))))))

(defun vox-doctor--limits ()
  "Check numeric connection, queue and transcript limits."
  (vox-doctor--check 'limits
    (if-let* ((reason (vox-core--limits-error)))
        (vox-doctor--result 'limits 'fail reason
                            "Reset the named option to a supported value.")
      (vox-doctor--result
       'limits 'ok "connection, drain, backlog and transcript limits are valid"))))

(defun vox-doctor--session ()
  "Report the current session and reload state."
  (vox-doctor--check 'session
    (cond
     (vox--reloading
      (vox-doctor--result 'session 'ok "source reload in progress"))
     ((vox-current-session)
      (vox-doctor--result
       'session 'ok
       (format "active session in state %s"
               (vox-session-state (vox-current-session)))
       "Finish with vox-stop or discard with vox-cancel before reloading."))
     (t
      (vox-doctor--result 'session 'ok "idle; no active Vox session")))))

(defun vox-doctor--log ()
  "Report the opt-in event log setting."
  (vox-doctor--check 'log
    (if vox-event-log-enabled
        (vox-doctor--result 'log 'ok
                            "event log enabled (memory only)")
      (vox-doctor--result
       'log 'ok "event log disabled"
       "Run M-x vox-toggle-event-log before reproducing a problem."))))

(defun vox-doctor--devices ()
  "Report device discovery settings without listing devices."
  (vox-doctor--check 'devices
    (if (and (numberp vox-device-discovery-timeout)
             (<= 0.1 vox-device-discovery-timeout 30))
        (vox-doctor--result
         'devices 'skip
         (format "not probed; discovery timeout %.1fs"
                 vox-device-discovery-timeout)
         "Run M-x vox-select-input-device to list inputs.")
      (vox-doctor--result
       'devices 'warn "`vox-device-discovery-timeout' is outside 0.1 to 30"
       "Run M-x vox-select-input-device after fixing the timeout."))))

(defun vox-doctor-check ()
  "Return Vox readiness results as a list of plists.
Each result has :id, :status (`ok', `warn', `fail' or `skip'), :summary,
and an optional :hint.  This is read-only: it resolves no credentials,
starts no process, opens no connection, and writes no file."
  (let ((context (vox-doctor--context)))
    (list (vox-doctor--emacs)
          (vox-doctor--websocket)
          (vox-doctor--tls)
          (vox-doctor--zlib context)
          (vox-doctor--ffmpeg context)
          (vox-doctor--backends context)
          (vox-doctor--selection context)
          (vox-doctor--endpoint context)
          (vox-doctor--key context)
          (vox-doctor--input)
          (vox-doctor--stop context)
          (vox-doctor--limits)
          (vox-doctor--session)
          (vox-doctor--log)
          (vox-doctor--devices))))

(defun vox-doctor--count (status results)
  "Return how many RESULTS have STATUS."
  (cl-count status results :key (lambda (result) (plist-get result :status))))

(defun vox-doctor--format-result (result)
  "Return one formatted report line for RESULT, plus its hint."
  (let* ((status (plist-get result :status))
         (label (alist-get status vox-doctor--status-labels))
         (face (alist-get status vox-doctor--status-faces))
         (id (upcase (symbol-name (plist-get result :id))))
         (hint (plist-get result :hint)))
    (concat (propertize (format "%-4s" label) 'face face)
            (format "  %-10s  %s\n" id (plist-get result :summary))
            (if hint
                (format "      %-10s  %s\n" "" hint)
              ""))))

(defun vox-doctor--render (results)
  "Return the complete report string for RESULTS.
The string contains no credential, device, PCM or transcript value."
  (let ((fail (vox-doctor--count 'fail results))
        (warn (vox-doctor--count 'warn results))
        (skip (vox-doctor--count 'skip results))
        (ok (vox-doctor--count 'ok results)))
    (concat
     (format "Vox doctor: %d ok, %d warn, %d fail, %d skip\n"
             ok warn fail skip)
     (format "Generated %s; no microphone, network, or credential access.\n\n"
             (format-time-string "%Y-%m-%d %H:%M:%S %Z"))
     (mapconcat #'vox-doctor--format-result results "")
     "\n"
     (if (> fail 0)
         "Result: FAIL. Fix the entries marked FAIL; warnings are advisory.\n"
       "Result: PASS. No failing checks; warnings and skips are advisory.\n"))))

(defun vox-doctor--display (results)
  "Render RESULTS into the read-only `*Vox doctor*' buffer and select it.
The report is the command's primary output, so it is brought to the
current window instead of being left in an arbitrary other window."
  (let ((buffer (get-buffer-create "*Vox doctor*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (vox-doctor--render results))
        (goto-char (point-min))
        (special-mode)))
    (pop-to-buffer buffer)
    buffer))

;;;###autoload
(defun vox-doctor ()
  "Report Vox dependency and configuration readiness.
The read-only report is opened and selected in `*Vox doctor*'.  No
credential is resolved, no microphone is opened, no device is listed, no
connection is attempted, and no file is written.  Device discovery stays
an explicit `vox-select-input-device' action because it can trigger native
permission prompts."
  (interactive)
  (let* ((results (vox-doctor-check))
         (failures (vox-doctor--count 'fail results))
         (warnings (vox-doctor--count 'warn results)))
    (vox-doctor--display results)
    (message "Vox doctor: %d failed, %d warning(s); see *Vox doctor*"
             failures warnings)
    results))

(provide 'vox-doctor)
;;; vox-doctor.el ends here
