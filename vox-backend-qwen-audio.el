;;; vox-backend-qwen-audio.el --- Qwen task-streaming ASR -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; DashScope run-task protocol, distinct from Qwen's Realtime API.
;; PCM16LE, 16000 Hz, mono travels in binary WebSocket frames.
;;; Code:
(require 'vox-backend)
(require 'vox-transport)
(require 'vox-core)

(defcustom vox-qwen-audio-silence-ms 800
  "Server sentence-ending silence threshold in milliseconds, 200 to 6000.
This is independent of local automatic recording stop."
  :type 'integer :group 'vox)

(defun vox-qwen-audio--task-id ()
  "Generate a UUID-format task correlation ID, not a credential."
  (format "%08x-%04x-4%03x-%04x-%04x%08x"
          (random #x100000000) (random #x10000) (random #x1000)
          (logior #x8000 (random #x4000))
          (random #x10000) (random #x100000000)))

(defun vox-qwen-audio-run-task (task-id model &optional language)
  "Build run-task for TASK-ID and MODEL, optionally hinting LANGUAGE."
  (unless (and (integerp vox-qwen-audio-silence-ms)
               (<= 200 vox-qwen-audio-silence-ms 6000))
    (error "Qwen Audio silence duration must be between 200 and 6000 ms"))
  (let ((parameters (list :format "pcm" :sample_rate 16000
                          :max_sentence_silence vox-qwen-audio-silence-ms)))
    (when language
      (setq parameters (plist-put parameters :language_hints (vector language))))
    (list :header (list :action "run-task" :task_id task-id :streaming "duplex")
          :payload (list :task_group "audio" :task "asr" :function "recognition"
                         :model model :parameters parameters
                         :input (make-hash-table :test #'equal)))))

(defun vox-qwen-audio-normalize (object)
  "Normalize a decoded streaming OBJECT without retaining provider metadata.
Sentence text replaces the earlier text for that ID; it is not a delta.
Heartbeats and unrelated events are ignored.  Errors omit provider echoes."
  (pcase (plist-get (plist-get object :header) :event)
    ("task-started" (list :type :ready))
    ("task-finished" (list :type :completed))
    ("task-failed" (list :type :error :code "provider-error"
                         :message "Qwen Audio rejected the task"))
    ("result-generated"
     (let* ((sentence (plist-get (plist-get (plist-get object :payload) :output)
                                 :sentence))
            (id (plist-get sentence :sentence_id))
            (text (plist-get sentence :text))
            (final (plist-get sentence :sentence_end)))
       (unless (eq (plist-get sentence :heartbeat) t)
         (unless (and (integerp id) (> id 0) (stringp text)
                      (memq final '(t :false)))
           (error "Invalid Qwen Audio sentence"))
         (list :type (if (eq final t) :segment-final :segment-partial)
               :id (number-to-string id) :text text))))))

(defun vox-qwen-audio--put (session key value)
  "Store VALUE under KEY in SESSION adapter state."
  (setf (vox-session-backend-state session)
        (plist-put (vox-session-backend-state session) key value)))

(defun vox-qwen-audio--message (session payload opcode)
  "Process one complete text PAYLOAD with OPCODE for SESSION."
  (let ((state (vox-session-backend-state session)))
    (unless (or (plist-get state :closed) (plist-get state :completed))
      (unless (and (eq opcode 'text) (stringp payload)
                   (<= (string-bytes payload) (* 1024 1024)))
        (error "Invalid Qwen Audio message frame"))
      (let* ((object (vox-json-read payload))
             (task-id (plist-get (plist-get object :header) :task_id))
             (event (vox-qwen-audio-normalize object))
             (kind (plist-get event :type))
             (items (plist-get state :items)))
        (unless (and (stringp task-id)
                     (equal task-id (plist-get state :task-id)))
          (error "Qwen Audio task ID mismatch"))
        (pcase kind
          (:ready
           (unless (plist-get state :ready)
             (vox-qwen-audio--put session :ready t)
             (vox-log-event (vox-session-generation session) 'provider-event :kind 'ready)
             (funcall (plist-get state :on-ready))))
          (:error
           (funcall (plist-get state :on-error) (plist-get event :message)))
          (:completed
           (unless (and (plist-get state :ready) (plist-get state :finished))
             (error "Unexpected Qwen Audio completion before finish"))
           ;; Never promote a provisional sentence merely because the task ended.
           (let (pending)
             (maphash (lambda (_id status)
                        (unless (eq status 'final) (setq pending t))) items)
             (when pending (error "Qwen Audio ended with an unfinished sentence")))
           (vox-qwen-audio--put session :completed t)
           (funcall (plist-get state :on-event) event))
          ((or :segment-partial :segment-final)
           (unless (plist-get state :ready)
             (error "Qwen Audio result before task-started"))
           (let* ((id (plist-get event :id))
                  (previous (gethash id items)))
             (unless (eq previous 'final)
               (unless (or previous (< (hash-table-count items) vox-max-segments))
                 (error "Qwen Audio sentence limit exceeded"))
               (puthash id (if (eq kind :segment-final) 'final 'partial) items)
               (funcall (plist-get state :on-event) event)))))))))

(defun vox-qwen-audio-connect (session on-ready on-event on-error)
  "Connect SESSION with ON-READY, ON-EVENT and ON-ERROR callbacks."
  (let* ((generation (vox-session-generation session))
         (methods (if (plist-get (vox-session-methods session) :configuration)
                      (vox-session-methods session)
                    (vox-backend-methods 'qwen-audio)))
         (configuration (plist-get methods :configuration))
         (model (plist-get methods :model))
         (url (vox-backend-url configuration model))
         (_ (vox--require-live session generation))
         (_ (vox-check-endpoint url '("dashscope.aliyuncs.com"
                                      "dashscope-intl.aliyuncs.com")))
         (_ (vox--require-live session generation))
         (secret (vox-backend-secret configuration
                                     (url-host (url-generic-parse-url url)))))
    (vox--require-live session generation)
    (let* ((task-id (vox-qwen-audio--task-id))
           (request (vox-json-encode
                     (vox-qwen-audio-run-task
                      task-id model (vox-backend-language configuration)))))
      (setf (vox-session-backend-state session)
            (list :task-id task-id :items (make-hash-table :test #'equal)
                  :on-ready on-ready :on-event on-event :on-error on-error))
      (vox-transport-open
       session url (list (cons "Authorization" (concat "Bearer " secret)))
       (lambda () (vox-transport-send-text session request))
       (lambda (payload opcode) (vox-qwen-audio--message session payload opcode))
       on-error
       (lambda ()
         (let ((state (vox-session-backend-state session)))
           (unless (or (plist-get state :closed) (plist-get state :completed))
             (funcall on-error "Qwen Audio connection closed before task-finished"))))))))

(defun vox-qwen-audio-send-pcm (session bytes)
  "Send raw unibyte PCM BYTES for ready SESSION."
  (let ((state (vox-session-backend-state session)))
    (unless (and (plist-get state :ready) (not (plist-get state :finished))
                 (not (plist-get state :closed)) (not (plist-get state :completed))
                 (stringp bytes) (not (multibyte-string-p bytes))
                 (zerop (% (length bytes) 2)))
      (error "Qwen Audio is not ready for PCM or PCM is invalid"))
    (unless (zerop (length bytes))
      (vox-transport-send-binary session bytes))))

(defun vox-qwen-audio-finish (session)
  "Send finish-task exactly once for SESSION, after all audio is drained."
  (let ((state (vox-session-backend-state session)))
    (unless (or (plist-get state :finished) (plist-get state :closed)
                (plist-get state :completed))
      (unless (plist-get state :ready) (error "Qwen Audio is not ready to finish"))
      (vox-qwen-audio--put session :finished t)
      (vox-transport-send-text
       session (vox-json-encode
                (list :header (list :action "finish-task"
                                    :task_id (plist-get state :task-id)
                                    :streaming "duplex")
                      :payload (list :input (make-hash-table :test #'equal))))))))

(defun vox-qwen-audio-close (session)
  "Close SESSION without sending finish-task or committing a hypothesis."
  (unless (plist-get (vox-session-backend-state session) :closed)
    (vox-qwen-audio--put session :closed t)
    (vox-transport-close session)))

(vox-register-backend
 'qwen-audio
 (list :connect #'vox-qwen-audio-connect :send-pcm #'vox-qwen-audio-send-pcm
       :finish #'vox-qwen-audio-finish :cancel #'vox-qwen-audio-close
       :close #'vox-qwen-audio-close :needs-external-audio t :chunk-ms 100))

(provide 'vox-backend-qwen-audio)
;;; vox-backend-qwen-audio.el ends here
