;;; vox-test-start.el --- Interactive startup preflight tests -*- lexical-binding: t; no-byte-compile: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; No device discovery, microphone, subprocess or provider is used here.
;;; Code:
(require 'vox-test-support)
(require 'vox)

(defmacro vox-start-test--stub (&rest body)
  "Run BODY with fake input selection and a captured core start."
  (declare (indent 0) (debug t))
  `(let ((vox--active-session nil) (vox-audio-input nil)
         (vox-audio-program "synthetic-ffmpeg")
         (vox-backends (list (vox-make-qwen "Qwen"))) (vox-selection nil)
         (vox-selection-history nil) (vox--selection-revision 0)
         (noninteractive nil) (external t) (selected 0) (started 0)
         (selection '("-f" "avfoundation" "-i" ":2")) start-args)
     (cl-letf (((symbol-function 'vox-backend-methods)
                (lambda (_ &optional _model) (list :needs-external-audio external)))
               ((symbol-function 'executable-find) (lambda (_) "/synthetic/ffmpeg"))
               ((symbol-function 'vox-select-input-device)
                (lambda (&optional _) (cl-incf selected)
                  (setq vox-audio-input (copy-sequence selection))))
               ((symbol-function 'vox-core-start)
                (lambda (backend sink &optional buffer marker model)
                  (cl-incf started)
                  (setq start-args (list backend sink buffer
                                         (when marker (marker-position marker))
                                         (current-buffer) model))
                  'started)))
       (with-temp-buffer ,@body))))

(ert-deftest vox-start-first-interactive-call-selects-input ()
  :tags '(vox-unit)
  (vox-start-test--stub
    (should (eq (call-interactively #'vox-start) 'started))
    (should (= selected 1))
    (should (= started 1))
    (should (equal vox-audio-input selection))))

(ert-deftest vox-start-interactive-toggle-keeps-selection-interactive ()
  :tags '(vox-unit)
  (vox-start-test--stub
    (call-interactively #'vox-toggle)
    (should (= selected 1))
    (should (= started 1))))

(ert-deftest vox-start-explicit-configuration-never-prompts ()
  :tags '(vox-unit)
  (vox-start-test--stub
    (setq vox-audio-input '("-re" "-f" "lavfi" "-i" "synthetic-source"))
    (let ((original vox-audio-input))
      (call-interactively #'vox-start)
      (should (eq vox-audio-input original))
      (should (= selected 0))
      (should (= started 1)))))

(ert-deftest vox-start-programmatic-and-batch-calls-do-not-prompt ()
  :tags '(vox-unit)
  (vox-start-test--stub
    (should-error (vox-start) :type 'user-error)
    (should-error (vox-toggle) :type 'user-error)
    (let ((noninteractive t))
      (should-error (call-interactively #'vox-start) :type 'user-error))
    (should (= selected 0))
    (should (= started 0))))

(ert-deftest vox-start-cli-needs-neither-picker-nor-ffmpeg ()
  :tags '(vox-unit)
  (vox-start-test--stub
    (setq external nil vox-selection 'cli)
    (cl-letf (((symbol-function 'executable-find)
               (lambda (_) (ert-fail "Self-recording backend looked for FFmpeg"))))
      (call-interactively #'vox-start))
    (should (= selected 0))
    (should (= started 1))
    (should (eq (car start-args) 'cli))))

(ert-deftest vox-start-no-picker-for-invalid-existing-input ()
  :tags '(vox-unit)
  (dolist (input '("not argv" ("-f" . "pulse") ("-i" 1)))
    (vox-start-test--stub
      (setq vox-audio-input input)
      (should-error (call-interactively #'vox-start) :type 'user-error)
      (should (eq vox-audio-input input))
      (should (= selected 0))
      (should (= started 0)))))

(ert-deftest vox-start-missing-ffmpeg-fails-before-selection ()
  :tags '(vox-unit)
  (vox-start-test--stub
    (cl-letf (((symbol-function 'executable-find) (lambda (_) nil)))
      (should-error (call-interactively #'vox-start) :type 'user-error))
    (should (= selected 0))
    (should (= started 0))))

(ert-deftest vox-start-selection-quit-or-error-never-connects ()
  :tags '(vox-unit)
  (dolist (failure '(quit user-error))
    (vox-start-test--stub
      (cl-letf (((symbol-function 'vox-select-input-device)
                 (lambda (&optional _) (signal failure '("Synthetic selection failure")))))
        (should (eq (condition-case condition
                        (progn (call-interactively #'vox-start) nil)
                      ((quit error) (car condition)))
                    failure)))
      (should-not vox-audio-input)
      (should (= started 0)))))

(ert-deftest vox-start-active-session-fails-before-selection ()
  :tags '(vox-unit)
  (vox-start-test--stub
    (setq vox--active-session (vox--make-session :state 'recording))
    (should-error (call-interactively #'vox-start) :type 'user-error)
    (should (= selected 0))
    (should (= started 0))))

(ert-deftest vox-start-picker-cannot-retarget-buffer-or-backend ()
  :tags '(vox-unit)
  (vox-start-test--stub
    (insert "ABCD")
    (goto-char 3)
    (let ((target (current-buffer)) (other (generate-new-buffer " *vox-start-other*")))
      (unwind-protect
          (cl-letf (((symbol-function 'vox-select-input-device)
                     (lambda (&optional _)
                       (setq vox-audio-input selection vox-selection '("Doubao" nil))
                       (goto-char (point-min))
                       (insert "X")
                       (set-buffer other))))
            (call-interactively #'vox-start)
            (should (equal (vox-backend-name (nth 0 start-args)) "Qwen"))
            (should (eq (nth 2 start-args) target))
            (should (= (nth 3 start-args) 4))
            (should (eq (nth 4 start-args) target)))
        (kill-buffer other)))))

(ert-deftest vox-start-rechecks-target-after-selection ()
  :tags '(vox-unit)
  (dolist (change '(kill read-only))
    (vox-start-test--stub
      (cl-letf (((symbol-function 'vox-select-input-device)
                 (lambda (&optional _)
                   (setq vox-audio-input selection)
                   (if (eq change 'kill) (kill-buffer (current-buffer))
                     (setq buffer-read-only t)))))
        (should-error (call-interactively #'vox-start) :type 'user-error))
      (should (= started 0)))))

(ert-deftest vox-start-read-only-target-fails-before-selection ()
  :tags '(vox-unit)
  (vox-start-test--stub
    (setq buffer-read-only t)
    (should-error (call-interactively #'vox-start) :type 'user-error)
    (should (= selected 0))
    (should (= started 0))))

(ert-deftest vox-start-reentrant-session-cannot-be-overwritten ()
  :tags '(vox-unit)
  (vox-start-test--stub
    (let ((other (vox--make-session :state 'connecting)))
      (cl-letf (((symbol-function 'vox-select-input-device)
                 (lambda (&optional _)
                   (setq vox-audio-input selection vox--active-session other))))
        (should-error (call-interactively #'vox-start) :type 'user-error))
      (should (eq vox--active-session other))
      (should (= started 0)))))

(ert-deftest vox-start-rejects-selection-without-valid-argv ()
  :tags '(vox-unit)
  (dolist (invalid '(nil "invalid" ("-i" 1)))
    (vox-start-test--stub
      (cl-letf (((symbol-function 'vox-select-input-device)
                 (lambda (&optional _) (setq vox-audio-input invalid))))
        (should-error (call-interactively #'vox-start) :type 'user-error))
      (should (= started 0)))))

(ert-deftest vox-start-picker-cannot-retarget-model-or-backend-fields ()
  :tags '(vox-unit)
  (vox-start-test--stub
    (setq vox-backends (list (vox-make-qwen "Synthetic" :models '(first second)
                                         :language "en"))
          vox-selection (list "Synthetic" (copy-sequence "first")))
    (cl-letf (((symbol-function 'vox-select-input-device)
               (lambda (&optional _)
                 (setq vox-audio-input selection)
                 (aset (cadr vox-selection) 0 ?X)
                  (aset (vox-backend-language (car vox-backends)) 0 ?X)
                 (setf (vox-backend-host (car vox-backends)) "changed.example"
                       (vox-backend-models (car vox-backends)) '("changed"))
                 (setq vox-selection '("Synthetic" "second")))))
      (call-interactively #'vox-start))
    (should (equal (nth 5 start-args) "first"))
    (should-not (eq (car start-args) (car vox-backends)))
    (should (equal (vox-backend-host (car start-args)) "dashscope.aliyuncs.com"))
    (should (equal (vox-backend-language (car start-args)) "en"))
    (should (equal (vox-backend-models (car start-args)) '("first" "second")))))

(ert-deftest vox-start-default-model-choice-survives-picker ()
  :tags '(vox-unit)
  (vox-start-test--stub
    (cl-letf (((symbol-function 'vox-select-input-device)
               (lambda (&optional _)
                 (setq vox-audio-input selection vox-selection '("Missing" "changed")))))
      (call-interactively #'vox-start))
    (should (equal (nth 5 start-args) "qwen3-asr-flash-realtime"))))

(ert-deftest vox-start-named-snapshot-survives-backend-selection ()
  :tags '(vox-unit)
  (vox-start-test--stub
    (let* ((first (vox-make-qwen "First" :models '(first-a first-b)))
           (second (vox-make-doubao "Second"))
           (vox-backends (list first second)))
      (setq vox-selection '("First" first-b))
      (cl-letf (((symbol-function 'vox-select-input-device)
                 (lambda (&optional _)
                   (setq vox-audio-input selection)
                   (vox-select)
                   (setf (vox-backend-host first) "changed.example")))
                ((symbol-function 'completing-read) (lambda (&rest _) "\"Second\" / \"bigmodel\"")))
        (call-interactively #'vox-start))
      (should (equal vox-selection '("Second" "bigmodel")))
      (should (= started 1))
      (should (equal (nth 5 start-args) "first-b"))
      (should (equal (vox-backend-name (car start-args)) "First"))
      (should (equal (vox-backend-host (car start-args)) "dashscope.aliyuncs.com")))))

(ert-deftest vox-start-default-model-snapshot-survives-directory-mutation ()
  :tags '(vox-unit)
  (dolist (choice '(nil ("Qwen" nil)))
    (vox-start-test--stub
      (setq vox-selection choice)
      (cl-letf (((symbol-function 'vox-select-input-device)
                 (lambda (&rest _)
                   (setq vox-audio-input selection)
                   (aset (car (vox-backend-models (car vox-backends))) 0 ?X)
                   (setf (vox-backend-models (car vox-backends)) '("replacement")))))
        (call-interactively #'vox-start))
      (should (equal (nth 5 start-args) "qwen3-asr-flash-realtime"))
      (should (equal (vox-backend-models (car start-args))
                     '("qwen3-asr-flash-realtime")))
      (should (= started 1)))))

(provide 'vox-test-start)
;;; vox-test-start.el ends here
