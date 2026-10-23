;;; vox-tts-qwen.el --- Qwen Realtime streaming speech synthesis -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Qwen application events over the shared guarded websocket.el transport.
;; ServerCommit accepts producer fragments; session.finished completes synthesis.
;;; Code:
(require 'vox-tts)
(require 'vox-transport)

(cl-defstruct (vox-tts-qwen--context (:constructor vox-tts-qwen--make-context))
  owner backend id phase timer busy write-failed closing closed responses (received 0))

(defun vox-tts-qwen--send (context type &optional fields)
  "Send event TYPE with FIELDS for CONTEXT without nested writes."
  (when (or (vox-tts-qwen--context-closed context) (vox-tts-qwen--context-busy context))
    (error "TTS connection is closed or already sending"))
  (let ((owner (vox-tts-qwen--context-owner context)) completed)
    (setf (vox-tts-qwen--context-busy context) t (vox-tts--session-input-ready owner) nil)
    (unwind-protect
        (prog1 (vox-transport-send-text
                context (vox-json-encode
                         (append `((event_id . ,(vox-tts--request-id)) (type . ,type)) fields)))
          (setq completed t))
      (setf (vox-tts-qwen--context-busy context) nil)
      (unless completed (setf (vox-tts-qwen--context-write-failed context) t))
      (when (and completed (vox-tts--live-p owner)
                 (not (vox-tts-qwen--context-closed context))
                 (eq (vox-tts-qwen--context-phase context) 'ready))
        (setf (vox-tts--session-input-ready owner) t)
        (vox-tts--input-schedule owner)))))

(defun vox-tts-qwen--close (context)
  "Try clearing queued text, then dispose CONTEXT without waiting for an ack.
An in-flight or failed write must never be followed by a nested clear frame.
Clearing buffered text does not establish cancellation of accepted synthesis."
  (unless (or (vox-tts-qwen--context-closed context) (vox-tts-qwen--context-closing context))
    (setf (vox-tts-qwen--context-closing context) t)
    (when (timerp (vox-tts-qwen--context-timer context))
      (cancel-timer (vox-tts-qwen--context-timer context)))
    (setf (vox-tts-qwen--context-timer context) nil)
    (unwind-protect
        (when (and (not (vox-tts-qwen--context-busy context))
                   (not (vox-tts-qwen--context-write-failed context))
                   (memq (vox-tts-qwen--context-phase context) '(ready finishing)))
          (ignore-errors (vox-tts-qwen--send context "input_text_buffer.clear")))
      (setf (vox-tts-qwen--context-closed context) t)
      (clrhash (vox-tts-qwen--context-responses context))
      (vox-transport-close context))))

(defun vox-tts-qwen--configure (context)
  "Configure CONTEXT outside the transport callback."
  (setf (vox-tts-qwen--context-timer context) nil)
  (let ((owner (vox-tts-qwen--context-owner context)))
    (when (and (vox-tts--live-p owner) (not (vox-tts-qwen--context-closed context))
               (eq (vox-tts-qwen--context-phase context) 'configure))
      (condition-case nil
          (progn
            (setf (vox-tts-qwen--context-phase context) 'await-session)
            (vox-tts-qwen--send
             context "session.update"
             `((session . ((voice . ,(vox-backend-voice (vox-tts-qwen--context-backend context)))
                           (mode . "server_commit") (language_type . "Auto")
                           (response_format . "pcm") (sample_rate . 24000))))))
        (quit (vox-tts--end owner 'cancelled) (signal 'quit nil))
        (error (vox-tts--fail owner))))))

(defun vox-tts-qwen--message (context bytes opcode)
  "Consume a Qwen event in BYTES with OPCODE for CONTEXT's captured owner."
  (let ((owner (vox-tts-qwen--context-owner context)))
    (when (and (vox-tts--live-p owner) (not (vox-tts-qwen--context-closed context))
               (not (vox-tts-qwen--context-closing context)))
      (unless (eq opcode 'text) (error "Expected JSON TTS response"))
      (cl-incf (vox-tts-qwen--context-received context) (string-bytes bytes))
      (when (> (vox-tts-qwen--context-received context) (vox-tts--session-response-limit owner))
        (error "TTS response limit exceeded"))
      (let* ((event (vox-json-read bytes)) (type (plist-get event :type))
             (phase (vox-tts-qwen--context-phase context))
             (settings (plist-get event :session))
             (responses (vox-tts-qwen--context-responses context)))
        (pcase type
          ("session.created"
           (unless (and (eq phase 'connecting) (stringp (plist-get settings :id))
                        (< 0 (length (plist-get settings :id)) 257))
             (error "Unexpected TTS session"))
           (setf (vox-tts-qwen--context-id context) (plist-get settings :id)
                 (vox-tts-qwen--context-phase context) 'configure
                 (vox-tts-qwen--context-timer context)
                 (run-at-time 0.01 nil #'vox-tts-qwen--configure context)))
          ("session.updated"
           (unless (and (eq phase 'await-session)
                        (equal (plist-get settings :id) (vox-tts-qwen--context-id context))
                        (equal (plist-get settings :mode) "server_commit")
                        (equal (plist-get settings :voice)
                               (vox-backend-voice (vox-tts-qwen--context-backend context)))
                        (equal (plist-get settings :response_format) "pcm")
                        (equal (plist-get settings :sample_rate) 24000))
             (error "Unexpected TTS configuration"))
           (setf (vox-tts-qwen--context-phase context) 'ready)
           (unless (vox-tts-qwen--context-busy context)
             (setf (vox-tts--session-input-ready owner) t)
             (vox-tts--input-schedule owner)))
          ("session.finished"
           (unless (and (eq phase 'finishing) (vox-tts--session-input-sent-finish owner)
                        (not (vox-tts--session-text-queue owner))
                        (zerop (hash-table-count responses))
                        (vox-tts--session-pcm-started owner)
                        (zerop (% (vox-tts--session-audio-bytes owner) 2)))
             (error "TTS completed before input or audio finished"))
           (setf (vox-tts-qwen--context-phase context) 'finished)
           (vox-tts-qwen--close context)
           (vox-tts--source-finished owner))
          (_
           (unless (memq phase '(ready finishing)) (error "TTS event before readiness"))
           (pcase type
             ("response.created"
              (let ((id (plist-get (plist-get event :response) :id)))
                (unless (and (stringp id) (< 0 (length id) 257)
                             (not (gethash id responses)) (< (hash-table-count responses) 4096))
                  (error "Invalid TTS response identifier"))
                (puthash id 'audio responses)))
             ("response.done"
              (let* ((response (plist-get event :response)) (id (plist-get response :id)))
                (unless (and (eq (gethash id responses) 'done)
                             (equal (plist-get response :status) "completed"))
                  (error "Incomplete TTS response"))
                (remhash id responses)))
             ((or "response.audio.delta" "response.audio.done"
                  "response.output_item.added" "response.output_item.done"
                  "response.content_part.added" "response.content_part.done")
              (let* ((id (plist-get event :response_id)) (state (gethash id responses)))
                (unless state (error "Unknown TTS response"))
                (cond
                 ((equal type "response.audio.delta")
                  (unless (eq state 'audio) (error "Audio after response completion"))
                  (let ((audio (base64-decode-string (plist-get event :delta))))
                    (unless (zerop (length audio))
                      (unless (vox-tts--session-pcm-started owner)
                        (setf (vox-tts--session-pcm-started owner) t)
                        (vox-tts--play owner vox-tts--pcm-wave-header))
                      (vox-tts--play owner audio))))
                 ((equal type "response.audio.done")
                  (unless (eq state 'audio) (error "Duplicate TTS audio completion"))
                  (puthash id 'done responses)))))
             ("input_text_buffer.committed" nil)
             (_ (error "TTS session failed or unexpected event")))))))))

(defun vox-tts-qwen-open (session backend model)
  "Open Qwen streaming input/output for SESSION with captured BACKEND and MODEL."
  (let* ((url (vox-backend-url backend model))
         (context (vox-tts-qwen--make-context :owner session :backend backend :phase 'connecting
                                             :responses (make-hash-table :test #'equal))))
    (vox-check-endpoint url (vox-tts--official-hosts 'tts-qwen-realtime))
    (when (vox-tts--live-p session)
      (let ((key (vox-backend-secret backend (vox-backend-host backend))))
        (when (vox-tts--live-p session)
          (setf (vox-tts--session-source-close session) (lambda () (vox-tts-qwen--close context))
                (vox-tts--session-input-send session)
                (lambda (text) (vox-tts-qwen--send context "input_text_buffer.append" `((text . ,text))))
                (vox-tts--session-input-finish session)
                (lambda ()
                  (setf (vox-tts-qwen--context-phase context) 'finishing)
                  (vox-tts-qwen--send context "session.finish")))
          (vox-transport-open
           context url `(("Authorization" . ,(concat "Bearer " key))) #'ignore
           (lambda (bytes opcode)
             (condition-case nil (vox-tts-qwen--message context bytes opcode)
               (error (vox-tts--fail session))))
           (lambda (_safe)
             (unless (vox-tts-qwen--context-closing context) (vox-tts--fail session)))
           (lambda ()
             (unless (vox-tts-qwen--context-closing context) (vox-tts--fail session)))
           (lambda () (not (vox-tts-qwen--context-closed context)))
           (vox-tts--session-generation session)))))))

(provide 'vox-tts-qwen)
;;; vox-tts-qwen.el ends here
