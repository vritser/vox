;;; vox-ui.el --- Preview overlays and captured-buffer sinks -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Preview never edits text.  Only authoritative completion commits one change.
;;; Code:
(require 'vox-core)
(require 'motion-line nil t)

(declare-function motion-line-frames "motion-line" (frames &optional duration))
(declare-function motion-line-play "motion-line" (slot clip &rest args))
(declare-function motion-line-playing-p "motion-line" (slot))
(declare-function motion-line-stop "motion-line" (slot))
(declare-function motion-line-string "motion-line" (slot))

(defcustom vox-preview t "Show a one-line overlay while recording."
  :type 'boolean :group 'vox)
(defcustom vox-preview-width 72 "Maximum preview display columns."
  :type 'integer :group 'vox)
(defcustom vox-mode-line t
  "Show the persistent Vox microphone icon in the mode line."
  :type 'boolean :group 'vox)
(defcustom vox-mode-line-icon "●"
  "One-cell fallback glyph used when Emacs cannot render the SVG icon."
  :type 'string :group 'vox)

(defconst vox-ui--mode-line-states '(connecting recording draining finalizing)
  "Session states that animate the Vox mode-line indicator.")

(defvar vox-ui--mode-line-images nil
  "Cached SVG sound-wave frames for the Vox mode line.")
(defvar vox-ui--mode-line-images-color nil
  "Face color used to build `vox-ui--mode-line-images'.")

(defconst vox-ui--mode-line-wave-opacities
  '((1.0 0.35 0.08)
    (0.45 1.0 0.35)
    (0.12 0.45 1.0)
    (0.04 0.12 0.45))
  "Opacity triples that move a sound-wave pulse outward on both sides.")

(defconst vox-ui--mode-line-wave-arcs
  '((10.2 -1 5.9 10.1 1.2)
    (7.6 -1 4.8 11.2 1.8)
    (5.0 -1 3.7 12.3 2.4)
    (17.8 1 5.9 10.1 1.2)
    (20.4 1 4.8 11.2 1.8)
    (23.0 1 3.7 12.3 2.4))
  "X, direction, top, bottom and curve width for the six sound-wave arcs.
The first three arcs are the left side, the last three the right side; each
triple grows from the inner, shorter arc to the outer, taller arc.")

(defun vox-ui--mode-line-svg (phase color)
  "Return PHASE's sound-wave microphone SVG tinted COLOR."
  (let* ((opacities
          (nth (mod phase (length vox-ui--mode-line-wave-opacities))
               vox-ui--mode-line-wave-opacities))
         (remaining (append opacities opacities))
         (arcs
          (mapconcat
           (lambda (arc)
             (let* ((x (nth 0 arc))
                    (direction (nth 1 arc))
                    (top (nth 2 arc))
                    (bottom (nth 3 arc))
                    (curve (nth 4 arc))
                    (control (+ x (* curve direction)))
                    (high (+ top (/ (- bottom top) 3.0)))
                    (low (- bottom (/ (- bottom top) 3.0)))
                    (opacity (pop remaining)))
               (format
                (concat "<path d=\"M%s %sC%s %s %s %s %s %s\" "
                        "stroke=\"%s\" stroke-width=\"1.3\" "
                        "stroke-linecap=\"round\" opacity=\"%s\"/>")
                x top control high control low x bottom color opacity)))
           vox-ui--mode-line-wave-arcs "")))
    (concat
     "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"28\" height=\"16\" "
     "viewBox=\"0 0 28 16\" fill=\"none\">"
     arcs
     "<rect x=\"12.25\" y=\"2.2\" width=\"3.5\" height=\"6.6\" rx=\"1.75\" "
     "stroke=\"" color "\" stroke-width=\"1.3\"/>"
     "<path d=\"M10.5 7.6C10.5 9.6 12 11.1 14 11.1C16 11.1 17.5 9.6 17.5 7.6\" "
     "stroke=\"" color "\" stroke-width=\"1.3\" stroke-linecap=\"round\"/>"
     "<path d=\"M14 11.1V13.4M11.6 13.4H16.4\" stroke=\"" color "\" "
     "stroke-width=\"1.3\" stroke-linecap=\"round\"/></svg>")))

(defun vox-ui--mode-line-color (face)
  "Return a concrete SVG foreground color for FACE, or nil."
  (let ((foreground (and (display-graphic-p) (face-foreground face nil t))))
    (when (and foreground (not (equal foreground "unspecified")))
      (let ((rgb (condition-case nil (color-values foreground) (error nil))))
        (when rgb
          (apply #'format "#%02x%02x%02x"
                 (mapcar (lambda (channel) (/ channel 257)) rgb)))))))

(defun vox-ui--mode-line-images (color)
  "Return cached sound-wave frames tinted COLOR, or nil."
  (when (and color (display-graphic-p)
             (fboundp 'image-type-available-p)
             (image-type-available-p 'svg))
    (unless (and (vectorp vox-ui--mode-line-images)
                 (> (length vox-ui--mode-line-images) 0)
                 (equal color vox-ui--mode-line-images-color))
      (setq vox-ui--mode-line-images
            (condition-case nil
                (vconcat
                 (mapcar (lambda (phase)
                           (create-image (vox-ui--mode-line-svg phase color)
                                         'svg t :ascent 'center :height 1.0))
                         (number-sequence
                          0 (1- (length vox-ui--mode-line-wave-opacities)))))
              (error nil))
            vox-ui--mode-line-images-color color))
    vox-ui--mode-line-images))

(defconst vox-ui--mode-line-slot 'vox-mode-line
  "Motion-line slot used for the Vox mode line.")

(defvar-local vox-ui--mode-line-face-color nil
  "Face color currently loaded into this buffer's motion-line slot.")

(defvar vox-ui--mode-line-idle-image nil
  "Cached idle microphone image for the Vox mode line.")
(defvar vox-ui--mode-line-idle-color nil
  "Face color used to build `vox-ui--mode-line-idle-image'.")

(defvar vox-ui--mode-line-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1] 'vox-toggle)
    map)
  "Keymap for clicking the Vox mode-line icon.")

(defconst vox-mode-line-construct '(:eval (vox-ui--mode-line-text))
  "Mode-line construct that renders the Vox microphone icon.
Vox appends it to `global-mode-string', which puts it at the end of the
mode line.  To place the icon elsewhere, remove it from there and insert
this construct into your own `mode-line-format'.")

(defun vox-ui--mode-line-place ()
  "Append the Vox construct to `global-mode-string'."
  (when (listp global-mode-string)
    (setq global-mode-string
          (remove vox-mode-line-construct global-mode-string)))
  (setq global-mode-string
        (append (if (listp global-mode-string)
                    global-mode-string
                  (list global-mode-string))
                (list vox-mode-line-construct)))
  (ignore-errors (force-mode-line-update t)))

(defun vox-ui--mode-line-idle-svg (color)
  "Return a standalone microphone SVG tinted COLOR."
  (concat
   "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" "
   "viewBox=\"0 0 16 16\" fill=\"none\">"
   "<rect x=\"5.75\" y=\"1.5\" width=\"4.5\" height=\"8\" rx=\"2.25\" "
   "stroke=\"" color "\" stroke-width=\"1.4\"/>"
   "<path d=\"M3.5 7.5C3.5 10 5.5 12 8 12C10.5 12 12.5 10 12.5 7.5\" "
   "stroke=\"" color "\" stroke-width=\"1.4\" stroke-linecap=\"round\"/>"
   "<path d=\"M8 12V14.5M5.5 14.5H10.5\" stroke=\"" color "\" "
   "stroke-width=\"1.4\" stroke-linecap=\"round\"/></svg>"))

(defun vox-ui--mode-line-idle-image (color)
  "Return a cached idle microphone image tinted COLOR, or nil."
  (when (and color (display-graphic-p)
             (fboundp 'image-type-available-p)
             (image-type-available-p 'svg))
    (unless (and vox-ui--mode-line-idle-image
                 (equal color vox-ui--mode-line-idle-color))
      (setq vox-ui--mode-line-idle-image
            (condition-case nil
                (create-image (vox-ui--mode-line-idle-svg color)
                              'svg t :ascent 'center :height 1.0)
              (error nil))
            vox-ui--mode-line-idle-color color))
    vox-ui--mode-line-idle-image))

(defun vox-ui--mode-line-clickable (text help)
  "Return TEXT carrying the Vox click map and HELP."
  (propertize text
              'local-map vox-ui--mode-line-map
              'mouse-face 'mode-line-highlight
              'help-echo help))

(defun vox-ui--mode-line-idle ()
  "Return the idle Vox mode-line icon."
  (let ((image (vox-ui--mode-line-idle-image
                (vox-ui--mode-line-color 'mode-line))))
    (vox-ui--mode-line-clickable
     (if image (propertize " " 'display image) vox-mode-line-icon)
     "Vox: click to start recording")))

(defun vox-ui--mode-line-active (session)
  "Return a static active icon for SESSION outside its target buffer."
  (let* ((state (vox-session-state session))
         (face (if (eq state 'recording) 'error 'warning))
         (images (vox-ui--mode-line-images (vox-ui--mode-line-color face)))
         (image (and (vectorp images) (> (length images) 0)
                     (aref images 0))))
    (vox-ui--mode-line-clickable
     (if image
         (propertize " " 'display image)
       (propertize vox-mode-line-icon 'face face))
     (format "Vox: %s; click to stop" state))))

(defun vox-ui--mode-line-text ()
  "Return the global Vox mode-line icon."
  (if (not vox-mode-line)
      ""
    (let ((animated (and (featurep 'motion-line)
                         (fboundp 'motion-line-string)
                         (motion-line-string vox-ui--mode-line-slot))))
      (cond
       ((and animated (not (equal animated "")))
        (vox-ui--mode-line-clickable
         animated
         (format "Vox: %s; click to stop"
                 (if (and vox--active-session
                          (memq (vox-session-state vox--active-session)
                                vox-ui--mode-line-states))
                     (vox-session-state vox--active-session)
                   "recording"))))
       ((and vox--active-session
             (memq (vox-session-state vox--active-session)
                   vox-ui--mode-line-states))
        (vox-ui--mode-line-active vox--active-session))
       (t (vox-ui--mode-line-idle))))))

(vox-ui--mode-line-place)

(defun vox-ui--mode-line-frames (color)
  "Return a motion-line sound-wave clip tinted COLOR, or nil."
  (when (and color (fboundp 'motion-line-frames))
    (let ((images (vox-ui--mode-line-images color)))
      (when (and (vectorp images) (> (length images) 0))
        (motion-line-frames
         (mapcar (lambda (image)
                   (propertize " " 'display image))
                 (append images nil))
         0.2)))))

(defun vox-ui--mode-line-start (session state)
  "Animate SESSION's STATE in its target buffer."
  (let ((buffer (vox-session-target-buffer session)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let* ((face (if (eq state 'recording) 'error 'warning))
               (color (vox-ui--mode-line-color face))
               (frames (and color (vox-ui--mode-line-frames color))))
          (when (and frames
                     (featurep 'motion-line)
                     (fboundp 'motion-line-play))
            (unless (and (equal color vox-ui--mode-line-face-color)
                         (motion-line-playing-p vox-ui--mode-line-slot))
              (condition-case nil
                  (progn
                    (motion-line-play vox-ui--mode-line-slot frames :repeat t)
                    (setq vox-ui--mode-line-face-color color))
                (error nil)))))))
    (force-mode-line-update t)))

(defun vox-ui--mode-line-stop (session)
  "Stop SESSION's animation in its target buffer."
  (let ((buffer (vox-session-target-buffer session)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (and (featurep 'motion-line)
                   (fboundp 'motion-line-stop))
          (condition-case nil
              (motion-line-stop vox-ui--mode-line-slot)
            (error nil)))
        (setq vox-ui--mode-line-face-color nil))))
  (force-mode-line-update t))

(defun vox-ui--mode-line-update (session state)
  "Update SESSION's mode line for STATE."
  (if (and vox-mode-line (memq state vox-ui--mode-line-states))
      (vox-ui--mode-line-start session state)
    (vox-ui--mode-line-stop session)))

(defun vox-ui--instrument-sink (sink)
  "Return a copy of SINK that also updates the Vox mode line."
  (let ((on-state (plist-get sink :on-state)))
    (plist-put (copy-sequence sink) :on-state
               (lambda (session state)
                 (vox-ui--mode-line-update session state)
                 (when on-state (funcall on-state session state))))))

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
                                      (- column (window-hscroll window)) 1)))))
    width))

(defun vox-make-buffer-sink ()
  "Return a sink using the session's captured buffer and insertion marker.
Typing at that marker moves it after typed text.  Point follows committed text
only when still at that marker.  Neither preview nor commit switches windows
or sends input to an agent."
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
                           (truncate-string-to-width
                            (replace-regexp-in-string "[\n\r\t]+" " " text)
                            width nil nil (when (>= width 3) "..."))
                           'face 'shadow))))))
     :on-state
     (lambda (session state)
       (when (memq state '(completed cancelled error))
         (when (overlayp overlay) (delete-overlay overlay))
         (setq overlay nil))
       (unless noninteractive
         (cond
           ((eq state 'recording)
            (if (eq (vox-session-stop-mode session) 'silence)
                (message "Vox: recording; pause to finish, or use vox-stop to end early")
              (message "Vox: recording (manual stop); use vox-stop or vox-toggle to finish")))
           ((and (eq state 'completed)
                 (string-empty-p
                  (string-trim (or (vox-session-final-text session) ""))))
            (message
             "Vox: no speech recognized; nothing inserted (check the input device)%s"
             (if (plist-get (vox-session-statistics session) :audio-tail-risk)
                 "; recorder tail may be truncated" "")))
           ((and (memq state '(finalizing completed))
                 (plist-get (vox-session-statistics session) :audio-tail-risk))
            (message "Vox: %s; recorder needed a second interrupt, tail audio may be truncated" state))
           (t (message "Vox: %s" state)))))
     :on-finish
     (lambda (session text)
       (let ((buffer (vox-session-target-buffer session))
             (marker (vox-session-target-marker session)))
         (unless (and (buffer-live-p buffer) (eq (marker-buffer marker) buffer))
           (error "Vox target no longer exists"))
         (with-current-buffer buffer
           (when buffer-read-only (error "Vox target is read-only"))
           (let ((follow-point (= (point) marker)))
             (save-excursion
               (save-restriction
                 ;; A restriction can otherwise clamp the captured marker silently.
                 (widen)
                 (goto-char marker)
                 (undo-boundary)
                 (atomic-change-group (insert text))
                 (undo-boundary)))
             ;; The insertion-type marker follows text; save-excursion does not.
             (when follow-point (goto-char marker))))))
     :on-error
     (lambda (_session _error)
       (unless noninteractive
         (message "Vox failed; no partial text inserted. Use vox-show-transcript for recovery."))))))

(provide 'vox-ui)
;;; vox-ui.el ends here
