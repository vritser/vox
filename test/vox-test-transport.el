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

(provide 'vox-test-transport)
;;; vox-test-transport.el ends here
