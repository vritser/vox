;;; vox-test-qwen.el --- Qwen protocol tests -*- lexical-binding: t; no-byte-compile: t; -*-
(require 'vox-test-support)
(require 'cl-lib)
(require 'vox-backend-qwen)

(ert-deftest vox-qwen-config-is-vad-pcm ()
  :tags '(vox-unit)
  (let* ((vox-qwen-language "zh") (vox-qwen-silence-ms 400)
         (object (vox-json-read (vox-json-encode (vox-qwen-session-update "e1"))))
         (session (plist-get object :session)))
    (should (equal (plist-get session :input_audio_format) "pcm"))
    (should (= (plist-get session :sample_rate) 16000))
    (should (equal (plist-get (plist-get session :turn_detection) :type) "server_vad"))
    (should (= (plist-get (plist-get session :turn_detection) :silence_duration_ms) 400))
    (should (equal (plist-get object :event_id) "e1")))
  (let ((vox-qwen-language nil))
    (should-not (plist-member (plist-get (vox-qwen-session-update "e") :session)
                              :input_audio_transcription)))
  (let ((vox-qwen-silence-ms 199)) (should-error (vox-qwen-session-update "e"))))

(ert-deftest vox-qwen-pure-normalization-and-replacement ()
  :tags '(vox-unit)
  (let* ((partial (vox-qwen-normalize
                   '(:type "conversation.item.input_audio_transcription.text"
                     :item_id "a" :text "\u4eca\u5929" :stash "\u5929\u6c14")))
         (final (vox-qwen-normalize
                 '(:type "conversation.item.input_audio_transcription.completed"
                   :item_id "a" :transcript "\u4eca\u5929\u5929\u6c14\u597d"))))
    (should (equal (plist-get partial :text) "\u4eca\u5929\u5929\u6c14"))
    (should (eq (plist-get partial :type) :segment-partial))
    (should (eq (plist-get final :type) :segment-final))
    (should (equal (plist-get final :text) "\u4eca\u5929\u5929\u6c14\u597d")))
  (should-not (vox-qwen-normalize '(:type "unrecognized.future.event")))
  (should-error (vox-qwen-normalize
                 '(:type "conversation.item.input_audio_transcription.text" :text "bad" :stash "")))
  (dolist (type '("error" "conversation.item.input_audio_transcription.failed"))
    (let ((result (vox-qwen-normalize (list :type type :error '(:message "secret-audio")))))
      (should (eq (plist-get result :type) :error))
      (should-not (string-match-p "secret-audio" (prin1-to-string result))))))

(ert-deftest vox-qwen-credential-sources ()
  :tags '(vox-unit)
  ;; Default: auth-source for the connecting host; no environment lookup.
  (let* ((session (vox--make-session :id "credentials" :generation 1))
         (vox--active-session session)
         (vox-model nil) headers queried)
    (cl-letf (((symbol-function 'auth-source-search)
               (lambda (&rest args)
                 (setq queried (list (plist-get args :host)
                                     (plist-get args :user)))
                 '((:secret (lambda () "synthetic-auth-key")))))
              ((symbol-function 'getenv)
               (lambda (&rest _) (ert-fail "Credential lookup read the environment")))
              ((symbol-function 'vox-transport-open)
               (lambda (_session _url h &rest _) (setq headers h))))
      (vox-qwen-connect session #'ignore #'ignore #'ignore)
      (should (equal (cdr (assoc "Authorization" headers))
                     "Bearer synthetic-auth-key"))
      (should (equal queried '("dashscope.aliyuncs.com" "apikey")))))
  ;; Literal and function keys bypass auth-source.
  (dolist (key (list "synthetic-literal" (lambda () "synthetic-literal")))
    (let* ((configuration (vox-make-qwen "Key" :key key))
           (session (vox--make-session
                     :id "credentials" :generation 1
                     :methods (vox-backend-methods configuration)))
           (vox--active-session session)
           (vox-model nil)
           headers)
      (cl-letf (((symbol-function 'auth-source-search)
                 (lambda (&rest _) (ert-fail "Explicit key consulted auth-source")))
                ((symbol-function 'vox-transport-open)
                 (lambda (_session _url h &rest _) (setq headers h))))
        (vox-qwen-connect session #'ignore #'ignore #'ignore)
        (should (equal (cdr (assoc "Authorization" headers))
                       "Bearer synthetic-literal"))))))

(ert-deftest vox-qwen-missing-auth-source-key-never-opens-transport ()
  :tags '(vox-unit)
  (let* ((session (vox--make-session :id "missing" :generation 1))
         (vox--active-session session)
         (vox-model nil) opened)
    (cl-letf (((symbol-function 'auth-source-search) (lambda (&rest _) nil))
              ((symbol-function 'getenv)
               (lambda (&rest _) (ert-fail "Environment fallback used")))
              ((symbol-function 'vox-transport-open)
               (lambda (&rest _) (setq opened t))))
      (should-error (vox-qwen-connect session #'ignore #'ignore #'ignore)
                    :type 'user-error)
      (should-not opened))))

(ert-deftest vox-qwen-connect-ready-audio-finish-order ()
  :tags '(vox-unit)
  (let* ((session (vox--make-session :id "test" :generation 1))
         (vox--active-session session)
         callbacks headers sent events errors (ready 0) (closed 0))
    (cl-letf (((symbol-function 'vox-backend-secret) (lambda (&rest _) "test-secret"))
              ((symbol-function 'vox-transport-open)
               (lambda (_session _url h open message error close)
                 (setq headers h callbacks (list open message error close))))
              ((symbol-function 'vox-transport-send-text)
               (lambda (_session text) (push (vox-json-read text) sent)))
              ((symbol-function 'vox-transport-close) (lambda (_) (cl-incf closed))))
      (vox-qwen-connect session (lambda () (cl-incf ready))
                        (lambda (e) (push e events)) (lambda (e) (push e errors)))
      (should (equal (cdr (assoc "Authorization" headers)) "Bearer test-secret"))
      (should-error (vox-qwen-send-pcm session (unibyte-string 0 0)))
      (funcall (nth 0 callbacks))
      (should (= ready 0))
      (funcall (nth 1 callbacks) "{\"type\":\"session.updated\"}" 'text)
      (funcall (nth 1 callbacks) "{\"type\":\"session.updated\"}" 'text)
      (should (= ready 1))
      (vox-qwen-send-pcm session (unibyte-string 0 255 128 1))
      (should (equal (base64-decode-string (plist-get (car sent) :audio))
                     (unibyte-string 0 255 128 1)))
      (vox-qwen-finish session)
      (vox-qwen-finish session)
      (should (equal (mapcar (lambda (x) (plist-get x :type)) (reverse sent))
                     '("session.update" "input_audio_buffer.append" "session.finish")))
      (should (= (length (delete-dups (mapcar (lambda (x) (plist-get x :event_id)) sent))) 3))
      (should-error (vox-qwen-send-pcm session (unibyte-string 0 0)))
      (funcall (nth 1 callbacks) "{\"type\":\"session.finished\"}" 'text)
      (funcall (nth 1 callbacks) "{\"type\":\"session.finished\"}" 'text)
      (funcall (nth 3 callbacks))
      (should (= (length events) 1))
      (should-not errors)
      (vox-qwen-close session) (vox-qwen-close session)
      (should (= closed 1)))))

(ert-deftest vox-qwen-independent-configurations-and-captured-open-options ()
  :tags '(vox-unit)
  ;; Synthetic credentials and delayed fake transports; no provider access.
  (let* ((vox-model nil)
         (vox-qwen-language "en") (vox-qwen-silence-ms 600)
         (key-calls 0)
         (first (vox-make-qwen
                 "first" :models '(base selected)
                 :endpoint "/custom?feature=one&model=old&model=stale"
                 :key (lambda () (cl-incf key-calls) "synthetic-first")))
         (second (vox-make-qwen
                  "second" :host "dashscope-intl.aliyuncs.com"
                  :models '(other) :endpoint "/other?feature=two"
                  :key (lambda () (cl-incf key-calls) "synthetic-second")))
         (a (vox--make-session :id "a" :generation 1
                               :methods (vox-backend-methods first 'selected)))
         (b (vox--make-session :id "b" :generation 2
                               :methods (vox-backend-methods second 'other)))
         (vox--active-session a)
         connections sent)
    (should (= key-calls 0))
    (setf (vox-backend-host first) "changed.invalid"
          (vox-backend-models first) '("changed"))
    (cl-letf (((symbol-function 'auth-source-search)
               (lambda (&rest _) (ert-fail "Explicit key must take precedence")))
              ((symbol-function 'getenv)
               (lambda (&rest _) (ert-fail "Explicit key must take precedence")))
              ((symbol-function 'vox-transport-open)
               (lambda (s url headers open &rest _)
                 (push (list s url headers open) connections)))
              ((symbol-function 'vox-transport-send-text)
               (lambda (s text) (push (cons s (vox-json-read text)) sent))))
      (vox-qwen-connect a #'ignore #'ignore #'ignore)
      (setq vox-qwen-language "ja" vox-qwen-silence-ms 900
            vox--active-session b)
      (vox-qwen-connect b #'ignore #'ignore #'ignore)
      (setq vox-model 'invalid vox-qwen-language nil vox-qwen-silence-ms 200)
      (should (= key-calls 2))
      (dolist (connection connections)
        (let* ((s (nth 0 connection)) (url (nth 1 connection))
               (query (cadr (split-string url "?")))
               (pairs (split-string query "&")))
          (should (= (cl-count-if (lambda (pair) (string-prefix-p "model=" pair))
                                  pairs) 1))
          (if (eq s a)
              (progn
                (should (string-prefix-p "wss://dashscope.aliyuncs.com/custom?" url))
                (should (member "model=selected" pairs))
                (should (member "feature=one" pairs))
                (should (equal (cdr (assoc "Authorization" (nth 2 connection)))
                               "Bearer synthetic-first")))
            (should (string-prefix-p "wss://dashscope-intl.aliyuncs.com/other?" url))
            (should (member "model=other" pairs))
            (should (member "feature=two" pairs))
            (should (equal (cdr (assoc "Authorization" (nth 2 connection)))
                           "Bearer synthetic-second")))
          (funcall (nth 3 connection))))
      (dolist (entry sent)
        (let ((request (plist-get (cdr entry) :session)))
          (should (equal (plist-get (plist-get request :input_audio_transcription)
                                    :language)
                         (if (eq (car entry) a) "en" "ja")))
          (should (= (plist-get (plist-get request :turn_detection) :silence_duration_ms)
                     (if (eq (car entry) a) 600 900)))))
      (should (= (length sent) 2)))))

(ert-deftest vox-qwen-custom-host-consent-precedes-lazy-key ()
  :tags '(vox-unit)
  (dolist (approved '(nil t))
    (let* ((vox-model nil) (noninteractive nil) order
           (backend (vox-make-qwen
                     "proxy" :host "qwen.example" :models '(proxy)
                     :key (lambda () (push 'key order) "synthetic-key")))
           (session (vox--make-session :generation 1
                                      :methods (vox-backend-methods backend)))
           (vox--active-session session))
      (should-not order)
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (lambda (_) (push 'consent order) approved))
                ((symbol-function 'vox-transport-open)
                 (lambda (&rest _) (push 'transport order))))
        (if approved
            (progn
              (vox-qwen-connect session #'ignore #'ignore #'ignore)
              (should (equal (reverse order) '(consent key transport))))
          (should-error (vox-qwen-connect session #'ignore #'ignore #'ignore)
                        :type 'user-error)
          (should (equal order '(consent))))))))

(ert-deftest vox-qwen-custom-host-auth-source-uses-parsed-host ()
  :tags '(vox-unit)
  (let* ((vox-model nil) (noninteractive nil)
         (backend (vox-make-qwen "proxy" :host "qwen.example:9443"))
         (session (vox--make-session :generation 1
                                    :methods (vox-backend-methods backend)))
         (vox--active-session session)
         queried)
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t))
              ((symbol-function 'auth-source-search)
               (lambda (&rest args)
                 (setq queried (plist-get args :host))
                 '((:secret "synthetic-key"))))
              ((symbol-function 'vox-transport-open) #'ignore))
      (vox-qwen-connect session #'ignore #'ignore #'ignore)
      (should (equal queried "qwen.example")))))

(ert-deftest vox-qwen-invalid-model-never-resolves-key-or-opens-transport ()
  :tags '(vox-unit)
  (let ((vox-model 'not-supported) calls)
    (cl-letf (((symbol-function 'vox-backend-secret)
               (lambda (&rest _) (push 'key calls)))
              ((symbol-function 'vox-transport-open)
               (lambda (&rest _) (push 'transport calls))))
      (should-error (vox-qwen-connect (vox--make-session) #'ignore #'ignore #'ignore))
      (should-not calls))))

(ert-deftest vox-qwen-stale-session-never-resolves-key-or-opens-transport ()
  :tags '(vox-unit)
  (let ((vox--active-session nil) (vox-model nil) calls
        (session (vox--make-session :id "stale" :generation 1)))
    (cl-letf (((symbol-function 'vox-backend-secret)
               (lambda (&rest _) (push 'key calls)))
              ((symbol-function 'vox-transport-open)
               (lambda (&rest _) (push 'transport calls))))
      (let ((err (should-error
                  (vox-qwen-connect session #'ignore #'ignore #'ignore))))
        (should (string-match-p "no longer active" (error-message-string err))))
      (should-not calls))))

(ert-deftest vox-qwen-late-partial-ignored ()
  :tags '(vox-unit)
  (let* ((events nil)
         (session (vox--make-session
                   :backend-state
                   (list :final-items (make-hash-table :test #'equal)
                         :on-event (lambda (e) (push e events))))))
    (dolist (e '((:type "conversation.item.input_audio_transcription.text"
                 :item_id "a" :text "a" :stash "b")
                (:type "conversation.item.input_audio_transcription.completed"
                 :item_id "a" :transcript "A")
                (:type "conversation.item.input_audio_transcription.text"
                 :item_id "a" :text "late" :stash "")
                (:type "conversation.item.input_audio_transcription.text"
                 :item_id "b" :text "B" :stash "")))
      (vox-qwen--message session (vox-json-encode e) 'text))
    (should (equal (mapcar (lambda (e) (plist-get e :text)) (reverse events))
                   '("ab" "A" "B")))))

(ert-deftest vox-qwen-close-without-authoritative-completion-is-error ()
  :tags '(vox-unit)
  (let* ((session (vox--make-session :id "s" :generation 2))
         (vox--active-session session) close errors)
    (cl-letf (((symbol-function 'vox-backend-secret) (lambda (&rest _) "test"))
              ((symbol-function 'vox-transport-open)
               (lambda (_s _u _h _o _m _e c) (setq close c))))
      (vox-qwen-connect session #'ignore #'ignore (lambda (e) (push e errors)))
      (funcall close)
      (should (equal errors '("Qwen connection closed before session.finished"))))))

(ert-deftest vox-qwen-reject-malformed-and-premature-finish ()
  :tags '(vox-unit)
  (let ((s (vox--make-session :backend-state '(:finished nil))))
    (should-error (vox-qwen--message s "{}" 'binary))
    (should-error (vox-qwen--message s "not json" 'text))
    (should-error (vox-qwen--message s "{\"type\":\"session.finished\"}" 'text))))

(defconst vox-qwen-test--fixtures
  (expand-file-name "fixtures" (file-name-directory (or load-file-name buffer-file-name))))

(ert-deftest vox-qwen-official-static-examples ()
  :tags '(vox-unit)
  (let ((events (with-temp-buffer
                  (insert-file-contents (expand-file-name "qwen-official-events.jsonl"
                                                          vox-qwen-test--fixtures))
                  (mapcar (lambda (line) (vox-qwen-normalize (vox-json-read line)))
                          (split-string (buffer-string) "\n" t)))))
    (should (equal (mapcar (lambda (event) (plist-get event :type)) events)
                   '(:segment-partial :segment-final :completed)))
    (should (equal (plist-get (car events) :text) "\u5317\u4eac\u7684"))
    (should (equal (plist-get (cadr events) :text) "\u4eca\u5929\u5929\u6c14\u600e\u4e48\u6837"))))

(ert-deftest vox-qwen-reentrant-startup-cancel-prevents-secret-and-transport ()
  :tags '(vox-unit)
  (dolist (boundary '(approval key))
    (let* ((vox--active-session nil) (vox--last-session nil)
           (vox-model nil) (noninteractive nil) order opened
           (backend (vox-make-qwen
                     "cancel" :host "qwen.example"
                     :key (lambda ()
                            (push 'key order)
                            (when (eq boundary 'key) (vox-core-cancel))
                            "synthetic-key"))))
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (lambda (_)
                   (push 'approval order)
                   (when (eq boundary 'approval) (vox-core-cancel))
                   t))
                ((symbol-function 'vox-transport-open)
                 (lambda (&rest _) (setq opened t)))
                ((symbol-function 'vox-transport-close) #'ignore)
                ((symbol-function 'vox-audio-start)
                 (lambda (&rest _) (ert-fail "Cancelled startup must not record")))
                ((symbol-function 'vox-audio-cancel) #'ignore))
        (with-temp-buffer
          (unwind-protect
              (let ((session (vox-core-start backend nil)))
                (should (eq (vox-session-state session) 'cancelled))
                (should (vox-session-cleaned session))
                (should-not (vox-session-backend-state session))
                (should-not (vox-session-connect-timer session))
                (should-not (vox-current-session))
                (should (eq vox--last-session session))
                (should-not opened)
                (should (equal (reverse order)
                               (if (eq boundary 'approval) '(approval)
                                 '(approval key)))))
            (vox-core-cancel)))))))

(ert-deftest vox-qwen-successive-sessions-isolate-pcm-items-and-old-sockets ()
  :tags '(vox-unit)
  (skip-unless (require 'websocket nil t))
  ;; Synthetic PCM/JSON and local pipes exercise the real transport guards;
  ;; websocket creation and recording are mocked, with no network or microphone.
  ;; This verifies Realtime adapter isolation, not live model compatibility.
  (dolist (terminal '(complete cancel error))
    (let ((vox--active-session nil) (vox--last-session nil)
          (vox--generation 0) (vox-event-log-enabled nil)
          (vox-transport--contexts (make-hash-table :test #'eq))
          (vox-stop-mode 'manual)
          (backend (vox-make-qwen
                    "Synthetic" :models '(qwen3-asr-flash-realtime)
                    :key "synthetic-key"))
          (real-message (symbol-function 'vox-qwen--message))
          sockets sent commits handled first second)
      (cl-letf (((symbol-function 'vox-transport--check-dependency) #'ignore)
                ((symbol-function 'vox-qwen--message)
                 (lambda (session payload opcode)
                   (push session handled)
                   (funcall real-message session payload opcode)))
                ((symbol-function 'websocket-open)
                 (lambda (url &rest args)
                   (let ((ws
                          (websocket-inner-create
                           :url url
                           :conn (make-pipe-process
                                  :name "vox-qwen-test" :buffer nil
                                  :coding 'binary :noquery t)
                           :on-open (plist-get args :on-open)
                           :on-message (plist-get args :on-message)
                           :on-error (plist-get args :on-error)
                           :on-close (plist-get args :on-close))))
                     (push ws sockets)
                     ws)))
                ((symbol-function 'vox-transport-send-text)
                 (lambda (session text)
                   (push (cons session (vox-json-read text)) sent)))
                ((symbol-function 'vox-audio-start) (lambda (&rest _) nil))
                ((symbol-function 'vox-audio-stop) #'vox-core-audio-ended)
                ((symbol-function 'vox-audio-cancel) #'ignore))
        (cl-labels
            ((message-to
              (socket object)
              (funcall
               (websocket-on-message socket) socket
               (make-websocket-frame
                :opcode 'text :completep t
                :payload (encode-coding-string (vox-json-encode object) 'utf-8))))
             (ready
              (socket)
              (funcall (websocket-on-open socket) socket)
              (message-to socket '(:type "session.updated")))
             (finish
              (session socket text)
              (vox-core-stop session)
              (message-to
               socket
               (list :type "conversation.item.input_audio_transcription.completed"
                     :item_id "reused-id" :transcript text))
              (message-to socket '(:type "session.finished")))
             (audio-for
              (session)
              (mapcar
               (lambda (entry) (base64-decode-string (plist-get (cdr entry) :audio)))
               (cl-remove-if-not
                (lambda (entry)
                  (and (eq (car entry) session)
                       (equal (plist-get (cdr entry) :type) "input_audio_buffer.append")))
                (reverse sent)))))
          (with-temp-buffer
            (unwind-protect
                (progn
                  (setq first (vox-core-start
                               backend
                               (list :on-finish
                                     (lambda (_session text) (push text commits)))
                               nil nil nil))
                  (ready (car sockets))
                  (vox-core-audio first (unibyte-string 1 2 3 4))
                  ;; A final-item tombstone in A must not suppress B's partial.
                  (message-to
                   (car sockets)
                   '(:type "conversation.item.input_audio_transcription.completed"
                     :item_id "reused-id" :transcript "first-round"))
                  (pcase terminal
                    ('complete (finish first (car sockets) "first-round"))
                    ('cancel (vox-core-cancel first))
                    ('error
                     (funcall (websocket-on-error (car sockets))
                              (car sockets) 'synthetic "untrusted")))
                  (should (vox-session-cleaned first))
                  (should-not (vox-session-backend-state first))
                  (should (equal (vox-session-audio-pending first) (unibyte-string)))
                  (setq second (vox-core-start
                                backend
                                (list :on-finish
                                      (lambda (_session text) (push text commits)))
                                nil nil nil))
                  (ready (car sockets))
                  (should (= (length sockets) 2))
                  (should-not (eq (car sockets) (cadr sockets)))
                  (should (eq (vox-current-session) second))
                  (message-to
                   (car sockets)
                   '(:type "conversation.item.input_audio_transcription.text"
                     :item_id "reused-id" :text "second-" :stash "round"))
                  (should (equal (vox-session-text second) "second-round"))
                  ;; All retained callbacks of A must be inert while B records.
                  (let ((before-stale (length handled)))
                    (message-to
                     (cadr sockets)
                     '(:type "conversation.item.input_audio_transcription.completed"
                       :item_id "reused-id" :transcript "stale-first"))
                    (funcall (websocket-on-open (cadr sockets)) (cadr sockets))
                    (funcall (websocket-on-close (cadr sockets)) (cadr sockets))
                    (funcall (websocket-on-error (cadr sockets))
                             (cadr sockets) 'synthetic "untrusted")
                    (should (= (length handled) before-stale)))
                  (should (eq (vox-session-state second) 'recording))
                  (should (equal (vox-session-text second) "second-round"))
                  (should-not (vox-session-backend-state first))
                  (vox-core-audio second (unibyte-string 5 6 7 8))
                  (finish second (car sockets) "second-round")
                  (should (equal (audio-for first)
                                 (if (eq terminal 'complete)
                                     (list (unibyte-string 1 2 3 4)) nil)))
                  (should (equal (audio-for second) (list (unibyte-string 5 6 7 8))))
                  (should (equal (reverse commits)
                                 (if (eq terminal 'complete)
                                     '("first-round" "second-round") '("second-round"))))
                  (should (eq (vox-session-state second) 'completed))
                  (should (= (hash-table-count vox-transport--contexts) 0)))
              (vox-core-cancel)
              (dolist (socket sockets)
                (ignore-errors (delete-process (websocket-conn socket)))))))))))

(provide 'vox-test-qwen)
;;; vox-test-qwen.el ends here
