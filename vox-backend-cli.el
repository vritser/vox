;;; vox-backend-cli.el --- Optional bounded NDJSON streaming backend -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; CLI records its own audio.  Control stdin is NDJSON, never a shell command.
;;; Code:
(require 'vox-core)

(defcustom vox-cli-command nil "CLI argv list; the program must implement Vox NDJSON v1."
  :type '(repeat string) :group 'vox)
(defcustom vox-cli-max-line-bytes 1048576 "Maximum bytes in one CLI JSON line."
  :type 'integer :group 'vox)
(defcustom vox-cli-max-retained-input-bytes (* 2 1024 1024)
  "Maximum bytes in active and queued CLI process callbacks."
  :type 'integer :group 'vox)
(defcustom vox-cli-max-retained-input-chunks 1024
  "Maximum active and queued CLI callbacks, including terminal notifications."
  :type 'integer :group 'vox)

(cl-defstruct (vox-cli--input (:constructor vox-cli--make-input))
  queue tail feeding closed (bytes 0) (count 0))

(defun vox-cli--reset-input (input)
  "Release INPUT's queued callbacks and retained-byte charge."
  (setf (vox-cli--input-queue input) nil
        (vox-cli--input-tail input) nil
        (vox-cli--input-bytes input) 0
        (vox-cli--input-count input) 0))

(defun vox-cli--dispatch (session line)
  "Parse one UTF-8 LINE and emit a normalized SESSION event."
  (let* ((text (decode-coding-string line 'utf-8))
         (_ (when (cl-some (lambda (char) (>= char #x3fff80)) text)
              (error "Invalid CLI UTF-8")))
         (event (vox-json-read text))
         (state (vox-session-backend-state session))
         (emit (plist-get state :on-event))
         (type (plist-get event :type)))
    (unless (equal (plist-get event :v) 1) (error "Unsupported CLI protocol"))
    (when (plist-get state :completed) (error "CLI output after completed"))
    (pcase type
      ("started"
       (unless (plist-get state :started)
         (setf (vox-session-backend-state session) (plist-put state :started t))
         (funcall (plist-get state :on-ready))))
      ((or "partial" "final")
       (unless (plist-get state :started) (error "CLI output before started"))
       (funcall emit (list :type (if (equal type "partial") :segment-partial :segment-final)
                           :id (plist-get event :segment_id) :text (plist-get event :text)
                           :revision (plist-get event :revision))))
      ("completed"
       (unless (plist-get state :stopping) (error "CLI completed before stop"))
       ;; Wait for a zero exit status as well as the explicit completion event.
       (setf (vox-session-backend-state session) (plist-put state :completed t)))
      ("error" (funcall (plist-get state :on-error) "CLI reported an error"))
      (_ (error "Unknown CLI event")))))

(defun vox-cli--consume (session bytes)
  "Accumulate arbitrary byte chunks for SESSION; parse only complete lines."
  (let* ((state (vox-session-backend-state session))
         (pending (or (plist-get state :pending) (unibyte-string)))
         (start 0) end)
    (catch 'session-ended
      ;; Do not concat an unbounded callback before enforcing line limits.
      (while (setq end (string-match "\n" bytes start))
        (when (or (vox-session-cleaned session)
                  (memq (vox-session-state session) '(completed cancelled error)))
          (throw 'session-ended nil))
        (when (> (+ (length pending) (- end start)) vox-cli-max-line-bytes)
          (error "CLI line exceeds limit"))
        (vox-cli--dispatch session (concat pending (substring bytes start end)))
        (when (or (vox-session-cleaned session)
                  (memq (vox-session-state session) '(completed cancelled error)))
          (throw 'session-ended nil))
        (setq pending (unibyte-string) start (1+ end)))
      (unless (or (vox-session-cleaned session)
                  (memq (vox-session-state session) '(completed cancelled error)))
        (when (> (+ (length pending) (- (length bytes) start)) vox-cli-max-line-bytes)
          (error "CLI line exceeds limit"))
        (setf (vox-session-backend-state session)
              (plist-put (vox-session-backend-state session) :pending
                         (concat pending (substring bytes start))))))))

(defun vox-cli--receive (session input)
  "Consume SESSION INPUT in arrival order across reentrant callbacks.
INPUT is a byte string or a (STATUS . EXIT-CODE) terminal notification.
Keep each callback's byte charge until its entire input has been consumed."
  (unless (or (vox-session-cleaned session)
              (memq (vox-session-state session) '(completed cancelled error))
              (and (stringp input) (zerop (length input))))
    (let* ((state (vox-session-backend-state session))
           (queue (or (plist-get state :input) (vox-cli--make-input)))
           (size (if (stringp input) (length input) 0))
           (entry (list input)))
      (unless (vox-cli--input-closed queue)
        (when (or (> (+ (vox-cli--input-bytes queue) size)
                     vox-cli-max-retained-input-bytes)
                  (>= (vox-cli--input-count queue)
                      vox-cli-max-retained-input-chunks))
          (error "CLI retained input exceeds limit"))
        (setf (vox-session-backend-state session) (plist-put state :input queue))
        (if (vox-cli--input-tail queue)
            (setcdr (vox-cli--input-tail queue) entry)
          (setf (vox-cli--input-queue queue) entry))
        (setf (vox-cli--input-tail queue) entry)
        (cl-incf (vox-cli--input-bytes queue) size)
        (cl-incf (vox-cli--input-count queue))
        (unless (vox-cli--input-feeding queue)
          (setf (vox-cli--input-feeding queue) t)
          (unwind-protect
              (while (and (not (vox-cli--input-closed queue))
                          (not (vox-session-cleaned session))
                          (not (memq (vox-session-state session)
                                     '(completed cancelled error)))
                          (vox-cli--input-queue queue))
                (let ((next (pop (vox-cli--input-queue queue))))
                  (unless (vox-cli--input-queue queue)
                    (setf (vox-cli--input-tail queue) nil))
                  (if (stringp next)
                      (vox-cli--consume session next)
                    (let ((current (vox-session-backend-state session)))
                      (if (and (eq (car next) 'exit) (= (cdr next) 0)
                               (plist-get current :completed)
                               (string-empty-p (plist-get current :pending)))
                          (funcall (plist-get current :on-event) '(:type :completed))
                        (funcall
                         (plist-get current :on-error)
                         "CLI exited without successful explicit completion"))))
                  (unless (or (vox-cli--input-closed queue)
                              (vox-session-cleaned session))
                    (cl-decf (vox-cli--input-count queue))
                    (cl-decf (vox-cli--input-bytes queue)
                             (if (stringp next) (length next) 0)))))
            (setf (vox-cli--input-feeding queue) nil)
            (vox-cli--reset-input queue)))))))

(defun vox-cli--feed (session bytes)
  "Queue SESSION BYTES without allowing nested input to overtake them."
  (vox-cli--receive session bytes))

(defun vox-cli--connect (session on-ready on-event on-error)
  "Launch SESSION CLI with ON-READY, ON-EVENT and ON-ERROR callbacks."
  (unless (and (consp vox-cli-command) (cl-every #'stringp vox-cli-command)
               (executable-find (car vox-cli-command)))
    (user-error "Configure vox-cli-command with an executable argv list"))
  (let ((generation (vox-session-generation session)) proc stderr)
    (setf (vox-session-backend-state session)
          (list :on-ready on-ready :on-event on-event :on-error on-error
                :pending (unibyte-string)))
    (setq stderr (make-pipe-process :name "vox-cli-stderr" :buffer nil
                                    :noquery t :filter (lambda (&rest _) nil)))
    (condition-case nil
        (setq proc
              (make-process
               :name "vox-cli" :buffer nil :command vox-cli-command
               :connection-type 'pipe :coding 'binary :noquery t :stderr stderr
               :filter (lambda (_process bytes)
                         (when (vox-session-live-p session generation)
                           (condition-case nil (vox-cli--feed session bytes)
                             (quit (vox-core-cancel session) (signal 'quit nil))
                             (error (funcall on-error "Invalid or oversized CLI output")))))
               :sentinel
               (lambda (process _event)
                 (when (and (vox-session-live-p session generation)
                            (memq (process-status process) '(exit signal failed)))
                   (condition-case nil
                       (vox-cli--receive session
                                         (cons (process-status process)
                                               (process-exit-status process)))
                     (quit (vox-core-cancel session) (signal 'quit nil))
                     (error (funcall on-error "Invalid or oversized CLI output")))))))
      (error (when (process-live-p stderr) (delete-process stderr))
             (error "CLI could not start"))
      (quit
       (when (processp stderr) (ignore-errors (delete-process stderr)))
       (signal 'quit nil)))
    (let ((current (vox-session-backend-state session)))
      (if (and current (vox-session-live-p session generation))
          (setf (vox-session-backend-state session)
                (append (list :process proc :stderr stderr) current))
        ;; A callback during startup may have cleaned the session before this
        ;; point; reclaim the processes rather than resurrecting state.
        (dolist (process (list proc stderr))
          (when (processp process) (ignore-errors (delete-process process))))))))

(defun vox-cli--finish (session)
  "Request graceful CLI stop for SESSION using an explicit control line."
  (let ((state (vox-session-backend-state session)))
    (unless (plist-get state :stopping)
      (setf (vox-session-backend-state session) (plist-put state :stopping t))
      (process-send-string (plist-get state :process) "{\"v\":1,\"type\":\"stop\"}\n"))))

(defun vox-cli--close (session)
  "Terminate SESSION CLI and discard its diagnostics without logging them."
  (let ((state (vox-session-backend-state session)))
    (when-let* ((input (plist-get state :input)))
      (setf (vox-cli--input-closed input) t)
      (vox-cli--reset-input input))
    (dolist (process (list (plist-get state :process) (plist-get state :stderr)))
      (when (and (processp process) (process-live-p process))
        (delete-process process)))))

(defun vox-cli--cancel (session)
  "Tell SESSION CLI to cancel, then force cleanup without waiting."
  (let ((proc (plist-get (vox-session-backend-state session) :process)))
    (when (and (processp proc) (process-live-p proc))
      (ignore-errors (process-send-string proc "{\"v\":1,\"type\":\"cancel\"}\n"))))
  (vox-cli--close session))

(vox-register-backend 'cli
                      (list :connect #'vox-cli--connect :finish #'vox-cli--finish
                            :cancel #'vox-cli--cancel :close #'vox-cli--close
                            :needs-external-audio nil :supports-partial t
                            :supports-segment-final t :supports-graceful-stop t))
(provide 'vox-backend-cli)
;;; vox-backend-cli.el ends here
