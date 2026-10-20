;;; vox-test-audio.el --- Capture tests -*- lexical-binding: t; no-byte-compile: t; -*-

(require 'vox-test-support)
(require 'cl-lib)
(require 'vox-audio)

(defmacro vox-audio-test--mock (&rest body)
  "Run BODY with an active session and a pipe replacing FFmpeg."
  (declare (indent 0) (debug t))
  `(let* ((session (vox--make-session :id "audio-test" :generation 1 :state 'recording))
          (vox--active-session session)
          (vox-audio-input '("-f" "lavfi" "-i" "anullsrc"))
          (vox-audio-program "test-ffmpeg")
          command received ended errors recorder stderr)
     (unwind-protect
         (cl-letf (((symbol-function 'executable-find) (lambda (_) "/test/ffmpeg"))
                   ((symbol-function 'make-process)
                    (lambda (&rest args)
                      (setq command (plist-get args :command)
                            stderr (plist-get args :stderr))
                      (should (eq (plist-get args :coding) 'binary))
                      (should (eq (plist-get args :connection-type) 'pipe))
                      (make-pipe-process :name "vox-test-recorder" :buffer nil
                                         :coding 'binary :noquery t
                                         :filter (plist-get args :filter)
                                         :sentinel (plist-get args :sentinel)))))
           (setq recorder (vox-audio-start session
                                          (lambda (bytes) (push bytes received))
                                          (lambda () (push 'ended ended))
                                          (lambda (message) (push message errors))))
           (ignore command received ended errors recorder stderr)
           ,@body)
       (vox-audio-cancel session))))

(ert-deftest vox-audio-requires-explicit-input ()
  :tags '(vox-unit)
  (let ((vox-audio-input nil))
    (should-error (vox-audio-start (vox--make-session) #'ignore #'ignore #'ignore)
                  :type 'user-error)))

(ert-deftest vox-audio-binary-and-separated-stderr ()
  :tags '(vox-unit)
  (vox-audio-test--mock
    (let ((bytes (unibyte-string 0 128 255 1)))
      (funcall (process-filter recorder) recorder bytes)
      (funcall (process-filter stderr) stderr "SECRET_DEVICE TOKEN")
      (should (equal (car received) bytes))
      (should-not (multibyte-string-p (car received)))
      (should-not (process-buffer stderr))
      (should-not (process-buffer recorder))
      (should (= 19 (process-get stderr 'vox-stderr-bytes)))
      (should (equal (last command 10)
                     '("-vn" "-ac" "1" "-ar" "16000" "-acodec" "pcm_s16le" "-f" "s16le" "pipe:1")))
      (should-not errors))))

(ert-deftest vox-audio-stop-keeps-final-bytes-until-sentinel ()
  :tags '(vox-unit)
  (vox-audio-test--mock
    (let ((interrupts 0)
          (filter (process-filter recorder))
          (sentinel (process-sentinel recorder)))
      (cl-letf (((symbol-function 'interrupt-process) (lambda (&rest _) (cl-incf interrupts))))
        (vox-audio-stop session)
        (vox-audio-stop session))
      (should (= interrupts 1))
      (should-not ended)
      (funcall filter recorder (unibyte-string 1 255))
      (cl-letf (((symbol-function 'process-status) (lambda (_) 'exit))
                ((symbol-function 'process-exit-status) (lambda (_) 255)))
        (funcall sentinel recorder "sensitive raw process event")
        (funcall sentinel recorder "again"))
      (should (equal received (list (unibyte-string 1 255))))
      (should (equal ended '(ended)))
      (should-not errors)
      (should-not (vox-session-recorder session))
      (should-not (process-live-p stderr)))))

(ert-deftest vox-audio-cancel-is-idempotent-and-silent ()
  :tags '(vox-unit)
  (vox-audio-test--mock
    (vox-audio-cancel session)
    (vox-audio-cancel session)
    (should-not (process-live-p recorder))
    (should-not (process-live-p stderr))
    (should-not received)
    (should-not ended)
    (should-not errors)))

(ert-deftest vox-audio-stale-generation-drops-callbacks ()
  :tags '(vox-unit)
  (vox-audio-test--mock
    (setf (vox-session-generation session) 2)
    (funcall (process-filter recorder) recorder (unibyte-string 5 6))
    (cl-letf (((symbol-function 'process-status) (lambda (_) 'exit))
              ((symbol-function 'process-exit-status) (lambda (_) 0)))
      (funcall (process-sentinel recorder) recorder "finished"))
    (should-not received)
    (should-not ended)
    (should-not errors)
    (should-not (process-live-p stderr))))

(ert-deftest vox-audio-rejects-multibyte-and-redacts-errors ()
  :tags '(vox-unit)
  (vox-audio-test--mock
    (funcall (process-filter recorder) recorder (string #x4e2d))
    (should-not received)
    (should (equal errors '("Audio delivery failed")))
    (should-not (process-live-p stderr))))

(ert-deftest vox-audio-callback-errors-do-not-escape ()
  :tags '(vox-unit)
  (vox-audio-test--mock
    (vox-audio-cancel session)
    (setq recorder
          (vox-audio-start session (lambda (_) (error "SECRET AUDIO")) #'ignore
                           (lambda (_) (error "SECRET ERROR HANDLER"))))
    (should-not (funcall (process-filter recorder) recorder (unibyte-string 0)))
    (should-not (process-live-p recorder))))

(ert-deftest vox-audio-unexpected-exit-is-safe-error ()
  :tags '(vox-unit)
  (vox-audio-test--mock
    (cl-letf (((symbol-function 'process-status) (lambda (_) 'exit))
              ((symbol-function 'process-exit-status) (lambda (_) 1)))
      (funcall (process-sentinel recorder) recorder "SECRET_DEVICE crash"))
    (should (= (length errors) 1))
    (should-not (string-match-p "SECRET" (car errors)))
    (should-not ended)))

(ert-deftest vox-audio-lavfi-integration ()
  :tags '(vox-unit)
  "Use a finite synthetic source, not a microphone or cloud service."
  (skip-unless (executable-find "ffmpeg"))
  (let* ((session (vox--make-session :id "lavfi-test" :generation 1 :state 'recording))
         (vox--active-session session)
         (vox-audio-program "ffmpeg")
         (vox-audio-input '("-f" "lavfi" "-i"
                            "sine=frequency=440:sample_rate=16000:duration=0.03"))
         (bytes (unibyte-string)) ended errors process stderr)
    (unwind-protect
        (progn
          (setq process (vox-audio-start session
                                         (lambda (part)
                                           (should-not (multibyte-string-p part))
                                           (setq bytes (concat bytes part)))
                                         (lambda () (setq ended t))
                                         (lambda (message) (push message errors)))
                stderr (process-get process 'vox-stderr))
          ;; Waiting is confined to the test harness, never production code.
          (let ((deadline (+ (float-time) 5)))
            (while (and (not ended) (not errors) (< (float-time) deadline))
              (accept-process-output nil 0.05)))
          (should ended)
          (should-not errors)
          (should (= (length bytes) 960))
          (should-not (process-live-p stderr))
          (should-not (vox-session-recorder session)))
      (vox-audio-cancel session))))

(ert-deftest vox-audio-retained-callbacks-after-cancel-are-ignored ()
  :tags '(vox-unit)
  (vox-audio-test--mock
    (let ((filter (process-filter recorder))
          (sentinel (process-sentinel recorder)))
      (vox-audio-cancel session)
      (funcall filter recorder (unibyte-string 1 2))
      (cl-letf (((symbol-function 'process-status) (lambda (_) 'exit))
                ((symbol-function 'process-exit-status) (lambda (_) 0)))
        (funcall sentinel recorder "late"))
      (should-not received)
      (should-not ended)
      (should-not errors))))

(ert-deftest vox-audio-lavfi-asynchronous-stop-integration ()
  :tags '(vox-unit)
  "Interrupt a running virtual source and await its terminal sentinel."
  (skip-unless (executable-find "ffmpeg"))
  (let* ((session (vox--make-session :id "lavfi-stop" :generation 1 :state 'recording))
         (vox--active-session session)
         (vox-audio-program "ffmpeg")
         (vox-audio-input '("-re" "-f" "lavfi" "-i"
                            "sine=frequency=440:sample_rate=16000"))
         (count 0) ended errors process stderr)
    (unwind-protect
        (progn
          (setq process
                (vox-audio-start session
                                 (lambda (bytes)
                                   (cl-incf count (length bytes))
                                   (vox-audio-stop session))
                                 (lambda () (setq ended t))
                                 (lambda (message) (push message errors)))
                stderr (process-get process 'vox-stderr))
          (let ((deadline (+ (float-time) 5)))
            (while (and (not ended) (not errors) (< (float-time) deadline))
              (accept-process-output nil 0.05)))
          (should ended)
          (should-not errors)
          (should (> count 0))
          (should (= (% count 2) 0))
          (should-not (process-live-p stderr))
          (should-not (process-get process 'vox-interrupt-timer))
          (when (plist-get (vox-session-statistics session) :audio-interrupt-retries)
            (should (plist-get (vox-session-statistics session) :audio-tail-risk)))
          (should-not (vox-session-recorder session)))
      (vox-audio-cancel session))))

(ert-deftest vox-audio-stop-retry-is-bounded-and-cancel-safe ()
  :tags '(vox-unit)
  (vox-audio-test--mock
    (let ((interrupts 0))
      (cl-letf (((symbol-function 'interrupt-process) (lambda (&rest _) (cl-incf interrupts))))
        (vox-audio-stop session)
        (let* ((timer (process-get recorder 'vox-interrupt-timer))
               (retry (timer--function timer)))
          (cancel-timer timer)
          (funcall retry)
          (funcall retry)
          (should (= interrupts 2))
          (should (= (plist-get (vox-session-statistics session) :audio-interrupt-retries) 1))
          (should (plist-get (vox-session-statistics session) :audio-tail-risk))
          (vox-audio-cancel session)
          (funcall retry)
          (should (= interrupts 2))
          (should-not (process-live-p stderr)))))))

(provide 'vox-test-audio)
;;; vox-test-audio.el ends here
