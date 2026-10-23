;;; vox-tts.el --- Optional API and CLI speech output -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Incremental text synthesis and bounded streaming playback, separate from ASR.
;;; Code:
(require 'vox-backend)

(declare-function vox-tts-qwen-open "vox-tts-qwen" (session backend model))
(declare-function vox-tts-doubao-open "vox-tts-doubao" (session backend))

(defvar vox--active-session nil)
(defvar vox--starting nil)
(defvar vox--reloading nil)

(defcustom vox-tts-selection nil
  "Next TTS choice: (NAME MODEL), or nil for the first TTS-capable backend."
  :type 'sexp :group 'vox)
(defcustom vox-tts-player-command
  '("ffplay" "-nodisp" "-autoexit" "-loglevel" "error" "-probesize" "32768" "-analyzeduration" "0" "-i" "pipe:0")
  "Trusted player argv reading encoded audio from stdin until EOF."
  :type '(repeat string) :group 'vox)
(defcustom vox-tts-max-text-chars 4096 "Maximum text characters per synthesis session."
  :type 'integer :group 'vox)
(defcustom vox-tts-max-audio-bytes (* 16 1024 1024) "Maximum synthesized audio bytes."
  :type 'integer :group 'vox)
(defcustom vox-tts-max-response-bytes (* 24 1024 1024) "Maximum cumulative provider response bytes."
  :type 'integer :group 'vox)
(defcustom vox-tts-max-pending-bytes (* 2 1024 1024)
  "Maximum queued player bytes, including an in-flight write."
  :type 'integer :group 'vox)
(defcustom vox-tts-timeout 60 "Maximum seconds until the synthesis stream completes."
  :type 'number :group 'vox)
(defcustom vox-tts-playback-timeout 600 "Maximum seconds for playback."
  :type 'number :group 'vox)

(defun vox-tts--limits-error ()
  "Return a configuration limit error, or nil; never perform I/O."
  (or (cl-loop for option in '(vox-tts-max-text-chars vox-tts-max-audio-bytes
                               vox-tts-max-response-bytes vox-tts-max-pending-bytes)
               for value = (symbol-value option)
               unless (and (integerp value) (> value 0))
               return (format "`%s' must be a positive integer" option))
      (cl-loop for option in '(vox-tts-timeout vox-tts-playback-timeout)
               for value = (symbol-value option)
               unless (and (numberp value) (> value 0))
               return (format "`%s' must be a positive number" option))))

(defun vox-tts--official-hosts (type)
  "Return trusted API hosts for TTS protocol TYPE."
  (pcase type
    ('tts-qwen-realtime '("dashscope.aliyuncs.com" "dashscope-intl.aliyuncs.com"))
    ('tts-doubao-ws '("openspeech.bytedance.com"))))

(defun vox-tts--snapshot (backend)
  "Return a validated detached TTS capability from BACKEND."
  (vox-backend-capability backend 'tts))

(defun vox-tts--directory ()
  "Return snapshots of the TTS-capable entries in the shared directory."
  (mapcar (lambda (entry) (vox-backend-snapshot (cdr entry)))
          (vox--backend-candidates 'tts)))

(defun vox-tts--resolve ()
  "Return (CONNECTION . MODEL) for the next speech request."
  (let* ((directory (vox-tts--directory))
         (choice vox-tts-selection)
         (backend
          (if (null choice) (car directory)
            (unless (and (proper-list-p choice) (= (length choice) 2))
              (user-error "Invalid Vox TTS selection"))
            (cl-find (car choice) directory :test #'equal :key #'vox-backend-config-name))))
    (unless backend (user-error "No matching TTS capability in vox-backends"))
    (let ((connection (vox-tts--snapshot backend)))
      (cons connection (vox--backend-model connection (cadr choice))))))

(defvar vox-tts--selection-revision 0)
;;;###autoload
(defun vox-tts-select ()
  "Choose a TTS-capable backend/model for the next utterance."
  (interactive)
  (let* ((directory (vox-tts--directory))
         (previous (vox--backend-copy-tree vox-tts-selection))
         (revision vox-tts--selection-revision)
         (completion-ignore-case nil)
         (choices
          (cl-mapcan
           (lambda (backend)
             (let ((connection (vox-tts--snapshot backend)))
               (mapcar (lambda (model)
                         (let ((name (vox-backend-name connection)))
                           (cons (format "%S / %S" name model) (list name model))))
                       (or (vox-backend-models connection) '(nil))))) directory))
         (selected (cdr (assoc (completing-read "Vox TTS: " choices nil t) choices))))
    (unless selected (user-error "No Vox TTS choice selected"))
    (unless (and (= revision vox-tts--selection-revision)
                 (equal previous vox-tts-selection)
                 (equal directory (vox-tts--directory)))
      (user-error "Vox TTS configuration changed during selection"))
    (setq vox-tts-selection (vox--backend-copy-tree selected))
    (cl-incf vox-tts--selection-revision)
    vox-tts-selection))

(cl-defstruct (vox-tts--session (:constructor vox-tts--make-session))
  generation state processes timer player limit response-limit playback-timeout
  player-process playback-timer pump-timer busy source-done eof
  pending-limit (pending-bytes 0) (audio-bytes 0) (chunk-count 0) chunks tail
  pcm-started
  input-ready input-closed input-sent-finish input-busy input-timer
  input-send input-finish source-close text-limit (text-chars 0) text-nonempty
  text-queue text-tail (text-count 0))
(defvar vox-tts--active nil)
(defvar vox-tts--generation 0)

(defun vox-tts--live-p (session)
  "Whether SESSION still owns speech output."
  (and (eq session vox-tts--active)
       (= (vox-tts--session-generation session) vox-tts--generation)))

(defun vox-tts--dispose (process)
  "Silently dispose PROCESS, including pipes already at EOF."
  (when (processp process)
    (set-process-filter process #'ignore)
    (set-process-sentinel process #'ignore)
    (ignore-errors (delete-process process))))

(defun vox-tts--end (session state)
  "End SESSION in STATE and release all resources without touching a successor."
  (when (eq session vox-tts--active) (setq vox-tts--active nil))
  (setf (vox-tts--session-state session) state)
  (dolist (timer (list (vox-tts--session-timer session)
                       (vox-tts--session-playback-timer session)
                       (vox-tts--session-pump-timer session)
                       (vox-tts--session-input-timer session)))
    (when (timerp timer) (cancel-timer timer)))
  (mapc #'vox-tts--dispose (vox-tts--session-processes session))
  (setf (vox-tts--session-processes session) nil
        (vox-tts--session-timer session) nil
        (vox-tts--session-playback-timer session) nil
        (vox-tts--session-pump-timer session) nil
        (vox-tts--session-player-process session) nil
        (vox-tts--session-chunks session) nil
        (vox-tts--session-tail session) nil
        (vox-tts--session-pending-bytes session) 0
        (vox-tts--session-chunk-count session) 0
        (vox-tts--session-input-timer session) nil
        (vox-tts--session-text-queue session) nil
        (vox-tts--session-text-tail session) nil
        (vox-tts--session-text-count session) 0
        (vox-tts--session-input-send session) nil
        (vox-tts--session-input-finish session) nil)
  ;; Release local audio before a best-effort provider cancellation can yield.
  (let ((close (vox-tts--session-source-close session)))
    (setf (vox-tts--session-source-close session) nil)
    (when close (funcall close))))

(defun vox-tts-stop ()
  "Immediately cancel synthesis and playback; discard pending audio."
  (when vox-tts--active (vox-tts--end vox-tts--active 'cancelled)))

(defun vox-tts--fail (session)
  "Fail a live SESSION with a fixed message, never provider diagnostics."
  (when (vox-tts--live-p session)
    (vox-tts--end session 'error)
    (message "Vox TTS failed; check configuration, limits and service availability")))

(defun vox-tts--argv (command)
  "Validate and copy executable argv COMMAND without invoking a shell."
  (unless (and (consp command) (proper-list-p command)
               (cl-every (lambda (s) (and (stringp s) (not (string-match-p "\0" s)))) command)
               (executable-find (car command)))
    (user-error "Configure Vox TTS with an executable argv list"))
  (mapcar #'copy-sequence command))

(defun vox-tts--process (session command filter sentinel)
  "Start COMMAND owned by SESSION with FILTER and SENTINEL, discarding stderr."
  (let ((stderr (make-pipe-process :name "vox-tts-stderr" :buffer nil :noquery t
                                   :coding 'binary :filter #'ignore :sentinel #'ignore))
        process)
    (if (not (vox-tts--live-p session)) (vox-tts--dispose stderr)
      (push stderr (vox-tts--session-processes session))
      (setq process
            (make-process :name "vox-tts" :buffer nil :command command
                          :connection-type 'pipe :coding 'binary :noquery t
                          :stderr stderr :filter filter :sentinel sentinel))
      (if (vox-tts--live-p session)
          (push process (vox-tts--session-processes session))
        (vox-tts--dispose process)))
    process))

(defun vox-tts--schedule (session)
  "Schedule one bounded player write for SESSION outside receive callbacks."
  (when (and (vox-tts--live-p session)
             (not (vox-tts--session-busy session))
             (not (vox-tts--session-pump-timer session)))
    (setf (vox-tts--session-pump-timer session)
          (run-at-time 0.01 nil #'vox-tts--pump session))))

(defun vox-tts--play (session bytes)
  "Queue encoded BYTES in arrival order while SESSION owns speech output."
  (when (vox-tts--live-p session)
    (unless (and (stringp bytes) (not (multibyte-string-p bytes))
                 (not (vox-tts--session-source-done session)))
      (error "Invalid TTS audio"))
    (unless (zerop (length bytes))
      (when (or (> (+ (length bytes) (vox-tts--session-audio-bytes session))
                   (vox-tts--session-limit session))
                (> (+ (length bytes) (vox-tts--session-pending-bytes session))
                   (vox-tts--session-pending-limit session))
                (>= (vox-tts--session-chunk-count session) 4096))
        (error "TTS audio queue limit exceeded"))
      (let ((cell (list bytes)))
        (if (vox-tts--session-tail session)
            (setcdr (vox-tts--session-tail session) cell)
          (setf (vox-tts--session-chunks session) cell))
        (setf (vox-tts--session-tail session) cell))
      (cl-incf (vox-tts--session-audio-bytes session) (length bytes))
      (cl-incf (vox-tts--session-pending-bytes session) (length bytes))
      (cl-incf (vox-tts--session-chunk-count session))
      (vox-tts--schedule session))))

(defun vox-tts--source-finished (session)
  "Mark successful synthesis for SESSION; drain pending bytes before EOF."
  (when (vox-tts--live-p session)
    (unless (> (vox-tts--session-audio-bytes session) 0)
      (error "Empty TTS stream"))
    (setf (vox-tts--session-source-done session) t)
    (when (timerp (vox-tts--session-timer session))
      (cancel-timer (vox-tts--session-timer session)))
    (setf (vox-tts--session-timer session) nil)
    (vox-tts--schedule session)))

(defun vox-tts--pump (session)
  "Send at most 4096 bytes to SESSION's one player, without nested writes."
  (when (and (vox-tts--live-p session) (not (vox-tts--session-busy session)))
    (setf (vox-tts--session-pump-timer session) nil
          (vox-tts--session-busy session) t)
    (unwind-protect
        (condition-case nil
            (progn
              (when (and (vox-tts--session-chunks session)
                         (not (vox-tts--session-player-process session)))
                (setf (vox-tts--session-state session) 'playing
                      (vox-tts--session-playback-timer session)
                      (run-at-time (vox-tts--session-playback-timeout session) nil
                                   #'vox-tts--fail session))
                (let ((process
                       (vox-tts--process
                        session (vox-tts--session-player session) #'ignore
                        (lambda (proc _event)
                          (when (and (vox-tts--live-p session)
                                     (memq (process-status proc) '(exit signal failed)))
                            (if (and (vox-tts--session-eof session)
                                     (eq (process-status proc) 'exit)
                                     (= (process-exit-status proc) 0))
                                (vox-tts--end session 'completed)
                              (vox-tts--fail session)))))))
                  (when (vox-tts--live-p session)
                    (setf (vox-tts--session-player-process session) process))))
              (when (and (vox-tts--live-p session) (vox-tts--session-chunks session))
                (let* ((chunk (car (vox-tts--session-chunks session)))
                       (size (min 4096 (length chunk)))
                       (whole (= size (length chunk))))
                  ;; Remove before a yielding send.  Keep its byte/count charge
                  ;; until the send returns, so reentry cannot bypass bounds.
                  (if whole
                      (progn
                        (pop (vox-tts--session-chunks session))
                        (unless (vox-tts--session-chunks session)
                          (setf (vox-tts--session-tail session) nil)))
                    (setcar (vox-tts--session-chunks session) (substring chunk size)))
                  (process-send-string (vox-tts--session-player-process session)
                                       (substring chunk 0 size))
                  (when (vox-tts--live-p session)
                    (cl-decf (vox-tts--session-pending-bytes session) size)
                    (when whole (cl-decf (vox-tts--session-chunk-count session))))))
              (when (and (vox-tts--live-p session)
                         (vox-tts--session-source-done session)
                         (not (vox-tts--session-chunks session))
                         (not (vox-tts--session-eof session)))
                (setf (vox-tts--session-eof session) t)
                (process-send-eof (vox-tts--session-player-process session))))
          (quit (vox-tts--end session 'cancelled) (signal 'quit nil))
          (error (vox-tts--fail session)))
      (setf (vox-tts--session-busy session) nil)
      (when (and (vox-tts--live-p session) (vox-tts--session-chunks session))
        (vox-tts--schedule session)))))

(defun vox-tts--input-schedule (session)
  "Schedule one text write for SESSION without nested sends."
  (when (and (vox-tts--live-p session) (vox-tts--session-input-ready session)
             (not (vox-tts--session-input-busy session))
             (not (vox-tts--session-input-timer session)))
    (setf (vox-tts--session-input-timer session)
          (run-at-time 0.01 nil #'vox-tts--input-pump session))))

(defun vox-tts--input-pump (session)
  "Send one bounded text fragment for SESSION, then finish after queue drain."
  (when (and (vox-tts--live-p session) (vox-tts--session-input-ready session)
             (not (vox-tts--session-input-busy session)))
    (setf (vox-tts--session-input-timer session) nil
          (vox-tts--session-input-busy session) t)
    (unwind-protect
        (condition-case nil
            (progn
              (when (vox-tts--session-text-queue session)
                (let ((text (pop (vox-tts--session-text-queue session))))
                  (unless (vox-tts--session-text-queue session)
                    (setf (vox-tts--session-text-tail session) nil))
                  (funcall (vox-tts--session-input-send session) text)
                  (when (vox-tts--live-p session)
                    (cl-decf (vox-tts--session-text-count session)))))
              (when (and (vox-tts--live-p session)
                         (vox-tts--session-input-closed session)
                         (not (vox-tts--session-text-queue session))
                         (not (vox-tts--session-input-sent-finish session)))
                ;; Set before yielding: an authoritative reply may arrive inside send.
                (setf (vox-tts--session-input-sent-finish session) t)
                (funcall (vox-tts--session-input-finish session))))
          (quit (vox-tts--end session 'cancelled) (signal 'quit nil))
          (error (vox-tts--fail session)))
      (setf (vox-tts--session-input-busy session) nil)
      (when (and (vox-tts--live-p session) (vox-tts--session-text-queue session))
        (vox-tts--input-schedule session)))))

(defun vox-tts-send (session text)
  "Append TEXT to captured incremental SESSION, preserving whitespace and order.
Accept text before provider readiness.  Reject stale or finished handles.
A character or queued-fragment overflow fails the session; never drop text."
  (unless (and (vox-tts--session-p session) (vox-tts--live-p session)
               (vox-tts--session-input-send session)
               (not (vox-tts--session-input-closed session)))
    (user-error "TTS input session is inactive, unsupported or already finished"))
  (unless (stringp text) (user-error "TTS text must be a string"))
  (let ((count (ceiling (length text) 256)))
    (when (or (> (+ (length text) (vox-tts--session-text-chars session))
                 (vox-tts--session-text-limit session))
              (> (+ count (vox-tts--session-text-count session)) 4096))
      (vox-tts--fail session)
      (user-error "TTS text stream exceeds configured limits"))
    (cl-incf (vox-tts--session-text-chars session) (length text))
    (unless (string-empty-p (string-trim text))
      (setf (vox-tts--session-text-nonempty session) t))
    (dotimes (index count)
      (let ((cell (list (substring-no-properties text (* index 256)
                                                (min (length text) (* (1+ index) 256))))))
        (if (vox-tts--session-text-tail session)
            (setcdr (vox-tts--session-text-tail session) cell)
          (setf (vox-tts--session-text-queue session) cell))
        (setf (vox-tts--session-text-tail session) cell)
        (cl-incf (vox-tts--session-text-count session))))
    (vox-tts--input-schedule session))
  session)

(defun vox-tts-finish (session)
  "Close SESSION's text input, keeping synthesis and playback running."
  (unless (and (vox-tts--session-p session) (vox-tts--live-p session)
               (vox-tts--session-input-finish session))
    (user-error "TTS input session is inactive or unsupported"))
  (unless (vox-tts--session-text-nonempty session)
    (user-error "TTS input contains no non-whitespace text"))
  (setf (vox-tts--session-input-closed session) t)
  (vox-tts--input-schedule session)
  session)

(defun vox-tts--cli (session command)
  "Open COMMAND's stdin for incremental text and stream stdout into SESSION."
  (let ((process
         (vox-tts--process
          session command
          (lambda (_process bytes)
            (condition-case nil (vox-tts--play session bytes)
              (error (vox-tts--fail session))))
          (lambda (proc _event)
            (when (and (vox-tts--live-p session)
                       (memq (process-status proc) '(exit signal failed)))
              (condition-case nil
                  (if (and (vox-tts--session-input-sent-finish session)
                           (eq (process-status proc) 'exit) (= (process-exit-status proc) 0))
                      (vox-tts--source-finished session)
                    (vox-tts--fail session))
                (error (vox-tts--fail session))))))))
    (when (vox-tts--live-p session)
      (setf (vox-tts--session-input-ready session) t
            (vox-tts--session-input-send session)
            (lambda (text) (process-send-string process (encode-coding-string text 'utf-8 t)))
            (vox-tts--session-input-finish session)
            (lambda () (process-send-eof process))))))

(defconst vox-tts--pcm-wave-header
  (concat "RIFF" (unibyte-string 255 255 255 255) "WAVEfmt "
          (unibyte-string 16 0 0 0 1 0 1 0 192 93 0 0 128 187 0 0 2 0 16 0)
          "data" (unibyte-string 255 255 255 255))
  "Streaming WAV header for Qwen's signed 16-bit little-endian mono 24 kHz PCM.")

(defun vox-tts--request-id ()
  "Return a UUID-shaped request identifier containing no user data."
  (let ((hex (md5 (format "%s-%s-%s" (float-time) (emacs-pid) (random)))))
    (format "%s-%s-4%s-8%s-%s" (substring hex 0 8) (substring hex 8 12)
            (substring hex 13 16) (substring hex 17 20) (substring hex 20 32))))

(defun vox-tts--start (text incremental backend model)
  "Start TEXT or open INCREMENTAL input using captured BACKEND and MODEL."
  (when (or vox--reloading vox--starting vox--active-session)
    (user-error "Finish Vox recording, startup or reload before speaking"))
  (let ((reason (vox-tts--limits-error)))
    (when reason (user-error "%s" reason)))
  (unless (or incremental
              (and (stringp text) (not (string-empty-p (string-trim text)))
                   (<= (length text) vox-tts-max-text-chars)))
    (user-error "Vox TTS text is empty or exceeds the configured limit"))
  (when (and model (not backend)) (user-error "TTS model requires an explicit backend"))
  (let* ((resolved (cond (backend (let ((copy (vox-tts--snapshot backend)))
                                    (cons copy (vox--backend-model copy model))))
                         (t (vox-tts--resolve))))
         (selected (car resolved))
         (player (vox-tts--argv vox-tts-player-command))
         (command (when (eq (vox-backend-type selected) 'tts-cli)
                    (vox-tts--argv (vox-backend-command selected))))
         (text (when text (substring-no-properties text))))
    (vox-tts-stop)
    (let ((session (vox-tts--make-session
                    :generation (cl-incf vox-tts--generation) :state 'synthesizing
                    :player player :limit vox-tts-max-audio-bytes
                    :response-limit vox-tts-max-response-bytes
                    :pending-limit vox-tts-max-pending-bytes :text-limit vox-tts-max-text-chars
                    :playback-timeout vox-tts-playback-timeout)))
      (setq vox-tts--active session)
      (setf (vox-tts--session-timer session)
            (run-at-time vox-tts-timeout nil #'vox-tts--fail session))
      (condition-case nil
          (progn
            (pcase (vox-backend-type selected)
              ('tts-cli (vox-tts--cli session command))
              ('tts-doubao-ws
               (require 'vox-tts-doubao)
               (vox-tts-doubao-open session selected))
              ('tts-qwen-realtime
               (require 'vox-tts-qwen)
               (vox-tts-qwen-open session selected (cdr resolved)))
              (_ (error "Unsupported TTS protocol")))
            (when (and (not incremental) (vox-tts--live-p session))
              (vox-tts-send session text)
              (vox-tts-finish session)))
        (quit (vox-tts--end session 'cancelled) (signal 'quit nil))
        (error (vox-tts--fail session)))
      session)))

(defun vox-tts-open (&optional backend model)
  "Open an incremental text session using optional BACKEND and MODEL.
Feed it with `vox-tts-send', then `vox-tts-finish'.
Stop cancels both directions."
  (vox-tts--start nil t backend model))

(defun vox-tts-start (text &optional backend model)
  "Speak complete TEXT using optional BACKEND and MODEL.
Streaming-input protocols use incremental input with bounded chunks."
  (vox-tts--start text nil backend model))

(provide 'vox-tts)
;;; vox-tts.el ends here
