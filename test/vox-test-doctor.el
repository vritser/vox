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
          (list (vox-make-qwen "Test Qwen" :key "synthetic-literal-key")))
         (vox-selection nil)
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
      (should (= (length results) 15))
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
      (setq vox-backends (list (vox-make-qwen "Literal" :key secret)))
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
            (list (vox-make-qwen
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
    (setq vox-backends (list 42) vox-selection '("Missing" nil))
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
    (setq vox-selection 'cli)
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
          (list (vox-make-qwen "Custom" :host "asr.example.test")))
    (let ((result (vox-doctor-test--get 'endpoint (vox-doctor-check))))
      (should (eq (plist-get result :status) 'warn))
      (should (string-match-p "asr.example.test" (plist-get result :summary))))))

(ert-deftest vox-doctor-qwen-audio-is-read-only-and-classified ()
  :tags '(vox-unit)
  (vox-doctor-test--env
    (setq vox-backends
          (list (vox-make-qwen-audio
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
    (setq vox-selection 'qwen-audio)
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
        (should (= (length results) 15))
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
              (should (= (length results) 15))
              (should (eq displayed (get-buffer "*Vox doctor*")))
              (with-current-buffer displayed
                (should (derived-mode-p 'special-mode))
                (should buffer-read-only)
                (should (string-match-p "Vox doctor:" (buffer-string)))
                (should (string-match-p "Result: " (buffer-string))))))))
    (when (get-buffer "*Vox doctor*")
      (kill-buffer "*Vox doctor*"))))

(provide 'vox-test-doctor)
;;; vox-test-doctor.el ends here
