;;; vox-test-qwen-audio.el --- Native task-streaming tests -*- lexical-binding: t; no-byte-compile: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Synthetic protocol data and mocked capture/transport only.  These tests do
;; not read real credentials, contact DashScope, or open a microphone.
;;; Code:
(require 'vox-test-support)
(require 'vox-backend-qwen-audio)

(defun vox-qwen-audio-test--event (session event &optional sentence)
  "Build synthetic EVENT for SESSION, optionally with SENTENCE output."
  (list :header (list :event event
                      :task_id (plist-get (vox-session-backend-state session) :task-id))
        :payload (if sentence (list :output (list :sentence sentence))
                   (list :output (make-hash-table :test #'equal)))))

(defun vox-qwen-audio-test--deliver (session event &optional sentence)
  "Deliver synthetic EVENT and optional SENTENCE to SESSION."
  (vox-qwen-audio--message
   session (vox-json-encode (vox-qwen-audio-test--event session event sentence)) 'text))

(defmacro vox-qwen-audio-test--adapter (&rest body)
  "Run BODY with a connected synthetic adapter and captured transport calls."
  (declare (indent 0) (debug t))
  `(let* ((vox-selection nil)
          (vox-qwen-audio-silence-ms 800)
          (configuration (vox-make-qwen-audio "Synthetic" :key "synthetic-key"))
          (session (vox--make-session :id "synthetic" :generation 1 :state 'connecting
                                      :methods (vox-backend-methods configuration)))
          (vox--active-session session)
          callbacks headers url sent events errors (ready 0) (closed 0))
     (cl-letf (((symbol-function 'auth-source-search)
                (lambda (&rest _) (ert-fail "Literal key read auth-source")))
               ((symbol-function 'vox-transport-open)
                (lambda (_session destination h open message fail close)
                  (setq url destination headers h
                        callbacks (list open message fail close))))
               ((symbol-function 'vox-transport-send-text)
                (lambda (_session text) (push (cons 'text (vox-json-read text)) sent)))
               ((symbol-function 'vox-transport-send-binary)
                (lambda (_session bytes) (push (cons 'binary bytes) sent)))
               ((symbol-function 'vox-transport-close)
                (lambda (_) (cl-incf closed))))
       (vox-qwen-audio-connect session (lambda () (cl-incf ready))
                                   (lambda (event) (push event events))
                                   (lambda (error) (push error errors)))
       ,@body)))

(ert-deftest vox-qwen-audio-factory-and-url-are-separate ()
  :tags '(vox-unit)
  (let* ((backend (vox-make-qwen-audio "Streaming"))
         (methods (vox-backend-methods 'qwen-audio)))
    (should (eq (vox-backend-type backend) 'qwen-audio))
    (should (equal (vox-backend-models backend) '("qwen-audio-3.0-asr-flash-streaming")))
    (should (equal (vox-backend-host backend) "dashscope.aliyuncs.com"))
    (should (equal (vox-backend-endpoint backend) "/api-ws/v1/inference"))
    (should-not (vox-backend-key backend))
    (should-not (vox-backend-language backend))
    (should (eq (vox-backend-type (plist-get methods :configuration)) 'qwen-audio))
    (should (equal (plist-get methods :model) "qwen-audio-3.0-asr-flash-streaming"))
    (should (plist-get methods :needs-external-audio))
    (should (equal (vox-backend-url backend nil)
                   "wss://dashscope.aliyuncs.com/api-ws/v1/inference")))
  (let ((backend (vox-make-qwen-audio "Custom" :models '(first second)
                                          :endpoint "/custom?model=server&x=1")))
    (should (equal (vox-backend-url backend 'second)
                   "wss://dashscope.aliyuncs.com/custom?model=server&x=1"))
    (should-error (vox-backend-methods backend 'missing) :type 'user-error)))

(ert-deftest vox-qwen-audio-run-task-shape-and-language ()
  :tags '(vox-unit)
  (let* ((vox-qwen-audio-silence-ms 800)
         (id "a1234567-1234-4234-8234-123456789abc")
         (request (vox-json-read (vox-json-encode
                                 (vox-qwen-audio-run-task id "chosen-model" "en"))))
         (header (plist-get request :header))
         (payload (plist-get request :payload))
         (parameters (plist-get payload :parameters)))
    (should (equal header (list :action "run-task" :task_id id :streaming "duplex")))
    (should (equal (plist-get payload :task_group) "audio"))
    (should (equal (plist-get payload :task) "asr"))
    (should (equal (plist-get payload :function) "recognition"))
    (should (equal (plist-get payload :model) "chosen-model"))
    (should (equal (plist-get parameters :format) "pcm"))
    (should (= (plist-get parameters :sample_rate) 16000))
    (should (= (plist-get parameters :max_sentence_silence) 800))
    (should (equal (plist-get parameters :language_hints) '("en")))
    (should (string-match-p "\"input\":{}" (vox-json-encode
                                             (vox-qwen-audio-run-task id "chosen-model")))))
  (let ((vox-qwen-audio-silence-ms 400))
    (should-not (plist-member
                 (plist-get (plist-get (vox-qwen-audio-run-task "id" "model") :payload)
                            :parameters)
                 :language_hints)))
  (dolist (invalid '(199 6001 "800" nil))
    (let ((vox-qwen-audio-silence-ms invalid))
      (should-error (vox-qwen-audio-run-task "id" "model")))))

(ert-deftest vox-qwen-audio-normalization-is-sentence-replacement ()
  :tags '(vox-unit)
  (let ((session (vox--make-session :backend-state '(:task-id "synthetic"))))
    (dolist (case '((:false :segment-partial) (t :segment-final)))
      (let ((event (vox-qwen-audio-normalize
                    (vox-qwen-audio-test--event
                     session "result-generated"
                     (list :sentence_id 7 :text "replacement" :sentence_end (car case))))))
        (should (eq (plist-get event :type) (cadr case)))
        (should (equal (plist-get event :id) "7"))
        (should (equal (plist-get event :text) "replacement"))))
    (should-not (vox-qwen-audio-normalize
                 (vox-qwen-audio-test--event session "result-generated" '(:heartbeat t)))))
  (should-not (vox-qwen-audio-normalize '(:header (:event "future-event"))))
  (let ((event (vox-qwen-audio-normalize
                '(:header (:event "task-failed" :error_code "private-code"
                                  :error_message "private-transcript-and-key")))))
    (should (eq (plist-get event :type) :error))
    (should-not (string-match-p "private-" (prin1-to-string event)))))

(ert-deftest vox-qwen-audio-normalization-rejects-malformed-sentences ()
  :tags '(vox-unit)
  (let ((session (vox--make-session :backend-state '(:task-id "synthetic"))))
    (dolist (sentence '((:sentence_id 0 :text "bad" :sentence_end t)
                        (:sentence_id -1 :text "bad" :sentence_end t)
                        (:sentence_id "1" :text "bad" :sentence_end t)
                        (:sentence_id 1.5 :text "bad" :sentence_end t)
                        (:sentence_id 1 :text nil :sentence_end t)
                        (:sentence_id 1 :text "bad" :sentence_end nil)
                        (:sentence_id 1 :text "bad" :sentence_end 1)
                        (:sentence_id 1 :text "bad")))
      (should-error
       (vox-qwen-audio-normalize
        (vox-qwen-audio-test--event session "result-generated" sentence))))))

(ert-deftest vox-qwen-audio-ready-binary-finish-order-and-idempotence ()
  :tags '(vox-unit)
  (vox-qwen-audio-test--adapter
    (should (equal url "wss://dashscope.aliyuncs.com/api-ws/v1/inference"))
    (should (equal (cdr (assoc "Authorization" headers)) "Bearer synthetic-key"))
    (should-not sent)
    (should-error (vox-qwen-audio-send-pcm session (unibyte-string 1 2)))
    (funcall (nth 0 callbacks))
    (should (= ready 0))
    (let ((task-id (plist-get (vox-session-backend-state session) :task-id)))
      (should (string-match-p
               "\\`[[:xdigit:]]\\{8\\}-[[:xdigit:]]\\{4\\}-[[:xdigit:]]\\{4\\}-[[:xdigit:]]\\{4\\}-[[:xdigit:]]\\{12\\}\\'"
               task-id))
      (should (equal (plist-get (plist-get (cdar sent) :header) :task_id) task-id))
      (vox-qwen-audio-test--deliver session "task-started")
      (vox-qwen-audio-test--deliver session "task-started")
      (should (= ready 1))
      (vox-qwen-audio-send-pcm session (unibyte-string 0 255 128 1))
      (should (equal (car sent) (cons 'binary (unibyte-string 0 255 128 1))))
      (should-error (vox-qwen-audio-send-pcm session (unibyte-string 1)))
      (should-error (vox-qwen-audio-send-pcm session (string #x100)))
      (vox-qwen-audio-finish session)
      (vox-qwen-audio-finish session)
      (should (= (length sent) 3))
      (should (equal (mapcar #'car (reverse sent)) '(text binary text)))
      (should (equal (plist-get (plist-get (cdar sent) :header) :action) "finish-task"))
      (should (equal (plist-get (plist-get (cdar sent) :header) :task_id) task-id))
      (should-error (vox-qwen-audio-send-pcm session (unibyte-string 1 2)))
      (vox-qwen-audio-test--deliver session "task-finished")
      (vox-qwen-audio-test--deliver session "task-finished")
      (funcall (nth 3 callbacks))
      (should (equal (mapcar (lambda (event) (plist-get event :type)) events) '(:completed)))
      (should-not errors)
      (vox-qwen-audio-close session)
      (vox-qwen-audio-close session)
      (should (= closed 1)))))

(ert-deftest vox-qwen-audio-terminal-and-malformed-guards ()
  :tags '(vox-unit)
  (vox-qwen-audio-test--adapter
    (should-error (vox-qwen-audio-finish session))
    (should-error (vox-qwen-audio--message session "{}" 'binary))
    (should-error (vox-qwen-audio--message session "not-json" 'text))
    (should-error (vox-qwen-audio--message session (make-string (1+ (* 1024 1024)) ?x) 'text))
    (should-error (vox-qwen-audio--message
                   session "{\"header\":{\"event\":\"task-started\",\"task_id\":\"wrong\"}}" 'text))
    (should (= ready 0))
    (should-error (vox-qwen-audio-test--deliver
                   session "result-generated"
                   '(:sentence_id 1 :text "premature" :sentence_end t)))
    (should-error (vox-qwen-audio-test--deliver session "task-finished"))
    (should-not events)
    (funcall (nth 3 callbacks))
    (should (= (length errors) 1))
    (should (stringp (car errors)))
    (vox-qwen-audio-close session)
    (vox-qwen-audio--message session "invalid after close" 'binary)
    (should-not events)))

(ert-deftest vox-qwen-audio-final-sentences-suppress-late-and-duplicate-events ()
  :tags '(vox-unit)
  (vox-qwen-audio-test--adapter
    (vox-qwen-audio-test--deliver session "task-started")
    (dolist (sentence '((:sentence_id 1 :text "draft" :sentence_end :false)
                        (:sentence_id 1 :text "revised" :sentence_end :false)
                        (:heartbeat t)
                        (:sentence_id 1 :text "Final." :sentence_end t)
                        (:sentence_id 1 :text "late" :sentence_end :false)
                        (:sentence_id 1 :text "duplicate-final" :sentence_end t)
                        (:sentence_id 2 :text " Next." :sentence_end t)))
      (vox-qwen-audio-test--deliver session "result-generated" sentence))
    (should (equal (mapcar (lambda (event) (plist-get event :text)) (reverse events))
                   '("draft" "revised" "Final." " Next.")))
    (vox-qwen-audio-finish session)
    (vox-qwen-audio-test--deliver session "task-finished")
    (let ((before (copy-sequence events)))
      (vox-qwen-audio-test--deliver
       session "result-generated" '(:sentence_id 3 :text "after finish" :sentence_end t))
      (should (equal before events)))))

(ert-deftest vox-qwen-audio-pending-partial-never-becomes-authoritative ()
  :tags '(vox-unit)
  (vox-qwen-audio-test--adapter
    (vox-qwen-audio-test--deliver session "task-started")
    (vox-qwen-audio-test--deliver
     session "result-generated" '(:sentence_id 1 :text "unfinished" :sentence_end :false))
    (vox-qwen-audio-finish session)
    (should-error (vox-qwen-audio-test--deliver session "task-finished"))
    (should (equal (mapcar (lambda (event) (plist-get event :type)) events)
                   '(:segment-partial)))))

(ert-deftest vox-qwen-audio-item-count-is-bounded ()
  :tags '(vox-unit)
  (let ((vox-max-segments 2))
    (vox-qwen-audio-test--adapter
      (vox-qwen-audio-test--deliver session "task-started")
      (dolist (id '(1 2))
        (vox-qwen-audio-test--deliver
         session "result-generated" (list :sentence_id id :text "" :sentence_end t)))
      (should-error (vox-qwen-audio-test--deliver
                     session "result-generated" '(:sentence_id 3 :text "" :sentence_end t)))
      (should (= (length events) 2))
      (should (= (hash-table-count (plist-get (vox-session-backend-state session) :items)) 2)))))

(ert-deftest vox-qwen-audio-captures-model-language-and-silence-before-open ()
  :tags '(vox-unit)
  (let* ((vox-qwen-audio-silence-ms 600)
         (language (copy-sequence "en"))
         (configuration (vox-make-qwen-audio "Captured" :models '(first selected)
                                               :language language :key "synthetic"))
         (session (vox--make-session :generation 1 :state 'connecting
                                     :methods (vox-backend-methods configuration 'selected)))
         (vox--active-session session) open request)
    (aset language 0 ?X)
    (setf (vox-backend-language configuration) "ja")
    (cl-letf (((symbol-function 'vox-transport-open)
               (lambda (_session _url _headers callback &rest _) (setq open callback)))
              ((symbol-function 'vox-transport-send-text)
               (lambda (_session text) (setq request (vox-json-read text)))))
      (vox-qwen-audio-connect session #'ignore #'ignore #'ignore)
      (setq vox-qwen-audio-silence-ms 900)
      (funcall open)
      (let* ((payload (plist-get request :payload))
             (parameters (plist-get payload :parameters)))
        (should (equal (plist-get payload :model) "selected"))
        (should (equal (plist-get parameters :language_hints) '("en")))
        (should (= (plist-get parameters :max_sentence_silence) 600))))))

(ert-deftest vox-qwen-audio-custom-host-approval-precedes-key ()
  :tags '(vox-unit)
  (dolist (approved '(nil t))
    (let* ((noninteractive nil) order
           (configuration (vox-make-qwen-audio
                           "Custom" :host "stream.example.test:9443"
                           :key (lambda () (push 'key order) "synthetic")))
           (session (vox--make-session :generation 1 :state 'connecting
                                       :methods (vox-backend-methods configuration)))
           (vox--active-session session))
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (lambda (_) (push 'approval order) approved))
                ((symbol-function 'vox-transport-open)
                 (lambda (&rest _) (push 'transport order))))
        (if approved
            (progn
              (vox-qwen-audio-connect session #'ignore #'ignore #'ignore)
              (should (equal (reverse order) '(approval key transport))))
          (should-error (vox-qwen-audio-connect session #'ignore #'ignore #'ignore)
                        :type 'user-error)
          (should (equal order '(approval))))))))

(ert-deftest vox-qwen-audio-stale-session-does-not-resolve-credentials ()
  :tags '(vox-unit)
  (let* ((vox--active-session nil) key-read opened
         (session (vox--make-session :generation 1 :state 'connecting
                                     :methods (vox-backend-methods 'qwen-audio))))
    (cl-letf (((symbol-function 'vox-backend-secret)
               (lambda (&rest _) (setq key-read t) "synthetic"))
              ((symbol-function 'vox-transport-open)
               (lambda (&rest _) (setq opened t))))
      (should-error (vox-qwen-audio-connect session #'ignore #'ignore #'ignore))
      (should-not key-read)
      (should-not opened))))

(ert-deftest vox-qwen-audio-key-cancellation-does-not-resurrect-state ()
  :tags '(vox-unit)
  (let* ((vox--active-session nil) (vox--last-session nil) opened
         (configuration (vox-make-qwen-audio
                         "Cancel" :key (lambda () (vox-core-cancel) "synthetic"))))
    (cl-letf (((symbol-function 'vox-transport-open)
               (lambda (&rest _) (setq opened t)))
              ((symbol-function 'vox-transport-close) #'ignore)
              ((symbol-function 'vox-audio-cancel) #'ignore))
      (with-temp-buffer
        (unwind-protect
            (let ((session (vox-core-start configuration nil)))
              (should (eq (vox-session-state session) 'cancelled))
              (should (vox-session-cleaned session))
              (should-not (vox-session-backend-state session))
              (should-not opened)
              (should-not vox--active-session))
          (vox-core-cancel))))))

(ert-deftest vox-qwen-audio-core-commits-final-sentences-only-after-task-finished ()
  :tags '(vox-unit)
  (let ((vox--active-session nil) (vox--last-session nil)
        (vox-stop-mode 'manual) commits captured sent (recordings 0))
    (cl-letf (((symbol-function 'vox-transport-open)
               (lambda (session _url _headers open message _error _close)
                 (setq captured (list session open message))))
              ((symbol-function 'vox-transport-send-text)
               (lambda (_session text) (push (cons 'text (vox-json-read text)) sent)))
              ((symbol-function 'vox-transport-send-binary)
               (lambda (_session bytes) (push (cons 'binary bytes) sent)))
              ((symbol-function 'vox-transport-close) #'ignore)
              ((symbol-function 'vox-audio-start)
               (lambda (&rest _) (cl-incf recordings) nil))
              ((symbol-function 'vox-audio-stop) #'vox-core-audio-ended)
              ((symbol-function 'vox-audio-cancel) #'ignore))
      (with-temp-buffer
        (unwind-protect
            (let ((session
                   (vox-core-start
                    (vox-make-qwen-audio "Core" :key "synthetic")
                    (list :on-finish (lambda (_session text) (push text commits))))))
              (should (eq session (car captured)))
              (should (= recordings 0))
              (funcall (nth 1 captured))
              (should (= recordings 0))
              (vox-qwen-audio-test--deliver session "task-started")
              (should (= recordings 1))
              (vox-qwen-audio-test--deliver
               session "result-generated" '(:sentence_id 1 :text "dra" :sentence_end :false))
              (vox-qwen-audio-test--deliver
               session "result-generated" '(:sentence_id 1 :text "First." :sentence_end t))
              (vox-qwen-audio-test--deliver
               session "result-generated" '(:sentence_id 2 :text " Second." :sentence_end t))
              (should (equal (vox-session-text session t) "First. Second."))
              (should-not commits)
              (vox-core-audio session (unibyte-string 1 2 3 4))
              (vox-core-stop session)
              (should (eq (vox-session-state session) 'finalizing))
              (should (equal (mapcar #'car (reverse sent)) '(text binary text)))
              (should (equal (cdr (cadr (reverse sent))) (unibyte-string 1 2 3 4)))
              (should-not commits)
              (vox-qwen-audio-test--deliver session "task-finished")
              (should (equal commits '("First. Second.")))
              (should (eq (vox-session-state session) 'completed))
              (should (vox-session-cleaned session))
              (should-not (vox-session-backend-state session))
              (should-not vox--active-session))
          (vox-core-cancel))))))

(ert-deftest vox-qwen-audio-approval-cancel-prevents-key-and-transport ()
  :tags '(vox-unit)
  (let* ((noninteractive nil) (vox--active-session nil) (vox--last-session nil)
         key-read opened
         (configuration (vox-make-qwen-audio
                         "Cancel approval" :host "custom.example.test"
                         :key (lambda () (setq key-read t) "synthetic"))))
    (cl-letf (((symbol-function 'yes-or-no-p)
               (lambda (_) (vox-core-cancel) t))
              ((symbol-function 'vox-transport-open)
               (lambda (&rest _) (setq opened t)))
              ((symbol-function 'vox-transport-close) #'ignore)
              ((symbol-function 'vox-audio-cancel) #'ignore))
      (with-temp-buffer
        (unwind-protect
            (let ((session (vox-core-start configuration nil)))
              (should (eq (vox-session-state session) 'cancelled))
              (should (vox-session-cleaned session))
              (should-not (vox-session-backend-state session))
              (should-not key-read)
              (should-not opened)
              (should-not vox--active-session))
          (vox-core-cancel))))))

(ert-deftest vox-qwen-audio-default-key-uses-connection-host ()
  :tags '(vox-unit)
  (let* ((configuration (vox-make-qwen-audio
                         "Auth" :host "dashscope-intl.aliyuncs.com"))
         (session (vox--make-session :generation 1 :state 'connecting
                                     :methods (vox-backend-methods configuration)))
         (vox--active-session session) queried headers)
    (cl-letf (((symbol-function 'auth-source-search)
               (lambda (&rest args)
                 (setq queried (list (plist-get args :host) (plist-get args :user)))
                 '((:secret "synthetic-auth"))))
              ((symbol-function 'getenv)
               (lambda (&rest _) (ert-fail "Default key read environment")))
              ((symbol-function 'vox-transport-open)
               (lambda (_session _url h &rest _) (setq headers h))))
      (vox-qwen-audio-connect session #'ignore #'ignore #'ignore)
      (should (equal queried '("dashscope-intl.aliyuncs.com" "apikey")))
      (should (equal (cdr (assoc "Authorization" headers)) "Bearer synthetic-auth")))))

(ert-deftest vox-qwen-audio-reentrant-cleanup-is-not-overwritten ()
  :tags '(vox-unit)
  (dolist (boundary '(ready pcm finish))
    (let ((vox--active-session nil) (vox--last-session nil)
          (vox-stop-mode 'manual) captured (closed 0))
      (cl-letf (((symbol-function 'vox-transport-open)
                 (lambda (session &rest _) (setq captured session)))
                ((symbol-function 'vox-transport-send-text)
                 (lambda (session _text)
                   (when (eq boundary 'finish) (vox-core-cancel session))))
                ((symbol-function 'vox-transport-send-binary)
                 (lambda (session _bytes)
                   (when (eq boundary 'pcm) (vox-core-cancel session))))
                ((symbol-function 'vox-transport-close)
                 (lambda (_) (cl-incf closed)))
                ((symbol-function 'vox-audio-start) (lambda (&rest _) nil))
                ((symbol-function 'vox-audio-stop) #'vox-core-audio-ended)
                ((symbol-function 'vox-audio-cancel) #'ignore))
        (with-temp-buffer
          (unwind-protect
              (let ((session
                     (vox-core-start
                      (vox-make-qwen-audio "Reentry" :key "synthetic")
                      (list :on-state
                            (lambda (session state)
                              (when (and (eq boundary 'ready) (eq state 'recording))
                                (vox-core-cancel session)))))))
                (should (eq session captured))
                (vox-qwen-audio-test--deliver session "task-started")
                (pcase boundary
                  ('pcm (vox-core-audio session (make-string 3200 1)))
                  ('finish (vox-core-stop session)))
                (should (eq (vox-session-state session) 'cancelled))
                (should (vox-session-cleaned session))
                (should-not (vox-session-backend-state session))
                (should-not vox--active-session)
                (should (= closed 1)))
            (vox-core-cancel)))))))

(ert-deftest vox-qwen-audio-core-failure-paths-never-commit ()
  :tags '(vox-unit)
  (dolist (failure '(pending-partial task-failed early-close premature-finish))
    (let ((vox--active-session nil) (vox--last-session nil)
          (vox-stop-mode 'manual) message-callback close-callback commits errors)
      (cl-letf (((symbol-function 'vox-transport-open)
                 (lambda (session _url _headers _open message _error close)
                   ;; Model the shared transport's callback error/generation guard.
                   (setq message-callback
                         (vox--guard session (vox-session-generation session) message)
                         close-callback close)))
                ((symbol-function 'vox-transport-send-text) #'ignore)
                ((symbol-function 'vox-transport-close) #'ignore)
                ((symbol-function 'vox-audio-start) (lambda (&rest _) nil))
                ((symbol-function 'vox-audio-stop) #'vox-core-audio-ended)
                ((symbol-function 'vox-audio-cancel) #'ignore))
        (with-temp-buffer
          (unwind-protect
              (let ((session
                     (vox-core-start
                      (vox-make-qwen-audio "Failure" :key "synthetic")
                      (list :on-finish (lambda (_ text) (push text commits))
                            :on-error (lambda (_ message) (push message errors))))))
                (vox-qwen-audio-test--deliver session "task-started")
                (vox-qwen-audio-test--deliver
                 session "result-generated"
                 '(:sentence_id 1 :text "private-unfinished" :sentence_end :false))
                (pcase failure
                  ('early-close (funcall close-callback))
                  ('task-failed
                   (let ((event (vox-qwen-audio-test--event session "task-failed")))
                     (setf (plist-get (plist-get event :header) :error_message) "private-error")
                     (funcall message-callback (vox-json-encode event) 'text)))
                  (_
                   (when (eq failure 'pending-partial) (vox-core-stop session))
                   (funcall message-callback
                            (vox-json-encode (vox-qwen-audio-test--event session "task-finished"))
                            'text)))
                (should (eq (vox-session-state session) 'error))
                (should (vox-session-cleaned session))
                (should-not (vox-session-backend-state session))
                (should-not commits)
                (should (= (length errors) 1))
                (should-not (string-match-p "private-" (prin1-to-string errors)))
                (should-not vox--active-session))
            (vox-core-cancel)))))))

(ert-deftest vox-qwen-audio-zero-audio-finish-needs-no-sentence ()
  :tags '(vox-unit)
  (vox-qwen-audio-test--adapter
    (funcall (nth 0 callbacks))
    (vox-qwen-audio-test--deliver session "task-started")
    (vox-qwen-audio-send-pcm session (unibyte-string))
    (vox-qwen-audio-finish session)
    (should (equal (mapcar #'car sent) '(text text)))
    (should-not events)
    (vox-qwen-audio-test--deliver session "task-finished")
    (should (equal (mapcar (lambda (event) (plist-get event :type)) events) '(:completed)))
    (should-not errors)))

(provide 'vox-test-qwen-audio)
;;; vox-test-qwen-audio.el ends here
