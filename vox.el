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
(require 'cl-lib)
(require 'vox-core)
(require 'vox-ui)
(require 'vox-audio)
(require 'vox-device)
(require 'vox-transport)
(require 'vox-backend-qwen)
(require 'vox-backend-doubao)
(require 'vox-backend-cli)

;;;###autoload
(defun vox-start (&optional backend sink)
  "Start BACKEND (default `vox-backend') using SINK or a buffer sink.
The recording captures `vox-model' (or the backend's first model);
`vox-core-start' accepts an explicit model for one call.
SINK is a plist of :on-preview, :on-finish, :on-state, :on-error functions.
It receives the captured session, never the callback's current buffer.
For a headless session with no sink use `vox-core-start' directly.
Vox-owned recordings stop after silence by default; see `vox-stop-mode'.
An interactive start prompts for an input device when `vox-audio-input' is
nil.  Programmatic calls require explicit input configuration and do not prompt."
  (interactive)
  (when (vox-current-session) (user-error "A Vox session is already active"))
  (when buffer-read-only
    (unless sink (user-error "Vox target buffer is read-only")))
  (let ((selected-backend (vox-backend-snapshot (or backend vox-backend)))
        (selected-model (if (stringp vox-model) (copy-sequence vox-model) vox-model))
        (interactivep (called-interactively-p 'interactive))
        (target (current-buffer))
        (marker (copy-marker (point) t)))
    (unwind-protect
        (progn
          (when (plist-get (vox-backend-methods selected-backend selected-model) :needs-external-audio)
            (unless (and (stringp vox-audio-program) (executable-find vox-audio-program))
              (user-error "FFmpeg is unavailable; configure vox-audio-program first"))
            (when (and (null vox-audio-input) interactivep)
              (vox-select-input-device))
            (unless (and (consp vox-audio-input) (proper-list-p vox-audio-input)
                         (cl-every #'stringp vox-audio-input))
              (user-error "Use vox-select-input-device or configure vox-audio-input as an argv list")))
          ;; Discovery and completion may process callbacks or change the buffer.
          (when (vox-current-session) (user-error "A Vox session is already active"))
          (unless (buffer-live-p target) (user-error "Vox target buffer no longer exists"))
          (with-current-buffer target
            (when (and buffer-read-only (not sink))
              (user-error "Vox target buffer is read-only"))
            (vox-core-start selected-backend
                            (vox-ui--instrument-sink
                             (or sink (vox-make-buffer-sink)))
                            target marker selected-model)))
      (set-marker marker nil))))

(defvar vox-model-history nil
  "Minibuffer history of models chosen with `vox-select-model'.")

;;;###autoload
(defun vox-select-model ()
  "Select an advertised model of `vox-backend' for the next recording.
Change `vox-model' only; do not connect, read keys, or save configuration.
An already active session retains its captured backend and model."
  (interactive)
  (let* ((backend vox-backend)
         (configuration (plist-get (vox-backend-methods backend nil) :configuration)))
    (unless configuration (user-error "This Vox backend does not advertise ASR models"))
    (let* ((models (vox-backend-models configuration))
           (choice (completing-read "Vox ASR model: " models nil t nil
                                    'vox-model-history))
           (model (car (member choice models))))
      (when (and (null model) completion-ignore-case)
        (let ((matches (cl-remove-if-not
                        (lambda (candidate)
                          (eq t (compare-strings choice nil nil candidate nil nil t)))
                        models)))
          (when (> (length matches) 1)
            (user-error "Ambiguous ASR model; choose a candidate with its exact case"))
          (setq model (car matches))))
      (unless model (user-error "No ASR model selected"))
      (unless (eq backend vox-backend)
        (user-error "Vox backend changed during model selection; try again"))
      (vox-backend-methods backend model)
      (setq vox-model (copy-sequence model))
      (message "Vox model set to %s for the next recording" model)
      vox-model)))

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
    (cond ((not session)
           (if (called-interactively-p 'interactive)
               (call-interactively #'vox-start)
             (vox-start)))
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
