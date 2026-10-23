;;; vox-test-doctor.el --- Read-only self-check tests -*- lexical-binding: t; no-byte-compile: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Every check here is offline.  Tests never resolve credentials, start a
;; process or session, list devices, or open a connection; resolvers and
;; capture entry points are replaced with functions that signal if called.

;;; Code:
(require 'vox-test-support)
(require 'vox-backend-cli)
(require 'vox-doctor)

(defmacro vox-doctor-test--env (&rest body)
  "Run BODY with valid, synthetic Vox options and no active session."
  (declare (indent 0) (debug t))
  `(let ((vox-backends
          (list (vox-test-make-qwen "Test Qwen" :key "synthetic-literal-key")))
         (vox-asr-selection nil)
         (vox-tts-selection nil)
         (vox-tts-player-command '("sh"))
         (vox-tts-max-text-chars 4096)
         (vox-tts-max-audio-bytes (* 16 1024 1024))
         (vox-tts-max-response-bytes (* 24 1024 1024))
         (vox-tts-max-pending-bytes (* 2 1024 1024))
         (vox-tts-timeout 60)
         (vox-tts-playback-timeout 600)
         (vox-tts--active nil)
         (vox--starting nil)
         (vox-audio-input '("-f" "lavfi" "-i" "sine"))
         (vox-audio-program "ffmpeg")
         (vox-stop-mode 'silence)
         (vox-silence-seconds 1.2)
         (vox-silence-threshold 0.01)
         (vox-audio-backlog-seconds 2)
         (vox-connect-timeout 20)
         (vox-stop-timeout 15)
         (vox-max-session-seconds 300)
         (vox-preview-interval 0.1)
         (vox-max-transcript-chars 200000)
         (vox-max-segments 1024)
         (vox-max-segment-id-bytes 1024)
         (vox-max-segment-id-total-bytes 65536)
         (vox-device-discovery-timeout 5)
         (vox-event-log-enabled nil)
         (vox--active-session nil)
         (vox--reloading nil))
     ,@body))

(defun vox-doctor-test--get (id results)
  "Return the result for ID in RESULTS, or signal."
  (or (cl-find id results :key (lambda (result) (plist-get result :id)))
      (error "Missing Vox doctor result: %s" id)))

(defun vox-doctor-test--status (id results)
  "Return the status of check ID in RESULTS."
  (plist-get (vox-doctor-test--get id results) :status))

(ert-deftest vox-doctor-default-report-is-well-formed ()
  :tags '(vox-unit)
  (vox-doctor-test--env
    (let ((results (vox-doctor-check)))
      (should (= (length results) 22))
      (dolist (result results)
        (should (memq (plist-get result :status) '(fail warn skip ok)))
        (should (symbolp (plist-get result :id)))
        (should (stringp (plist-get result :summary)))
        (should (> (length (plist-get result :summary)) 0)))
      (should (eq (vox-doctor-test--status 'emacs results) 'ok))
      (should (eq (vox-doctor-test--status 'backends results) 'ok))
      (should (eq (vox-doctor-test--status 'selection results) 'ok))
      (should (eq (vox-doctor-test--status 'stop results) 'ok))
      (should (eq (vox-doctor-test--status 'limits results) 'ok))
      (should-not vox--active-session))))

(ert-deftest vox-doctor-never-renders-a-literal-key ()
  :tags '(vox-unit)
  (let ((secret "sk-doctor-synthetic-secret"))
    (vox-doctor-test--env
      (setq vox-backends (list (vox-test-make-qwen "Literal" :key secret)))
      (let* ((results (vox-doctor-check))
             (report (vox-doctor--render results))
             (summary (plist-get (vox-doctor-test--get 'key results) :summary)))
        (should (eq (vox-doctor-test--status 'key results) 'warn))
        (should (string-match-p "literal" summary))
        (should-not (string-match-p (regexp-quote secret) report))))))

(ert-deftest vox-doctor-never-resolves-credentials ()
  :tags '(vox-unit)
  (let ((calls 0))
    (vox-doctor-test--env
      (setq vox-backends
            (list (vox-test-make-qwen
                   "Deferred" :key (lambda () (cl-incf calls) "synthetic"))))
      (cl-letf (((symbol-function 'vox-backend-secret)
                 (lambda (&rest _) (error "credential resolver must not run"))))
        (let ((results (vox-doctor-check)))
          (should (eq (vox-doctor-test--status 'key results) 'ok))
          (should (string-match-p "not called"
                                  (plist-get (vox-doctor-test--get 'key results)
                                             :summary)))
          (should (= calls 0)))))))

(ert-deftest vox-doctor-invalid-directory-and-selection-are-reported ()
  :tags '(vox-unit)
  (vox-doctor-test--env
    (setq vox-backends (list 42) vox-asr-selection '("Missing" nil))
    (let ((results (vox-doctor-check)))
      (should (eq (vox-doctor-test--status 'backends results) 'fail))
      (should (eq (vox-doctor-test--status 'selection results) 'fail))
      (should (string-match-p
               "entry 1"
               (plist-get (vox-doctor-test--get 'backends results) :summary)))))
  (vox-doctor-test--env
    (setq vox-backends nil)
    (let ((results (vox-doctor-check)))
      (should (eq (vox-doctor-test--status 'backends results) 'fail))
      (should (string-match-p
               "nonempty"
               (plist-get (vox-doctor-test--get 'backends results) :summary))))))

(ert-deftest vox-doctor-invalid-options-fail-with-reasons ()
  :tags '(vox-unit)
  (vox-doctor-test--env
    (setq vox-stop-mode 'bogus)
    (should (eq (vox-doctor-test--status 'stop (vox-doctor-check)) 'fail)))
  (vox-doctor-test--env
    (setq vox-silence-seconds 0.1)
    (let ((result (vox-doctor-test--get 'stop (vox-doctor-check))))
      (should (eq (plist-get result :status) 'fail))
      (should (string-match-p "0.2" (plist-get result :summary)))))
  (vox-doctor-test--env
    (setq vox-max-segments 0)
    (let ((result (vox-doctor-test--get 'limits (vox-doctor-check))))
      (should (eq (plist-get result :status) 'fail))
      (should (string-match-p "positive integers" (plist-get result :summary)))))
  (vox-doctor-test--env
    (setq vox-audio-backlog-seconds 9)
    (let ((result (vox-doctor-test--get 'limits (vox-doctor-check))))
      (should (eq (plist-get result :status) 'fail))
      (should (string-match-p "0.5 to 5" (plist-get result :summary))))))

(ert-deftest vox-doctor-ffmpeg-requirement-follows-the-backend ()
  :tags '(vox-unit)
  (vox-doctor-test--env
    (setq vox-audio-program "vox-doctor-no-such-ffmpeg")
    (should (eq (vox-doctor-test--status 'ffmpeg (vox-doctor-check)) 'fail))
    (setq vox-asr-selection 'cli)
    (let ((result (vox-doctor-test--get 'ffmpeg (vox-doctor-check))))
      (should (eq (plist-get result :status) 'skip))
      (should (string-match-p "self-recording" (plist-get result :summary))))))

(ert-deftest vox-doctor-input-values-stay-private ()
  :tags '(vox-unit)
  (vox-doctor-test--env
    (setq vox-audio-input '("-f" "pulse" "-i" "private-device-name"))
    (let* ((results (vox-doctor-check))
           (report (vox-doctor--render results)))
      (should (eq (vox-doctor-test--status 'input results) 'ok))
      (should (string-match-p
               "4 argv"
               (plist-get (vox-doctor-test--get 'input results) :summary)))
      (should-not (string-match-p "private-device-name" report))))
  (vox-doctor-test--env
    (setq vox-audio-input '("-f" 42))
    (should (eq (vox-doctor-test--status 'input (vox-doctor-check)) 'fail)))
  (vox-doctor-test--env
    (setq vox-audio-input nil)
    (should (eq (vox-doctor-test--status 'input (vox-doctor-check)) 'skip))))

(ert-deftest vox-doctor-endpoint-classifies-official-and-custom-hosts ()
  :tags '(vox-unit)
  (vox-doctor-test--env
    (let ((result (vox-doctor-test--get 'endpoint (vox-doctor-check))))
      (should (eq (plist-get result :status) 'ok))
      (should (string-match-p "dashscope.aliyuncs.com"
                              (plist-get result :summary))))
    (setq vox-backends
          (list (vox-test-make-qwen "Custom" :host "asr.example.test")))
    (let ((result (vox-doctor-test--get 'endpoint (vox-doctor-check))))
      (should (eq (plist-get result :status) 'warn))
      (should (string-match-p "asr.example.test" (plist-get result :summary))))))

(ert-deftest vox-doctor-qwen-audio-is-read-only-and-classified ()
  :tags '(vox-unit)
  (vox-doctor-test--env
    (setq vox-backends
          (list (vox-test-make-qwen-audio
                 "Streaming" :host "dashscope-intl.aliyuncs.com"
                 :key (lambda () (ert-fail "Doctor read a streaming key")))))
    (cl-letf (((symbol-function 'vox-transport-open)
               (lambda (&rest _) (ert-fail "Doctor connected"))))
      (let ((results (vox-doctor-check)))
        (should (eq (vox-doctor-test--status 'endpoint results) 'ok))
        (should (eq (vox-doctor-test--status 'key results) 'ok))
        (should (equal (plist-get (vox-doctor-test--get 'selection results) :summary)
                       "Streaming / qwen-audio-3.0-asr-flash-streaming"))))
    (setf (vox-backend-host (car vox-backends)) "workspace.cn-beijing.maas.aliyuncs.com")
    (should (eq (vox-doctor-test--status 'endpoint (vox-doctor-check)) 'warn))
    (setq vox-asr-selection 'qwen-audio)
    (should (eq (vox-doctor-test--status 'selection (vox-doctor-check)) 'ok))))

(ert-deftest vox-doctor-checks-have-no-runtime-side-effects ()
  :tags '(vox-unit)
  (vox-doctor-test--env
    (cl-letf (((symbol-function 'vox-audio-start)
               (lambda (&rest _) (error "capture must not start")))
              ((symbol-function 'vox-device-list)
               (lambda (&rest _) (error "device listing must not start")))
              ((symbol-function 'vox-transport-open)
               (lambda (&rest _) (error "transport must not open"))))
      (let ((results (vox-doctor-check)))
        (should (= (length results) 22))
        (should-not vox--active-session)
        (should-not (get-buffer "*Vox doctor*"))))))

(ert-deftest vox-doctor-reports-an-active-session-without-touching-it ()
  :tags '(vox-unit)
  (vox-test-session
    (let* ((results (vox-doctor-check))
           (result (vox-doctor-test--get 'session results)))
      (should (eq (plist-get result :status) 'ok))
      (should (string-match-p "connecting" (plist-get result :summary)))
      (should (eq (vox-current-session) session))
      (should (eq (vox-session-state session) 'connecting)))))

(ert-deftest vox-doctor-render-reports-counts-and-hints ()
  :tags '(vox-unit)
  (let ((report
         (vox-doctor--render
          (list (vox-doctor--result 'alpha 'fail "broken" "fix it")
                (vox-doctor--result 'beta 'warn "advisory")
                (vox-doctor--result 'gamma 'skip "not probed")
                (vox-doctor--result 'delta 'ok "fine")))))
    (should (string-match-p "Vox doctor: 1 ok, 1 warn, 1 fail, 1 skip" report))
    (should (string-match-p "FAIL  ALPHA" report))
    (should (string-match-p "broken" report))
    (should (string-match-p "fix it" report))
    (should (string-match-p "Result: FAIL" report))
    (should (string-match-p
             "Result: PASS"
             (vox-doctor--render
              (list (vox-doctor--result 'delta 'ok "fine"))))))
  (should-error (vox-doctor--result 'alpha 'bogus "invalid") :type 'error))

(ert-deftest vox-doctor-displays-a-read-only-buffer ()
  :tags '(vox-unit)
  (when (get-buffer "*Vox doctor*")
    (kill-buffer "*Vox doctor*"))
  (unwind-protect
      (vox-doctor-test--env
        (let (displayed)
          (cl-letf (((symbol-function 'pop-to-buffer)
                     (lambda (buffer &rest _) (setq displayed buffer) buffer)))
            (let ((results (let ((inhibit-message t)) (vox-doctor))))
              (should (= (length results) 22))
              (should (eq displayed (get-buffer "*Vox doctor*")))
              (with-current-buffer displayed
                (should (derived-mode-p 'special-mode))
                (should buffer-read-only)
                (should (string-match-p "Vox doctor:" (buffer-string)))
                (should (string-match-p "Result: " (buffer-string))))))))
    (when (get-buffer "*Vox doctor*")
      (kill-buffer "*Vox doctor*"))))

(ert-deftest vox-doctor-tts-unconfigured-is-optional-but-explicit-selection-fails ()
  :tags '(vox-unit)
  (vox-doctor-test--env
    (setq vox-tts-player-command '("missing-player") vox-tts-timeout 0)
    (let ((results (vox-doctor-check)))
      (dolist (id '(tts-selection tts-player tts-cli tts-endpoint tts-key tts-limits tts-session))
        (should (eq (vox-doctor-test--status id results) 'skip))))
    (setq vox-tts-selection '("Test Qwen" nil))
    (let ((results (vox-doctor-check)))
      (should (eq (vox-doctor-test--status 'tts-selection results) 'fail))
      (should (eq (vox-doctor-test--status 'tts-player results) 'fail))
      (should (eq (vox-doctor-test--status 'tts-limits results) 'fail)))))

(ert-deftest vox-doctor-tts-api-providers-and-tts-only-directory ()
  :tags '(vox-unit)
  (dolist (case (list (list (vox-make-qwen "Qwen" :asr nil :tts t)
                            "Qwen / qwen3-tts-flash-realtime; voice Cherry" 'ok "WSS")
                      (list (vox-make-doubao "Doubao" :asr nil :tts t)
                            "Doubao / seed-tts-2.0; voice zh_female_vv_uranus_bigtts" 'ok "WSS")))
    (vox-doctor-test--env
      (setq vox-backends (list (car case)))
      (let ((results (vox-doctor-check)))
        (should (equal (plist-get (vox-doctor-test--get 'tts-selection results) :summary) (cadr case)))
        (dolist (id '(tts-selection tts-player tts-endpoint tts-key tts-limits tts-session))
          (should (eq (vox-doctor-test--status id results) 'ok)))
        (should (eq (vox-doctor-test--status 'websocket results) (nth 2 case)))
        (should (string-match-p (nth 3 case)
                                (plist-get (vox-doctor-test--get 'tts-endpoint results) :summary)))
        (dolist (id '(selection ffmpeg zlib input stop limits tts-cli))
          (should (eq (vox-doctor-test--status id results) 'skip))))
      (setq vox-asr-selection '("Missing ASR" nil))
      (should (eq (vox-doctor-test--status 'selection (vox-doctor-check)) 'fail)))))

(ert-deftest vox-doctor-tts-invalid-selection-does-not-hide-other-checks ()
  :tags '(vox-unit)
  (dolist (selection '(bad ("Missing" nil) ("Output" unknown-model) ("Output")))
    (vox-doctor-test--env
      (setq vox-backends (list (vox-make-qwen "Output" :asr nil :tts t)) vox-tts-selection selection)
      (let ((results (vox-doctor-check)))
        (should (eq (vox-doctor-test--status 'tts-selection results) 'fail))
        (should (eq (vox-doctor-test--status 'tts-player results) 'ok))
        (should (eq (vox-doctor-test--status 'tts-limits results) 'ok))
        (should (eq (vox-doctor-test--status 'tts-endpoint results) 'skip)))))
  (vox-doctor-test--env
    (setq vox-backends (list (vox-make-qwen "Output" :asr nil :tts t)))
    (setf (vox-provider-tts (car vox-backends)) '(:protocol tts-qwen-realtime :voice "bad\nvoice"))
    (let ((results (vox-doctor-check)))
      (should (eq (vox-doctor-test--status 'backends results) 'fail))
      (should (eq (vox-doctor-test--status 'tts-selection results) 'fail)))))

(ert-deftest vox-doctor-tts-commands-check-availability-without-exposing-argv ()
  :tags '(vox-unit)
  (vox-doctor-test--env
    (setq vox-backends (list (vox-make-cli "Local" :tts '(:command ("sh" "private-cli-argument")))))
    (setq vox-tts-player-command '("sh" "private-player-argument"))
    (let* ((results (vox-doctor-check)) (report (vox-doctor--render results)))
      (should (eq (vox-doctor-test--status 'tts-cli results) 'ok))
      (should (eq (vox-doctor-test--status 'tts-player results) 'ok))
      (should (eq (vox-doctor-test--status 'tts-key results) 'skip))
      (should (eq (vox-doctor-test--status 'tts-endpoint results) 'skip))
      (should (eq (vox-doctor-test--status 'tls results) 'skip))
      (should-not (string-match-p "private-.*-argument" report))
      (should (string-match-p "audible output.*not tested" report)))
    (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))
      (let ((results (vox-doctor-check)))
        (should (eq (vox-doctor-test--status 'tts-cli results) 'fail))
        (should (eq (vox-doctor-test--status 'tts-player results) 'fail))))
    (dolist (command '(nil "sh" ("sh" 7) ("sh" . "bad") ("sh" "bad\0arg")))
      (setq vox-tts-player-command command)
      (should (eq (vox-doctor-test--status 'tts-player (vox-doctor-check)) 'fail)))))

(ert-deftest vox-doctor-tts-endpoints-follow-runtime-host-and-port-policy ()
  :tags '(vox-unit)
  (dolist (case '(("dashscope.aliyuncs.com" ok) ("DASHSCOPE.ALIYUNCS.COM:443" ok)
                  ("dashscope.aliyuncs.com:444" warn) ("custom.example" warn)))
    (vox-doctor-test--env
      (setq vox-backends (list (vox-make-qwen "O" :asr nil :tts t :host (car case))))
      (should (eq (vox-doctor-test--status 'tts-endpoint (vox-doctor-check)) (cadr case)))))
  (vox-doctor-test--env
    (setq vox-backends (list (vox-make-qwen "Shared" :tts '(:host "dashscope-intl.aliyuncs.com"))))
    (should (eq (vox-doctor-test--status 'tts-endpoint (vox-doctor-check)) 'ok))))

(ert-deftest vox-doctor-tts-credentials-are-classified-without-values ()
  :tags '(vox-unit)
  (vox-doctor-test--env
    (setq vox-backends (list (vox-make-qwen "Shared" :key "private-synthetic-key" :tts t)))
    (let ((results (vox-doctor-check)))
      (should (eq (vox-doctor-test--status 'tts-key results) 'warn))
      (should-not (string-match-p "private-synthetic-key" (vox-doctor--render results))))
    (setq vox-backends (list (vox-make-qwen "Override" :key "private-synthetic-key" :tts '(:key nil))))
    (let ((result (vox-doctor-test--get 'tts-key (vox-doctor-check))))
      (should (eq (plist-get result :status) 'ok))
      (should (string-match-p "auth-source" (plist-get result :summary))))))

(ert-deftest vox-doctor-tts-never-performs-runtime-io ()
  :tags '(vox-unit)
  (vox-doctor-test--env
    (let ((calls 0))
      (setq vox-backends (list (vox-make-qwen "Shared" :tts t
                                             :key (lambda () (cl-incf calls) "synthetic"))))
      ;; Installing subr stubs must not itself compile native trampolines and
      ;; write files before the read-only check even starts (Emacs 28 and newer).
      (cl-progv '(comp-enable-subr-trampolines native-comp-enable-subr-trampolines) '(nil nil)
        (cl-letf (((symbol-function 'vox-backend-secret) (lambda (&rest _) (cl-incf calls) (error "forbidden")))
                ((symbol-function 'auth-source-search) (lambda (&rest _) (cl-incf calls) (error "forbidden")))
                ((symbol-function 'make-process) (lambda (&rest _) (cl-incf calls) (error "forbidden")))
                ((symbol-function 'make-network-process) (lambda (&rest _) (cl-incf calls) (error "forbidden")))
                ((symbol-function 'url-retrieve) (lambda (&rest _) (cl-incf calls) (error "forbidden")))
                ((symbol-function 'yes-or-no-p) (lambda (&rest _) (cl-incf calls) (error "forbidden")))
                ((symbol-function 'write-region) (lambda (&rest _) (cl-incf calls) (error "forbidden"))))
        (let ((results (vox-doctor-check)))
          (should (eq (vox-doctor-test--status 'tts-selection results) 'ok))
          (should (eq (vox-doctor-test--status 'tts-key results) 'ok))
          (should (eq (vox-doctor-test--status 'tts-player results) 'ok))
          (should (= calls 0)))
        (setf (vox-provider-tts (car vox-backends)) '(:protocol tts-qwen-realtime :host "custom.example"))
        (should (eq (vox-doctor-test--status 'tts-endpoint (vox-doctor-check)) 'warn))
        (should (= calls 0)))))))

(ert-deftest vox-doctor-tts-limits-match-startup-rejection ()
  :tags '(vox-unit)
  (vox-doctor-test--env
    (setq vox-backends (list (vox-make-qwen "O" :asr nil :tts t)))
    (dolist (case '((vox-tts-max-text-chars 0) (vox-tts-max-text-chars 1.5)
                    (vox-tts-max-audio-bytes -1) (vox-tts-max-response-bytes bad)
                    (vox-tts-timeout nil) (vox-tts-playback-timeout 0)
                    (vox-tts-max-pending-bytes 0)))
      (cl-progv (list (car case)) (list (cadr case))
        (let ((result (vox-doctor-test--get 'tts-limits (vox-doctor-check))))
          (should (eq (plist-get result :status) 'fail))
          (should (string-match-p (symbol-name (car case)) (plist-get result :summary))))
        (should-error (vox-tts-start "synthetic") :type 'user-error)))
    (let ((vox-tts-timeout 0.5) (vox-tts-playback-timeout 0.25))
      (should (eq (vox-doctor-test--status 'tts-limits (vox-doctor-check)) 'ok)))))

(ert-deftest vox-doctor-tts-session-is-an-observer ()
  :tags '(vox-unit)
  (vox-doctor-test--env
    (setq vox-backends (list (vox-make-qwen "O" :asr nil :tts t)))
    (dolist (state '(synthesizing playing))
      (let* ((session (vox-tts--make-session :state state :audio-bytes 123))
             (vox-tts--active session)
             (result (vox-doctor-test--get 'tts-session (vox-doctor-check))))
        (should (eq (plist-get result :status) 'ok))
        (should (string-match-p (symbol-name state) (plist-get result :summary)))
        (should (eq vox-tts--active session))
        (should (eq (vox-tts--session-state session) state))
        (should (= (vox-tts--session-audio-bytes session) 123))))
    (let ((vox--starting t))
      (should (eq (vox-doctor-test--status 'tts-session (vox-doctor-check)) 'warn)))
    (let ((vox--reloading t))
      (should (eq (vox-doctor-test--status 'tts-session (vox-doctor-check)) 'warn)))))

(provide 'vox-test-doctor)
;;; vox-test-doctor.el ends here
