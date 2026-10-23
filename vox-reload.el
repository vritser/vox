;;; vox-reload.el --- Reload idle Vox sources without resetting settings -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Source reload is not an unload or a migration of live session structures.
;;; Code:
;; Also initialize these when bootstrapping over an already-loaded older core.
(defvar vox--reloading nil)
(defvar vox--starting nil)

(require 'vox-ui)
(require 'vox-device)

(defconst vox-reload--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing this loaded copy of Vox.")

(defvar vox-reload--files nil
  "Exact source files being reloaded, dynamically bound by `vox-reload'.")

(defun vox-reload--sources (directory)
  "Read Vox sources in DIRECTORY and return dependency order.
Exclude the package descriptor.  Reject unreadable forms, missing internal
requires and dependency cycles before changing running definitions."
  (unless (file-readable-p (expand-file-name "vox.el" directory))
    (user-error "No vox.el source in %s" directory))
  (let (entries ordered visited visiting)
    (dolist (file (directory-files directory t "\\`vox\\(?:-[^.]+\\)?\\.el\\'"))
      (unless (equal (file-name-nondirectory file) "vox-pkg.el")
        (let (dependencies)
          (condition-case err
              (with-temp-buffer
                (insert-file-contents file)
                (delay-mode-hooks (emacs-lisp-mode))
                (goto-char (point-min))
                (while (progn (forward-comment (point-max)) (not (eobp)))
                  (pcase (read (current-buffer))
                    (`(require (quote ,feature) . ,_)
                     (push feature dependencies)))))
            (error (error "Cannot read %s: %s" file (error-message-string err))))
          (push (list (intern (file-name-base file)) file (nreverse dependencies))
                entries))))
    (setq entries (nreverse entries))
    (cl-labels
        ((visit (entry)
           (unless (memq (car entry) visited)
             (when (memq (car entry) visiting)
               (error "Circular Vox require: %s" (car entry)))
             (push (car entry) visiting)
             (dolist (dependency (nth 2 entry))
               (let ((other (assq dependency entries)))
                 (cond
                  (other (visit other))
                  ((and (symbolp dependency)
                        (or (eq dependency 'vox)
                            (string-prefix-p "vox-" (symbol-name dependency))))
                   (error "Missing Vox source: %s.el" dependency)))))
             (pop visiting)
             (push (car entry) visited)
             (push (cadr entry) ordered))))
      (dolist (entry entries) (visit entry)))
    (nreverse ordered)))

(defun vox-reload--read (stream)
  "Read a form from STREAM, refreshing Vox keymap defaults in place.
Retain ordinary `defvar' state.  Existing text properties keep referring to
the same keymap object; ad-hoc edits to package maps are replaced."
  (let ((form (read stream)))
    (if (not (member load-file-name vox-reload--files))
        form
      (pcase form
        (`(defvar ,name ,initial . ,_)
         (if (and (boundp name) (keymapp (symbol-value name)))
             `(progn
                ,form
                (let ((new-map ,initial))
                  (unless (keymapp new-map)
                    (error "Reloaded keymap is no longer a keymap: %s" ',name))
                  (setcdr ,name (cdr new-map))))
           form))
        (_ form)))))

;;;###autoload
(defun vox-reload (&optional directory)
  "Reload all Vox source modules while idle, retaining settings and history.
DIRECTORY defaults to this loaded package's source directory.  Explicit .el
paths bypass stale bytecode.  Keep backend/model selection, input settings,
event logs, the last transcript and the session generation counter.  Refresh
package keymaps in place and invalidate mode-line image caches.

Finish or cancel an active session before reloading; this command never stops
recording, inserts text, opens a connection or restarts a session.  Device
selection, active minibuffers and nested reloads are also refused.

All sources are read before loading, but evaluation is not transactional: a
load error can leave some definitions updated.  Fix and reload again, or
restart Emacs.  Removed definitions stay resident; changed struct layouts
and changes to retained state initialization require an Emacs restart."
  (interactive)
  (when vox--reloading (user-error "A Vox reload is already in progress"))
  (when vox--starting (user-error "Wait for Vox startup to finish before reloading"))
  (when (vox-current-session)
    (user-error "Finish or cancel the active Vox session before reloading"))
  (when vox-tts--active
    (user-error "Stop Vox speech output before reloading"))
  (when (or (active-minibuffer-window) vox-device--busy vox-device--selecting)
    (user-error "Finish device selection or the active minibuffer before reloading"))
  (let ((directory (file-name-as-directory
                    (expand-file-name (or directory vox-reload--directory))))
        (guard (lambda (&rest _)
                 (user-error "Wait for Vox reload to finish before starting or selecting input")))
        (vox--reloading t))
    (when (file-remote-p directory)
      (user-error "Vox reload needs a local source directory"))
    ;; Old loaded entrypoints may predate the flag checks.  Temporary advice
    ;; protects bootstrap too, and Emacs preserves it across source redefinition.
    (unwind-protect
        (progn
          (dolist (entry '(vox-start vox-core-start vox-device--check-idle))
            (advice-add entry :before guard))
          (let* ((vox-reload--files (vox-reload--sources directory))
                 (load-path (cons directory load-path))
                 (load-read-function #'vox-reload--read))
            (dolist (file vox-reload--files)
              (load file nil t t))
            (setq vox-ui--mode-line-images nil
                  vox-ui--mode-line-images-color nil
                  vox-ui--mode-line-idle-image nil
                  vox-ui--mode-line-idle-color nil)
            (dolist (buffer (buffer-list))
              (with-current-buffer buffer
                (when (local-variable-p 'vox-ui--mode-line-face-color)
                  (setq vox-ui--mode-line-face-color nil))))
            (force-mode-line-update t)
            (message "Reloaded %d Vox source modules" (length vox-reload--files))
            (length vox-reload--files)))
      (dolist (entry '(vox-start vox-core-start vox-device--check-idle))
        (advice-remove entry guard)))))

(provide 'vox-reload)
;;; vox-reload.el ends here
