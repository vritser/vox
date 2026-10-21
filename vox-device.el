;;; vox-device.el --- Explicit local audio device selection -*- lexical-binding: t; -*-

;;; Commentary:
;; Discover inputs only on explicit invocation, using FFmpeg without a shell.
;; Listing can trigger native permission UI.  Diagnostics stay private and
;; bounded; no enumeration, capture, or persistence occurs when loading this file.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'vox-audio)

(defcustom vox-device-discovery-timeout 5
  "Maximum seconds to wait for local FFmpeg input discovery.
Must be a finite number from 0.1 through 30.  Listing devices can cause
native permission prompts; quit aborts discovery without changing input."
  :type 'number :group 'vox-audio)

(defvar vox-device--busy nil
  "Non-nil while this module owns an input discovery operation.")

(defvar vox-device--selecting nil
  "Non-nil while an explicit device selection command is in progress.")

(defconst vox-device--output-limit 65536
  "Maximum bytes retained from a device listing.")

(defun vox-device--check-idle ()
  "Reject device changes while any Vox session owns the recorder lifecycle."
  (when vox--reloading (user-error "Wait for Vox reload to finish before selecting an input"))
  (when (vox-current-session)
    (user-error "Stop or cancel the active Vox session before selecting an input")))

(defun vox-device--record (name backend id)
  "Build a candidate for NAME with BACKEND and exact input ID."
  (list :label (format "%s [%s:%s]" name backend id)
        :input (list "-f" backend "-i" id)))

(defun vox-device--unique (devices)
  "Return DEVICES in order, deduplicated by exact input argv."
  (let ((seen (make-hash-table :test #'equal)))
    (cl-remove-if
     (lambda (device)
       (let ((input (plist-get device :input)))
         (prog1 (gethash input seen) (puthash input t seen))))
     devices)))

(defun vox-device--parse-avfoundation (output)
  "Parse only AVFoundation audio records in FFmpeg listing OUTPUT."
  (let ((case-fold-search nil) audio devices)
    (dolist (line (split-string output "[\r\n]+" t))
      (when (string-match "\\`\\[AVFoundation[^]]*\\] *\\(.*\\)\\'" line)
        (setq line (match-string 1 line))
        (cond
         ((string-prefix-p "AVFoundation audio devices:" line) (setq audio t))
         ((string-prefix-p "AVFoundation video devices:" line) (setq audio nil))
         ((and audio (string-match "\\`\\[\\([0-9]+\\)\\] \\(.+\\)\\'" line))
          (push (vox-device--record (match-string 2 line) "avfoundation"
                                    (concat ":" (match-string 1 line)))
                devices)))))
    (vox-device--unique (nreverse devices))))

(defun vox-device--parse-dshow (output)
  "Parse modern or legacy DirectShow audio records in OUTPUT.
Prefer the following Alternative name identifier over the friendly name."
  (let ((case-fold-search nil) legacy-audio current devices)
    (dolist (line (split-string output "[\r\n]+" t))
      (when (string-match "\\`\\[dshow[^]]*\\] *\\(.*\\)\\'" line)
        (setq line (match-string 1 line))
        (cond
         ((string-prefix-p "DirectShow audio devices" line)
          (setq legacy-audio t current nil))
         ((string-prefix-p "DirectShow video devices" line)
          (setq legacy-audio nil current nil))
         ((string-match "\\`Alternative name \"\\(.*\\)\"\\'" line)
          (when current
            (let ((id (match-string 1 line)))
              (setcdr current (vox-device--record (car current) "dshow"
                                                  (concat "audio=" id))))))
         ((string-match "\\`\"\\(.*\\)\"\\(?: (\\([^)]*\\))\\)?\\'" line)
          (let ((name (match-string 1 line)) (kind (match-string 2 line)))
            (setq current nil)
            (when (or (member "audio" (split-string (or kind "") ", *" t))
                      (and (null kind) legacy-audio))
              (setq current (cons name (vox-device--record name "dshow"
                                                           (concat "audio=" name))))
              (push current devices)))))))
    ;; DirectShow splits the input on colons, even without a shell.  Its
    ;; reported alternative IDs replace colons; a friendly-only colon name
    ;; cannot be selected safely by this interface.
    (vox-device--unique
     (cl-remove-if
      (lambda (device)
        (string-match-p ":" (car (last (plist-get device :input)))))
      (mapcar #'cdr (nreverse devices))))))

(defun vox-device--parse-pulse (output)
  "Parse FFmpeg show_sources PulseAudio records in OUTPUT.
Source IDs remain a single argv token, including spaces and quotes.
Monitor/system-audio sources retain their reported descriptive labels."
  (let ((case-fold-search nil) devices)
    (dolist (line (split-string output "[\r\n]+" t))
      (when (string-match
             "\\`\\([ *]\\) \\(.+?\\) \\[\\(.*\\)\\]\\(?: (\\(audio\\|none\\))\\)?\\'" line)
        (let ((id (match-string 2 line))
              (name (match-string 3 line)))
          ;; PulseAudio does not populate media_types, so ordinary sources
          ;; can be marked `none' too.  Never treat that as an empty device.
          (when (let ((case-fold-search t))
                  (string-match-p "monitor" (concat id " " name)))
            (setq name (concat "Monitor / system audio: " name)))
          (push (vox-device--record name "pulse" id) devices))))
    (vox-device--unique (nreverse devices))))

(defun vox-device--discover (arguments)
  "Return bounded FFmpeg listing output for ARGUMENTS, never via a shell.
Only normal exit is accepted; listing commands may intentionally exit nonzero.
No partial output is returned on timeout, overflow, quit, or process failure."
  (unless (and (numberp vox-device-discovery-timeout)
               (<= 0.1 vox-device-discovery-timeout 30))
    (user-error "vox-device-discovery-timeout must be finite and between 0.1 and 30"))
  (let ((program (and (stringp vox-audio-program)
                      (executable-find vox-audio-program))))
    (unless program
      (user-error "FFmpeg is unavailable; configure vox-audio-program or vox-audio-input"))
    (let ((output "") (bytes 0) overflow timed-out failed process finished
          (deadline (+ (float-time) vox-device-discovery-timeout)))
      (unwind-protect
          (condition-case nil
              (progn
                (setq process
                      (make-process
                       :name "vox-device-discovery" :buffer nil :stderr nil
                       :command (cons program arguments) :connection-type 'pipe
                       :coding 'utf-8-unix :noquery t
                       :sentinel (lambda (child _event)
                                   (let ((status (process-status child)))
                                     (when (memq status '(exit signal failed closed))
                                       (setq finished status))))
                       :filter (lambda (_process chunk)
                                 (unless overflow
                                   (setq bytes (+ bytes (string-bytes chunk)))
                                   (if (> bytes vox-device--output-limit)
                                       (setq overflow t output "")
                                     (setq output (concat output chunk)))))))
                (while (and (not finished) (not overflow) (not timed-out))
                  (if (>= (float-time) deadline)
                      (setq timed-out t)
                    ;; Wait for all processes so timers, UI, and quit remain live.
                    (accept-process-output nil 0.05)))
                (when (>= (float-time) deadline) (setq timed-out t))
                (unless (or overflow timed-out)
                  (setq failed (not (eq finished 'exit)))))
            (error (setq failed t)))
        (when process
          (set-process-filter process #'ignore)
          (set-process-sentinel process #'ignore)
          (when (process-live-p process) (delete-process process))))
      (cond
       (overflow (user-error "FFmpeg device listing exceeded the safe output limit; configure vox-audio-input manually"))
       (timed-out (user-error "FFmpeg device discovery timed out; configure vox-audio-input manually"))
       (failed (user-error "FFmpeg device discovery failed; configure vox-audio-input manually"))
       (t output)))))

(defun vox-device-list ()
  "Discover supported local audio inputs on demand using configured FFmpeg.
Return plists with :label (human-readable) and :input (exact FFmpeg argv).
Supported systems are macOS AVFoundation, Windows DirectShow, and GNU/Linux
PulseAudio (including PipeWire's PulseAudio compatibility service).
Never selects an input or persists configuration.  Native permission UI may
appear.  Unsupported systems/builds require manual `vox-audio-input' setup."
  (vox-device--check-idle)
  (when vox-device--busy
    (user-error "Vox device discovery is already in progress"))
  (let* ((vox-device--busy t)
         (spec (pcase system-type
                 ('darwin (cons #'vox-device--parse-avfoundation
                                '("-hide_banner" "-f" "avfoundation" "-list_devices" "true" "-i" "")))
                 ('windows-nt (cons #'vox-device--parse-dshow
                                    '("-hide_banner" "-list_devices" "true" "-f" "dshow" "-i" "dummy")))
                 ('gnu/linux (cons #'vox-device--parse-pulse
                                   '("-hide_banner" "-sources" "pulse")))
                 (_ (user-error "Device discovery is unsupported on this OS; configure vox-audio-input manually"))))
         (devices (funcall (car spec) (vox-device--discover (cdr spec)))))
    (unless devices
      (user-error "No supported audio inputs found; check FFmpeg support and permissions or configure vox-audio-input manually"))
    devices))

(defun vox-device--save-input (input)
  "Save INPUT, restoring its Customize metadata if saving errors or quits."
  (let* ((properties '(saved-value customized-value customized-variable-comment
                                  theme-value))
         (previous-properties
          (mapcar (lambda (property)
                    (list property
                          (not (null (plist-member (symbol-plist 'vox-audio-input)
                                                   property)))
                          (copy-tree (get 'vox-audio-input property))))
                  properties))
         (input-setting-p
          (lambda (setting)
            (and (eq (car setting) 'theme-value)
                 (eq (cadr setting) 'vox-audio-input))))
         (previous-settings
          (copy-tree (cl-remove-if-not input-setting-p (get 'user 'theme-settings))))
         (previous-default (default-value 'vox-audio-input))
         saved)
    (unwind-protect
        (progn
          (customize-save-variable 'vox-audio-input input)
          (setq saved t))
      (unless saved
        (set-default 'vox-audio-input previous-default)
        (dolist (entry previous-properties)
          (if (nth 1 entry)
              (put 'vox-audio-input (car entry) (nth 2 entry))
            (cl-remprop 'vox-audio-input (car entry))))
        ;; Restore only this option; callbacks may customize other options.
        (put 'user 'theme-settings
             (append previous-settings
                     (cl-remove-if input-setting-p (get 'user 'theme-settings))))))))

;;;###autoload
(defun vox-select-input-device (&optional save)
  "Explicitly select a local input for `vox-audio-input' using completion.
With prefix SAVE, persist only `vox-audio-input' via Customize.  Otherwise
change it for this Emacs session only.  Quit or failure retains the previous
input.  Even a single candidate requires explicit selection."
  (interactive "P")
  (vox-device--check-idle)
  (when vox-device--selecting
    (user-error "Vox input selection is already in progress"))
  (let* ((vox-device--selecting t)
         (devices (vox-device-list))
         (choices (mapcar (lambda (device)
                            (cons (plist-get device :label)
                                  (plist-get device :input)))
                          devices))
         ;; Do not retain private device identifiers in generic history.
         (selection (completing-read "Vox audio input: " choices nil t nil t))
         (input (cdr (assoc selection choices)))
         (previous vox-audio-input))
    ;; Completion can accept different casing; only canonicalize a unique match.
    (when (and (null input) completion-ignore-case)
      (let ((matches (cl-remove-if-not
                      (lambda (choice)
                        (eq t (compare-strings selection nil nil (car choice) nil nil t)))
                      choices)))
        (when (> (length matches) 1)
          (user-error "Ambiguous audio input; choose a candidate with its exact case"))
        (setq input (cdar matches))))
    (unless input (user-error "No audio input selected; configuration unchanged"))
    (vox-device--check-idle)
    (unwind-protect
        (progn
          (if save
              (vox-device--save-input input)
            (setq vox-audio-input input))
          (setq previous input))
      (setq vox-audio-input previous))
    input))

(provide 'vox-device)
;;; vox-device.el ends here
