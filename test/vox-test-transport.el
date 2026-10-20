;;; vox-test-transport.el --- Upstream transport tests -*- lexical-binding: t; no-byte-compile: t; -*-

(require 'vox-test-support)
(require 'cl-lib)
(require 'vox-transport)

(defmacro vox-transport-test--connection (&rest body)
  "Run BODY with real upstream framing and a mocked native network pipe."
  (declare (indent 0) (debug t))
  `(progn
     (skip-unless (require 'websocket nil t))
     (let* ((session (vox--make-session :id "transport-test" :generation 1 :state 'connecting))
            (vox--active-session session)
            (socket (make-pipe-process :name "vox-test-network" :buffer nil
                                       :coding 'binary :noquery t))
            (network-status 'connect)
            (real-status (symbol-function 'process-status))
            (real-send (symbol-function 'process-send-string))
            (websocket-debug t)
            (websocket-callback-debug-on-error t)
            writes opened messages errors closed tls-verified asynchronous ws)
       (unwind-protect
           (cl-letf (((symbol-function 'open-network-stream)
                      (lambda (_name _buffer host _service &rest args)
                        (setq asynchronous (plist-get args :nowait)
                              tls-verified (plist-get (gnutls-boot-parameters :hostname host)
                                                      :verify-error))
                        (should (eq (plist-get args :type) 'tls))
                        (should-not websocket-debug)
                        socket))
                     ((symbol-function 'process-status)
                      (lambda (process)
                        (if (eq process socket) network-status
                          (funcall real-status process))))
                     ((symbol-function 'process-send-string)
                      (lambda (process bytes)
                        (if (eq process socket)
                            (progn
                              (should-not (eq network-status 'connect))
                              (should-not websocket-debug)
                              (push bytes writes))
                          (funcall real-send process bytes)))))
             (setq ws (vox-transport-open
                       session "wss://vox-test.invalid/realtime"
                       '(("Authorization" . "Bearer SECRET_KEY"))
                       (lambda () (push t opened))
                       (lambda (payload opcode) (push (list payload opcode) messages))
                       (lambda (safe) (push safe errors))
                       (lambda () (push t closed))))
             (ignore writes opened messages errors closed tls-verified asynchronous ws)
             ,@body)
         (vox-transport-close session)
         (set-process-filter socket #'ignore)
         (set-process-sentinel socket #'ignore)
         (ignore-errors (delete-process socket))))))

(defmacro vox-transport-test--upgrade ()
  "Drive the mocked socket through the real upstream HTTP upgrade parser."
  '(progn
     (setq network-status 'open)
     (funcall (process-sentinel socket) socket "open")
     (funcall (process-filter socket) socket
              (concat "HTTP/1.1 101 Switching Protocols\r\n"
                      "Upgrade: websocket\r\nConnection: upgrade\r\n"
                      "Sec-WebSocket-Accept: " (websocket-accept-string ws) "\r\n\r\n"))))

(defun vox-transport-test--wire (opcode payload complete)
  "Build synthetic server wire bytes using the audited upstream encoder."
  (websocket-encode-frame (make-websocket-frame :opcode opcode :payload payload
                                               :completep complete) nil))

(ert-deftest vox-transport-nowait-tls-and-debug ()
  :tags '(vox-unit)
  (vox-transport-test--connection
    (should ws)
    (should asynchronous)
    (should (eq tls-verified t))
    (should (eq ws (vox-session-websocket session)))
    (should-not writes)
    (vox-transport-test--upgrade)
    (should (= (length writes) 1))
    (should (string-match-p "Authorization: Bearer SECRET_KEY" (car writes)))
    (should (equal opened '(t)))
    (should-not errors)
    (should-not (get-buffer "*websocket wss://vox-test.invalid/realtime debug*"))
    ;; Unrelated clients keep their user-selected debug settings.
    (should websocket-debug)))

(ert-deftest vox-transport-shim-leaves-unrelated-sockets-unchanged ()
  :tags '(vox-unit)
  (let ((pipe (make-pipe-process :name "vox-unrelated" :noquery t)) seen)
    (unwind-protect
        (progn
          (vox-transport--handshake (lambda (&rest args) (setq seen args))
                                    "ws://unrelated" pipe "key" nil nil nil t)
          (should (eq (car (last seen)) t)))
      (delete-process pipe))))

(ert-deftest vox-transport-fragmented-utf8-across-octets ()
  :tags '(vox-unit)
  (vox-transport-test--connection
    (vox-transport-test--upgrade)
    (let* ((text (string #x4e2d #x6587))
           (bytes (encode-coding-string text 'utf-8)))
      (funcall (process-filter socket) socket
               (vox-transport-test--wire 'text (substring bytes 0 1) nil))
      (should-not messages)
      (funcall (process-filter socket) socket
               (vox-transport-test--wire 'ping "ping" t))
      (should-not messages)
      (funcall (process-filter socket) socket
               (vox-transport-test--wire 'continuation (substring bytes 1) t))
      (should (equal messages (list (list text 'text))))
      (should-not errors))))

(ert-deftest vox-transport-binary-split-wire-and-coalesced-messages ()
  :tags '(vox-unit)
  (vox-transport-test--connection
    (vox-transport-test--upgrade)
    (let* ((bytes (unibyte-string 0 255 128 1))
           (wire (vox-transport-test--wire 'binary bytes t)))
      (funcall (process-filter socket) socket (substring wire 0 1))
      (should-not messages)
      (funcall (process-filter socket) socket
               (concat (substring wire 1) (vox-transport-test--wire 'text "{}" t)))
      (should (equal messages (list (list "{}" 'text) (list bytes 'binary))))
      (should-not (multibyte-string-p (caar (last messages)))))
    (should-not errors)))

(ert-deftest vox-transport-message-limit-independent-of-tcp-chunks ()
  :tags '(vox-unit)
  ;; Synthetic frames: test every split, including one coalesced callback.
  (let* ((vox-transport-max-message-bytes 32)
         (payload (make-string 30 ?x)))
    (skip-unless (require 'websocket nil t))
    (let ((wire (concat (vox-transport-test--wire 'text payload t)
                        (vox-transport-test--wire 'binary payload t))))
      (dotimes (split (1+ (length wire)))
        (vox-transport-test--connection
          (vox-transport-test--upgrade)
          (funcall (process-filter socket) socket (substring wire 0 split))
          (funcall (process-filter socket) socket (substring wire split))
          (should-not errors)
          (should (equal messages (list (list payload 'binary)
                                       (list payload 'text)))))))))

(ert-deftest vox-transport-large-coalesced-batch-is-bounded ()
  :tags '(vox-unit)
  (vox-transport-test--connection
    (vox-transport-test--upgrade)
    (let* ((vox-transport-max-message-bytes 32)
           (wire (vox-transport-test--wire 'text (make-string 30 ?x) t))
           (reader (symbol-function 'websocket-read-frame))
           (largest 0))
      (cl-letf (((symbol-function 'websocket-read-frame)
                 (lambda (input)
                   (setq largest (max largest (length input)))
                   (funcall reader input))))
        (funcall (process-filter socket) socket
                 (apply #'concat (make-list 1000 wire))))
      (should (<= largest (+ 14 vox-transport-max-message-bytes)))
      (should (= (length messages) 1000))
      (should-not errors))))

(ert-deftest vox-transport-handshake-and-first-frames-coalesced ()
  :tags '(vox-unit)
  (vox-transport-test--connection
    (setq network-status 'open)
    (funcall (process-sentinel socket) socket "open")
    (let* ((vox-transport-max-message-bytes 32)
           (wire (vox-transport-test--wire 'text (make-string 30 ?x) t))
           (header (concat "HTTP/1.1 101 Switching Protocols\r\n"
                           "Upgrade: websocket\r\nConnection: upgrade\r\n"
                           "Sec-WebSocket-Accept: " (websocket-accept-string ws)
                           "\r\n\r\n")))
      ;; The callback exceeds the handshake budget, but the header does not.
      (funcall (process-filter socket) socket (substring header 0 (- (length header) 2)))
      (funcall (process-filter socket) socket
               (concat (substring header -2) (apply #'concat (make-list 600 wire))))
      (should (equal opened '(t)))
      (should (= (length messages) 600))
      (should-not errors))))

(ert-deftest vox-transport-handshake-transition-recomputes-wire-budget ()
  :tags '(vox-unit)
  (vox-transport-test--connection
    (setq network-status 'open)
    (funcall (process-sentinel socket) socket "open")
    (let ((vox-transport-max-message-bytes 4)
          (reader (symbol-function 'websocket-read-frame))
          (largest 0))
      (cl-letf (((symbol-function 'websocket-read-frame)
                 (lambda (input)
                   (setq largest (max largest (length input)))
                   (funcall reader input))))
        (funcall (process-filter socket) socket
                 (concat "HTTP/1.1 101 Switching Protocols\r\n"
                         "Upgrade: websocket\r\nConnection: upgrade\r\n"
                         "Sec-WebSocket-Accept: " (websocket-accept-string ws) "\r\n\r\n"
                         (substring (vox-transport-test--wire
                                     'binary (make-string 1000 ?x) t) 0 500))))
      (should (<= largest (+ 14 vox-transport-max-message-bytes)))
      (should-not messages)
      (should (= (length errors) 1)))))

(ert-deftest vox-transport-control-payload-has-independent-limit ()
  :tags '(vox-unit)
  (vox-transport-test--connection
    (vox-transport-test--upgrade)
    (let ((vox-transport-max-message-bytes 4))
      (funcall (process-filter socket) socket
               (concat (vox-transport-test--wire 'text "a" nil)
                       (vox-transport-test--wire 'ping (make-string 125 ?p) t)
                       (vox-transport-test--wire 'pong (make-string 125 ?p) t)
                       (vox-transport-test--wire 'continuation "b" t))))
    (should (equal messages '(("ab" text))))
    (should (= (length writes) 2))
    (should-not errors)))

(ert-deftest vox-transport-control-payload-over-limit-rejected ()
  :tags '(vox-unit)
  (vox-transport-test--connection
    (vox-transport-test--upgrade)
    (funcall (process-filter socket) socket
             (vox-transport-test--wire 'pong (make-string 126 ?p) t))
    (should (= (length errors) 1))
    (should-not messages)))

(ert-deftest vox-transport-callback-close-stops-coalesced-input ()
  :tags '(vox-unit)
  (vox-transport-test--connection
    (vox-transport-test--upgrade)
    (let ((callback (symbol-function 'vox-transport--frame))
          (reader (symbol-function 'websocket-read-frame))
          (after-close 0))
      (cl-letf (((symbol-function 'vox-transport--frame)
                 (lambda (&rest args)
                   (apply callback args)
                   (vox-transport-close session)))
                ((symbol-function 'websocket-read-frame)
                 (lambda (input)
                   (when (and (not (vox-session-websocket session))
                              (> (length input) 0))
                     (cl-incf after-close))
                   (funcall reader input))))
        (funcall (process-filter socket) socket
                 (concat (vox-transport-test--wire 'text "first" t)
                         (vox-transport-test--wire 'text "second" t)
                         (vox-transport-test--wire 'ping "late" t))))
      (should (zerop after-close)))
    (should (equal messages '(("first" text))))
    (should (= (length writes) 1))
    (should-not errors)))

(ert-deftest vox-transport-handshake-wire-limit-retained ()
  :tags '(vox-unit)
  (vox-transport-test--connection
    (funcall (process-filter socket) socket (make-string 16385 ?x))
    (should-not opened)
    (should-not messages)
    (should (= (length errors) 1))
    (should (<= (length (websocket-inflight-input ws)) 16384))))

(ert-deftest vox-transport-handshake-exact-wire-limit-opens ()
  :tags '(vox-unit)
  (vox-transport-test--connection
    (setq network-status 'open)
    (funcall (process-sentinel socket) socket "open")
    (let* ((vox-transport-max-message-bytes 1)
           (header (concat "HTTP/1.1 101 Switching Protocols\r\n"
                           "Upgrade: websocket\r\nConnection: upgrade\r\n"
                           "Sec-WebSocket-Accept: " (websocket-accept-string ws)
                           "\r\nX-Padding: "))
           (wire (concat header (make-string (- 16384 (length header) 4) ?x)
                         "\r\n\r\n" (vox-transport-test--wire 'text "x" t))))
      (funcall (process-filter socket) socket wire)
      (should (equal opened '(t)))
      (should (equal messages '(("x" text))))
      (should-not errors))))

(ert-deftest vox-transport-bytewise-masked-max-frame ()
  :tags '(vox-unit)
  (vox-transport-test--connection
    (vox-transport-test--upgrade)
    (let* ((vox-transport-max-message-bytes 126)
           (payload (make-string 126 ?x))
           (wire (concat (websocket-encode-frame
                          (make-websocket-frame :opcode 'binary :payload payload
                                                :completep t) t)
                         (vox-transport-test--wire 'text "next" t))))
      (dotimes (index (length wire))
        (funcall (process-filter socket) socket (substring wire index (1+ index))))
      (should (equal messages (list '("next" text) (list payload 'binary))))
      (should-not errors))))

(ert-deftest vox-transport-orphan-continuation-is-safe-error ()
  :tags '(vox-unit)
  (vox-transport-test--connection
    (vox-transport-test--upgrade)
    (funcall (process-filter socket) socket
             (vox-transport-test--wire 'continuation "SECRET_TRANSCRIPT" t))
    (should-not messages)
    (should (= (length errors) 1))
    (should-not (string-match-p "SECRET" (car errors)))
    (should-not (vox-session-websocket session))))

(ert-deftest vox-transport-overlapping-messages-rejected ()
  :tags '(vox-unit)
  (vox-transport-test--connection
    (vox-transport-test--upgrade)
    (funcall (process-filter socket) socket
             (concat (vox-transport-test--wire 'text "a" nil)
                     (vox-transport-test--wire 'binary "b" t)))
    (should-not messages)
    (should (= (length errors) 1))))

(ert-deftest vox-transport-limits-fragments-and-payload ()
  :tags '(vox-unit)
  (vox-transport-test--connection
    (vox-transport-test--upgrade)
    (let ((vox-transport-max-message-bytes 3))
      (funcall (process-filter socket) socket (vox-transport-test--wire 'text "ab" nil))
      (funcall (process-filter socket) socket
               (vox-transport-test--wire 'continuation "cd" t)))
    (should-not messages)
    (should (= (length errors) 1))))

(ert-deftest vox-transport-limits-empty-fragment-count ()
  :tags '(vox-unit)
  (vox-transport-test--connection
    (vox-transport-test--upgrade)
    (let ((vox-transport-max-fragments 2))
      (funcall (process-filter socket) socket
               (concat (vox-transport-test--wire 'text "" nil)
                       (vox-transport-test--wire 'continuation "" nil)
                       (vox-transport-test--wire 'continuation "" t))))
    (should-not messages)
    (should (= (length errors) 1))))

(ert-deftest vox-transport-limits-upstream-incomplete-wire-buffer ()
  :tags '(vox-unit)
  (vox-transport-test--connection
    (vox-transport-test--upgrade)
    (let ((vox-transport-max-message-bytes 4)
          (wire (vox-transport-test--wire 'binary (make-string 100 ?x) t)))
      (funcall (process-filter socket) socket (substring wire 0 10))
      (funcall (process-filter socket) socket (substring wire 10 20)))
    (should-not messages)
    (should (= (length errors) 1))))

(ert-deftest vox-transport-invalid-utf8-rejected ()
  :tags '(vox-unit)
  (vox-transport-test--connection
    (vox-transport-test--upgrade)
    (funcall (process-filter socket) socket
             (vox-transport-test--wire 'text (unibyte-string 255) t))
    (should-not messages)
    (should (= (length errors) 1))))

(ert-deftest vox-transport-stale-and-duplicate-close-callbacks ()
  :tags '(vox-unit)
  (vox-transport-test--connection
    (vox-transport-test--upgrade)
    (funcall (websocket-on-close ws) ws)
    (funcall (websocket-on-close ws) ws)
    (funcall (websocket-on-message ws) ws
             (make-websocket-frame :opcode 'text :payload "late" :completep t))
    (should (equal closed '(t)))
    (should-not messages)
    (should-not errors)))

(ert-deftest vox-transport-generation-guard ()
  :tags '(vox-unit)
  (vox-transport-test--connection
    (setf (vox-session-generation session) 2)
    (funcall (websocket-on-open ws) ws)
    (funcall (websocket-on-error ws) ws 'on-open '(error "SECRET"))
    (funcall (websocket-on-close ws) ws)
    (should-not opened)
    (should-not errors)
    (should-not closed)))

(ert-deftest vox-transport-rejects-plaintext-and-header-injection ()
  :tags '(vox-unit)
  (dolist (url '("ws://example.test" "wss://user:secret@example.test"
                 "wss://example.test/#fragment" "wss://example.test/\r\nInjected"))
    (should-error (vox-transport--validate url nil) :type 'user-error))
  (should-error (vox-transport--validate "wss://example.test" '(("X-Key" . "a\r\nb")))
                :type 'user-error))

(ert-deftest vox-transport-sends-text-utf8-and-binary-verbatim ()
  :tags '(vox-unit)
  (vox-transport-test--connection
    (vox-transport-test--upgrade)
    (setq writes nil)
    (let ((text (string #x4e2d)) (bytes (unibyte-string 0 255 128)))
      (vox-transport-send-text session text)
      (let ((frame (websocket-read-frame (car writes))))
        (should (eq (websocket-frame-opcode frame) 'text))
        (should (equal (websocket-frame-payload frame) (encode-coding-string text 'utf-8))))
      (vox-transport-send-binary session bytes)
      (let ((frame (websocket-read-frame (car writes))))
        (should (eq (websocket-frame-opcode frame) 'binary))
        (should (equal (websocket-frame-payload frame) bytes)))
      (should-error (vox-transport-send-binary session (string #x4e2d))))))

(ert-deftest vox-transport-safe-send-error ()
  :tags '(vox-unit)
  (vox-transport-test--connection
    (vox-transport-test--upgrade)
    (cl-letf (((symbol-function 'websocket-send-text)
               (lambda (&rest _) (error "SECRET_KEY SECRET_TRANSCRIPT"))))
      (let ((err (should-error (vox-transport-send-text session "private"))))
        (should (equal (error-message-string err) "WebSocket send failed"))))))

(ert-deftest vox-transport-invalid-handshake-never-opens ()
  :tags '(vox-unit)
  (vox-transport-test--connection
    (setq network-status 'open)
    (funcall (process-sentinel socket) socket "open")
    (funcall (process-filter socket) socket "HTTP/1.1 403 Forbidden\r\n\r\n")
    (should-not opened)
    ;; Upstream calls close before error; Vox latches closed and refuses its
    ;; erroneous subsequent on-open.  Core interprets premature close as failure.
    (should (equal closed '(t)))
    (should-not (vox-session-websocket session))))

(ert-deftest vox-transport-slow-send-fails-after-return ()
  :tags '(vox-unit)
  (vox-transport-test--connection
    (vox-transport-test--upgrade)
    (let ((clock '(0.0 2.0)) (vox-transport-send-timeout 1.0))
      (cl-letf (((symbol-function 'float-time) (lambda (&rest _) (pop clock))))
        (should-error (vox-transport-send-text session "private"))))
    (should (equal errors '("WebSocket write exceeded time budget")))
    (should-not (vox-session-websocket session))))

(ert-deftest vox-transport-unsupported-api-fails-closed ()
  :tags '(vox-unit)
  (skip-unless (require 'websocket nil t))
  (cl-letf (((symbol-function 'websocket-ensure-handshake) (lambda (_) nil)))
    (should-error (vox-transport--check-dependency) :type 'user-error)))

(ert-deftest vox-transport-message-callback-errors-are-contained ()
  :tags '(vox-unit)
  (vox-transport-test--connection
    (vox-transport-test--upgrade)
    (cl-letf (((symbol-function 'vox-transport--frame)
               (lambda (&rest _) (error "SECRET_TRANSCRIPT"))))
      (funcall (websocket-on-message ws) ws
               (make-websocket-frame :opcode 'text :payload "secret" :completep t)))
    (should (equal errors '("WebSocket message rejected or callback failed")))
    (should-not (vox-session-websocket session))))

(ert-deftest vox-transport-reentrant-pong-preserves-input-order ()
  :tags '(vox-unit)
  (vox-transport-test--connection
    (vox-transport-test--upgrade)
    (let ((send (symbol-function 'process-send-string)) reentered)
      (cl-letf (((symbol-function 'process-send-string)
                 (lambda (process bytes)
                   (funcall send process bytes)
                   (unless reentered
                     (setq reentered t)
                     (funcall (process-filter socket) socket
                              (vox-transport-test--wire 'text "second" t))
                     (funcall (process-filter socket) socket
                              (vox-transport-test--wire 'text "third" t))))))
        (funcall (process-filter socket) socket
                 (concat (vox-transport-test--wire 'ping "ping" t)
                         (vox-transport-test--wire 'text "first" t))))
      (should reentered))
    (should-not errors)
    (should (equal (reverse messages)
                   '(("first" text) ("second" text) ("third" text))))))

(ert-deftest vox-transport-reentrant-pong-preserves-fragment-order ()
  :tags '(vox-unit)
  (vox-transport-test--connection
    (vox-transport-test--upgrade)
    (let ((send (symbol-function 'process-send-string)) reentered)
      (cl-letf (((symbol-function 'process-send-string)
                 (lambda (process bytes)
                   (funcall send process bytes)
                   (unless reentered
                     (setq reentered t)
                     (funcall (process-filter socket) socket
                              (vox-transport-test--wire 'text "next" t))))))
        (funcall (process-filter socket) socket
                 (concat (vox-transport-test--wire 'text "a" nil)
                         (vox-transport-test--wire 'ping "ping" t)
                         (vox-transport-test--wire 'continuation "b" t))))
      (should reentered))
    (should-not errors)
    (should (equal (reverse messages) '(("ab" text) ("next" text))))))

(ert-deftest vox-transport-reentrant-input-overflow-clears-retained-data ()
  :tags '(vox-unit)
  (vox-transport-test--connection
    (vox-transport-test--upgrade)
    (let ((send (symbol-function 'process-send-string))
          (context (gethash session vox-transport--contexts))
          (vox-transport-max-retained-input-bytes 12)
          reentered after-first-errors after-first-size)
      (cl-letf (((symbol-function 'process-send-string)
                 (lambda (process bytes)
                   (funcall send process bytes)
                   (unless reentered
                     (setq reentered t)
                     ;; Six active bytes plus six queued bytes exactly fit.
                     (funcall (process-filter socket) socket
                              (vox-transport-test--wire 'text "next" t))
                     (setq after-first-errors (copy-sequence errors)
                           after-first-size (vox-transport--context-input-bytes context))
                     (funcall (process-filter socket) socket
                              (vox-transport-test--wire 'text "more" t))))))
        (funcall (process-filter socket) socket
                 (concat (vox-transport-test--wire 'ping "p" t)
                         (vox-transport-test--wire 'text "a" t))))
      (should reentered)
      (should-not after-first-errors)
      (should (= after-first-size 12))
      (should (equal errors '("WebSocket input rejected or callback failed")))
      (should-not messages)
      (should-not (vox-session-websocket session))
      (should-not (vox-transport--context-input-queue context))
      (should-not (vox-transport--context-input-tail context))
      (should-not (vox-transport--context-input-feeding context))
      (should (zerop (vox-transport--context-input-bytes context))))))

(ert-deftest vox-transport-coalesced-read-has-retained-input-bound ()
  :tags '(vox-unit)
  (vox-transport-test--connection
    (vox-transport-test--upgrade)
    (let ((vox-transport-max-retained-input-bytes 5))
      (funcall (process-filter socket) socket
               (concat (vox-transport-test--wire 'text "a" t)
                       (vox-transport-test--wire 'text "b" t))))
    (should-not messages)
    (should (equal errors '("WebSocket input rejected or callback failed")))
    (should-not (vox-session-websocket session))))

(ert-deftest vox-transport-reentrant-input-discarded-after-close-or-stale-generation ()
  :tags '(vox-unit)
  (dolist (action '(close generation))
    (vox-transport-test--connection
      (vox-transport-test--upgrade)
      (let ((send (symbol-function 'process-send-string))
            (filter (process-filter socket))
            (context (gethash session vox-transport--contexts))
            reentered queued)
        (cl-letf (((symbol-function 'process-send-string)
                   (lambda (process bytes)
                     (funcall send process bytes)
                     (unless reentered
                       (setq reentered t)
                       (funcall filter socket (vox-transport-test--wire 'text "queued" t))
                       (setq queued (not (null (vox-transport--context-input-queue context))))
                       (if (eq action 'close)
                           (vox-transport-close session)
                         (cl-incf (vox-session-generation session)))
                       (funcall filter socket (vox-transport-test--wire 'text "late" t))))))
          (funcall filter socket
                   (concat (vox-transport-test--wire 'ping "p" t)
                           (vox-transport-test--wire 'text "outer-tail" t))))
        (should reentered)
        (should queued)
        (should-not messages)
        (should-not errors)
        (should-not (vox-transport--context-input-queue context))
        (should-not (vox-transport--context-input-tail context))
        (should-not (vox-transport--context-input-feeding context))
        (should (zerop (vox-transport--context-input-bytes context)))))))

(ert-deftest vox-transport-validates-retained-input-limit ()
  :tags '(vox-unit)
  (dolist (limit '(0 -1 1.5 nil))
    (let ((vox-transport-max-retained-input-bytes limit))
      (should-error (vox-transport--validate "wss://vox-test.invalid" nil)
                    :type 'user-error))
    (let ((vox-transport-max-retained-input-chunks limit))
      (should-error (vox-transport--validate "wss://vox-test.invalid" nil)
                    :type 'user-error))))

(ert-deftest vox-transport-reentrant-terminal-sentinel-keeps-receive-order ()
  :tags '(vox-unit)
  (dolist (close-first '(nil t))
    (vox-transport-test--connection
      (vox-transport-test--upgrade)
      (let ((send (symbol-function 'process-send-string))
            (filter (process-filter socket))
            (sentinel (process-sentinel socket))
            reentered)
        (cl-letf (((symbol-function 'process-send-string)
                   (lambda (process bytes)
                     (funcall send process bytes)
                     (unless reentered
                       (setq reentered t)
                       (unless close-first
                         (funcall filter socket
                                  (vox-transport-test--wire 'text "queued-before-close" t)))
                       (setq network-status 'closed)
                       (funcall sentinel socket "SECRET_RAW_CLOSE_EVENT")
                       (funcall filter socket
                                (vox-transport-test--wire 'text "late-after-close" t))))))
          (funcall filter socket
                   (concat (vox-transport-test--wire 'ping "p" t)
                           (vox-transport-test--wire 'text "outer-final" t))))
        (should reentered)
        (should-not errors)
        (should (equal closed '(t)))
        (should (equal (reverse messages)
                       (if close-first '(("outer-final" text))
                         '(("outer-final" text) ("queued-before-close" text)))))
        (should-not (vox-session-websocket session))))))

(ert-deftest vox-transport-input-quit-disposes-before-propagating ()
  :tags '(vox-unit)
  (vox-transport-test--connection
    (vox-transport-test--upgrade)
    (let ((context (gethash session vox-transport--contexts)) caught)
      (cl-letf (((symbol-function 'process-send-string)
                 (lambda (&rest _) (signal 'quit nil))))
        (condition-case nil
            (funcall (process-filter socket) socket
                     (concat (vox-transport-test--wire 'ping "p" t)
                             (vox-transport-test--wire 'text "aborted-tail" t)))
          (quit (setq caught t))))
      (should caught)
      (should-not (vox-transport--live-p context))
      (should-not (vox-session-websocket session))
      (should-not (gethash session vox-transport--contexts))
      (should-not messages)
      (should (equal errors '("WebSocket input interrupted")))
      (should-not (vox-transport--context-input-feeding context))
      (should-not (vox-transport--context-input-queue context))
      (should (zerop (vox-transport--context-input-bytes context))))))

(ert-deftest vox-transport-reentrant-input-chunk-limit-ignores-empty-reads ()
  :tags '(vox-unit)
  (vox-transport-test--connection
    (vox-transport-test--upgrade)
    (let ((send (symbol-function 'process-send-string))
          (context (gethash session vox-transport--contexts))
          (vox-transport-max-retained-input-chunks 3)
          reentered empty-count full-count before-overflow-errors)
      (cl-letf (((symbol-function 'process-send-string)
                 (lambda (process bytes)
                   (funcall send process bytes)
                   (unless reentered
                     (setq reentered t)
                     (dotimes (_ 100)
                       (funcall (process-filter socket) socket (unibyte-string)))
                     (setq empty-count (vox-transport--context-input-count context))
                     (dotimes (_ 2)
                       (funcall (process-filter socket) socket
                                (vox-transport-test--wire 'text "queued" t)))
                     (setq full-count (vox-transport--context-input-count context)
                           before-overflow-errors (copy-sequence errors)
                           network-status 'closed)
                     (funcall (process-sentinel socket) socket "private event")))))
        (funcall (process-filter socket) socket (vox-transport-test--wire 'ping "p" t)))
      (should reentered)
      (should (= empty-count 1))
      (should (= full-count 3))
      (should-not before-overflow-errors)
      (should (equal errors '("WebSocket connection failed")))
      (should-not messages)
      (should-not (vox-session-websocket session))
      (should-not (vox-transport--context-input-queue context))
      (should (zerop (vox-transport--context-input-bytes context)))
      (should (zerop (vox-transport--context-input-count context))))))

(ert-deftest vox-transport-protocol-close-stops-at-wire-boundary ()
  :tags '(vox-unit)
  (dolist (delayed '(nil t))
    (dolist (close-wire (list (unibyte-string #x88 0)
                             (concat (unibyte-string #x88 16 3 232) "normal closure")))
      (vox-transport-test--connection
        (vox-transport-test--upgrade)
        (let ((delete (symbol-function 'delete-process))
              (filter (process-filter socket))
              (sentinel (process-sentinel socket))
              requested)
          (cl-letf (((symbol-function 'delete-process)
                     (lambda (process)
                       (if (not (eq process socket)) (funcall delete process)
                         (setq requested t network-status 'closed)
                         (unless delayed (funcall sentinel socket "deleted"))))))
            (funcall filter socket
                     (concat (vox-transport-test--wire 'text "before-close" t)
                             close-wire
                             (vox-transport-test--wire 'text "after-close" t)))
            (funcall filter socket (vox-transport-test--wire 'text "later-read" t))
            (funcall sentinel socket "delayed terminal event"))
          (should requested)
          (should-not errors)
          (should (equal messages '(("before-close" text))))
          (should (equal closed '(t)))
          (should-not (vox-session-websocket session)))))))

(ert-deftest vox-transport-protocol-close-retains-already-queued-eof ()
  :tags '(vox-unit)
  (vox-transport-test--connection
    (vox-transport-test--upgrade)
    (let ((send (symbol-function 'process-send-string))
          (delete (symbol-function 'delete-process))
          (filter (process-filter socket))
          (sentinel (process-sentinel socket))
          reentered requested)
      (cl-letf (((symbol-function 'process-send-string)
                 (lambda (process bytes)
                   (funcall send process bytes)
                   (unless reentered
                     (setq reentered t network-status 'closed)
                     (funcall sentinel socket "earlier EOF"))))
                ((symbol-function 'delete-process)
                 (lambda (process)
                   (if (eq process socket) (setq requested t)
                     (funcall delete process)))))
        (funcall filter socket
                 (concat (vox-transport-test--wire 'ping "p" t)
                         (vox-transport-test--wire 'text "before-close" t)
                         (unibyte-string #x88 2 3 232)
                         (vox-transport-test--wire 'text "after-close" t))))
      (should reentered)
      (should requested)
      (should-not errors)
      (should (equal messages '(("before-close" text))))
      (should (equal closed '(t)))
      (should-not (vox-session-websocket session)))))

(provide 'vox-test-transport)
;;; vox-test-transport.el ends here
