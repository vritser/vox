;;; vox-test-runner.el --- Runner contract self-tests -*- lexical-binding: t; no-byte-compile: t; -*-

(add-to-list 'load-path
             (file-name-directory (or load-file-name buffer-file-name)))
(defvar vox-test-no-run)
(let ((vox-test-no-run t)) (require 'vox-test))

(ert-deftest vox-runner-rejects-empty-selection ()
  :tags '(vox-runner)
  (should-error (vox-test-run '(member vox-deliberately-missing-test)))
  (should (= 1 (catch 'exit
                 (cl-letf (((symbol-function 'kill-emacs)
                            (lambda (status) (throw 'exit status))))
                   (let ((standard-output (generate-new-buffer " *vox-runner-log*")))
                     (unwind-protect
                         (vox-test-batch '(member vox-deliberately-missing-test))
                       (kill-buffer standard-output))))))))

(ert-deftest vox-runner-normalizes-legacy-selector-assertion ()
  :tags '(vox-runner)
  ;; Emacs 28's `ert-select-tests' asserts on an unknown test name.  While
  ;; ERT binds `debug-on-error', `cl-assert' calls the debugger directly and
  ;; would abort the test unless the runner binds it to nil.
  (cl-letf (((symbol-function 'ert-select-tests)
             (lambda (&rest _) (cl-assert nil))))
    (should-error (vox-test-run '(member vox-deliberately-missing-test))
                  :type 'error)))

(ert-deftest vox-runner-propagates-test-status ()
  :tags '(vox-runner)
  (dolist (unexpected '(0 1))
    (should
     (= unexpected
        (catch 'exit
          (cl-letf (((symbol-function 'vox-test-run) (lambda (&optional _) 'stats))
                    ((symbol-function 'ert-stats-completed-unexpected)
                     (lambda (_) unexpected))
                    ((symbol-function 'kill-emacs)
                     (lambda (status) (throw 'exit status))))
            (vox-test-batch)))))))

(ert-deftest vox-runner-default-selection-excludes-tooling ()
  :tags '(vox-runner)
  (let ((tests (ert-select-tests '(tag vox-unit) t)))
    (should (> (length tests) 0))
    (should-not (cl-some (lambda (test) (memq 'vox-runner (ert-test-tags test))) tests))))

(ert-deftest vox-runner-subsystem-load-is-independent ()
  :tags '(vox-runner)
  (let ((emacs (expand-file-name invocation-name invocation-directory)))
    (with-temp-buffer
      (should
       (zerop
        (call-process emacs nil t nil "-Q" "--batch" "-L" vox-test-directory
                      "-l" (expand-file-name "vox-test-cli.el" vox-test-directory)
                      "--eval"
                      "(let ((tests (ert-select-tests t t))) (unless (and tests (cl-every (lambda (test) (string-prefix-p \"vox-cli-\" (symbol-name (ert-test-name test)))) tests)) (error \"Subsystem leaked unrelated tests\")))"))))))

(provide 'vox-test-runner)
(when noninteractive (ert-run-tests-batch-and-exit '(tag vox-runner)))
;;; vox-test-runner.el ends here
