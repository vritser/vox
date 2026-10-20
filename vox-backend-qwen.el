;;; vox-backend-qwen.el --- Qwen realtime ASR adapter -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; VAD only.  Audio is PCM16LE, 16000 Hz, mono.  See docs/protocol-audit.md.
;;; Code:
(require 'vox-backend)
(require 'vox-transport)
(require 'vox-core)

(defcustom vox-qwen-language "zh"
  "Qwen source language, or nil for automatic detection."
  :type '(choice (const :tag "Automatic" nil) string) :group 'vox)
(defcustom vox-qwen-silence-ms 400
  "Server VAD silence duration in milliseconds, between 200 and 6000."
  :type 'integer :group 'vox)

(defun vox-qwen-session-update (event-id)
  "Build a VAD session.update object using EVENT-ID."
  (unless (and (integerp vox-qwen-silence-ms)
               (<= 200 vox-qwen-silence-ms 6000))
    (error "Qwen silence duration must be between 200 and 6000 ms"))
  (let ((session (list :input_audio_format "pcm" :sample_rate 16000
                       :turn_detection
                       (list :type "server_vad" :threshold 0.0
                             :silence_duration_ms vox-qwen-silence-ms))))
    (when vox-qwen-language
      (setq session (plist-put session :input_audio_transcription
                               (list :language vox-qwen-language))))
    (list :event_id event-id :type "session.update" :session session)))

(defun vox-qwen-normalize (object)
  "Purely normalize a decoded server OBJECT; ignore unrelated events.
Provider errors intentionally omit untrusted messages and parameter echoes."
  (let ((type (plist-get object :type)) (id (plist-get object :item_id)))
    (pcase type
      ("session.updated" (list :type :ready))
      ("session.finished" (list :type :completed))
      ("conversation.item.input_audio_transcription.text"
       (unless (and (stringp id) (> (length id) 0)
                    (stringp (plist-get object :text))
                    (stringp (plist-get object :stash)))
         (error "Invalid Qwen partial event"))
       (list :type :segment-partial :id id
             :text (concat (plist-get object :text) (plist-get object :stash))))
      ("conversation.item.input_audio_transcription.completed"
       (unless (and (stringp id) (> (length id) 0)
                    (stringp (plist-get object :transcript)))
         (error "Invalid Qwen final event"))
       (list :type :segment-final :id id :text (plist-get object :transcript)))
      ("conversation.item.input_audio_transcription.failed"
       (list :type :error :code "transcription-failed"
             :message "Qwen could not transcribe an audio item"))
      ("error" (list :type :error :code "provider-error"
                     :message "Qwen rejected the request")))))

(defun vox-qwen--put (session key value)
  "Store VALUE under KEY in SESSION adapter state."
  (setf (vox-session-backend-state session)
        (plist-put (vox-session-backend-state session) key value)))

(defun vox-qwen--event-id (session)
  "Allocate a unique event identifier within SESSION."
  (let ((counter (1+ (or (plist-get (vox-session-backend-state session) :counter) 0))))
    (vox-qwen--put session :counter counter)
    (format "vox-%s-%s-%d" (vox-session-id session)
            (vox-session-generation session) counter)))

(defun vox-qwen--message (session payload opcode)
  "Handle one complete text PAYLOAD with OPCODE for SESSION."
  (unless (plist-get (vox-session-backend-state session) :closed)
    (let* ((state (vox-session-backend-state session))
           (event (progn
                    (unless (and (eq opcode 'text) (stringp payload)
                                 (<= (string-bytes payload) (* 1024 1024)))
                      (error "Invalid Qwen message frame"))
                    (vox-qwen-normalize (vox-json-read payload))))
           (kind (plist-get event :type))
           (id (plist-get event :id)))
      (pcase kind
        (:ready
         (unless (plist-get state :ready)
           (vox-qwen--put session :ready t)
           (funcall (plist-get state :on-ready))))
        (:error (funcall (plist-get state :on-error) (plist-get event :message)))
        (:completed
         (unless (plist-get state :finished)
           (error "Unexpected Qwen completion before finish"))
         (unless (plist-get state :completed)
           (vox-qwen--put session :completed t)
           (funcall (plist-get state :on-event) event)))
        (:segment-partial
         (unless (gethash id (plist-get state :final-items))
           (funcall (plist-get state :on-event) event)))
        (:segment-final
         (puthash id t (plist-get state :final-items))
         (funcall (plist-get state :on-event) event))))))

(defun vox-qwen-connect (session on-ready on-event on-error)
  "Connect SESSION with ON-READY, ON-EVENT, and ON-ERROR callbacks."
  (let* ((generation (vox-session-generation session))
         (methods (if (plist-get (vox-session-methods session) :configuration)
                      (vox-session-methods session)
                    (vox-backend-methods 'qwen)))
         (configuration (plist-get methods :configuration))
         (model (plist-get methods :model))
         (url (vox-backend-url configuration model))
         ;; Endpoint approval and key functions may reentrantly cancel SESSION.
         (_ (vox--require-live session generation))
         (_ (vox-check-endpoint url '("dashscope.aliyuncs.com"
                                      "dashscope-intl.aliyuncs.com")))
         (_ (vox--require-live session generation))
         (host (url-host (url-generic-parse-url url)))
         (secret (vox-backend-secret configuration host)))
    (vox--require-live session generation)
    (setf (vox-session-backend-state session)
          (list :on-ready on-ready :on-event on-event :on-error on-error
                :final-items (make-hash-table :test #'equal)))
    (let ((request (vox-json-encode
                    (vox-qwen-session-update (vox-qwen--event-id session)))))
      (vox-transport-open
       session url (list (cons "Authorization" (concat "Bearer " secret)))
       (lambda () (vox-transport-send-text session request))
       (lambda (payload opcode) (vox-qwen--message session payload opcode))
       on-error
       (lambda ()
         (let ((state (vox-session-backend-state session)))
           (unless (or (plist-get state :closed) (plist-get state :completed))
             (funcall on-error "Qwen connection closed before session.finished"))))))))

(defun vox-qwen-send-pcm (session bytes)
  "Send unibyte PCM BYTES for ready SESSION."
  (let ((state (vox-session-backend-state session)))
    (unless (and (plist-get state :ready) (not (plist-get state :finished))
                 (not (plist-get state :closed))
                 (stringp bytes) (not (multibyte-string-p bytes))
                 (zerop (% (length bytes) 2)))
      (error "Qwen is not ready for PCM or PCM is invalid"))
    (unless (zerop (length bytes))
      (vox-transport-send-text
       session (vox-json-encode
                (list :event_id (vox-qwen--event-id session)
                      :type "input_audio_buffer.append"
                      :audio (base64-encode-string bytes t)))))))

(defun vox-qwen-finish (session)
  "Send VAD session.finish exactly once for SESSION."
  (let ((state (vox-session-backend-state session)))
    (unless (or (plist-get state :finished) (plist-get state :closed))
      (unless (plist-get state :ready) (error "Qwen is not ready to finish"))
      (vox-qwen--put session :finished t)
      (vox-transport-send-text
       session (vox-json-encode
                (list :event_id (vox-qwen--event-id session) :type "session.finish"))))))

(defun vox-qwen-close (session)
  "Close SESSION without committing an incomplete hypothesis."
  (unless (plist-get (vox-session-backend-state session) :closed)
    (vox-qwen--put session :closed t)
    (vox-transport-close session)))

(vox-register-backend
 'qwen (list :connect #'vox-qwen-connect :send-pcm #'vox-qwen-send-pcm
             :finish #'vox-qwen-finish :cancel #'vox-qwen-close :close #'vox-qwen-close
             :needs-external-audio t :chunk-ms 100))

(provide 'vox-backend-qwen)
;;; vox-backend-qwen.el ends here
