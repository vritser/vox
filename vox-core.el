;;; vox-core.el --- Session lifecycle and transcript reconciliation -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; No provider-specific branches or buffer insertion belong in this module.
;;; Code:
(require 'vox-backend)
(require 'vox-activity)
(require 'vox-log)

(defcustom vox-stop-mode 'silence
  "How recordings stop: `silence' for short phrases or `manual'.
Silence detection requires Vox-owned PCM capture.  Self-recording backends
such as CLI use manual stopping.  Changes apply to the next session."
  :type '(choice (const :tag "Short phrase: stop after silence" silence)
                 (const :tag "Continuous recording: stop manually" manual))
  :group 'vox)
(defcustom vox-silence-seconds 1.2
  "Quiet PCM seconds before graceful stop, between 0.2 and 10.
Detection starts only after 100 ms of consecutive above-threshold audio.
This is an energy heuristic, not speech classification."
  :type 'number :group 'vox)
(defcustom vox-silence-threshold 0.01
  "Normalized RMS threshold for quiet audio, greater than zero and at most 1.
Lower this for quiet speech; raise it for background noise.  A higher
threshold can mistake soft speech for silence.  Settings are captured at start."
  :type 'number :group 'vox)

(defcustom vox-audio-chunk-ms 100 "Default PCM frame duration in milliseconds."
  :type '(choice (const 100) (const 200)) :group 'vox)
(defcustom vox-audio-backlog-seconds 2 "Maximum queued PCM, in seconds (0.5 to 5)."
  :type 'number :group 'vox)
(defcustom vox-connect-timeout 20 "Seconds allowed for backend readiness."
  :type 'number :group 'vox)
(defcustom vox-stop-timeout 15 "Seconds allowed to drain and receive completion."
  :type 'number :group 'vox)
(defcustom vox-max-session-seconds 300 "Recording duration before graceful stop."
  :type 'number :group 'vox)
(defcustom vox-preview-interval 0.1 "Minimum interval between preview notifications."
  :type 'number :group 'vox)
(defcustom vox-max-transcript-chars 200000 "Maximum live hypothesis characters."
  :type 'integer :group 'vox)
(defcustom vox-max-segments 1024
  "Maximum distinct segments retained in a live hypothesis."
  :type 'integer :group 'vox)
(defcustom vox-max-segment-id-bytes 1024
  "Maximum bytes in a single segment identifier."
  :type 'integer :group 'vox)
(defcustom vox-max-segment-id-total-bytes 65536
  "Maximum total identifier bytes across distinct retained segments."
  :type 'integer :group 'vox)

(cl-defstruct (vox-session (:constructor vox--make-session))
  id generation backend methods backend-state state websocket recorder
  audio-pending audio-timer audio-pumping audio-ended chunk-bytes queue-limit stop-mode activity
  target-buffer target-marker sink segments snapshot snapshot-revision snapshot-final
  (segment-count 0) (segment-id-bytes 0) (segment-text-chars 0)
  preview-text final-text stop-requested finish-sent finish-dispatched committed cleaned
  stop-timer connect-timer duration-timer preview-timer kill-hook
  last-error statistics)

(defvar vox--active-session nil)
(defvar vox--last-session nil)
(defvar vox--generation 0)
(defvar vox--reloading nil
  "Non-nil while source reload excludes new sessions and device discovery.")
(defvar vox--starting nil
  "Non-nil while startup may hold definitions or configuration across callbacks.")

(declare-function vox-audio-start "vox-audio" (session on-bytes on-ended on-error))
(declare-function vox-audio-stop "vox-audio" (session))
(declare-function vox-audio-cancel "vox-audio" (session))

(defun vox-current-session () "Return the active session, or nil." vox--active-session)

(defun vox-session-live-p (session generation)
  "Whether SESSION still owns callbacks captured with GENERATION."
  (and (eq session vox--active-session)
       (= generation (vox-session-generation session))
       (not (memq (vox-session-state session) '(completed cancelled error)))))

(defun vox--live-p (session)
  "Return non-nil if SESSION is live."
  (vox-session-live-p session (vox-session-generation session)))

(defun vox--require-live (session generation)
  "Signal an error unless SESSION still owns GENERATION.
Adapters call this before and after user callbacks, because endpoint approval
and key functions may reentrantly cancel the session."
  (unless (vox-session-live-p session generation)
    (error "Vox session is no longer active")))

(defun vox--notify (session key &rest args)
  "Notify SESSION sink KEY with ARGS.  Never print sink exceptions."
  (when-let* ((fn (plist-get (vox-session-sink session) key)))
    (apply fn session args)))

(defun vox--method (session key &rest args)
  "Call SESSION method KEY with ARGS."
  (when-let* ((fn (plist-get (vox-session-methods session) key)))
    (apply fn session args)))

(defun vox--state (session state)
  "Transition SESSION to STATE, enforcing the nonterminal graph."
  (let ((old (vox-session-state session)))
    (unless (or (memq state '(error cancelled))
                (memq state (cdr (assq old '((connecting recording)
                                            (recording draining)
                                            (draining finalizing)
                                            (finalizing completed))))))
      (error "Invalid Vox state transition"))
    (setf (vox-session-state session) state)
    (vox-log-event (vox-session-generation session) 'state :state state)
    (vox--notify session :on-state state)))

(defun vox--cancel-timer (timer)
  "Cancel TIMER when it is a timer."
  (when (timerp timer) (cancel-timer timer)))

(defun vox--private-pipe-process (name filter)
  "Create pipe process NAME with FILTER and no buffer for its output.
Stderr pipes are read only by a discarding filter.  Emacs 30 and older use
the process name as the buffer when `:buffer' is nil, so attach a dedicated
buffer, detach it, and reclaim it."
  (let ((buffer (generate-new-buffer " *vox-private-pipe*")))
    (unwind-protect
        (let ((process (make-pipe-process
                        :name name :buffer buffer :coding 'binary
                        :noquery t :filter filter :sentinel #'ignore)))
          (set-process-buffer process nil)
          process)
      (kill-buffer buffer))))

(defun vox--cleanup (session)
  "Release SESSION resources exactly once; terminal state precedes teardown."
  (unless (vox-session-cleaned session)
    (setf (vox-session-cleaned session) t)
    (dolist (timer (list (vox-session-audio-timer session)
                         (vox-session-preview-timer session)
                         (vox-session-connect-timer session)
                         (vox-session-duration-timer session)
                         (vox-session-stop-timer session)))
      (vox--cancel-timer timer))
    (when (fboundp 'vox-audio-cancel)
      (ignore-errors (vox-audio-cancel session)))
    (ignore-errors (vox--method session :close))
    (when (buffer-live-p (vox-session-target-buffer session))
      (with-current-buffer (vox-session-target-buffer session)
        (remove-hook 'kill-buffer-hook (vox-session-kill-hook session) t)))
    (when (markerp (vox-session-target-marker session))
      (set-marker (vox-session-target-marker session) nil))
    (setf (vox-session-audio-pending session) (unibyte-string)
          (vox-session-activity session) nil
          (vox-session-audio-timer session) nil
          (vox-session-preview-timer session) nil
          (vox-session-connect-timer session) nil
          (vox-session-duration-timer session) nil
          (vox-session-stop-timer session) nil
          (vox-session-backend-state session) nil)
    (vox-log-event (vox-session-generation session) 'cleanup
                   :state (vox-session-state session) :queued 0
                   :received (or (plist-get (vox-session-statistics session) :received-bytes) 0)
                   :sent (or (plist-get (vox-session-statistics session) :sent-bytes) 0)
                   :queue-peak (or (plist-get (vox-session-statistics session) :queue-peak) 0)
                   :tail-risk (eq (plist-get (vox-session-statistics session) :audio-tail-risk) t))
    (when (eq session vox--active-session) (setq vox--active-session nil))
    (setq vox--last-session session)))

(defun vox-core-fail (session message &optional reason)
  "Fail SESSION with sanitized MESSAGE, without committing partial text.
REASON is an optional fixed event-log category; MESSAGE is never logged."
  (when (vox--live-p session)
    (setf (vox-session-last-error session) message
          (vox-session-state session) 'error)
    (vox-log-event (vox-session-generation session) 'error :state 'error :reason reason)
    (unwind-protect
        (progn (ignore-errors (vox--notify session :on-state 'error))
               (ignore-errors (vox--notify session :on-error message)))
      (ignore-errors (vox--method session :cancel))
      (vox--cleanup session))))

(defun vox--guard (session generation function)
  "Wrap FUNCTION in SESSION GENERATION and error guards."
  (lambda (&rest args)
    (if (vox-session-live-p session generation)
        (condition-case nil (apply function args)
          (error (vox-core-fail session "Vox callback failed; session safely stopped" 'callback)))
      (vox-log-event generation 'stale-callback :state (vox-session-state session)))))

(defun vox-core-start (backend sink &optional buffer marker model)
  "Start BACKEND with SINK, capturing BUFFER and MARKER as output ownership.
MODEL omitted or nil selects the backend's first model, independently of
`vox-selection'.  An explicit symbol/string selects an allowed model.
Backend configuration and model are captured before callbacks or connection.
A nil SINK is supported for headless callers.  MARKER is copied and follows
text typed at the original insertion point.  Return the new session."
  (when vox--reloading (user-error "Wait for Vox reload to finish before starting"))
  (when vox--active-session (user-error "A Vox session is already active"))
  (unless (and (memq vox-stop-mode '(silence manual))
               (cl-every (lambda (limit) (and (integerp limit) (> limit 0)))
                         (list vox-max-transcript-chars vox-max-segments
                               vox-max-segment-id-bytes vox-max-segment-id-total-bytes))
               (numberp vox-audio-backlog-seconds)
               (<= 0.5 vox-audio-backlog-seconds 5)
               (> vox-connect-timeout 0) (> vox-stop-timeout 0)
               (> vox-max-session-seconds 0) (> vox-preview-interval 0))
    (user-error "Invalid Vox limits"))
  (let* ((vox--starting t)
         (target (or buffer (current-buffer)))
         ;; Capture output ownership before a callable backend option runs.
         (position (if marker marker (with-current-buffer target (point))))
         (methods (copy-sequence (vox-backend-methods backend model)))
         (stop-mode (if (and (eq vox-stop-mode 'silence)
                             (plist-get methods :needs-external-audio))
                        'silence 'manual))
         (activity (when (eq stop-mode 'silence)
                     (vox-activity-create vox-silence-threshold vox-silence-seconds)))
         (chunk-ms (or (plist-get methods :chunk-ms) vox-audio-chunk-ms))
         (chunk-ms (if (functionp chunk-ms) (funcall chunk-ms) chunk-ms))
         ;; A backend option can run user code and start another session.
         (_ (when vox--active-session (user-error "A Vox session is already active")))
         (generation (cl-incf vox--generation))
         (session (vox--make-session
                   :id (format "vox-%s-%d" (format-time-string "%s%N") generation)
                   :generation generation
                   :backend (or (plist-get methods :configuration) backend)
                   :methods methods
                   :stop-mode stop-mode :activity activity
                   :state 'connecting :sink sink :target-buffer target
                   :target-marker (with-current-buffer target (copy-marker position t))
                   :audio-pending (unibyte-string) :chunk-bytes (* 32 chunk-ms)
                   :queue-limit (floor (* 32000 vox-audio-backlog-seconds))
                   :preview-text ""
                   :statistics (list :received-bytes 0 :sent-bytes 0 :queue-peak 0))))
    (unless (memq chunk-ms '(100 200)) (user-error "Vox frames must be 100 or 200 ms"))
    (setq vox--active-session session)
    (vox-log-event generation 'start :state 'connecting :stop-mode stop-mode
                   :backend (let ((configuration (plist-get methods :configuration)))
                              (if (vox-backend-p configuration) (vox-backend-type configuration)
                                (if (eq backend 'cli) 'cli 'other))))
    (setf (vox-session-kill-hook session)
          (vox--guard session generation (lambda () (vox-core-cancel session))))
    (with-current-buffer target
      (add-hook 'kill-buffer-hook (vox-session-kill-hook session) nil t))
    (setf (vox-session-connect-timer session)
          (run-at-time vox-connect-timeout nil
                       (vox--guard session generation
                                   (lambda () (vox-core-fail session "Backend readiness timed out" 'timeout)))))
    (condition-case nil
        (progn
          (vox--notify session :on-state 'connecting)
          (when (vox--live-p session)
            (vox--method
             session :connect
             (vox--guard session generation (lambda () (vox--ready session)))
             (vox--guard session generation (lambda (event) (vox-core-event session event)))
             (vox--guard session generation (lambda (message) (vox-core-fail session message 'provider))))))
      (quit (vox-core-cancel session) (signal 'quit nil))
      (error (vox-core-fail session "Backend setup failed; check credentials, endpoint and dependencies")))
    session))

(defun vox--ready (session)
  "Start recording only after SESSION backend declares readiness."
  (when (eq (vox-session-state session) 'connecting)
    (vox-log-event (vox-session-generation session) 'ready)
    (vox--cancel-timer (vox-session-connect-timer session))
    (setf (vox-session-connect-timer session) nil)
    (vox--state session 'recording)
    (when (and (vox--live-p session) (eq (vox-session-state session) 'recording))
      (let ((generation (vox-session-generation session)))
        (setf (vox-session-duration-timer session)
              (run-at-time vox-max-session-seconds nil
                           (vox--guard session generation
                                       (lambda ()
                                         (when (eq (vox-session-state session) 'recording)
                                           (setf (vox-session-statistics session)
                                                 (plist-put (vox-session-statistics session)
                                                            :stop-reason 'duration))
                                           (vox-core-stop session))))))
        (when (plist-get (vox-session-methods session) :needs-external-audio)
          (setf (vox-session-recorder session)
                (vox-audio-start
                 session
                 (vox--guard session generation (lambda (bytes) (vox-core-audio session bytes)))
                 (vox--guard session generation (lambda () (vox-core-audio-ended session)))
                 (vox--guard session generation (lambda (message) (vox-core-fail session message 'recorder))))))))))

(defun vox-core-stop (&optional session)
  "Gracefully stop SESSION, or the active session, idempotently."
  (setq session (or session vox--active-session))
  (when (and session (vox--live-p session))
    (pcase (vox-session-state session)
      ('connecting
       (vox-log-event (vox-session-generation session) 'stop-request :reason 'connecting)
       (vox-core-cancel session))
      ('recording
       (condition-case nil
           (progn
             (setf (vox-session-stop-requested session) t)
             (vox-log-event (vox-session-generation session) 'stop-request
                            :reason (or (plist-get (vox-session-statistics session) :stop-reason)
                                        'manual)
                            :received (or (plist-get (vox-session-statistics session) :received-bytes) 0)
                            :sent (plist-get (vox-session-statistics session) :sent-bytes)
                            :queued (length (vox-session-audio-pending session)))
             (vox--state session 'draining)
             (when (vox--live-p session)
               (setf (vox-session-stop-timer session)
                     (run-at-time vox-stop-timeout nil
                                  (vox--guard session (vox-session-generation session)
                                              (lambda () (vox-core-fail session "Stop timed out; final audio may be incomplete" 'timeout)))))
               (if (plist-get (vox-session-methods session) :needs-external-audio)
                   (vox-audio-stop session)
                 (vox-core-audio-ended session))))
         (error (vox-core-fail session "Could not gracefully stop recording")))))))

(defun vox-core-cancel (&optional session)
  "Discard SESSION or active recording, without a final commit."
  (setq session (or session vox--active-session))
  (when (and session (vox--live-p session))
    (setf (vox-session-state session) 'cancelled
          (vox-session-segments session) nil
          (vox-session-segment-count session) 0
          (vox-session-segment-id-bytes session) 0
          (vox-session-segment-text-chars session) 0
          (vox-session-snapshot session) nil
          (vox-session-preview-text session) ""
          (vox-session-final-text session) nil)
    (vox-log-event (vox-session-generation session) 'cancel :state 'cancelled
                   :queued (length (vox-session-audio-pending session)))
    (unwind-protect
        (progn (ignore-errors (vox--notify session :on-state 'cancelled))
               (ignore-errors (vox--method session :cancel)))
      (vox--cleanup session))))

(defun vox-core-audio (session bytes)
  "Queue unibyte PCM BYTES for SESSION, then perform bounded send work."
  (when (and (vox--live-p session)
             (memq (vox-session-state session) '(recording draining))
             (not (vox-session-audio-ended session)))
    (unless (and (stringp bytes) (not (multibyte-string-p bytes)))
      (error "PCM must be unibyte"))
    (let* ((size (+ (length bytes) (length (vox-session-audio-pending session))))
           (previous (or (plist-get (vox-session-statistics session) :received-bytes) 0))
           (received (+ previous (length bytes))))
      (setf (vox-session-statistics session)
            (plist-put (vox-session-statistics session) :received-bytes received))
      (if (> size (vox-session-queue-limit session))
          (vox-core-fail session "PCM backlog limit exceeded; audio was not silently dropped" 'backlog)
        (setf (vox-session-audio-pending session) (concat (vox-session-audio-pending session) bytes)
              (vox-session-statistics session)
              (plist-put (vox-session-statistics session) :queue-peak
                         (max size (plist-get (vox-session-statistics session) :queue-peak))))
        ;; Log the first block and roughly once per second of PCM, not every read.
        (when (or (zerop previous) (/= (/ previous 32000) (/ received 32000)))
          (vox-log-event (vox-session-generation session) 'audio-receive
                         :bytes (length bytes) :received received :queued size))
        (when (and (eq (vox-session-state session) 'recording)
                   (vox-session-activity session))
          (vox-activity-feed (vox-session-activity session) bytes))
        (vox--pump session)
        ;; Sending can reenter and deliver newer speech; never reuse an old verdict.
        (when (and (vox--live-p session)
                   (eq (vox-session-state session) 'recording)
                   (vox-session-activity session)
                   (vox-activity-stop-p (vox-session-activity session)))
          (setf (vox-session-statistics session)
                (plist-put (vox-session-statistics session) :stop-reason 'silence))
          (vox-core-stop session))))))

(defun vox-core-audio-ended (session)
  "Observe recorder exit for SESSION before sending its final PCM remainder."
  (when (and (vox--live-p session) (not (vox-session-audio-ended session)))
    (if (not (eq (vox-session-state session) 'draining))
        (vox-core-fail session "Recorder exited unexpectedly; check input device and microphone permission" 'recorder)
      (setf (vox-session-audio-ended session) t)
      (vox--pump session))))

(defun vox--pump (session)
  "Send at most eight full frames and a final tail for SESSION.
Schedule remaining full frames for a later tick.
Reentrant capture only queues bytes; this invocation owns sends and finish."
  (when (and (vox--live-p session) (not (vox-session-audio-pumping session)))
    ;; Socket writes can dispatch recorder callbacks and timers before returning.
    (setf (vox-session-audio-pumping session) t)
    (unwind-protect
        (condition-case nil
            (let ((budget 8) (frame (vox-session-chunk-bytes session)))
              (while (and (> budget 0) (vox--live-p session)
                          (>= (length (vox-session-audio-pending session)) frame))
                (let ((bytes (substring (vox-session-audio-pending session) 0 frame)))
                  (setf (vox-session-audio-pending session)
                        (substring (vox-session-audio-pending session) frame))
                  (vox--send-pcm session bytes))
                (cl-decf budget))
              (when (vox--live-p session)
                (if (>= (length (vox-session-audio-pending session)) frame)
                    (unless (vox-session-audio-timer session)
                      (setf (vox-session-audio-timer session)
                            (run-at-time
                             0.01 nil
                             (vox--guard session (vox-session-generation session)
                                         (lambda ()
                                           (setf (vox-session-audio-timer session) nil)
                                           (vox--pump session))))))
                  (when (and (vox-session-audio-ended session)
                             (not (vox-session-finish-sent session)))
                    (let ((rest (vox-session-audio-pending session)))
                      (if (cl-oddp (length rest))
                          (vox-core-fail session
                                          "Recorder ended with a truncated PCM sample"
                                          'recorder)
                        (setf (vox-session-audio-pending session) (unibyte-string))
                        (when (> (length rest) 0) (vox--send-pcm session rest))
                        (when (vox--live-p session)
                          ;; The backlog timer is no longer needed once the
                          ;; tail is drained; leaving it armed can outlive
                          ;; finalization and report a bogus stale callback.
                          (vox--cancel-timer (vox-session-audio-timer session))
                          (setf (vox-session-audio-timer session) nil
                                (vox-session-finish-sent session) t)
                          (vox--state session 'finalizing)
                          (when (vox--live-p session)
                            (setf (vox-session-finish-dispatched session) t)
                            (vox-log-event (vox-session-generation session) 'finish-dispatch
                                           :queued (length (vox-session-audio-pending session))
                                           :sent (plist-get (vox-session-statistics session) :sent-bytes))
                            (vox--method session :finish)))))))))
          (quit (vox-core-cancel session) (signal 'quit nil))
          (error (vox-core-fail session "Audio transmission failed" 'send)))
      (setf (vox-session-audio-pumping session) nil))))

(defun vox--send-pcm (session bytes)
  "Send BYTES, recording accepted bytes (not network delivery) for SESSION."
  (vox--method session :send-pcm bytes)
  (let* ((previous (plist-get (vox-session-statistics session) :sent-bytes))
         (sent (+ (length bytes) previous)))
    (setf (vox-session-statistics session)
          (plist-put (vox-session-statistics session) :sent-bytes sent))
    (when (or (zerop previous) (/= (/ previous 32000) (/ sent 32000))
              (not (vox--live-p session)))
      (vox-log-event (vox-session-generation session) 'audio-send
                     :bytes (length bytes) :sent sent
                     :queued (length (vox-session-audio-pending session))
                     :state (vox-session-state session)))))

(defun vox-session-text (session &optional confirmed-only)
  "Build SESSION text in first-seen order; optionally use CONFIRMED-ONLY."
  (if (stringp (vox-session-snapshot session))
      (if (or (not confirmed-only) (vox-session-snapshot-final session))
          (vox-session-snapshot session) "")
    (mapconcat (lambda (entry)
                 (if (or (not confirmed-only) (plist-get (cdr entry) :final))
                     (plist-get (cdr entry) :text) ""))
               (vox-session-segments session) "")))

(defun vox--preview (session)
  "Coalesce preview notifications for SESSION."
  (setf (vox-session-preview-text session) (vox-session-text session))
  (unless (vox-session-preview-timer session)
    (setf (vox-session-preview-timer session)
          (run-at-time vox-preview-interval nil
                       (vox--guard session (vox-session-generation session)
                                   (lambda ()
                                     (setf (vox-session-preview-timer session) nil)
                                     (vox--notify session :on-preview (vox-session-preview-text session)
                                                  (vox-session-state session))))))))

(defun vox-core-event (session event)
  "Reconcile normalized EVENT for SESSION.  Callbacks cannot insert directly."
  (when (vox--live-p session)
    (condition-case nil
        (progn
          (vox-log-event (vox-session-generation session) 'recognition-event
                         :kind (pcase (plist-get event :type)
                                 (:segment-partial 'segment-partial)
                                 (:segment-final 'segment-final)
                                 (:snapshot 'snapshot) (:completed 'completed) (:error 'error)
                                 (_ 'unknown))
                         :chars (let ((text (plist-get event :text)))
                                  (if (stringp text) (length text) 0)))
          (pcase (plist-get event :type)
            ((or :segment-partial :segment-final)
             (let ((id (plist-get event :id)) (text (plist-get event :text))
                   (revision (plist-get event :revision))
                   (final (eq (plist-get event :type) :segment-final)))
               (unless (and (stringp id) (stringp text)
                            (<= (string-bytes id) vox-max-segment-id-bytes)
                            (or (null revision) (numberp revision)))
                 (error "Invalid segment"))
               ;; The segment cap also bounds these ordered-list traversals.
               (let* ((entry (assoc id (vox-session-segments session)))
                      (old (cdr entry)) (old-rev (plist-get old :revision)))
                 (unless (or (and (not final) (plist-get old :final))
                             (and revision old-rev
                                  (or (< revision old-rev)
                                      (and (= revision old-rev)
                                           (or (not final) (plist-get old :final))))))
                   (let ((count (+ (vox-session-segment-count session) (if entry 0 1)))
                         (id-bytes (+ (vox-session-segment-id-bytes session)
                                      (if entry 0 (string-bytes id))))
                         (chars (+ (- (vox-session-segment-text-chars session)
                                      (length (plist-get old :text)))
                                   (length text))))
                     (unless (and (<= count vox-max-segments)
                                  (<= id-bytes vox-max-segment-id-total-bytes)
                                  (<= chars vox-max-transcript-chars))
                       (error "Transcript limit exceeded"))
                     (let ((value (list :text text :revision (or revision old-rev) :final final)))
                       (if entry (setcdr entry value)
                         (setf (vox-session-segments session)
                               (nconc (vox-session-segments session) (list (cons id value))))))
                     (setf (vox-session-segment-count session) count
                           (vox-session-segment-id-bytes session) id-bytes
                           (vox-session-segment-text-chars session) chars
                           (vox-session-snapshot session) nil))
                   (vox--preview session)))))
            (:snapshot
             (let ((text (plist-get event :text)) (revision (plist-get event :revision))
                   (old (vox-session-snapshot-revision session)))
               (unless (and (stringp text) (or (null revision) (numberp revision)))
                 (error "Invalid snapshot"))
               (unless (and revision old (<= revision old))
                 (when (> (length text) vox-max-transcript-chars)
                   (error "Transcript limit exceeded"))
                 (setf (vox-session-snapshot session) text
                       (vox-session-snapshot-revision session) revision
                       (vox-session-snapshot-final session) (eq (plist-get event :final-p) t)
                       (vox-session-segments session) nil
                       (vox-session-segment-count session) 0
                       (vox-session-segment-id-bytes session) 0
                       (vox-session-segment-text-chars session) 0)
                 (vox--preview session))))
            (:completed (vox--complete session))
            (:error (vox-core-fail session "Provider reported a recognition error" 'provider))
            (_ nil)))
      (error (vox-core-fail session "Invalid recognition event or output sink failure" 'invalid-event)))))

(defun vox--complete (session)
  "Commit authoritative SESSION completion once, after audio finalization."
  (unless (and (eq (vox-session-state session) 'finalizing)
               (vox-session-finish-sent session)
               (vox-session-finish-dispatched session))
    (error "Provider completed before finish"))
  (setf (vox-session-final-text session) (vox-session-text session))
  (unless (vox-session-committed session)
    ;; Set the latch before calling external code to defeat reentrant events.
    (setf (vox-session-committed session) t)
    (vox--notify session :on-finish (vox-session-final-text session)))
  (when (vox--live-p session)
    (setf (vox-session-state session) 'completed)
    (vox-log-event (vox-session-generation session) 'complete :state 'completed
                   :chars (length (vox-session-final-text session))
                   :segments (vox-session-segment-count session))
    (unwind-protect (ignore-errors (vox--notify session :on-state 'completed))
      (vox--cleanup session))))

(provide 'vox-core)
;;; vox-core.el ends here
