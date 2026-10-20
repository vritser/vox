;;; compile.el --- Strict, artifact-free Vox compilation -*- lexical-binding: t; no-byte-compile: t; -*-

;;; Commentary:
;; Run with emacs -Q --batch -l scripts/compile.el from any directory.
;; Every warning is an error.  All byte code stays in a temporary directory.

;;; Code:

(require 'bytecomp)

(defconst vox-compile-root
  (file-name-directory
   (directory-file-name (file-name-directory (or load-file-name buffer-file-name))))
  "Root of the Vox source tree.")

(defun vox-compile-main ()
  "Compile all production sources strictly, without writing into the tree."
  (when (version< emacs-version "28.1")
    (error "Vox requires Emacs 28.1 or newer"))
  (let* ((files (delete (expand-file-name "vox-pkg.el" vox-compile-root)
                        (directory-files vox-compile-root t "\\`vox.*\\.el\\'")))
         (parent (file-name-as-directory (file-truename temporary-file-directory)))
         (created (make-temp-file (expand-file-name "vox-compile-" parent) t))
         (directory (file-truename created))
         (load-path (append (list vox-compile-root
                                  (expand-file-name ".deps" vox-compile-root))
                            load-path))
         ;; This also forces nested `require' calls to ignore stale .elc files.
         (load-suffixes '(".el"))
         (byte-compile-warnings t)
         (byte-compile-error-on-warn t)
         (byte-compile-dest-file-function
          (lambda (source)
            (expand-file-name (concat (file-name-nondirectory source) "c")
                              directory))))
    (unwind-protect
        (progn
          (unless files (error "No production vox*.el sources found"))
          (dolist (file files)
            (load file nil t t))
          (dolist (file files)
            (unless (and (byte-compile-file file)
                         (file-exists-p
                          (funcall byte-compile-dest-file-function file)))
              (error "Compilation failed: %s" file)))
          (princ (format "compile: %d source files passed (warnings are errors)\n"
                         (length files))))
      ;; Delete only the exact absolute directory created above, after an
      ;; independent canonical-path check; never follow a replacement symlink.
      (if (and (file-name-absolute-p directory)
               (file-directory-p directory)
               (not (file-symlink-p directory))
               (equal directory created)
               (equal (file-truename directory) created)
               (equal (file-name-directory directory) parent)
               (string-prefix-p "vox-compile-" (file-name-nondirectory directory)))
          (delete-directory directory t)
        (error "Refusing to remove unexpected temporary path: %s" directory)))))

(condition-case err
    (progn (vox-compile-main) (kill-emacs 0))
  (error
   (princ (format "compile: %s\n" (error-message-string err)))
   (kill-emacs 1)))

;;; compile.el ends here
