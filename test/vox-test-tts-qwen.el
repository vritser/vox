;;; vox-test-tts-qwen.el --- Qwen realtime speech tests -*- lexical-binding: t; no-byte-compile: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Synthetic events following the official static JSON layouts; no cloud or audio device.
;;; Code:
(require 'vox-test-support)
(require 'vox)
(require 'vox-tts-qwen)

(ert-deftest vox-tts-qwen-realtime-explicit-capability ()
  :tags '(vox-unit)
  (let ((backend (vox-backend-capability
                  (vox-make-qwen "Stream" :asr nil :tts '(:protocol tts-qwen-realtime)) 'tts)))
    (should (eq (vox-backend-type backend) 'tts-qwen-realtime))
    (should (equal (vox-backend-endpoint backend) "/api-ws/v1/realtime"))
    (should (equal (vox-backend-models backend) '("qwen3-tts-flash-realtime")))
    (should (equal (vox-backend-voice backend) "Cherry"))))

(defvar vox-tts-qwen-test--provider nil)

(defmacro vox-tts-qwen-test--session (&rest body)
  "Evaluate BODY with a real Qwen adapter over a synthetic transport."
  (declare (indent 0) (debug t))
  `(let ((vox-tts--active nil) (vox-tts--generation 0)
         (vox--active-session nil) (vox--starting nil) (vox--reloading nil)
         (vox-tts-player-command '("sh" "-c" "cat >/dev/null"))
         (vox-tts-timeout 5) (vox-tts-playback-timeout 5)
         (vox-tts-max-text-chars 4096) (vox-tts-max-pending-bytes 4096)
         (vox-tts-max-audio-bytes 8192) (vox-tts-max-response-bytes 16384)
         context on-message on-close on-error destination headers wire during-send (closed 0))
     (cl-letf (((symbol-function 'message) #'ignore)
               ((symbol-function 'vox-transport-open)
                (lambda (owner url auth _opened message failed ended &optional _live _generation)
                  (setq context owner destination url headers auth on-message message
                        on-error failed on-close ended)))
               ((symbol-function 'vox-transport-send-text)
                (lambda (_owner json)
                  (let ((event (vox-json-read json)))
                    (push event wire)
                    (when during-send (funcall during-send event)))))
               ((symbol-function 'vox-transport-close)
                (lambda (_owner) (cl-incf closed) (funcall on-close))))
       (let ((session (vox-speak-open
                       (or vox-tts-qwen-test--provider
                           (vox-make-qwen "Qwen" :asr nil :key "synthetic" :tts t)))))
         (unwind-protect (progn ,@body) (vox-speak-stop))))))

(defun vox-tts-qwen-test--event (callback type &rest fields)
  "Send synthetic TYPE with FIELDS to CALLBACK."
  (funcall callback (vox-json-encode (append `((type . ,type)) fields)) 'text))

(defun vox-tts-qwen-test--configure (context callback)
  "Send session.created to CALLBACK and drain CONTEXT's config timer."
  (vox-tts-qwen-test--event callback "session.created" '(session . ((id . "session-test"))))
  (cancel-timer (vox-tts-qwen--context-timer context))
  (vox-tts-qwen--configure context))

(defun vox-tts-qwen-test--ready (callback)
  "Acknowledge the requested format and voice through CALLBACK."
  (vox-tts-qwen-test--event
   callback "session.updated"
   '(session . ((id . "session-test") (voice . "Cherry") (mode . "server_commit")
                (response_format . "pcm") (sample_rate . 24000)))))

(defun vox-tts-qwen-test--pump (session)
  "Drain SESSION's next text input timer synchronously."
  (when (timerp (vox-tts--session-input-timer session))
    (cancel-timer (vox-tts--session-input-timer session)))
  (vox-tts--input-pump session))

(defun vox-tts-qwen-test--audio (callback id bytes)
  "Emit one synthetic response ID containing PCM BYTES through CALLBACK."
  (vox-tts-qwen-test--event callback "response.created" `(response . ((id . ,id))))
  (vox-tts-qwen-test--event callback "response.audio.delta"
                           `(response_id . ,id) `(delta . ,(base64-encode-string bytes t))))

(defun vox-tts-qwen-test--response-done (callback id)
  "Finish synthetic response ID through CALLBACK."
  (vox-tts-qwen-test--event callback "response.audio.done" `(response_id . ,id))
  (vox-tts-qwen-test--event callback "response.done" `(response . ((id . ,id) (status . "completed")))))

(ert-deftest vox-tts-qwen-default-and-removed-http-protocols ()
  :tags '(vox-unit)
  (should (eq (vox-backend-type (vox-backend-capability (vox-make-qwen "Q" :tts t) 'tts))
              'tts-qwen-realtime))
  (dolist (protocol '(tts-openai tts-qwen tts-doubao))
    (should-error (vox-make-qwen "Old" :tts (list :protocol protocol)) :type 'user-error))
  (should-not (fboundp 'vox-make-openai)))

(ert-deftest vox-tts-qwen-handshake-text-order-and-finish ()
  :tags '(vox-unit)
  (vox-tts-qwen-test--session
    (should (equal destination "wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen3-tts-flash-realtime"))
    (should (equal headers '(("Authorization" . "Bearer synthetic"))))
    (vox-speak-send session "你好")
    (vox-speak-send session " world")
    (vox-speak-finish session)
    (vox-tts-qwen-test--pump session)
    (should-not wire)
    (vox-tts-qwen-test--configure context on-message)
    (should (equal (plist-get (car wire) :session)
                   '(:voice "Cherry" :mode "server_commit" :language_type "Auto"
                     :response_format "pcm" :sample_rate 24000)))
    (vox-tts-qwen-test--pump session)
    (should (= (length wire) 1))
    (vox-tts-qwen-test--ready on-message)
    (vox-tts-qwen-test--pump session)
    (should (equal (plist-get (car wire) :text) "你好"))
    (should-not (vox-tts--session-input-sent-finish session))
    (vox-tts-qwen-test--pump session)
    (should (equal (mapcar (lambda (event) (plist-get event :type)) (reverse wire))
                   '("session.update" "input_text_buffer.append" "input_text_buffer.append" "session.finish")))
    (should (equal (plist-get (cadr wire) :text) " world"))
    (should (= (length (delete-dups (mapcar (lambda (event) (plist-get event :event_id)) wire))) 4))
    (should (eq (vox-tts-qwen--context-phase context) 'finishing))))

(ert-deftest vox-tts-qwen-streams-multiple-responses-before-input-finish ()
  :tags '(vox-unit)
  (vox-tts-qwen-test--session
    (vox-tts-qwen-test--configure context on-message)
    (vox-tts-qwen-test--ready on-message)
    (vox-speak-send session "第一段")
    (vox-tts-qwen-test--pump session)
    (vox-tts-qwen-test--audio on-message "r1" (unibyte-string 1 0))
    (should (= (vox-tts--session-audio-bytes session) 46))
    (should (equal (apply #'concat (vox-tts--session-chunks session))
                   (concat vox-tts--pcm-wave-header (unibyte-string 1 0))))
    (should-not (vox-tts--session-input-closed session))
    (should-not (vox-tts--session-source-done session))
    (vox-tts-qwen-test--response-done on-message "r1")
    (should-not (vox-tts--session-source-done session))
    (vox-speak-send session "第二段")
    (vox-speak-finish session)
    (vox-tts-qwen-test--pump session)
    (vox-tts-qwen-test--audio on-message "r2" (unibyte-string 2 0))
    (vox-tts-qwen-test--response-done on-message "r2")
    (should (= (vox-tts--session-audio-bytes session) 48))
    (vox-tts-qwen-test--event on-message "session.finished")
    (should (vox-tts--session-source-done session))
    (should (vox-tts--live-p session))
    (should (= closed 1))
    (should (equal (plist-get (car wire) :type) "session.finish"))
    (should-not (vox-tts--session-timer session))))

(ert-deftest vox-tts-qwen-cancel-clears-and-drops-unsent-text ()
  :tags '(vox-unit)
  (vox-tts-qwen-test--session
    (vox-tts-qwen-test--configure context on-message)
    (vox-tts-qwen-test--ready on-message)
    (vox-speak-send session "sent")
    (vox-tts-qwen-test--pump session)
    (vox-speak-send session "unsent")
    (vox-speak-stop session)
    (vox-tts-qwen-test--pump session)
    (should (equal (mapcar (lambda (event) (plist-get event :type)) (reverse wire))
                   '("session.update" "input_text_buffer.append" "input_text_buffer.clear")))
    (should (= closed 1))
    (should (eq (vox-tts--session-state session) 'cancelled))
    (should-not (vox-tts--session-text-queue session))
    (should-not (vox-tts--session-input-timer session))
    (vox-tts-qwen-test--audio on-message "late" (unibyte-string 1 0))
    (funcall on-error "private")
    (should (= (vox-tts--session-audio-bytes session) 0))
    (should (eq (vox-tts--session-state session) 'cancelled))))

(ert-deftest vox-tts-qwen-cancel-or-quit-during-write-never-appends-clear ()
  :tags '(vox-unit)
  (dolist (action '(cancel quit error))
    (vox-tts-qwen-test--session
      (vox-tts-qwen-test--configure context on-message)
      (vox-tts-qwen-test--ready on-message)
      (vox-speak-send session "first")
      (vox-speak-send session "second")
      (setq during-send (lambda (_event)
                          (pcase action
                            ('cancel (vox-speak-stop session))
                            ('quit (signal 'quit nil))
                            ('error (error "synthetic partial write")))))
      (let (interrupted)
        (condition-case nil (vox-tts-qwen-test--pump session)
          (quit (setq interrupted t)))
        (should (eq interrupted (eq action 'quit))))
      (should (equal (mapcar (lambda (event) (plist-get event :type)) (reverse wire))
                     '("session.update" "input_text_buffer.append")))
      (should (= closed 1))
      (should (eq (vox-tts--session-state session) (if (eq action 'error) 'error 'cancelled)))
      (should-not (vox-tts--session-text-queue session)))))

(ert-deftest vox-tts-qwen-reentrant-ready-and-producer-preserve-send-order ()
  :tags '(vox-unit)
  (vox-tts-qwen-test--session
    (vox-speak-send session "first")
    (setq during-send
          (lambda (event)
            (pcase (plist-get event :type)
              ("session.update"
               (vox-tts-qwen-test--ready on-message)
               (vox-tts-qwen-test--pump session)
               (should (= (length wire) 1)))
              ("input_text_buffer.append"
               (should (equal (plist-get event :text) "first"))
               (setq during-send nil)
               (vox-speak-send session "second")
               (vox-speak-finish session)
               (vox-tts-qwen-test--pump session)
               (should (= (length wire) 2))))))
    (vox-tts-qwen-test--configure context on-message)
    (should (vox-tts--session-input-ready session))
    (vox-tts-qwen-test--pump session)
    (vox-tts-qwen-test--pump session)
    (should (equal (mapcar (lambda (event) (plist-get event :type)) (reverse wire))
                   '("session.update" "input_text_buffer.append" "input_text_buffer.append" "session.finish")))
    (should (equal (plist-get (cadr wire) :text) "second"))))

(ert-deftest vox-tts-qwen-rejects-bad-session-configuration ()
  :tags '(vox-unit)
  (dolist (override '((id . "wrong") (voice . "wrong") (mode . "commit")
                      (sample_rate . 16000) (response_format . "mp3")))
    (vox-tts-qwen-test--session
      (vox-tts-qwen-test--configure context on-message)
      (let ((settings (copy-tree '((id . "session-test") (voice . "Cherry") (mode . "server_commit")
                                   (response_format . "pcm") (sample_rate . 24000)))))
        (setcdr (assq (car override) settings) (cdr override))
        (vox-tts-qwen-test--event on-message "session.updated" `(session . ,settings)))
      (should (eq (vox-tts--session-state session) 'error))
      (should (= closed 1)))))

(ert-deftest vox-tts-qwen-refuses-premature-empty-and-incomplete-completion ()
  :tags '(vox-unit)
  (dolist (fault '(premature empty odd unfinished failed wrong-id))
    (vox-tts-qwen-test--session
      (vox-tts-qwen-test--configure context on-message)
      (vox-tts-qwen-test--ready on-message)
      (vox-speak-send session "text")
      (unless (eq fault 'premature) (vox-speak-finish session))
      (vox-tts-qwen-test--pump session)
      (unless (eq fault 'empty)
        (vox-tts-qwen-test--audio on-message "r1" (if (eq fault 'odd) "a" "ab")))
      (pcase fault
        ('failed (vox-tts-qwen-test--event on-message "response.done"
                                          '(response . ((id . "r1") (status . "failed")))))
        ('wrong-id (vox-tts-qwen-test--response-done on-message "wrong"))
        ((or 'premature 'odd) (vox-tts-qwen-test--response-done on-message "r1")))
      (vox-tts-qwen-test--event on-message "session.finished")
      (should (eq (vox-tts--session-state session) 'error))
      (should-not (vox-tts--session-source-done session))
      (should (= closed 1)))))

(ert-deftest vox-tts-qwen-malformed-overbudget-and-remote-close-fail ()
  :tags '(vox-unit)
  (dolist (fault '(json binary base64 unknown remote-close remote-error budget))
    (vox-tts-qwen-test--session
      (vox-tts-qwen-test--configure context on-message)
      (vox-tts-qwen-test--ready on-message)
      (pcase fault
        ('json (funcall on-message "{" 'text))
        ('binary (funcall on-message "ab" 'binary))
        ('base64
         (vox-tts-qwen-test--event on-message "response.created" '(response . ((id . "r1"))))
         (vox-tts-qwen-test--event on-message "response.audio.delta" '(response_id . "r1") '(delta . "!")))
        ('unknown (vox-tts-qwen-test--event on-message "unknown"))
        ('remote-close (funcall on-close))
        ('remote-error (vox-tts-qwen-test--event on-message "error" '(error . ((message . "private")))))
        ('budget
         (setf (vox-tts--session-response-limit session) (vox-tts-qwen--context-received context))
         (vox-tts-qwen-test--event on-message "input_text_buffer.committed")))
      (should (eq (vox-tts--session-state session) 'error))
      (should (= closed 1)))))

(ert-deftest vox-tts-qwen-cancel-before-created-reclaims-handshake-timer ()
  :tags '(vox-unit)
  (vox-tts-qwen-test--session
    (vox-tts-qwen-test--event on-message "session.created" '(session . ((id . "session-test"))))
    (should (timerp (vox-tts-qwen--context-timer context)))
    (vox-speak-stop session)
    (vox-tts-qwen--configure context)
    (should-not wire)
    (should-not (vox-tts-qwen--context-timer context))
    (should (= closed 1))))

(ert-deftest vox-tts-qwen-model-query-and-key-callback-retain-snapshot ()
  :tags '(vox-unit)
  (let* ((provider (vox-make-qwen "Shared" :tts '(:endpoint "/api-ws/v1/realtime?x=1&model=old&%6dodel=older"
                                                :models (custom-model) :voice "Cherry")))
         (vox-tts-qwen-test--provider provider))
    (setf (vox-provider-key provider)
          (lambda ()
            (setf (vox-provider-host provider) "changed.invalid"
                  (vox-provider-tts provider) '(:protocol tts-qwen-realtime :voice "Changed"))
            "snapshot-key"))
    (vox-tts-qwen-test--session
      (should (equal destination "wss://dashscope.aliyuncs.com/api-ws/v1/realtime?x=1&model=custom-model"))
      (should (equal headers '(("Authorization" . "Bearer snapshot-key"))))
      (vox-tts-qwen-test--configure context on-message)
      (should (equal (plist-get (plist-get (car wire) :session) :voice) "Cherry")))))

(ert-deftest vox-tts-qwen-stale-events-cannot-affect-successor ()
  :tags '(vox-unit)
  (vox-tts-qwen-test--session
    (let* ((old-message on-message) (old-close on-close)
           (next (vox-speak-open (vox-make-qwen "Next" :asr nil :key "synthetic" :tts t))))
      (vox-tts-qwen-test--event old-message "error")
      (funcall old-close)
      (vox-speak-stop session)
      (should-error (vox-speak-send session "stale") :type 'user-error)
      (should (eq vox-tts--active next))
      (should (eq (vox-tts--session-state session) 'cancelled))
      (should (= (vox-tts--session-audio-bytes next) 0)))))

(ert-deftest vox-tts-qwen-finish-reentry-drains-player-before-completing ()
  :tags '(vox-unit)
  (vox-tts-qwen-test--session
    (vox-tts-qwen-test--configure context on-message)
    (vox-tts-qwen-test--ready on-message)
    (vox-speak-send session "one complete utterance")
    (vox-speak-finish session)
    (setq during-send
          (lambda (event)
            (when (equal (plist-get event :type) "session.finish")
              (vox-tts-qwen-test--audio on-message "r1" (unibyte-string 1 0 2 0))
              (vox-tts-qwen-test--response-done on-message "r1")
              (vox-tts-qwen-test--event on-message "session.finished")
              (funcall on-close)
              (should (vox-tts--session-source-done session))
              (should (vox-tts--live-p session))
              (should-not (vox-tts--session-eof session)))))
    (vox-tts-qwen-test--pump session)
    (should (= closed 1))
    (let ((deadline (+ (float-time) 3)))
      (while (and (vox-tts--live-p session) (< (float-time) deadline))
        (accept-process-output nil 0.01)))
    (should (eq (vox-tts--session-state session) 'completed))
    (should-not (vox-tts--session-processes session))
    (should-not (vox-tts--session-playback-timer session))
    (should (= closed 1))
    (should (equal (mapcar (lambda (event) (plist-get event :type)) (reverse wire))
                   '("session.update" "input_text_buffer.append" "session.finish")))))

(provide 'vox-test-tts-qwen)
;;; vox-test-tts-qwen.el ends here
