;;; vox.el --- Native streaming speech input for Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (websocket "1.15"))
;; Keywords: multimedia, convenience

;;; Commentary:
;; Independent Qwen/Doubao WSS speech input, plus optional streaming CLI.
;; Audio leaves this machine only when explicitly starting a cloud backend.
;; Preview is ephemeral; final text is inserted once and is never submitted.

;;; Code:
(require 'vox-core)
(require 'vox-ui)
(require 'vox-audio)
(require 'vox-transport)
(require 'vox-backend-qwen)
(require 'vox-backend-doubao)
(require 'vox-backend-cli)

(defcustom vox-backend 'qwen "Backend used by `vox-start'."
  :type 'symbol :group 'vox)

;;;###autoload
(defun vox-start (&optional backend sink)
  "Start BACKEND (default `vox-backend') using SINK or a buffer sink.
SINK is a plist of :on-preview, :on-finish, :on-state, :on-error functions.
It receives the captured session, never the callback's current buffer.
For a headless session with no sink use `vox-core-start' directly.
Vox-owned recordings stop after silence by default; see `vox-stop-mode'."
  (interactive)
  (when buffer-read-only
    (unless sink (user-error "Vox target buffer is read-only")))
  (when (plist-get (vox-backend-methods (or backend vox-backend)) :needs-external-audio)
    (unless (and (consp vox-audio-input) (cl-every #'stringp vox-audio-input))
      (user-error "Configure vox-audio-input with an explicit device argv list first"))
    (unless (executable-find vox-audio-program)
      (user-error "FFmpeg is unavailable; configure vox-audio-program first")))
  (vox-core-start (or backend vox-backend) (or sink (vox-make-buffer-sink))))

;;;###autoload
(defun vox-stop ()
  "Gracefully stop recording and wait for authoritative completion.
While connecting, stop cancels instead.  Repeated stops are harmless."
  (interactive)
  (vox-core-stop))

;;;###autoload
(defun vox-cancel ()
  "Cancel the active session without inserting any transcription."
  (interactive)
  (vox-core-cancel))

;;;###autoload
(defun vox-toggle ()
  "Start voice input or stop early; report connecting/finalizing status."
  (interactive)
  (let ((session (vox-current-session)))
    (cond ((not session) (vox-start))
          ((eq (vox-session-state session) 'recording) (vox-stop))
          (t (message "Vox: %s; use vox-cancel to discard" (vox-session-state session))))))

;;;###autoload
(defun vox-show-transcript ()
  "Show current/last hypothesis in a non-file recovery buffer.
Unfinished text is explicitly labeled and is never automatically inserted.
This command is an explicit user request to display otherwise private text."
  (interactive)
  (let ((session (or vox--active-session vox--last-session)))
    (unless session (user-error "No Vox transcript available"))
    (with-current-buffer (get-buffer-create "*Vox transcript*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Vox state: %s\n%s\n\n"
                        (vox-session-state session)
                        (if (vox-session-final-text session)
                            "Authoritative final text (insertion may have failed)."
                          "UNCONFIRMED hypothesis; do not treat this as a final result.")))
        (insert (or (vox-session-final-text session) (vox-session-text session))))
      (special-mode)
      (display-buffer (current-buffer)))))

;;;###autoload
(defun vox-copy-confirmed-text ()
  "Explicitly copy available final/confirmed text to the kill ring.
This may also write to the system clipboard according to Emacs settings."
  (interactive)
  (let* ((session (or vox--active-session vox--last-session))
         (text (and session (or (vox-session-final-text session)
                                (vox-session-text session t)))))
    (unless (and text (not (string-empty-p text)))
      (user-error "No confirmed Vox text available; vox-show-transcript shows unconfirmed text"))
    (kill-new text)
    (message "Vox confirmed text copied")))

;;;###autoload
(defun vox-forget-transcript ()
  "Forget the retained last session and close the explicit recovery buffer."
  (interactive)
  (setq vox--last-session nil)
  (when (get-buffer "*Vox transcript*") (kill-buffer "*Vox transcript*")))

(provide 'vox)
;;; vox.el ends here
