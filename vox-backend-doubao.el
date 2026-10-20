;;; vox-backend-doubao.el --- Experimental SeedASR adapter -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Implements the audited bigmodel_async sauc_python.zip wire format.
;; No Python code is imported or executed.  See docs/protocol-audit.md.
;;; Code:
(require 'vox-backend)
(require 'vox-transport)
(require 'vox-core)

(defcustom vox-doubao-second-pass t
  "Whether to request second-pass revisions of full snapshots."
  :type 'boolean :group 'vox)
(defcustom vox-doubao-chunk-ms 200
  "PCM packet duration, either 100 or 200 milliseconds."
  :type '(choice (const 100) (const 200)) :group 'vox)
(defconst vox-doubao--max-payload (* 1024 1024)
  "Maximum encoded and decoded protocol payload accepted by this adapter.")

(defun vox-doubao--uint32 (number &optional little-endian)
  "Encode NUMBER modulo 2^32; use LITTLE-ENDIAN when non-nil."
  (let ((bytes (list (logand (ash number -24) 255)
                     (logand (ash number -16) 255)
                     (logand (ash number -8) 255) (logand number 255))))
    (apply #'unibyte-string (if little-endian (reverse bytes) bytes))))

(defun vox-doubao--read-u32 (bytes offset &optional little-endian)
  "Read unsigned uint32 from BYTES at OFFSET, optionally LITTLE-ENDIAN."
  (unless (<= (+ offset 4) (length bytes)) (error "Truncated Doubao integer"))
  (let ((value 0))
    (dotimes (i 4)
      (setq value (+ (ash value 8)
                     (aref bytes (+ offset (if little-endian (- 3 i) i))))))
    value))

(defconst vox-doubao--crc-table
  (let ((table (make-vector 256 0)))
    (dotimes (i 256)
      (let ((crc i))
        (dotimes (_ 8)
          (setq crc (if (= (logand crc 1) 1)
                        (logxor #xedb88320 (ash crc -1)) (ash crc -1))))
        (aset table i crc)))
    table))

(defun vox-doubao--crc32 (bytes)
  "Return the IEEE CRC32 of unibyte BYTES."
  (let ((crc #xffffffff))
    (dotimes (i (length bytes))
      (setq crc (logxor (ash crc -8)
                       (aref vox-doubao--crc-table
                             (logand (logxor crc (aref bytes i)) 255)))))
    (logxor crc #xffffffff)))

(defun vox-doubao-gzip (bytes)
  "Return deterministic RFC 1952 gzip of unibyte BYTES, without subprocesses.
Stored DEFLATE blocks preserve bytes without compression; the wire compression
nibble remains GZIP, exactly as in the official request builder."
  (unless (and (stringp bytes) (not (multibyte-string-p bytes))
               (<= (length bytes) vox-doubao--max-payload))
    (error "Invalid Doubao gzip input"))
  (let ((offset 0) (size (length bytes)))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert (unibyte-string #x1f #x8b 8 0 0 0 0 0 0 255))
      (while (or (< offset size) (= offset 0))
        (let* ((count (min 65535 (- size offset)))
               (final (= (+ offset count) size))
               (inverse (logxor count #xffff)))
          (insert (unibyte-string (if final 1 0)
                                  (logand count 255) (ash count -8)
                                  (logand inverse 255) (ash inverse -8))
                  (substring bytes offset (+ offset count)))
          (setq offset (if (= count 0) 1 (+ offset count)))))
      (insert (vox-doubao--uint32 (vox-doubao--crc32 bytes) t)
              (vox-doubao--uint32 size t))
      (buffer-string))))

(defun vox-doubao--gunzip (bytes)
  "Decode gzip BYTES using native Emacs zlib, checking advertised size."
  (unless (and (fboundp 'zlib-available-p) (zlib-available-p)
               (>= (length bytes) 18)
               (= (aref bytes 0) #x1f) (= (aref bytes 1) #x8b)
               (= (aref bytes 2) 8)
               (<= (vox-doubao--read-u32 bytes (- (length bytes) 4) t)
                   vox-doubao--max-payload))
    (error "Unsupported or oversized Doubao gzip payload"))
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert bytes)
    (unless (and (zlib-decompress-region (point-min) (point-max))
                 (<= (buffer-size) vox-doubao--max-payload))
      (error "Invalid Doubao gzip payload"))
    (buffer-string)))

(defun vox-doubao-encode (message-type sequence payload &optional last)
  "Encode a client MESSAGE-TYPE (1/2), SEQUENCE, and unibyte PAYLOAD.
LAST marks the audio-only final packet with flags 3 and a negative sequence."
  (unless (and (memq message-type '(1 2)) (integerp sequence)
               (<= 1 sequence #x7fffffff) (or (not last) (= message-type 2)))
    (error "Invalid Doubao request metadata"))
  (let ((compressed (vox-doubao-gzip payload)))
    (concat (unibyte-string #x11
                            (logior (ash message-type 4) (if last 3 1))
                            #x11 0)
            (vox-doubao--uint32 (if last (- sequence) sequence))
            (vox-doubao--uint32 (length compressed)) compressed)))

(defun vox-doubao-decode (bytes)
  "Decode one complete server message BYTES into an adapter plist.
Reject truncated, coalesced, unknown, or oversized messages.  The transport
reassembles WebSocket continuation frames before calling this function.
Sequence, last-p, and event are envelope fields, not JSON body fields."
  (unless (and (stringp bytes) (not (multibyte-string-p bytes))
               (<= 4 (length bytes) (+ vox-doubao--max-payload 1024)))
    (error "Invalid Doubao binary frame"))
  (let* ((version (ash (aref bytes 0) -4))
         (header-size (* 4 (logand (aref bytes 0) 15)))
         (type (ash (aref bytes 1) -4))
         (flags (logand (aref bytes 1) 15))
         (serialization (ash (aref bytes 2) -4))
         (compression (logand (aref bytes 2) 15))
         (offset header-size) sequence event code size payload)
    (unless (and (= version 1) (<= 4 header-size (length bytes))
                 (= (aref bytes 3) 0) (memq type '(9 15))
                 (<= flags 7) (memq serialization '(0 1))
                 (memq compression '(0 1)))
      (error "Unsupported Doubao binary header"))
    (cl-labels ((u32 () (prog1 (vox-doubao--read-u32 bytes offset)
                         (setq offset (+ offset 4))))
                (i32 () (let ((n (u32))) (if (> n #x7fffffff) (- n #x100000000) n))))
      (when (/= (logand flags 1) 0) (setq sequence (i32)))
      (when (/= (logand flags 4) 0) (setq event (i32)))
      (setq code (if (= type 15) (i32) 0) size (u32)))
    (unless (and (<= size vox-doubao--max-payload)
                 (= (+ offset size) (length bytes)))
      (error "Invalid Doubao payload length"))
    (setq payload (substring bytes offset))
    (when (and (= compression 1) (> size 0))
      (setq payload (vox-doubao--gunzip payload)))
    (when (and (= type 9) (/= serialization 1) (> (length payload) 0))
      (error "Doubao recognition response must be JSON"))
    (list :message-type type :sequence sequence :event event
          :last-p (/= (logand flags 2) 0) :code code :payload-size size
          :payload (when (and (= serialization 1) (> (length payload) 0))
                     (vox-json-read (decode-coding-string payload 'utf-8-unix))))))

(defun vox-doubao-config (&optional model)
  "Build the full-result PCM request object for MODEL, defaulting to bigmodel."
  (list :user (list :uid "vox")
        :audio (list :format "pcm" :codec "raw" :rate 16000 :bits 16 :channel 1)
        :request (list :model_name (or model "bigmodel") :enable_itn t :enable_punc t
                       :show_utterances t
                       :enable_nonstream (if vox-doubao-second-pass t :false)
                       :result_type "full")))

(defun vox-doubao-normalize (packet revision)
  "Normalize decoded PACKET as a full snapshot with local receive REVISION.
Do not interpret provider sequence as a monotonic revision; that guarantee is
not specified.  WebSocket message order supplies local snapshot order."
  (let ((body (plist-get packet :payload)))
    (if (or (= (plist-get packet :message-type) 15)
            (/= (plist-get packet :code) 0)
            (and (numberp (plist-get body :code))
                 (/= (plist-get body :code) 0)))
        (list :type :error :code "provider-error"
              :message "Doubao rejected the request")
      (let* ((result (plist-get body :result))
             (text (and (listp result) (plist-get result :text))))
        (when result
          (unless (stringp text) (error "Invalid Doubao full result"))
          (list :type :snapshot :text text :revision revision
                :final-p (plist-get packet :last-p)))))))

(defun vox-doubao--put (session key value)
  "Store VALUE under KEY in SESSION adapter state."
  (setf (vox-session-backend-state session)
        (plist-put (vox-session-backend-state session) key value)))

(defun vox-doubao--message (session payload opcode)
  "Handle binary PAYLOAD with OPCODE for SESSION."
  (unless (or (plist-get (vox-session-backend-state session) :closed)
              (plist-get (vox-session-backend-state session) :completed))
    (unless (eq opcode 'binary) (error "Expected Doubao binary response"))
    (let* ((packet (vox-doubao-decode payload))
           (state (vox-session-backend-state session))
           (revision (1+ (or (plist-get state :revision) 0)))
           (event (vox-doubao-normalize packet revision))
           (last (plist-get packet :last-p)))
      (vox-doubao--put session :revision revision)
      (cond
       ((eq (plist-get event :type) :error)
        (funcall (plist-get state :on-error) (plist-get event :message)))
       ((and last (not (plist-get state :finished)))
        (funcall (plist-get state :on-error) "Doubao ended before client finish"))
       (t
        (unless (plist-get state :ready)
          (vox-doubao--put session :ready t)
          (funcall (plist-get state :on-ready)))
        (when event (funcall (plist-get state :on-event) event))
        (when last
          (vox-doubao--put session :completed t)
          (funcall (plist-get state :on-event) (list :type :completed))))))))

(defun vox-doubao--request-id ()
  "Create a UUID-shaped request identifier, without putting secrets in it."
  (let ((hex (md5 (format "%s-%s-%s" (float-time) (emacs-pid) (random)))))
    (format "%s-%s-4%s-8%s-%s" (substring hex 0 8) (substring hex 8 12)
            (substring hex 13 16) (substring hex 17 20) (substring hex 20 32))))

(defun vox-doubao-connect (session on-ready on-event on-error)
  "Connect experimental SESSION using ON-READY, ON-EVENT, ON-ERROR."
  (let* ((generation (vox-session-generation session))
         (_ (unless (and (fboundp 'zlib-available-p) (zlib-available-p))
              (error "Doubao requires Emacs native zlib support")))
         (methods (if (plist-get (vox-session-methods session) :configuration)
                      (vox-session-methods session)
                    (vox-backend-methods 'doubao)))
         (configuration (plist-get methods :configuration))
         (model (plist-get methods :model))
         (url (vox-backend-url configuration model))
         (resource-id (vox-backend-resource-id configuration))
         ;; Endpoint approval and key functions may reentrantly cancel SESSION.
         (_ (vox--require-live session generation))
         (_ (vox-check-endpoint url '("openspeech.bytedance.com")))
         (_ (vox--require-live session generation))
         (secret (vox-backend-secret
                  configuration (url-host (url-generic-parse-url url)))))
    (vox--require-live session generation)
    (let ((request (vox-doubao-encode
                    1 1 (encode-coding-string
                         (vox-json-encode (vox-doubao-config model)) 'utf-8-unix))))
      (setf (vox-session-backend-state session)
            (list :on-ready on-ready :on-event on-event :on-error on-error :sequence 2))
      (vox-transport-open
       session url
       (list (cons "X-Api-Key" secret) (cons "X-Api-Resource-Id" resource-id)
             (cons "X-Api-Request-Id" (vox-doubao--request-id)))
       (lambda () (vox-transport-send-binary session request))
       (lambda (payload opcode) (vox-doubao--message session payload opcode))
       on-error
       (lambda ()
         (let ((state (vox-session-backend-state session)))
           (unless (or (plist-get state :closed) (plist-get state :completed))
             (funcall on-error "Doubao connection closed before final response"))))))))

(defun vox-doubao-send-pcm (session bytes)
  "Queue PCM BYTES for SESSION, retaining one packet for the end marker."
  (let* ((state (vox-session-backend-state session))
         (pending (plist-get state :pending)) (seq (plist-get state :sequence)))
    (unless (and (plist-get state :ready) (not (plist-get state :finished))
                 (not (plist-get state :closed))
                 (stringp bytes) (not (multibyte-string-p bytes))
                 (<= (length bytes) 6400) (zerop (% (length bytes) 2)))
      (error "Doubao is not ready for PCM or PCM is invalid"))
    (unless (zerop (length bytes))
      (when pending
        (vox-transport-send-binary session (vox-doubao-encode 2 seq pending))
        (vox-doubao--put session :sequence (1+ seq)))
      (vox-doubao--put session :pending bytes))))

(defun vox-doubao-finish (session)
  "Send the retained final PCM packet for SESSION exactly once."
  (let ((state (vox-session-backend-state session)))
    (unless (or (plist-get state :finished) (plist-get state :closed))
      (unless (plist-get state :ready) (error "Doubao is not ready to finish"))
      (vox-doubao--put session :finished t)
      (vox-transport-send-binary
       session (vox-doubao-encode 2 (plist-get state :sequence)
                                  (or (plist-get state :pending) (unibyte-string)) t))
      (vox-doubao--put session :pending nil))))

(defun vox-doubao-close (session)
  "Close SESSION, discarding retained PCM without a success event."
  (unless (plist-get (vox-session-backend-state session) :closed)
    (vox-doubao--put session :closed t)
    (vox-doubao--put session :pending nil)
    (vox-transport-close session)))

(vox-register-backend
 'doubao (list :connect #'vox-doubao-connect :send-pcm #'vox-doubao-send-pcm
               :finish #'vox-doubao-finish :cancel #'vox-doubao-close
               :close #'vox-doubao-close :needs-external-audio t
               :experimental t :chunk-ms (lambda () vox-doubao-chunk-ms)))

(provide 'vox-backend-doubao)
;;; vox-backend-doubao.el ends here
