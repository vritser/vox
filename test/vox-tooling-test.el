;;; vox-tooling-test.el --- Checker contract self-tests -*- lexical-binding: t; no-byte-compile: t; -*-

;;; Commentary:
;; This filename deliberately does not match vox-test-*.el.
;; Run with emacs -Q --batch -l test/vox-tooling-test.el.

;;; Code:

(require 'ert)
(require 'cl-lib)

(defvar vox-check-no-run)
(let ((vox-check-no-run t))
  (load (expand-file-name "../scripts/check-lisp.el"
                          (file-name-directory (or load-file-name buffer-file-name)))
        nil t t))

(defmacro vox-tooling-with-file (text &rest body)
  "Evaluate BODY with `file' bound to a temporary file containing TEXT."
  (declare (indent 1) (debug t))
  `(let* ((file (make-temp-file "vox-tooling-" nil ".el" ,text))
          (created (file-truename file)))
     (unwind-protect
         (progn ,@body)
       (unless (and (file-name-absolute-p file)
                    (not (file-symlink-p file))
                    (equal (file-truename file) created))
         (error "Refusing to delete unexpected tooling fixture: %s" file))
       (delete-file file))))

(ert-deftest vox-tooling-valid-file-is-read-only ()
  (vox-tooling-with-file ";;; Example\n(defvar example '(1 [2 \"three\"]))\n"
    (let ((before (with-temp-buffer
                    (insert-file-contents-literally file) (buffer-string)))
          (mtime (file-attribute-modification-time (file-attributes file))))
      (should (vox-check-file file))
      (should (equal before (with-temp-buffer
                              (insert-file-contents-literally file) (buffer-string))))
      (should (equal mtime (file-attribute-modification-time (file-attributes file)))))))

(ert-deftest vox-tooling-final-comment-needs-no-newline ()
  (dolist (text '("(message \"ok\")\n; final comment" "; comment only" ""))
    (vox-tooling-with-file text
      (should (vox-check-file file)))))

(ert-deftest vox-tooling-missing-closer ()
  (vox-tooling-with-file "(defun broken ()\n  (list 1)\n"
    (should-error (vox-check-file file) :type 'vox-check-error)))

(ert-deftest vox-tooling-extra-closer ()
  (vox-tooling-with-file "(list 1))\n"
    (should-error (vox-check-file file) :type 'vox-check-error)))

(ert-deftest vox-tooling-invalid-reader-syntax ()
  (dolist (text '("#<broken>" "[1)" "#xNOTHEX" "\"unterminated"))
    (vox-tooling-with-file text
      (should-error (vox-check-file file) :type 'vox-check-error))))

(ert-deftest vox-tooling-reader-prefix-cannot-swallow-sentinel ()
  ;; These prefixes can pass the syntax scanner but still need a read object.
  (dolist (text '("#'" "'" "#@100 "))
    (vox-tooling-with-file text
      (should-error (vox-check-file file) :type 'vox-check-error))))

(ert-deftest vox-tooling-early-sentinel-cannot-hide-damage ()
  (vox-tooling-with-file "(:vox-check-end)\n#<broken>\n"
    (should-error (vox-check-file file) :type 'vox-check-error)))

(ert-deftest vox-tooling-empty-file-list-is-not-success ()
  (let ((standard-output (generate-new-buffer " *vox-tooling-output*")))
    (unwind-protect
        (should (= 2 (vox-check-files nil)))
      (kill-buffer standard-output))))

(ert-deftest vox-tooling-diagnostic-has-file-line-column ()
  (vox-tooling-with-file "; comment\n)\n"
    (let ((output (with-output-to-string
                    (should (= 1 (vox-check-files (list file)))))))
      (should (string-match-p (concat (regexp-quote file) ":2:1: ") output)))))

(ert-deftest vox-tooling-explicit-empty-cli-is-not-defaults ()
  (let ((command-line-args-left '("--")))
    (cl-letf (((symbol-function 'kill-emacs) #'identity)
              ((symbol-function 'vox-check-default-files)
               (lambda () (ert-fail "Explicit empty list must not use defaults"))))
      (should (= 2 (vox-check-main))))))

(ert-deftest vox-tooling-cli-requires-separator ()
  (dolist (args '(("source.el") ("--fix") ("--" "--fix")))
    (let ((command-line-args-left args))
      (cl-letf (((symbol-function 'kill-emacs) #'identity))
        (should (= 2 (vox-check-main)))))))

(when noninteractive
  (ert-run-tests-batch-and-exit "\\`vox-tooling-"))

(provide 'vox-tooling-test)
;;; vox-tooling-test.el ends here
