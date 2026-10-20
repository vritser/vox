;;; check-coverage.el --- Optional testcover report for Vox -*- lexical-binding: t; no-byte-compile: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Run from anywhere with:
;;   emacs -Q --batch -l scripts/check-coverage.el [-- THRESHOLD] [--all]
;; Instrument production modules with testcover, run the offline suite, and
;; print per-definition point coverage.  The default report lists only
;; definitions below THRESHOLD (80); `--all' prints every definition.  This is
;; informational and is not part of scripts/verify.sh; low coverage never fails
;; the run, but unexpected test failures still exit nonzero after the report.
;;
;; vox.el is excluded because Edebug wrappers change `called-interactively-p'
;; inside instrumented commands, which the interactive start tests exercise.
;; Definitions with no instrumented points (cl-defstruct constructors and
;; returned closures) are not measurable and are omitted from the totals.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'seq)
(require 'subr-x)
(require 'testcover)

(defvar vox-test-no-run)
(declare-function vox-test-run "vox-test" (&optional selector))

(defvar vox-cov-no-run nil
  "Non-nil prevents automatic execution when this file is loaded.")

(defconst vox-cov-root
  (let ((directory (file-name-directory
                    (file-truename (or load-file-name buffer-file-name)))))
    (directory-file-name
     (file-name-directory (directory-file-name directory))))
  "Repository root, derived from this script's location.")

(defconst vox-cov-product-files
  '("vox-activity.el" "vox-audio.el" "vox-backend.el"
    "vox-backend-cli.el" "vox-backend-doubao.el" "vox-backend-qwen.el"
    "vox-core.el" "vox-device.el" "vox-transport.el" "vox-ui.el")
  "Production modules instrumented by testcover.
`vox.el' is excluded: Edebug wrappers make `called-interactively-p' return nil
inside instrumented commands, and the interactive start tests depend on it.")

(defun vox-cov--prepare-load-path ()
  "Make the repository, its tests, and .deps resolvable."
  (dolist (directory (list vox-cov-root
                           (expand-file-name "test" vox-cov-root)
                           (expand-file-name ".deps" vox-cov-root)))
    (add-to-list 'load-path directory))
  (setq load-prefer-newer t))

(defun vox-cov--instrument ()
  "Instrument every product file and return the measurable symbols."
  (let ((inhibit-message t))
    (dolist (name vox-cov-product-files)
      (testcover-start (expand-file-name name vox-cov-root))))
  (let (symbols)
    (mapatoms
     (lambda (symbol)
       (when (and (get symbol 'edebug-coverage)
                  (not (string-prefix-p "edebug-anon" (symbol-name symbol))))
         (push symbol symbols))))
    symbols))

(defun vox-cov--points (symbol)
  "Return (COVERED . TOTAL) points for SYMBOL, or nil when not measurable."
  (let ((vector (get symbol 'edebug-coverage)))
    (when (and (vectorp vector) (> (length vector) 0))
      (let ((covered 0))
        (dotimes (index (length vector))
          (unless (eq (aref vector index) 'edebug-unknown)
            (cl-incf covered)))
        (cons covered (length vector))))))

(defun vox-cov--rows (symbols)
  "Return (SYMBOL PERCENT COVERED TOTAL) rows for SYMBOLS, lowest first."
  (let (rows)
    (dolist (symbol symbols)
      (let ((points (vox-cov--points symbol)))
        (when points
          (push (list symbol
                      (* 100.0 (/ (float (car points)) (cdr points)))
                      (car points) (cdr points))
                rows))))
    (sort rows (lambda (a b) (< (cadr a) (cadr b))))))

(defun vox-cov--unlisted-modules ()
  "Return production modules missing from `vox-cov-product-files'.
`vox.el' is excluded from instrumentation and `vox-pkg.el' is package metadata."
  (seq-remove (lambda (name)
                (or (member name '("vox.el" "vox-pkg.el"))
                    (member name vox-cov-product-files)))
              (directory-files vox-cov-root nil "\\`vox-.*\\.el\\'")))

(defun vox-cov--report (rows threshold all)
  "Print coverage ROWS, the total, and the definitions below THRESHOLD.
With ALL, print every definition instead of only the ones below THRESHOLD."
  (let ((total 0) (covered 0)
        (unlisted (vox-cov--unlisted-modules)))
    (princ "\n=== Vox coverage (per definition, testcover points) ===\n")
    (when unlisted
      (princ (format "Warning: not instrumented: %s\n"
                     (mapconcat #'identity unlisted ", "))))
    (when all
      (dolist (row rows)
        (princ (format "  %5.1f%%  %3d/%-3d  %s\n"
                       (cadr row) (caddr row) (cadddr row) (car row)))))
    (dolist (row rows)
      (cl-incf total (cadddr row))
      (cl-incf covered (caddr row)))
    (princ (format "\nTotal: %d/%d points (%.1f%%), %d definitions\n"
                   covered total
                   (if (zerop total) 0.0
                     (* 100.0 (/ (float covered) total)))
                   (length rows)))
    (unless all
      (let ((low (seq-filter (lambda (row) (< (cadr row) threshold)) rows)))
        (princ (format "\nDefinitions below %.0f%%: %d\n" threshold (length low)))
        (dolist (row low)
          (princ (format "  %5.1f%%  %3d/%-3d  %s\n"
                         (cadr row) (caddr row) (cadddr row) (car row))))))))

(defun vox-cov--options ()
  "Return (THRESHOLD . ALL-P) from the remaining command-line arguments.
The `--' separator is ignored; unknown arguments are an error."
  (let ((threshold 80) (all nil))
    (dolist (argument command-line-args-left)
      (cond ((equal argument "--"))
            ((string-match-p "\\`[0-9]+\\'" argument)
             (setq threshold (string-to-number argument)))
            ((equal argument "--all")
             (setq all t))
            (t (error "Unknown coverage argument: %s" argument))))
    (setq command-line-args-left nil)
    (cons threshold all)))

(defun vox-cov--main ()
  "Run the suite under testcover, print the report, and return an exit status."
  (vox-cov--prepare-load-path)
  (let ((options (condition-case error
                     (vox-cov--options)
                   (error
                    (princ (format "check-coverage: %s\n"
                                   (error-message-string error)))
                    (kill-emacs 2)))))
    (let* ((threshold (car options))
           (all (cdr options))
           (symbols (vox-cov--instrument))
           (vox-test-no-run t))
      (require 'vox-test)
      (let ((stats (vox-test-run)))
        (vox-cov--report (vox-cov--rows symbols) threshold all)
        (if (zerop (ert-stats-completed-unexpected stats)) 0 1)))))

(unless vox-cov-no-run
  (kill-emacs (vox-cov--main)))

;;; check-coverage.el ends here
