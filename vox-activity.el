;;; vox-activity.el --- Bounded PCM energy activity detector -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Pure PCM16LE/16kHz/mono energy detection; no capture, timers or core dependency.
;; A 20ms window is active when its RMS reaches the normalized threshold.
;; Five consecutive active windows arm silence detection.  This is not semantic
;; VAD: steady noise can arm it, quiet speech can be missed, and a pause can end
;; an utterance.  Processing is linear in samples with constant retained space.
;;; Code:

(require 'cl-lib)

(cl-defstruct (vox-activity
               (:constructor vox-activity--create)
               (:conc-name vox-activity--))
  "Bounded activity state; retain only numeric accumulators, never PCM chunks."
  cutoff silence-limit
  (samples 0) (energy 0) (speech 0) (silent 0) armed pending)

(defun vox-activity-create (threshold silence-seconds)
  "Create independent PCM activity state with THRESHOLD and SILENCE-SECONDS.
THRESHOLD is normalized RMS, greater than zero and at most one; signed
16-bit full scale is 32768.  SILENCE-SECONDS must be a number from 0.2 to
10, rounded upward to whole 20ms windows.  Invalid options signal
`user-error' without including their values in diagnostics."
  (unless (and (numberp threshold) (> threshold 0) (<= threshold 1))
    (user-error "Activity threshold must be a number greater than 0 and at most 1"))
  (unless (and (numberp silence-seconds)
               (>= silence-seconds 0.2) (<= silence-seconds 10))
    (user-error "Activity silence duration must be a number from 0.2 to 10 seconds"))
  (vox-activity--create
   ;; Integer sample energy cannot distinguish cutoffs below this floor.
   ;; Keeping it positive also prevents floating-point underflow arming silence.
   :cutoff (let ((amplitude (* threshold 32768.0)))
             (max (/ 1.0 320) (* amplitude amplitude)))
   :silence-limit (ceiling (* silence-seconds 50))))

(defun vox-activity-stop-p (state)
  "Return whether STATE currently qualifies for automatic stopping.
This query does not mutate STATE and is not latched: later active PCM can
revoke eligibility.  An incomplete sample, or a partial window whose RMS
already reaches the threshold, conservatively prevents stopping."
  (unless (vox-activity-p state)
    (user-error "Activity state must be created by vox-activity-create"))
  (and (vox-activity--armed state)
       (>= (vox-activity--silent state) (vox-activity--silence-limit state))
       (null (vox-activity--pending state))
       (or (zerop (vox-activity--samples state))
           (< (vox-activity--energy state)
              (* (vox-activity--cutoff state) (vox-activity--samples state))))))

(defun vox-activity-feed (state bytes)
  "Consume all unibyte PCM16LE BYTES into STATE and return stop eligibility.
Input is 16kHz mono and may be split at any byte.  Fixed 320-sample windows
are independent of chunk boundaries.  At most one trailing byte is retained
as an integer, together with bounded counters and window energy.  Empty
BYTES only queries current eligibility.  Invalid input signals `user-error'
without including audio in diagnostics or modifying STATE.

The whole chunk is processed before returning, so resumed speech later in
BYTES overrides earlier silence.  If delivery can reenter the caller, query
`vox-activity-stop-p' again immediately before initiating a stop."
  (unless (vox-activity-p state)
    (user-error "Activity state must be created by vox-activity-create"))
  (unless (and (stringp bytes) (not (multibyte-string-p bytes)))
    (user-error "Activity PCM input must be a unibyte string"))
  (let ((index 0)
        (size (length bytes))
        (pending (vox-activity--pending state))
        (samples (vox-activity--samples state))
        (energy (vox-activity--energy state))
        (speech (vox-activity--speech state))
        (silent (vox-activity--silent state))
        (armed (vox-activity--armed state))
        (window-cutoff (* 320 (vox-activity--cutoff state)))
        (silence-limit (vox-activity--silence-limit state)))
    (while (< index size)
      (let ((low (if pending
                     (prog1 pending (setq pending nil))
                   (prog1 (aref bytes index) (setq index (1+ index))))))
        (if (= index size)
            (setq pending low)
          (let ((sample (+ low (ash (aref bytes index) 8))))
            (setq index (1+ index))
            (when (>= sample 32768) (setq sample (- sample 65536)))
            (setq energy (+ energy (* sample sample))
                  samples (1+ samples))
            (when (= samples 320)
              (if (>= energy window-cutoff)
                  (setq speech (min 5 (1+ speech))
                        armed (or armed (= speech 5))
                        silent 0)
                (setq speech 0
                      silent (if armed (min silence-limit (1+ silent)) 0)))
              (setq samples 0 energy 0))))))
    (setf (vox-activity--pending state) pending
          (vox-activity--samples state) samples
          (vox-activity--energy state) energy
          (vox-activity--speech state) speech
          (vox-activity--silent state) silent
          (vox-activity--armed state) armed))
  (vox-activity-stop-p state))

(provide 'vox-activity)
;;; vox-activity.el ends here
