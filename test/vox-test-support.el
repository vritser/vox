;;; vox-test-support.el --- Shared test paths and fixtures -*- lexical-binding: t; no-byte-compile: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Subsystem files require this helper, never another subsystem's tests.
;;; Code:
(require 'ert)
(require 'cl-lib)

(defconst vox-test-directory
  (file-name-directory (or load-file-name buffer-file-name)))
(defconst vox-test-root-directory
  (file-name-directory (directory-file-name vox-test-directory)))
(add-to-list 'load-path vox-test-root-directory)
(add-to-list 'load-path (expand-file-name ".deps" vox-test-root-directory))
(setq load-prefer-newer t)
(require 'vox-core)

(defmacro vox-test-session (&rest body)
  "Run BODY with a fake backend and captured callbacks."
  (declare (indent 0) (debug t))
  `(let ((vox--active-session nil) (vox--last-session nil)
         (vox--backends (copy-hash-table vox--backends))
         ready emit fail session (finishes 0) (closes 0) commits states)
     (vox-register-backend
      'mock (list :connect (lambda (_s r e f) (setq ready r emit e fail f))
                  :finish (lambda (_s) (cl-incf finishes))
                  :cancel #'ignore :close (lambda (_s) (cl-incf closes))))
     (with-temp-buffer
       (unwind-protect
           (progn
             (setq session (vox-core-start
                            'mock (list :on-state (lambda (_s state) (push state states))
                                        :on-finish (lambda (_s text) (push text commits)))))
             ,@body)
         (vox-core-cancel)))))

(provide 'vox-test-support)
;;; vox-test-support.el ends here
