;;; vox-audio.el --- Asynchronous PCM capture -*- lexical-binding: t; -*-

;;; Commentary:
;; FFmpeg produces PCM16LE, 16 kHz, mono.  Core owns chunking and queue limits.
;; No microphone is selected implicitly and stderr never enters the PCM stream.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'vox-core)

(defgroup vox-audio nil "PCM capture for Vox." :group 'vox)

(defcustom vox-audio-program "ffmpeg"
  "FFmpeg executable used for capture, without shell interpretation."
  :type 'string :group 'vox-audio)

(defcustom vox-audio-input nil
  "FFmpeg input argument list; nil requires explicit device selection.
Use `vox-select-input-device', or choose when starting interactively with
nil input.  Programmatic/headless starts still require explicit argv.
For example, macOS can use (\"-f\" \"avfoundation\" \"-i\" \":0\").
For virtual-source tests use (\"-re\" \"-f\" \"lavfi\" \"-i\"
\"sine=frequency=440:sample_rate=16000\").  Arguments are passed directly
as argv, never to a shell.  Do not put secrets in these arguments."
  :type '(repeat string) :group 'vox-audio)

(defcustom vox-audio-interrupt-retry-delay 0.5
  "Seconds before one asynchronous SIGINT retry if capture remains alive.
Some FFmpeg builds need a second interrupt.  This may discard tail audio;
statistics record the retry and tail-loss risk.  Core owns the final stop
timeout.  No further signal escalation occurs in this module."
  :type 'number :group 'vox-audio)

(defun vox-audio--discard-stderr (session generation process bytes)
  "Discard diagnostic BYTES for PROCESS, guarding SESSION and GENERATION.
Only a saturated byte count is retained; device names and input URLs may
be sensitive, so even a truncated stderr string is not safe to retain."
  (condition-case nil
      (when (vox-session-live-p session generation)
        (process-put process 'vox-stderr-bytes
                     (min 65536 (+ (or (process-get process 'vox-stderr-bytes) 0)
                                   (string-bytes bytes)))))
    (error nil)))

(defun vox-audio--dispose (process)
  "Detach and reclaim PROCESS and its stderr pipe without callbacks."
  (when (processp process)
    (when-let* ((timer (process-get process 'vox-interrupt-timer)))
      (cancel-timer timer))
    (process-put process 'vox-interrupt-timer nil)
    (process-put process 'vox-on-error nil)
    (set-process-filter process #'ignore)
    (set-process-sentinel process #'ignore)
    (let ((stderr (process-get process 'vox-stderr)))
      (process-put process 'vox-stderr nil)
      (when (processp stderr)
        (set-process-filter stderr #'ignore)
        (set-process-sentinel stderr #'ignore)
        (ignore-errors (delete-process stderr))))
    (ignore-errors (delete-process process))))

(defun vox-audio-start (session on-bytes on-ended on-error)
  "Start SESSION's recorder and return the process.
ON-BYTES receives strictly unibyte PCM.  ON-ENDED receives no arguments.
ON-ERROR receives a fixed, safe diagnostic, never FFmpeg's raw stderr.
All callbacks are generation guarded and errors are contained."
  (unless (and (consp vox-audio-input)
               (proper-list-p vox-audio-input)
               (cl-every #'stringp vox-audio-input))
    (user-error "Configure vox-audio-input with an explicit FFmpeg input"))
  (unless (and (stringp vox-audio-program)
               (executable-find vox-audio-program))
    (user-error "FFmpeg is unavailable; configure vox-audio-program"))
  (when (vox-session-recorder session)
    (user-error "This session already owns a recorder"))
  (let ((generation (vox-session-generation session))
        (ended nil)
        stderr recorder)
    (unless (vox-session-live-p session generation)
      (user-error "Cannot start audio for an inactive session"))
    (cl-labels
        ((fail (safe-message)
           (unless ended
             (setq ended t)
             (when (eq recorder (vox-session-recorder session))
               (setf (vox-session-recorder session) nil))
             (vox-audio--dispose recorder)
             (condition-case nil
                 (when (vox-session-live-p session generation)
                   (funcall on-error safe-message))
               (error nil)))))
      (condition-case nil
          (progn
            (setq stderr
                  (make-pipe-process
                   :name "vox-audio-stderr" :buffer nil :coding 'binary
                   :noquery t
                   :filter (lambda (process bytes)
                             (vox-audio--discard-stderr
                              session generation process bytes))
                   :sentinel #'ignore))
            (setq recorder
                  (make-process
                   :name "vox-audio" :buffer nil :stderr stderr
                   :command (append
                             (list vox-audio-program "-nostdin" "-hide_banner"
                                   "-loglevel" "error")
                             vox-audio-input
                             '("-vn" "-ac" "1" "-ar" "16000"
                               "-acodec" "pcm_s16le" "-f" "s16le" "pipe:1"))
                   :connection-type 'pipe :coding 'binary :noquery t
                   :filter
                   (lambda (process bytes)
                     (condition-case nil
                         (when (and (not ended)
                                    (eq process (vox-session-recorder session))
                                    (vox-session-live-p session generation))
                           (unless (and (stringp bytes)
                                        (not (multibyte-string-p bytes)))
                             (error "Nonbinary recorder output"))
                           (funcall on-bytes bytes))
                       (error (fail "Audio delivery failed"))))
                   :sentinel
                   (lambda (process _event)
                     (condition-case nil
                         (when (memq (process-status process) '(exit signal failed))
                           (vox-log-event generation 'audio-exit
                                          :status (process-status process)
                                          :exit-code (process-exit-status process))
                           ;; Pending stdout precedes the terminal sentinel.
                           ;; Stop must not detach the filter early.
                           (when (and (not ended)
                                      (eq process (vox-session-recorder session)))
                             (let ((success
                                    (or (and (eq (process-status process) 'exit)
                                             (zerop (process-exit-status process)))
                                        (and (process-get process 'vox-stop-requested)
                                             (memq (process-exit-status process)
                                                   '(2 255))))))
                               (if (not success)
                                   (fail "FFmpeg capture failed; check input and microphone permission")
                                 (setq ended t)
                                 (when (eq process (vox-session-recorder session))
                                   (setf (vox-session-recorder session) nil))
                                 (vox-audio--dispose process)
                                 (when (vox-session-live-p session generation)
                                   (condition-case nil
                                       (funcall on-ended)
                                     (error
                                      (condition-case nil
                                          (when (vox-session-live-p session generation)
                                            (funcall on-error "Audio completion callback failed"))
                                        (error nil)))))))))
                       (error (fail "Audio process cleanup failed"))))))
            (process-put recorder 'vox-stderr stderr)
            (process-put recorder 'vox-on-error #'fail)
            (setf (vox-session-recorder session) recorder)
            (vox-log-event generation 'audio-start)
            recorder)
        (error
         (when (processp stderr) (ignore-errors (delete-process stderr)))
         (fail "Could not start FFmpeg; check executable and input configuration")
         nil)))))

(defun vox-audio--interrupt (process)
  "Interrupt only recorder PROCESS using the documented interrupt hook."
  ;; Pipe children need not own a process group; never signal a wider group.
  (let ((interrupt-process-functions
         (list (lambda (target &optional _group)
                 (signal-process target 'SIGINT)
                 t))))
    (interrupt-process process)))

(defun vox-audio-stop (session)
  "Asynchronously interrupt SESSION's recorder once, with one bounded retry.
Keep accepting final stdout until its terminal sentinel.  Core owns the
stop timeout; this function never waits for process output."
  (let ((process (vox-session-recorder session))
        (generation (vox-session-generation session)))
    (when (and (processp process) (process-live-p process)
               (not (process-get process 'vox-stop-requested)))
      (unless (and (numberp vox-audio-interrupt-retry-delay)
                   (> vox-audio-interrupt-retry-delay 0))
        (user-error "Invalid audio interrupt retry delay"))
      (process-put process 'vox-stop-requested t)
      (vox-log-event generation 'audio-stop)
      (condition-case nil
          (progn
            (vox-audio--interrupt process)
            (process-put
             process 'vox-interrupt-timer
             (run-at-time
              vox-audio-interrupt-retry-delay nil
              (lambda ()
                (process-put process 'vox-interrupt-timer nil)
                (condition-case nil
                    (when (and (eq process (vox-session-recorder session))
                               (vox-session-live-p session generation)
                               (not (process-get process 'vox-interrupt-retried))
                               (process-live-p process))
                      (process-put process 'vox-interrupt-retried t)
                      (let ((stats (copy-sequence (vox-session-statistics session))))
                        (setq stats (plist-put stats :audio-interrupt-retries 1)
                              stats (plist-put stats :audio-tail-risk t))
                        (setf (vox-session-statistics session) stats))
                      (vox-log-event generation 'audio-retry :tail-risk t)
                      (vox-audio--interrupt process))
                  (error
                   (when-let* ((fail (process-get process 'vox-on-error)))
                     (funcall fail "Audio interrupt retry failed"))))))))
        (error (error "Could not interrupt audio capture"))))))

(defun vox-audio-cancel (session)
  "Discard and reclaim SESSION's recorder, idempotently."
  (let ((process (vox-session-recorder session)))
    (setf (vox-session-recorder session) nil)
    (when process
      (vox-log-event (vox-session-generation session) 'audio-cancel))
    (vox-audio--dispose process)))

(provide 'vox-audio)
;;; vox-audio.el ends here
