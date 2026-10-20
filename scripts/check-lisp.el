;;; check-lisp.el --- Read-only Lisp syntax checks -*- lexical-binding: t; no-byte-compile: t; -*-

;;; Commentary:
;; Run with emacs -Q --batch -l scripts/check-lisp.el [-- FILE...].
;; Set `vox-check-no-run' before loading this file as a library.

;;; Code:

(defvar vox-check-no-run nil
  "Non-nil suppresses the batch entry point when this library is loaded.")

(defconst vox-check-root
  (file-name-directory
   (directory-file-name (file-name-directory (or load-file-name buffer-file-name))))
  "Root of the source tree containing this checker.")

(define-error 'vox-check-error "Lisp syntax check failed")

(defun vox-check-default-files ()
  "Return all root vox*.el files and Lisp files in scripts and test."
  (append (directory-files vox-check-root t "\\`vox.*\\.el\\'")
          (directory-files-recursively (expand-file-name "scripts" vox-check-root)
                                       "\\.el\\'")
          (directory-files-recursively (expand-file-name "test" vox-check-root)
                                       "\\.el\\'")))

(defun vox-check-buffer ()
  "Check the current buffer without evaluating any of its Lisp forms.
First scan balanced forms, then use the Lisp reader with an EOF sentinel.
The caller must use a temporary buffer: the sentinel is appended here."
  (emacs-lisp-mode)
  (goto-char (point-min))
  (forward-comment (point-max))
  (while (not (eobp))
    (forward-sexp 1)
    (forward-comment (point-max)))
  (goto-char (point-max))
  ;; The newline prevents a valid final line comment from eating the marker.
  (insert "\n")
  (let ((sentinel-position (point))
        (sentinel '(:vox-check-end))
        seen)
    (insert "(:vox-check-end)")
    (goto-char (point-min))
    (while (not seen)
      (forward-comment (point-max))
      (let* ((start (point))
             (form (read (current-buffer))))
        ;; Matching the marker's position prevents an earlier lookalike from
        ;; hiding damage.  A reader prefix must not consume the real marker.
        (setq seen (and (= start sentinel-position)
                        (= (point) (point-max))
                        (equal form sentinel))))))
  t)

(defun vox-check-file (file)
  "Return t if FILE has valid syntax; otherwise signal `vox-check-error'.
Error data is (FILE LINE COLUMN MESSAGE), with one-based coordinates."
  (with-temp-buffer
    (condition-case err
        (progn (insert-file-contents file) (vox-check-buffer))
      (error
       (let ((position (if (and (eq (car err) 'scan-error)
                                (integerp (nth 2 err)))
                           (nth 2 err)
                         (point))))
         (goto-char (max (point-min) (min position (point-max))))
         (signal 'vox-check-error
                 (list file (line-number-at-pos) (1+ (current-column))
                       (error-message-string err))))))))

(defun vox-check-files (files)
  "Check FILES, print diagnostics, and return a process exit status.
An empty file list is a usage error, never a successful check."
  (if (null files)
      (progn (princ "check-lisp: no files to check\n") 2)
    (let ((failed 0))
      (dolist (file files)
        (condition-case err
            (progn (vox-check-file file) (princ (format "OK %s\n" file)))
          (vox-check-error
           (setq failed (1+ failed))
           (princ (apply #'format "%s:%d:%d: %s\n" (cdr err))))))
      (princ (format "check-lisp: %d files, %d failed\n" (length files) failed))
      (if (zerop failed) 0 1))))

(defun vox-check-main ()
  "Run the batch checker, accepting positional files only after --."
  (let ((args command-line-args-left))
    (setq command-line-args-left nil)
    (kill-emacs
     (cond
      ((null args) (vox-check-files (vox-check-default-files)))
      ((and (equal (car args) "--")
            (not (member "--fix" (cdr args))))
       (vox-check-files (cdr args)))
      (t (princ "Usage: emacs -Q --batch -l scripts/check-lisp.el [-- FILE...]\n")
         2)))))

(unless vox-check-no-run
  (vox-check-main))

(provide 'vox-check-lisp)
;;; check-lisp.el ends here
