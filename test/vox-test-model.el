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
         (vox--active-session nil) (vox--last-session nil) (vox-selection nil)
         (vox--generation 0)
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
                              (setq vox-selection '("Synthetic" "second"))
                              (aset (car (vox-backend-models backend)) 0 ?X)
                              (setf (vox-backend-host backend) "changed.example")))))))
      (should (eq connected session))
      (should (equal (plist-get (vox-session-methods session) :model) "first"))
      (should-not (eq (vox-session-backend session) backend))
      (should (equal (vox-backend-host (vox-session-backend session))
                     "dashscope.aliyuncs.com"))
      (should (equal (vox-backend-models (vox-session-backend session))
                     '("first" "second"))))))

(ert-deftest vox-model-core-explicit-model-and-independent-default ()
  :tags '(vox-unit)
  (vox-model-test--session
    (setq vox-selection '("Missing" invalid))
    (let ((session (vox-core-start backend nil nil nil 'second)))
      (should (equal (plist-get (vox-session-methods session) :model) "second")))
    (vox-core-cancel)
    (let ((session (vox-core-start backend nil)))
      (should (equal (plist-get (vox-session-methods session) :model) "first")))
    (vox-core-cancel)
    (let ((session (vox-core-start backend nil nil nil nil)))
      (should (equal (plist-get (vox-session-methods session) :model) "first")))))

(ert-deftest vox-model-core-invalid-model-never-activates ()
  :tags '(vox-unit)
  (vox-model-test--session
    (should-error (vox-core-start backend nil nil nil 'unknown) :type 'user-error)
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

(provide 'vox-test-model)
;;; vox-test-model.el ends here
