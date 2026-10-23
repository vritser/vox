;;; vox-transport.el --- Guarded WebSocket transport -*- lexical-binding: t; -*-

;;; Commentary:
;; websocket.el is optional until connect.  See docs/transport-audit.md for
;; the narrowly scoped upstream asynchronous-handshake compatibility shim.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'url-parse)
(require 'gnutls)
(require 'vox-core)

(defgroup vox-transport nil "WebSocket transport for Vox." :group 'vox)
(defcustom vox-transport-max-message-bytes (* 1024 1024)
  "Maximum bytes in one incoming or outgoing WebSocket message."
  :type 'integer :group 'vox-transport)
(defcustom vox-transport-max-retained-input-bytes (* 2 1024 1024)
  "Maximum bytes retained by active and queued process-filter callbacks.
Reentrant input waits for earlier callbacks to finish.  Each callback keeps
its full byte charge until consumed, even after some frames are dispatched.
This independent bound can reject a large coalesced read of legal messages."
  :type 'integer :group 'vox-transport)
(defcustom vox-transport-max-retained-input-chunks 1024
  "Maximum active and queued input callbacks, including terminal sentinels.
Empty process-filter inputs do not consume this budget."
  :type 'integer :group 'vox-transport)
(defcustom vox-transport-max-fragments 1024
  "Maximum frames in a fragmented message, including empty frames."
  :type 'integer :group 'vox-transport)
(defcustom vox-transport-send-timeout 1.0
  "Fail if a socket write takes longer than this many seconds.
This is measured AFTER the native write returns; it cannot interrupt a
blocked process-send-string and is not strict network backpressure."
  :type 'number :group 'vox-transport)

(defvar websocket-debug)
(defvar websocket-callback-debug-on-error)
(declare-function websocket-open "websocket" (url &rest args))
(declare-function websocket-ensure-handshake "websocket"
                  (url conn key protocols extensions headers nowait))
(declare-function websocket-close "websocket" (ws))
(declare-function websocket-send "websocket" (ws frame))
(declare-function websocket-send-text "websocket" (ws text))
(declare-function websocket-ready-state "websocket" (ws))
(declare-function websocket-conn "websocket" (ws))
(declare-function websocket-inflight-input "websocket" (ws))
(declare-function websocket-get-opcode "websocket" (bytes))
(declare-function websocket-read-frame "websocket" (bytes))
(declare-function websocket-frame-length "websocket" (frame))
(declare-function websocket-frame-payload "websocket" (frame))
(declare-function websocket-frame-opcode "websocket" (frame))
(declare-function websocket-frame-completep "websocket" (frame))
(declare-function make-websocket-frame "websocket" (&rest args))

(cl-defstruct (vox-transport--context (:constructor vox-transport--make-context))
  session generation live-p websocket process on-error closed failed opened protocol-closed
  fragments opcode (size 0) (count 0)
  input-queue input-tail input-feeding (input-bytes 0) (input-count 0))

(defvar vox-transport--contexts (make-hash-table :test #'eq :weakness 'key))
(defvar vox-transport--opening nil
  "Dynamically bound context during a Vox connection's creation.")

(defun vox-transport--owner-live-p (context)
  "Check CONTEXT's owner independently of connection state."
  (if (vox-transport--context-live-p context)
      (funcall (vox-transport--context-live-p context))
    (vox-session-live-p (vox-transport--context-session context)
                        (vox-transport--context-generation context))))

(defun vox-transport--live-p (context)
  "Whether CONTEXT can deliver application callbacks."
  (and (not (vox-transport--context-closed context))
       (not (vox-transport--context-failed context))
       (vox-transport--owner-live-p context)))

(defun vox-transport--reset-fragments (context)
  "Drop all retained message data in CONTEXT."
  (setf (vox-transport--context-fragments context) nil
        (vox-transport--context-opcode context) nil
        (vox-transport--context-size context) 0
        (vox-transport--context-count context) 0))

(defun vox-transport--reset-input (context)
  "Release queued process input and its retained-byte charge in CONTEXT."
  (setf (vox-transport--context-input-queue context) nil
        (vox-transport--context-input-tail context) nil
        (vox-transport--context-input-bytes context) 0
        (vox-transport--context-input-count context) 0))

(defun vox-transport--dispose (context)
  "Reclaim CONTEXT's socket without delivering application callbacks."
  (unless (vox-transport--context-closed context)
    (vox-log-event (vox-transport--context-generation context) 'transport-close))
  (setf (vox-transport--context-closed context) t)
  (vox-transport--reset-fragments context)
  (vox-transport--reset-input context)
  (let* ((session (vox-transport--context-session context))
         (ws (vox-transport--context-websocket context))
         (process (vox-transport--context-process context))
         (websocket-debug nil)
         (websocket-callback-debug-on-error nil))
    (when (and (not (vox-transport--context-live-p context))
               (eq ws (vox-session-websocket session)))
      (setf (vox-session-websocket session) nil))
    (when (eq context (gethash session vox-transport--contexts))
      (remhash session vox-transport--contexts))
    (when (processp process)
      (set-process-filter process #'ignore)
      (set-process-sentinel process #'ignore)
      (process-put process 'vox-transport-context nil))
    ;; On cancellation, do not send a close frame: process-send-string can
    ;; block on a congested peer.  Reclaim the process directly instead.
    (when (processp process) (ignore-errors (delete-process process)))))

(defun vox-transport--fail (context safe-message)
  "Report fixed SAFE-MESSAGE once for CONTEXT, without raw error data."
  (let ((live (vox-transport--live-p context)))
    (when live
      (vox-log-event (vox-transport--context-generation context) 'transport-error))
    (setf (vox-transport--context-failed context) t)
    (vox-transport--dispose context)
    (when live
      (condition-case nil
          (when (vox-transport--owner-live-p context)
            (funcall (vox-transport--context-on-error context) safe-message))
        (error nil)))))

(defun vox-transport--handshake (original url conn key protocols extensions headers nowait)
  "Defer ORIGINAL's handshake for a Vox-owned CONN until TCP/TLS is open.
URL, KEY, PROTOCOLS, EXTENSIONS, HEADERS and NOWAIT are upstream arguments.
Non-Vox connections pass through untouched.  No HTTP or RFC encoding is
implemented here; the upstream handshake function still does all of it."
  (let ((context (or (process-get conn 'vox-transport-context)
                     vox-transport--opening)))
    (if (not context)
        (funcall original url conn key protocols extensions headers nowait)
      (process-put conn 'vox-transport-context context)
      (setf (vox-transport--context-process context) conn
            (vox-transport--context-websocket context)
            (process-get conn :websocket))
      (when (and (vox-transport--live-p context)
                 (memq (process-status conn) '(open run)))
        (let ((websocket-debug nil)
              (websocket-callback-debug-on-error nil))
          (funcall original url conn key protocols extensions headers nil))))))

(defun vox-transport--check-dependency ()
  "Load optional websocket.el and verify the APIs required by this adapter."
  (unless (require 'websocket nil t)
    (user-error "Install websocket.el before connecting Vox"))
  (unless (and (gnutls-available-p)
               (cl-every #'fboundp
                         '(websocket-open websocket-send websocket-send-text
                           websocket-close websocket-ready-state websocket-conn
                           websocket-inflight-input websocket-get-opcode
                           websocket-read-frame websocket-frame-length
                           websocket-frame-payload
                           websocket-frame-opcode websocket-frame-completep
                           make-websocket-frame websocket-ensure-handshake))
               (or (advice-member-p #'vox-transport--handshake 'websocket-ensure-handshake)
                   (equal (func-arity #'websocket-ensure-handshake) '(7 . 7))))
    (user-error "Unsupported WebSocket API or missing native GnuTLS"))
  (unless (advice-member-p #'vox-transport--handshake 'websocket-ensure-handshake)
    (advice-add 'websocket-ensure-handshake :around #'vox-transport--handshake)))

(defun vox-transport--validate (url headers)
  "Validate URL and HEADERS without including their contents in errors."
  (unless (and (integerp vox-transport-max-message-bytes)
               (> vox-transport-max-message-bytes 0)
               (integerp vox-transport-max-retained-input-bytes)
               (> vox-transport-max-retained-input-bytes 0)
               (integerp vox-transport-max-retained-input-chunks)
               (> vox-transport-max-retained-input-chunks 0)
               (integerp vox-transport-max-fragments)
               (> vox-transport-max-fragments 0)
               (numberp vox-transport-send-timeout)
               (> vox-transport-send-timeout 0))
    (user-error "Invalid Vox transport limits"))
  (unless (and (stringp url)
               (not (string-match-p "[\r\n\x00]" url))
               (let ((parsed (url-generic-parse-url url)))
                 (and (equal (url-type parsed) "wss")
                      (not (string-empty-p (or (url-host parsed) "")))
                      (not (url-user parsed)) (not (url-password parsed))
                      (not (url-target parsed)))))
    (user-error "Vox requires a WSS URL without userinfo or fragment"))
  (unless (and (proper-list-p headers)
               (cl-every
                (lambda (entry)
                  (and (consp entry) (stringp (car entry)) (stringp (cdr entry))
                       (string-match-p "\\`[!#$%&'*+.^_`|~0-9A-Za-z-]+\\'" (car entry))
                       (not (string-match-p "[\r\n\x00]" (cdr entry)))))
                headers))
    (user-error "Invalid WebSocket headers")))

(defun vox-transport--frame (context frame on-message)
  "Reassemble FRAME in CONTEXT and call ON-MESSAGE only on whole messages."
  (let ((opcode (websocket-frame-opcode frame))
        (payload (websocket-frame-payload frame))
        (complete (websocket-frame-completep frame)))
    (unless (memq opcode '(text binary continuation))
      (error "Unexpected WebSocket opcode"))
    (unless (and (stringp payload) (not (multibyte-string-p payload)))
      (error "WebSocket payload must be binary"))
    (if (eq opcode 'continuation)
        (unless (vox-transport--context-opcode context)
          (error "Unexpected continuation"))
      (when (vox-transport--context-opcode context)
        (error "Overlapping fragmented messages"))
      (setf (vox-transport--context-opcode context) opcode))
    (cl-incf (vox-transport--context-size context) (length payload))
    (cl-incf (vox-transport--context-count context))
    (when (or (> (vox-transport--context-size context) vox-transport-max-message-bytes)
              (> (vox-transport--context-count context) vox-transport-max-fragments))
      (error "WebSocket message limit exceeded"))
    (push payload (vox-transport--context-fragments context))
    (when complete
      (let* ((kind (vox-transport--context-opcode context))
             (bytes (apply #'concat (nreverse (vox-transport--context-fragments context))))
             (text (if (eq kind 'text) (decode-coding-string bytes 'utf-8) bytes)))
        (vox-transport--reset-fragments context)
        ;; Emacs represents malformed UTF-8 octets as raw-byte characters.
        (when (and (eq kind 'text)
                   (cl-some (lambda (char) (>= char #x3fff80)) text))
          (error "Invalid UTF-8 text frame"))
        (funcall on-message text kind)))))

(defun vox-transport--queue-input (context input)
  "Append INPUT to CONTEXT's bounded FIFO.
INPUT is a wire string or a (SENTINEL . PROCESS) terminal notification;
raw process-event strings are never retained."
  (let ((size (+ (vox-transport--context-input-bytes context)
                 (if (stringp input) (length input) 0)))
        (count (1+ (vox-transport--context-input-count context)))
        (entry (list input)))
    (when (or (> size vox-transport-max-retained-input-bytes)
              (> count vox-transport-max-retained-input-chunks))
      (error "WebSocket retained input limit exceeded"))
    (if (vox-transport--context-input-tail context)
        (setcdr (vox-transport--context-input-tail context) entry)
      (setf (vox-transport--context-input-queue context) entry))
    (setf (vox-transport--context-input-tail context) entry
          (vox-transport--context-input-bytes context) size
          (vox-transport--context-input-count context) count)))

(defun vox-transport--feed-input (context filter process bytes)
  "Queue BYTES for FILTER and PROCESS, preserving CONTEXT's receive order.
A native write, including an upstream pong reply, can reenter this function.
The outer callback must consume its whole input before nested input runs."
  (when (and (vox-transport--live-p context)
             (not (vox-transport--context-protocol-closed context)))
    (unless (and (stringp bytes) (not (multibyte-string-p bytes)))
      (error "WebSocket input must be binary"))
    (unless (zerop (length bytes))
      (vox-transport--queue-input context bytes)
      (unless (vox-transport--context-input-feeding context)
        (setf (vox-transport--context-input-feeding context) t)
        (unwind-protect
            (while (and (vox-transport--live-p context)
                        (vox-transport--context-input-queue context))
              (let ((input (pop (vox-transport--context-input-queue context))))
                (unless (vox-transport--context-input-queue context)
                  (setf (vox-transport--context-input-tail context) nil))
                ;; Protocol CLOSE stops byte parsing, not queued EOF delivery.
                (if (stringp input)
                    (vox-transport--consume-input context filter process input)
                  (funcall (car input) (cdr input) "closed"))
                ;; Disposal may have reset the charge during the callback.
                (when (vox-transport--live-p context)
                  (cl-decf (vox-transport--context-input-count context))
                  (cl-decf (vox-transport--context-input-bytes context)
                           (if (stringp input) (length input) 0)))))
          (setf (vox-transport--context-input-feeding context) nil)
          (vox-transport--reset-input context))))))

(defun vox-transport--consume-input (context filter process bytes)
  "Feed BYTES to upstream FILTER for PROCESS within CONTEXT's wire budget.
Probe bounded prefixes with the upstream parser, then deliver at most one
frame per call so application callbacks can close before any later frame.
The filter parses that prefix again; no RFC decoding is duplicated here.
HTTP parsing and all WebSocket decoding remain upstream responsibilities."
  (unless (and (stringp bytes) (not (multibyte-string-p bytes)))
    (error "WebSocket input must be binary"))
  (let ((ws (vox-transport--context-websocket context))
        (offset 0))
    (while (and (< offset (length bytes)) (vox-transport--live-p context)
                (not (vox-transport--context-protocol-closed context))
                (memq (websocket-ready-state ws) '(connecting open)))
      (let* ((pending (websocket-inflight-input ws))
             (retained (length pending))
             (connecting (eq (websocket-ready-state ws) 'connecting))
             (control (and (not connecting)
                           (memq (websocket-get-opcode
                                  (if (> retained 0) pending
                                    (substring bytes offset (1+ offset))))
                                 '(ping pong close))))
             ;; Control frames have a protocol limit, not an application
             ;; message limit.  Allow the largest possible wire header too.
             (limit (if connecting 16384
                      (+ 14 (if control 125 vox-transport-max-message-bytes))))
             ;; Geometric growth avoids copying a message-sized prefix for
             ;; every tiny frame in a large callback, while bounding larger probes.
             (target (if connecting limit (min limit (max 14 (* 2 retained)))))
             (end (min (length bytes) (+ offset (- target retained)))))
        (when (<= end offset)
          (error "WebSocket input limit exceeded"))
        (let* ((candidate (concat pending (substring bytes offset end)))
               (boundary
                (if connecting
                    (when-let* ((header-end (string-match "\r\n\r\n" candidate)))
                      (+ header-end 4))
                  (when-let* ((frame (websocket-read-frame candidate)))
                    (when (> (length (websocket-frame-payload frame))
                             (if control 125 vox-transport-max-message-bytes))
                      (error "WebSocket frame limit exceeded"))
                    (when (eq (websocket-frame-opcode frame) 'close)
                      ;; Upstream reports CLOSE length as one byte; never parse
                      ;; its remaining header/reason as another frame.
                      (setf (vox-transport--context-protocol-closed context) t))
                    (websocket-frame-length frame)))))
          (when boundary
            (setq end (+ offset (- boundary retained))))
          (unless (> end offset)
            (error "WebSocket parser made no progress"))
          (funcall filter process (substring bytes offset end))
          (setq offset end)
          ;; A valid maximum-sized frame/header must be complete at this
          ;; boundary.  Reject without ever admitting another byte upstream.
          (when (and (vox-transport--live-p context)
                     (>= (length (websocket-inflight-input ws)) limit))
            (error "WebSocket input limit exceeded")))))))

(defun vox-transport--wrap-process (context)
  "Protect CONTEXT's upstream filter and sentinel before asynchronous I/O."
  (let* ((process (vox-transport--context-process context))
         (filter (process-filter process))
         (sentinel (process-sentinel process)))
    (set-process-coding-system process 'binary 'binary)
    (set-process-query-on-exit-flag process nil)
    (set-process-filter
     process
     (lambda (proc bytes)
       (let ((websocket-debug nil) (websocket-callback-debug-on-error nil))
         (condition-case nil
             (when (vox-transport--live-p context)
               (vox-transport--feed-input context filter proc bytes))
           (quit
            (vox-transport--fail context "WebSocket input interrupted")
            (signal 'quit nil))
           (error (vox-transport--fail context "WebSocket input rejected or callback failed"))))))
    (set-process-sentinel
     process
     (lambda (proc event)
       (let ((websocket-debug nil) (websocket-callback-debug-on-error nil))
         (condition-case nil
             (when (vox-transport--live-p context)
               (if (and (vox-transport--context-input-feeding context)
                        (not (vox-transport--context-protocol-closed context))
                        (memq (process-status proc) '(closed failed exit signal)))
                   (vox-transport--queue-input context (cons sentinel proc))
                 (funcall sentinel proc event)))
           (quit
            (vox-transport--fail context "WebSocket connection interrupted")
            (signal 'quit nil))
           (error (vox-transport--fail context "WebSocket connection failed"))))))))

(defun vox-transport-open (session url headers on-open on-message on-error on-close
                                   &optional live-p generation)
  "Connect SESSION to WSS URL with HEADERS, without waiting for connection.
ON-OPEN and ON-CLOSE take no arguments.  ON-MESSAGE receives (payload opcode),
where text is decoded UTF-8 and binary is unibyte.  ON-ERROR receives only a
fixed safe string.  Return the websocket and set SESSION's websocket slot.
With LIVE-P, SESSION is an opaque owner; call the zero-argument predicate
instead of ASR accessors and use GENERATION only as a diagnostic identifier."
  (vox-transport--validate url headers)
  (vox-transport--check-dependency)
  (let* ((generation (if live-p generation (vox-session-generation session)))
         (context (vox-transport--make-context
                   :session session :generation generation :live-p live-p :on-error on-error))
         (gnutls-verify-error t)
         (gnutls-log-level 0)
         (websocket-debug nil)
         (websocket-callback-debug-on-error nil)
         (vox-transport--opening context))
    (unless (vox-transport--owner-live-p context)
      (user-error "Cannot connect an inactive session"))
    (when (or (gethash session vox-transport--contexts)
              (and (not live-p) (vox-session-websocket session)))
      (user-error "This session already owns a WebSocket"))
    (puthash session context vox-transport--contexts)
    (condition-case nil
        (let ((ws
               (websocket-open
                url :custom-header-alist headers :nowait t
                :on-open
                (lambda (socket)
                  (condition-case nil
                      (when (and (vox-transport--live-p context)
                                 (not (vox-transport--context-opened context)))
                        (setf (vox-transport--context-opened context) t
                              (vox-transport--context-websocket context) socket)
                        (unless live-p (setf (vox-session-websocket session) socket))
                        (vox-log-event generation 'transport-open)
                        (funcall on-open))
                    (error (vox-transport--fail context "WebSocket open callback failed"))))
                :on-message
                (lambda (_socket frame)
                  (condition-case nil
                      (if (vox-transport--live-p context)
                          (vox-transport--frame context frame on-message)
                        (vox-log-event generation 'stale-callback))
                    (error (vox-transport--fail context "WebSocket message rejected or callback failed"))))
                :on-error
                (lambda (_socket _type _raw-error)
                  (condition-case nil
                      (when (vox-transport--live-p context)
                        (vox-transport--fail context "WebSocket connection or protocol error"))
                    (error nil)))
                :on-close
                (lambda (_socket)
                  (condition-case nil
                      (when (vox-transport--live-p context)
                        (vox-transport--dispose context)
                        (condition-case nil
                            (funcall on-close)
                          (error
                           (when (vox-transport--owner-live-p context)
                             (condition-case nil
                                 (funcall on-error "WebSocket close callback failed")
                               (error nil))))))
                    (error nil))))))
          (setf (vox-transport--context-websocket context) ws
                (vox-transport--context-process context) (websocket-conn ws))
          (if (vox-transport--live-p context)
              (progn
                (unless live-p (setf (vox-session-websocket session) ws))
                (vox-transport--wrap-process context)
                ws)
            (vox-transport--dispose context)
            nil))
      (error
       (vox-transport--fail context "Could not open secure WebSocket; check dependency and endpoint")
       nil))))

(defun vox-transport--send (session payload opcode)
  "Send PAYLOAD with OPCODE for SESSION; expose only safe errors."
  (let ((context (gethash session vox-transport--contexts))
        (websocket-debug nil) (websocket-callback-debug-on-error nil))
    (condition-case nil
        (progn
          (unless (and context (vox-transport--live-p context)
                       (vox-transport--context-opened context)
                       (stringp payload)
                       (or (eq opcode 'text) (not (multibyte-string-p payload))))
            (error "Cannot send"))
          (let ((bytes (if (eq opcode 'text)
                           (encode-coding-string payload 'utf-8) payload))
                (ws (vox-transport--context-websocket context))
                (started (float-time)))
            (unless (<= (length bytes) vox-transport-max-message-bytes)
              (error "Message too large"))
            ;; Upstream send-text uses raw-text, not an explicit UTF-8 encode.
            ;; Pass pre-encoded octets to make the wire encoding deterministic.
            (if (eq opcode 'text)
                (websocket-send-text ws bytes)
              (websocket-send ws (make-websocket-frame
                                  :opcode 'binary :payload bytes :completep t)))
            (when (> (- (float-time) started) vox-transport-send-timeout)
              (vox-transport--fail context "WebSocket write exceeded time budget")
              (error "Slow WebSocket write"))
            t))
      (error (error "WebSocket send failed")))))

(defun vox-transport-send-text (session text)
  "Send TEXT as one UTF-8 message for SESSION."
  (vox-transport--send session text 'text))

(defun vox-transport-send-binary (session bytes)
  "Send strictly unibyte BYTES as one binary message for SESSION."
  (vox-transport--send session bytes 'binary))

(defun vox-transport-close (session)
  "Close SESSION's connection idempotently, without waiting or callbacks.
Provider finish/completion must precede this resource-reclamation step."
  (when-let* ((context (gethash session vox-transport--contexts)))
    (vox-transport--dispose context)))

(provide 'vox-transport)
;;; vox-transport.el ends here
