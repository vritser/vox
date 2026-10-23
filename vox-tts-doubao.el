;;; vox-tts-doubao.el --- Doubao bidirectional speech synthesis -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Application events over the existing guarded websocket.el transport.
;; Text enters TaskRequest incrementally; SessionFinished is authoritative.
;;; Code:
(require 'vox-tts)
(require 'vox-transport)

(cl-defstruct (vox-tts-doubao--context (:constructor vox-tts-doubao--make-context))
  owner backend id phase timer busy write-failed closing closed (received 0))

(defun vox-tts-doubao--u32 (number)
  "Encode unsigned NUMBER as four network-order bytes."
  (unibyte-string (logand (ash number -24) 255) (logand (ash number -16) 255)
                  (logand (ash number -8) 255) (logand number 255)))

(defun vox-tts-doubao--encode (event id payload)
  "Encode client EVENT, optional session ID and JSON PAYLOAD."
  (let ((bytes (encode-coding-string (vox-json-encode payload) 'utf-8))
        (id (when id (encode-coding-string id 'utf-8))))
    (concat (unibyte-string #x11 #x14 #x10 0) (vox-tts-doubao--u32 event)
            (when id (concat (vox-tts-doubao--u32 (length id)) id))
            (vox-tts-doubao--u32 (length bytes)) bytes)))

(defun vox-tts-doubao--decode (bytes)
  "Decode one bounded server event from unibyte BYTES, without raw diagnostics."
  (unless (and (stringp bytes) (not (multibyte-string-p bytes))
               (<= 12 (length bytes) vox-transport-max-message-bytes)
               (= (aref bytes 0) #x11) (= (aref bytes 3) 0))
    (error "Invalid TTS binary message"))
  (let ((type (aref bytes 1)) (serialization (aref bytes 2)) (offset 4))
    ;; Error frames need no body parsing: never expose provider diagnostics.
    (unless (and (memq type '(#x94 #xb4))
                 (if (= type #xb4) (= serialization 0) (= serialization #x10)))
      (error "Unsupported TTS message or service error"))
    (cl-labels ((u32 ()
                 (unless (<= (+ offset 4) (length bytes)) (error "Truncated TTS integer"))
                 (let ((n 0))
                   (dotimes (_ 4) (setq n (+ (ash n 8) (aref bytes offset)) offset (1+ offset)))
                   n))
                (field (limit)
                  (let ((size (u32)))
                    (unless (and (<= size limit) (<= (+ offset size) (length bytes)))
                      (error "Invalid TTS field size"))
                    (prog1 (substring bytes offset (+ offset size))
                      (setq offset (+ offset size))))))
      (let* ((event (u32)) (id (field 256)) (payload (field vox-transport-max-message-bytes)))
        (unless (and (= offset (length bytes))
                     (if (= type #xb4) (= event 352)
                       (memq event '(50 51 52 150 151 152 153 154 350 351))))
          (error "Unexpected TTS event"))
        (list :event event :id id
              :audio (when (= type #xb4) payload)
              :payload (unless (= type #xb4)
                         (vox-json-read (decode-coding-string payload 'utf-8))))))))

(defun vox-tts-doubao--send (context event payload &optional connection)
  "Send EVENT with PAYLOAD for CONTEXT; CONNECTION omits the session ID."
  (when (or (vox-tts-doubao--context-closed context) (vox-tts-doubao--context-busy context))
    (error "TTS connection is closed or already sending"))
  (let ((owner (vox-tts-doubao--context-owner context)) completed)
    (setf (vox-tts-doubao--context-busy context) t
          (vox-tts--session-input-ready owner) nil)
    (unwind-protect
        (prog1
            (vox-transport-send-binary
             context (vox-tts-doubao--encode event
                                            (unless connection (vox-tts-doubao--context-id context))
                                            payload))
          (setq completed t))
      (setf (vox-tts-doubao--context-busy context) nil)
      ;; A failed/interrupted write has unknown delivery.  Reclaim its socket;
      ;; appending even a cancel could splice into an incomplete WebSocket frame.
      (unless completed (setf (vox-tts-doubao--context-write-failed context) t))
      (when (and completed (vox-tts--live-p owner)
                 (not (vox-tts-doubao--context-closed context)))
        (pcase (vox-tts-doubao--context-phase context)
          ('ready
           (setf (vox-tts--session-input-ready owner) t)
           (vox-tts--input-schedule owner))
          ('start (vox-tts-doubao--schedule context)))))))

(defun vox-tts-doubao--close (context)
  "Best-effort cancel or finish CONTEXT, then unconditionally reclaim its socket.
Never send a nested cancel into an in-flight write; close the socket instead.
No provider cancellation or billing acknowledgement is implied by returning."
  (unless (or (vox-tts-doubao--context-closed context)
              (vox-tts-doubao--context-closing context))
    (setf (vox-tts-doubao--context-closing context) t)
    (when (timerp (vox-tts-doubao--context-timer context))
      (cancel-timer (vox-tts-doubao--context-timer context)))
    (setf (vox-tts-doubao--context-timer context) nil)
    (unwind-protect
        (unless (or (vox-tts-doubao--context-busy context)
                    (vox-tts-doubao--context-write-failed context))
          (condition-case nil
              (pcase (vox-tts-doubao--context-phase context)
                ('finished (vox-tts-doubao--send context 2 (make-hash-table) t))
                ((or 'await-session 'ready 'finishing)
                 (vox-tts-doubao--send context 101 (make-hash-table))))
            (error nil)))
      (setf (vox-tts-doubao--context-closed context) t)
      (vox-transport-close context))))

(defun vox-tts-doubao--control (context)
  "Send one connection/session handshake event for CONTEXT outside callbacks."
  (setf (vox-tts-doubao--context-timer context) nil)
  (let ((owner (vox-tts-doubao--context-owner context)))
    (when (and (vox-tts--live-p owner) (not (vox-tts-doubao--context-closed context))
               (not (vox-tts-doubao--context-busy context)))
      (condition-case nil
          (pcase (vox-tts-doubao--context-phase context)
            ('connect
             (setf (vox-tts-doubao--context-phase context) 'await-connection)
             (vox-tts-doubao--send context 1 (make-hash-table) t))
            ('start
             (setf (vox-tts-doubao--context-phase context) 'await-session)
             (vox-tts-doubao--send
              context 100
              `((event . 100) (namespace . "BidirectionalTTS") (user . ((uid . "vox")))
                (req_params . ((speaker . ,(vox-backend-voice (vox-tts-doubao--context-backend context)))
                               (audio_params . ((format . "mp3") (sample_rate . 24000)))))))))
        (quit (vox-tts--end owner 'cancelled) (signal 'quit nil))
        (error (vox-tts--fail owner))))))

(defun vox-tts-doubao--schedule (context)
  "Schedule CONTEXT's next handshake message."
  (when (and (not (vox-tts-doubao--context-timer context))
             (not (vox-tts-doubao--context-busy context))
             (not (vox-tts-doubao--context-closed context))
             (vox-tts--live-p (vox-tts-doubao--context-owner context)))
    (setf (vox-tts-doubao--context-timer context)
          (run-at-time 0.01 nil #'vox-tts-doubao--control context))))

(defun vox-tts-doubao--message (context bytes opcode)
  "Consume server BYTES with OPCODE for CONTEXT's captured owner."
  (let ((owner (vox-tts-doubao--context-owner context)))
    (when (and (vox-tts--live-p owner) (not (vox-tts-doubao--context-closed context))
               (not (vox-tts-doubao--context-closing context)))
      (unless (eq opcode 'binary) (error "Expected binary TTS response"))
      (cl-incf (vox-tts-doubao--context-received context) (length bytes))
      (when (> (vox-tts-doubao--context-received context) (vox-tts--session-response-limit owner))
        (error "TTS response limit exceeded"))
      (let* ((packet (vox-tts-doubao--decode bytes)) (event (plist-get packet :event))
             (phase (vox-tts-doubao--context-phase context))
             (code (plist-get (plist-get packet :payload) :status_code)))
        (unless (and (or (< event 100) (equal (plist-get packet :id) (vox-tts-doubao--context-id context)))
                     (memq code '(nil 0 20000000)))
          (error "TTS session mismatch or service error"))
        (pcase event
          (50
           (unless (eq phase 'await-connection) (error "Unexpected connection acknowledgement"))
           (setf (vox-tts-doubao--context-phase context) 'start)
           (vox-tts-doubao--schedule context))
          (150
           (unless (eq phase 'await-session) (error "Unexpected session acknowledgement"))
           (setf (vox-tts-doubao--context-phase context) 'ready)
           (unless (vox-tts-doubao--context-busy context)
             (setf (vox-tts--session-input-ready owner) t)
             (vox-tts--input-schedule owner)))
          (352
           (unless (memq phase '(ready finishing)) (error "Audio before session readiness"))
           (vox-tts--play owner (plist-get packet :audio)))
          (152
           (unless (and (eq phase 'finishing) (vox-tts--session-input-sent-finish owner)
                        (not (vox-tts--session-text-queue owner)))
             (error "TTS completed before input finish"))
           (setf (vox-tts-doubao--context-phase context) 'finished)
           (vox-tts-doubao--close context)
           (vox-tts--source-finished owner))
          ((or 154 350 351)
           (unless (memq phase '(ready finishing)) (error "Unexpected TTS metadata")))
          (_ (error "TTS session failed or closed before completion")))))))

(defun vox-tts-doubao-open (session backend)
  "Open bidirectional speech for SESSION using captured BACKEND settings."
  (let* ((url (concat "wss://" (vox-backend-host backend) (vox-backend-endpoint backend)))
         (context (vox-tts-doubao--make-context :owner session :backend backend
                                              :id (vox-tts--request-id) :phase 'connecting)))
    (vox-check-endpoint url (vox-tts--official-hosts 'tts-doubao-ws))
    (when (vox-tts--live-p session)
      (let ((key (vox-backend-secret backend (vox-backend-host backend))))
        (when (vox-tts--live-p session)
          (setf (vox-tts--session-source-close session) (lambda () (vox-tts-doubao--close context))
                (vox-tts--session-input-send session)
                (lambda (text)
                  (vox-tts-doubao--send context 200 `((event . 200) (req_params . ((text . ,text))))))
                (vox-tts--session-input-finish session)
                (lambda ()
                  (setf (vox-tts-doubao--context-phase context) 'finishing)
                  (vox-tts-doubao--send context 102 (make-hash-table))))
          (vox-transport-open
           context url `(("X-Api-Key" . ,key)
                         ("X-Api-Resource-Id" . ,(vox-backend-resource-id backend))
                         ("X-Api-Connect-Id" . ,(vox-tts--request-id)))
           (lambda ()
             (when (vox-tts--live-p session)
               (setf (vox-tts-doubao--context-phase context) 'connect)
               (vox-tts-doubao--schedule context)))
           (lambda (bytes opcode)
             (condition-case nil (vox-tts-doubao--message context bytes opcode)
               (error (vox-tts--fail session))))
           (lambda (_safe)
             (unless (vox-tts-doubao--context-closing context) (vox-tts--fail session)))
           (lambda ()
             (unless (vox-tts-doubao--context-closing context) (vox-tts--fail session)))
           (lambda () (not (vox-tts-doubao--context-closed context)))
           (vox-tts--session-generation session)))))))

(provide 'vox-tts-doubao)
;;; vox-tts-doubao.el ends here
