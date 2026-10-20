;;; vox-ui.el --- Preview overlays and captured-buffer sinks -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Preview never edits text.  Only authoritative completion commits one change.
;;; Code:
(require 'vox-core)

(defcustom vox-preview t "Show a one-line overlay while recording."
  :type 'boolean :group 'vox)
(defcustom vox-preview-width 72 "Maximum preview display columns."
  :type 'integer :group 'vox)

(defun vox-ui--preview-columns (session)
  "Return safe one-line preview columns at SESSION's captured marker."
  (let* ((buffer (vox-session-target-buffer session))
         (column (with-current-buffer buffer
                   (save-excursion
                     (save-restriction
                       (widen)
                       (goto-char (vox-session-target-marker session))
                       (current-column)))))
         (width (max 0 vox-preview-width)))
    (dolist (window (get-buffer-window-list buffer nil t))
      (setq width (min width (max 0 (- (window-body-width window)
                                      (- column (window-hscroll window)) 4)))))
    width))

(defun vox-make-buffer-sink ()
  "Return a sink using the session's captured buffer and insertion marker.
Typing at that marker moves it after typed text.  Neither preview nor commit
switches windows or sends input to an agent."
  (let (overlay)
    (list
     :on-preview
     (lambda (session text _status)
       (when (and vox-preview (buffer-live-p (vox-session-target-buffer session))
                  (marker-buffer (vox-session-target-marker session)))
         (unless (overlayp overlay)
           (setq overlay (make-overlay (vox-session-target-marker session)
                                       (vox-session-target-marker session)
                                       (vox-session-target-buffer session) t t)))
         (move-overlay overlay (vox-session-target-marker session)
                       (vox-session-target-marker session))
         (let ((width (vox-ui--preview-columns session)))
           (overlay-put overlay 'after-string
                        (when (> width 0)
                          (propertize
                           (concat " [" (truncate-string-to-width
                                          (replace-regexp-in-string "[\n\r\t]+" " " text)
                                          width nil nil (when (>= width 3) "...")) "]")
                           'face 'shadow))))))
     :on-state
     (lambda (session state)
       (when (memq state '(completed cancelled error))
         (when (overlayp overlay) (delete-overlay overlay))
         (setq overlay nil))
       (unless noninteractive
         (if (and (memq state '(finalizing completed))
                  (plist-get (vox-session-statistics session) :audio-tail-risk))
             (message "Vox: %s; recorder needed a second interrupt, tail audio may be truncated" state)
           (message "Vox: %s" state))))
     :on-finish
     (lambda (session text)
       (let ((buffer (vox-session-target-buffer session))
             (marker (vox-session-target-marker session)))
         (unless (and (buffer-live-p buffer) (eq (marker-buffer marker) buffer))
           (error "Vox target no longer exists"))
         (with-current-buffer buffer
           (when buffer-read-only (error "Vox target is read-only"))
           (save-excursion
             (save-restriction
               ;; A restriction can otherwise clamp the captured marker silently.
               (widen)
               (goto-char marker)
               (undo-boundary)
               (atomic-change-group (insert text))
               (undo-boundary))))))
     :on-error
     (lambda (_session _error)
       (unless noninteractive
         (message "Vox failed; no partial text inserted. Use vox-show-transcript for recovery."))))))

(provide 'vox-ui)
;;; vox-ui.el ends here
