;;; vox-test.el --- Unit-suite loader and batch entry point -*- lexical-binding: t; no-byte-compile: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Run: emacs -Q --batch -l test/vox-test.el
;; Bind `vox-test-no-run' when loading from another tool or interactive session.
;;; Code:
(add-to-list 'load-path
             (file-name-directory (or load-file-name buffer-file-name)))
(require 'vox-test-support)

(defvar vox-test-no-run nil
  "Non-nil prevents automatic batch execution when this runner is loaded.")

(dolist (file (directory-files vox-test-directory t "\\`vox-test-.+\\.el\\'"))
  (unless (member (file-name-nondirectory file)
                  '("vox-test-support.el" "vox-test-runner.el"))
    (require (intern (file-name-base file)))))

(defun vox-test-run (&optional selector)
  "Run SELECTOR (default Vox unit tests) and return ERT statistics.
An empty selection is an error, not a passing test run.  This function does
not exit Emacs and is suitable for interactive or coverage-tool use."
  (setq selector (or selector '(tag vox-unit)))
  ;; Emacs 28 asserts on an unknown test name instead of signaling
  ;; `ert-test-unbound'; its assertion calls the debugger directly while
  ;; ERT has `debug-on-error' bound, bypassing `condition-case'.
  (let ((tests (let ((debug-on-error nil))
                 (condition-case nil
                     (ert-select-tests selector t)
                   (cl-assertion-failed nil)
                   (ert-test-unbound nil)))))
    (unless tests
      (error "No Vox tests match %S" selector)))
  (cl-progv (when (boundp 'comp-enable-subr-trampolines)
              '(comp-enable-subr-trampolines))
      '(nil)
    (ert-run-tests-batch selector)))

(defun vox-test-batch (&optional selector)
  "Run SELECTOR and exit nonzero on failure or empty selection."
  (condition-case err
      (let ((stats (vox-test-run selector)))
        (kill-emacs (if (zerop (ert-stats-completed-unexpected stats)) 0 1)))
    (error
     (princ (format "Vox test runner: %s\n" (error-message-string err)))
     (kill-emacs 1))))

(provide 'vox-test)
(when (and noninteractive (not vox-test-no-run))
  (vox-test-batch))
;;; vox-test.el ends here
