;;; vox.el --- Native speech input and output for Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (websocket "1.15"))
;; Keywords: multimedia, convenience

;;; Commentary:
;; Independent Qwen/Doubao WSS speech input, plus optional streaming CLI.
;; Audio leaves this machine only when explicitly starting a cloud backend.
;; Preview is ephemeral; final text is inserted once and is never submitted.
;; Optional TTS sends explicit text to an API or trusted CLI and plays audio.

;;; Code:
(require 'cl-lib)
(require 'vox-core)
(require 'vox-ui)
(require 'vox-audio)
(require 'vox-device)
(require 'vox-transport)
(require 'vox-backend-qwen)
(require 'vox-backend-qwen-audio)
(require 'vox-backend-doubao)
(require 'vox-backend-cli)
(require 'vox-doctor)
(require 'vox-reload)

;;;###autoload
(defun vox-speak (text &optional backend model)
  "Speak TEXT using the TTS selection or explicit BACKEND and MODEL.
Interactively read the active region, or prompt for text without history.
Starting a recording stops speech output.  See `vox-tts-select'."
  ;; Read in the command body so call-interactively cannot record private text
  ;; as an argument in `command-history'.  Keyboard macros use this path too.
  (interactive (list nil))
  (when (called-interactively-p 'any)
    (setq text (if (use-region-p)
                   (buffer-substring-no-properties (region-beginning) (region-end))
                 (let ((history-add-new-input nil)) (read-string "Speak: ")))))
  (vox-tts-start text backend model))

;;;###autoload
(defun vox-speak-open (&optional backend model)
  "Open a speech session accepting text incrementally from a producer.
Use `vox-speak-send' as text arrives and `vox-speak-finish' at producer EOF.
BACKEND and MODEL default to TTS selection.  Return the captured session."
  (vox-tts-open backend model))

(defun vox-speak-send (session text)
  "Append TEXT to SESSION; stale handles cannot write into a successor."
  (vox-tts-send session text))

(defun vox-speak-finish (session)
  "Finish SESSION's text input and let remaining audio play."
  (vox-tts-finish session))

;;;###autoload
(defun vox-speak-stop (&optional session)
  "Stop synthesis and playback for SESSION, or the current output owner.
A stale SESSION does not cancel its successor."
  (interactive)
  (if session
      (when (vox-tts--live-p session) (vox-tts--end session 'cancelled))
    (vox-tts-stop)))

;;;###autoload
(defun vox-start (&optional backend sink model)
  "Start the current `vox-asr-selection', using SINK or a buffer sink.
An explicit BACKEND provider, connection or registered symbol bypasses
`vox-asr-selection' and `vox-backends'.  MODEL selects its model;
nil means the first configured model.
MODEL requires an explicit BACKEND.  Configuration and model are copied
before callbacks or device prompting.
Shared providers resolve their ASR capability.
SINK is a plist of :on-preview, :on-finish, :on-state, :on-error functions.
It receives the captured session, never the callback's current buffer.
For a headless session with no sink use `vox-core-start' directly.
Vox-owned recordings stop after silence by default; see `vox-stop-mode'.
An interactive start discovers inputs when `vox-audio-input' is nil, using
one candidate directly or prompting among multiple devices.  Programmatic
calls require explicit input configuration and do not prompt."
  (interactive)
  (when vox--reloading (user-error "Wait for Vox reload to finish before starting"))
  (when (vox-current-session) (user-error "A Vox session is already active"))
  (when buffer-read-only
    (unless sink (user-error "Vox target buffer is read-only")))
  (when (and model (null backend))
    (user-error "An explicit Vox model requires an explicit backend"))
  (let* ((vox--starting t)
         (resolved (if backend
                       (cons (vox-backend-snapshot backend)
                             (if (stringp model) (copy-sequence model) model))
                     (vox--resolve-selection)))
         (selected-backend (car resolved))
         (selected-model (cdr resolved))
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

(defvar vox-asr-selection-history nil
  "Minibuffer history of backend/model pairs chosen with `vox-asr-select'.")

(defvar vox--selection-revision 0
  "Successful picker revision, used to reject superseded prompts.")

;;;###autoload
(defun vox-asr-select ()
  "Select a backend/model pair for the next recording, or the CLI.
Use only configured models from `vox-backends', with case-sensitive names.
Registered protocol symbols other than `cli' are configured in Lisp, not
offered here.  Set and return `vox-asr-selection'.  Do not connect, read keys or
save settings.  An active session retains its snapshot.  Quit and invalid or
stale choices leave the current selection untouched, including changes by
nested commands."
  (interactive)
  (let* ((candidates (vox--backend-candidates))
         (snapshots (mapcar (lambda (entry) (vox-backend-snapshot (cdr entry)))
                            candidates))
         (previous vox-asr-selection)
         (previous-copy (vox--backend-copy-tree previous))
         (revision vox--selection-revision)
         (completion-ignore-case nil)
         (choices
          (append
           (cl-mapcan
            (lambda (backend)
              (let ((configuration (vox-backend-capability backend 'asr)))
                (mapcar (lambda (model)
                          (let ((name (vox-backend-name configuration)))
                            (cons (format "%S / %S" name model) (list name model))))
                        (or (vox-backend-models configuration) '(nil)))))
            snapshots)
           (list (cons "cli (no remote model)" 'cli))))
         (choice (completing-read "Vox backend / model: " choices nil t nil
                                  'vox-asr-selection-history))
         (selected (cdr (assoc choice choices))))
    (unless selected (user-error "No Vox backend/model pair selected"))
    ;; Completion may run nested commands or mutate objects and strings in place.
    (unless (and (= revision vox--selection-revision)
                 (eq previous vox-asr-selection)
                 (equal previous-copy vox-asr-selection)
                 (let ((current (vox--backend-candidates)))
                   (and (equal candidates current)
                        (cl-every #'eq (mapcar #'cdr candidates) (mapcar #'cdr current))
                        (equal snapshots
                               (mapcar (lambda (entry) (vox-backend-snapshot (cdr entry)))
                                       current)))))
      (user-error "Vox configuration changed during selection; try again"))
    ;; Validate protocol availability too, without invoking its methods.
    (let* ((vox-asr-selection selected)
           (resolved (vox--resolve-selection)))
      (vox-backend-methods (car resolved) (cdr resolved)))
    (setq vox-asr-selection (vox--backend-copy-tree selected))
    (cl-incf vox--selection-revision)
    (message "Vox selection set to %s for the next recording" choice)
    vox-asr-selection))

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
