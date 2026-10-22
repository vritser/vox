;;; vox-log.el --- Bounded, private-data-free session event log -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Logging is opt-in and memory-only.  The write boundary accepts only known
;; event names, bounded integers, and fixed enums; arbitrary data is never
;; printed.  No transcript, PCM, device, URL, credential, or error message is
;; retained here.  Opening the log shows a snapshot, not a live display.

;;; Code:

(require 'ring)

(defgroup vox-event-log nil
  "Memory-only diagnostic events for Vox."
  :group 'vox :prefix "vox-event-log-")

(defcustom vox-event-log-enabled nil
  "Non-nil records safe session metadata in memory.
Logging does not record audio, recognized text, devices, URLs, credentials,
or diagnostic strings.  Disabling logging retains existing events until
`vox-clear-event-log' is called.  No log file is written."
  :type 'boolean :group 'vox-event-log)

(defcustom vox-event-log-max-entries 1000
  "Maximum number of retained events.
Positive integers are capped at 10000; other values use the default 1000.
Capacity changes take effect on the next recorded event."
  :type 'integer :group 'vox-event-log)

(defvar vox-log--entries nil
  "Ring of already sanitized event lines, or nil before the first event.")

(defconst vox-log--events
  '(start ready state stop-request cancel error cleanup
    audio-start audio-stop audio-exit audio-cancel audio-retry
    audio-receive audio-send finish-dispatch recognition-event
    complete stale-callback provider-event transport-open transport-send
    transport-message transport-close transport-error)
  "Accepted event names.  All other values are ignored without printing.")

(defconst vox-log--numeric-fields
  '(:bytes :queued :sent :received :queue-peak :chars :segments :generation)
  "Fields accepting nonnegative integers no larger than one trillion.")

(defconst vox-log--enum-fields
  '((:state connecting recording draining finalizing completed cancelled error)
    (:reason manual silence duration connecting timeout callback recorder
             backlog send provider invalid-event sink cancelled unknown)
    (:backend qwen qwen-audio doubao cli other)
    (:kind segment snapshot completed error unknown segment-partial segment-final
           ready session-created speech-start speech-stop buffer-committed)
    (:status run exit signal failed closed)
    (:stop-mode manual silence))
  "Fields accepting only their listed symbol values.")

(defun vox-log--count-p (value)
  "Whether VALUE is a bounded, nonnegative integer."
  (and (integerp value) (<= 0 value 1000000000000)))

(defun vox-log--field-p (key value)
  "Whether KEY and VALUE are an explicitly allowed metadata pair."
  (cond
   ((memq key vox-log--numeric-fields) (vox-log--count-p value))
   ((eq key :exit-code) (and (integerp value) (<= -255 value 255)))
   ((eq key :tail-risk) (memq value '(nil t)))
   (t (memq value (cdr (assq key vox-log--enum-fields))))))

(defun vox-log--capacity ()
  "Return a safe event capacity regardless of the configured value."
  (if (and (integerp vox-event-log-max-entries)
           (> vox-event-log-max-entries 0))
      (min vox-event-log-max-entries 10000)
    1000))

(defun vox-log-event (generation event &rest fields)
  "Record EVENT for GENERATION with safe metadata from FIELDS.
GENERATION must be a positive integer no larger than one trillion.  EVENT
must be in `vox-log--events'.  FIELDS is a plist: unknown keys, strings,
objects, and values outside the fixed schema are ignored without printing.
Inspect at most 32 field pairs and keep each accepted key once, so malformed
or excessive metadata cannot produce an unbounded line.

When disabled, do nothing and create no resources.  Logging errors and
quits are contained so diagnostics cannot interrupt recording."
  (when vox-event-log-enabled
    (condition-case nil
        (when (and (vox-log--count-p generation) (> generation 0)
                   (memq event vox-log--events))
          (let ((remaining 32) seen parts)
            (while (and (> remaining 0) (consp fields) (consp (cdr fields)))
              (let ((key (car fields)) (value (cadr fields)))
                (when (and (not (memq key seen)) (vox-log--field-p key value))
                  (push key seen)
                  ;; Only allowlisted symbols and bounded integers reach format.
                  (push (format "%s=%s" (substring (symbol-name key) 1) value)
                        parts)))
              (setq fields (cddr fields) remaining (1- remaining)))
            (let* ((capacity (vox-log--capacity))
                   (line (concat
                          (format "%s g=%d %s"
                                  (format-time-string "%Y-%m-%dT%H:%M:%S.%3N%z")
                                  generation event)
                          (when parts (concat " " (mapconcat #'identity
                                                             (nreverse parts) " "))))))
              (unless vox-log--entries
                (setq vox-log--entries (make-ring capacity)))
              (unless (= (ring-size vox-log--entries) capacity)
                (ring-resize vox-log--entries capacity))
              (ring-insert vox-log--entries line))))
      ((error quit) nil))))

;;;###autoload
(defun vox-toggle-event-log (&optional arg)
  "Toggle recording of memory-only event metadata.
With positive prefix ARG enable logging; with zero or negative ARG disable
it.  Existing events remain available after disabling."
  (interactive "P")
  (setq vox-event-log-enabled
        (if arg (> (prefix-numeric-value arg) 0)
          (not vox-event-log-enabled)))
  (message "Vox event log %s (metadata only)"
           (if vox-event-log-enabled "enabled" "disabled"))
  vox-event-log-enabled)

(defun vox-log--file-backed-p (buffer)
  "Return non-nil if BUFFER or its base buffer visits a file."
  (or (buffer-local-value 'buffer-file-name buffer)
      (when-let* ((base (buffer-base-buffer buffer)))
        (buffer-local-value 'buffer-file-name base))))

;;;###autoload
(defun vox-show-event-log ()
  "Show a chronological snapshot of retained events in *Vox events*.
This explicitly creates a non-file, read-only buffer even when logging is
disabled.  Call again to refresh the snapshot."
  (interactive)
  (let ((lines (and vox-log--entries (nreverse (ring-elements vox-log--entries))))
        (buffer (get-buffer-create "*Vox events*")))
    (when (vox-log--file-backed-p buffer)
      (user-error "Rename the file-visiting *Vox events* buffer first"))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Vox event log: %s; %d events (metadata only)\n\n"
                        (if vox-event-log-enabled "enabled" "disabled")
                        (length lines)))
        (dolist (line lines) (insert line "\n"))
        (unless lines (insert "No retained events.\n"))
        (goto-char (point-min)))
      (special-mode)
      (set-buffer-modified-p nil))
    (display-buffer buffer)
    buffer))

;;;###autoload
(defun vox-clear-event-log ()
  "Forget retained event metadata and clear its display, if already open.
Do not change whether logging is enabled or create a log buffer."
  (interactive)
  (let ((buffer (get-buffer "*Vox events*")))
    (when (and buffer (vox-log--file-backed-p buffer))
      (user-error "Rename the file-visiting *Vox events* buffer first"))
    (setq vox-log--entries nil)
    (when buffer
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert "No retained events.\n"))
        (set-buffer-modified-p nil)))))

(provide 'vox-log)
;;; vox-log.el ends here
