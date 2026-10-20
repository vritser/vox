;;; vox-test-model.el --- Model selection and ownership tests -*- lexical-binding: t; no-byte-compile: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Synthetic backends and completion only; no recording, keys or network.
;;; Code:
(require 'vox-test-support)
(require 'vox)

(defmacro vox-model-test--session (&rest body)
  "Run BODY with a fake provider and isolated session ownership."
  (declare (indent 0) (debug t))
  `(let ((vox--backends (copy-hash-table vox--backends))
         (vox--active-session nil) (vox--last-session nil) (vox-model nil)
         (backend (vox-make-qwen "Synthetic" :models '(first second)))
         (connect-action #'ignore) (closes 0) (cancels 0) connected)
     (vox-register-backend
      'qwen (list :connect (lambda (session &rest _)
                             (setq connected session)
                             (funcall connect-action session))
                  :finish #'ignore
                  :cancel (lambda (_) (cl-incf cancels))
                  :close (lambda (_) (cl-incf closes))))
     (with-temp-buffer
       (unwind-protect (progn ,@body)
         (when vox--active-session (vox-core-cancel))))))

(ert-deftest vox-model-core-snapshots-before-state-callbacks ()
  :tags '(vox-unit)
  (vox-model-test--session
    (let ((session
           (vox-core-start
            backend (list :on-state
                          (lambda (_ state)
                            (when (eq state 'connecting)
                              (setq vox-model "second")
                              (aset (car (vox-backend-models backend)) 0 ?X)
                              (setf (vox-backend-host backend) "changed.example")))))))
      (should (eq connected session))
      (should (equal (plist-get (vox-session-methods session) :model) "first"))
      (should-not (eq (vox-session-backend session) backend))
      (should (equal (vox-backend-host (vox-session-backend session))
                     "dashscope.aliyuncs.com"))
      (should (equal (vox-backend-models (vox-session-backend session))
                     '("first" "second"))))))

(ert-deftest vox-model-core-distinguishes-omitted-and-explicit-nil ()
  :tags '(vox-unit)
  (vox-model-test--session
    (setq vox-model 'second)
    (let ((session (vox-core-start backend nil)))
      (should (equal (plist-get (vox-session-methods session) :model) "second")))
    (vox-core-cancel)
    (let ((session (vox-core-start backend nil nil nil nil)))
      (should (equal (plist-get (vox-session-methods session) :model) "first")))))

(ert-deftest vox-model-core-invalid-model-never-activates ()
  :tags '(vox-unit)
  (vox-model-test--session
    (setq vox-model 'unknown)
    (should-error (vox-core-start backend nil) :type 'user-error)
    (should-not vox--active-session)
    (should-not connected)))

(ert-deftest vox-model-core-credential-quit-cleans-session ()
  :tags '(vox-unit)
  (vox-model-test--session
    (setq connect-action (lambda (_) (signal 'quit nil)))
    (should (eq 'quit (condition-case nil (vox-core-start backend nil) (quit 'quit))))
    (should-not vox--active-session)
    (should (eq (vox-session-state connected) 'cancelled))
    (should (vox-session-cleaned connected))
    (should-not (marker-buffer (vox-session-target-marker connected)))
    (should (= closes 1))
    (should (= cancels 1))))

(defmacro vox-model-test--selection (&rest body)
  "Run BODY with synthetic advertised model names and no secret access."
  (declare (indent 0) (debug t))
  `(let ((vox-backend (vox-make-qwen "Synthetic" :models '(Model-A Model-B)))
         (vox-model nil))
     (cl-letf (((symbol-function 'vox-backend-secret)
                (lambda (&rest _) (ert-fail "Model selection read credentials")))
               ((symbol-function 'vox-transport-open)
                (lambda (&rest _) (ert-fail "Model selection opened transport")))
               ((symbol-function 'customize-save-variable)
                (lambda (&rest _) (ert-fail "Model selection persisted settings"))))
       ,@body)))

(ert-deftest vox-model-picker-selects-only-advertised-model ()
  :tags '(vox-unit)
  (let (reported)
    (vox-model-test--selection
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection predicate require-match &optional initial history)
                   (should (equal collection '("Model-A" "Model-B")))
                   (should-not predicate)
                   (should require-match)
                   (should-not initial)
                   (should (eq history 'vox-model-history))
                   "Model-B"))
                ((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (setq reported (apply #'format format-string args)))))
        (should (equal (vox-select-model) "Model-B")))
      (should (equal vox-model "Model-B"))
      (should (string-match-p "Model-B" reported)))))

(ert-deftest vox-model-picker-can-recover-from-invalid-current-model ()
  :tags '(vox-unit)
  (vox-model-test--selection
    (setq vox-model "not-advertised")
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "Model-A")))
      (should (equal (vox-select-model) "Model-A")))))

(ert-deftest vox-model-picker-quit-or-invalid-input-preserves-selection ()
  :tags '(vox-unit)
  (dolist (answer '(quit "" "not-advertised"))
    (vox-model-test--selection
      (setq vox-model "Model-A")
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _)
                   (if (eq answer 'quit) (signal 'quit nil) answer))))
        (should (condition-case nil (progn (vox-select-model) nil)
                  ((error quit) t))))
      (should (equal vox-model "Model-A")))))

(ert-deftest vox-model-picker-rechecks-backend-and-model-list ()
  :tags '(vox-unit)
  (dolist (change '(replace mutate))
    (vox-model-test--selection
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _)
                   (if (eq change 'replace)
                       (setq vox-backend (vox-make-doubao "Other"))
                     (setf (vox-backend-models vox-backend) '("Other")))
                   "Model-A")))
        (should-error (vox-select-model) :type 'user-error))
      (should-not vox-model))))

(ert-deftest vox-model-picker-canonicalizes-only-unambiguous-case ()
  :tags '(vox-unit)
  (vox-model-test--selection
    (let ((completion-ignore-case t))
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "model-a")))
        (should (equal (vox-select-model) "Model-A")))
      (setf (vox-backend-models vox-backend) '("Model-A" "model-a"))
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "MODEL-A")))
        (should-error (vox-select-model) :type 'user-error))
      (should (equal vox-model "Model-A"))
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "model-a")))
        (should (equal (vox-select-model) "model-a"))))))

(ert-deftest vox-model-picker-leaves-active-session-model-unchanged ()
  :tags '(vox-unit)
  (vox-model-test--session
    (let* ((vox-backend backend)
           (session (vox-core-start backend nil)))
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "second")))
        (vox-select-model))
      (should (equal vox-model "second"))
      (should (equal (plist-get (vox-session-methods session) :model) "first"))
      (should (eq vox--active-session session)))))

(ert-deftest vox-model-picker-cli-has-no-remote-model-list ()
  :tags '(vox-unit)
  (let ((vox-backend 'cli) (vox-model nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) (ert-fail "CLI prompted for a remote model"))))
      (should-error (vox-select-model) :type 'user-error))
    (should-not vox-model)))

(provide 'vox-test-model)
;;; vox-test-model.el ends here
