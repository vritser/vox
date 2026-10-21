;;; vox-test-reload.el --- Source reload regressions -*- lexical-binding: t; no-byte-compile: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Synthetic sources and provider callbacks only; no microphone or network.
;;; Code:
(require 'vox-test-support)
(require 'vox)

(defmacro vox-reload-test--directory (&rest body)
  "Run BODY with a private temporary source `directory'."
  (declare (indent 0) (debug t))
  `(let* ((parent (file-name-as-directory (file-truename temporary-file-directory)))
          (directory (make-temp-file (expand-file-name "vox-reload-test-" parent) t))
          (created directory))
     (unwind-protect
         (progn ,@body)
       (unless (and (equal directory created)
                    (not (file-symlink-p directory))
                    (equal (file-truename directory) created)
                    (equal (file-name-directory directory) parent)
                    (string-prefix-p "vox-reload-test-" (file-name-nondirectory directory)))
         (error "Refusing unexpected reload fixture cleanup"))
       (delete-directory directory t))))

(defun vox-reload-test--write (directory name content)
  "Write synthetic source CONTENT to NAME in DIRECTORY."
  (with-temp-file (expand-file-name name directory) (insert content)))

(ert-deftest vox-reload-refuses-owned-sessions-without-touching-them ()
  :tags '(vox-unit)
  (dolist (state '(connecting recording draining finalizing completed cancelled error))
    (let* ((session (vox--make-session :state state :preview-text "keep"))
           (vox--active-session session))
      (cl-letf (((symbol-function 'vox-reload--sources)
                 (lambda (_) (ert-fail "Read source while a session owned resources")))
                ((symbol-function 'vox-core-cancel)
                 (lambda (&rest _) (ert-fail "Reload cancelled a session"))))
        (should-error (vox-reload) :type 'user-error))
      (should (eq vox--active-session session))
      (should (eq (vox-session-state session) state))
      (should (equal (vox-session-preview-text session) "keep")))))

(ert-deftest vox-reload-refuses-nested-startup-device-and-minibuffer-work ()
  :tags '(vox-unit)
  (let ((vox--active-session nil))
    (dolist (flag '(vox--reloading vox--starting vox-device--busy vox-device--selecting))
      (cl-progv (list flag) '(t)
        (should-error (vox-reload) :type 'user-error)))
    (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () t)))
      (should-error (vox-reload) :type 'user-error))
    (should-error (vox-reload "/ssh:example.invalid:/vox/") :type 'user-error)))

(ert-deftest vox-reload-blocks-start-and-device-io-before-configuration ()
  :tags '(vox-unit)
  (let ((vox--reloading t) (vox--active-session nil) (vox--generation 17))
    (cl-letf (((symbol-function 'vox-backend-methods)
               (lambda (&rest _) (ert-fail "Resolved a backend during reload")))
              ((symbol-function 'executable-find)
               (lambda (&rest _) (ert-fail "Probed a recorder during reload"))))
      (should-error (vox-start 'qwen) :type 'user-error)
      (should-error (call-interactively #'vox-start) :type 'user-error)
      (should-error (vox-core-start 'qwen nil) :type 'user-error)
      (should-error (vox-device-list) :type 'user-error)
      (should-error (vox-select-input-device) :type 'user-error))
    (should (= vox--generation 17))
    (should-not vox--active-session)))

(ert-deftest vox-reload-refuses-reentry-from-startup-options ()
  :tags '(vox-unit)
  (vox-test-session
    (vox-core-cancel)
    (let ((methods (copy-sequence (gethash 'mock vox--backends))) rejected)
      (setq methods
            (plist-put methods :chunk-ms
                       (lambda ()
                         (should-error (vox-reload) :type 'user-error)
                         (setq rejected t)
                         100)))
      (puthash 'mock methods vox--backends)
      (setq session (vox-core-start 'mock nil))
      (should rejected)
      (should (eq (vox-session-state session) 'connecting))
      (should-not vox--starting)
      (should-not vox--reloading))))

(ert-deftest vox-reload-preflights-dependencies-and-excludes-descriptor ()
  :tags '(vox-unit)
  (vox-reload-test--directory
    (vox-reload-test--write directory "vox.el" "(require 'vox-z)\n(provide 'vox)\n")
    (vox-reload-test--write directory "vox-z.el" "(require 'vox-a)\n(provide 'vox-z)\n")
    (vox-reload-test--write directory "vox-a.el" "(require 'cl-lib)\n(provide 'vox-a)\n")
    (vox-reload-test--write directory "vox-pkg.el" "(deliberately invalid")
    (vox-reload-test--write directory "unrelated.el" "(deliberately invalid")
    (should (equal (mapcar #'file-name-nondirectory (vox-reload--sources directory))
                   '("vox-a.el" "vox-z.el" "vox.el")))
    (vox-reload-test--write directory "vox-a.el" "(require 'vox-missing)\n")
    (should (string-match-p "Missing Vox source: vox-missing.el"
                            (error-message-string
                             (should-error (vox-reload--sources directory)))))
    (vox-reload-test--write directory "vox-a.el" "(require 'vox)\n")
    (should (string-match-p "Circular Vox require"
                            (error-message-string
                             (should-error (vox-reload--sources directory)))))
    (vox-reload-test--write directory "vox-a.el" "(defun truncated (")
    (should (string-match-p "Cannot read"
                            (error-message-string
                             (should-error (vox-reload--sources directory)))))))

(ert-deftest vox-reload-preflight-failure-never-loads-or-leaves-guard ()
  :tags '(vox-unit)
  (vox-reload-test--directory
    (let ((vox--active-session nil) (vox--reloading nil) loaded)
      (should-error (vox-reload directory) :type 'user-error)
      (vox-reload-test--write directory "vox.el" "(provide 'vox)\n")
      (vox-reload-test--write directory "vox-zzz.el" "(defun truncated (")
      (cl-letf (((symbol-function 'load)
                 (lambda (&rest _) (setq loaded t))))
        (should (string-match-p "Cannot read"
                                (error-message-string
                                 (should-error (vox-reload directory))))))
      (should-not loaded)
      (should-not vox--reloading))))

(ert-deftest vox-reload-keeps-guard-through-source-loading ()
  :tags '(vox-unit)
  (let ((vox--active-session nil) (vox--reloading nil) loaded)
    (cl-letf (((symbol-function 'vox-reload--sources)
               (lambda (_)
                 (should vox--reloading)
                 '("/synthetic/vox.el")))
              ((symbol-function 'load)
               (lambda (file &rest _)
                 (push file loaded)
                 (should vox--reloading)
                 (should-error (vox-reload) :type 'user-error)
                 (should-error (vox-start 'qwen) :type 'user-error)
                 (should-error (vox-device-list) :type 'user-error)
                 (error "Synthetic evaluation failure"))))
      (should (equal (error-message-string (should-error (vox-reload)))
                     "Synthetic evaluation failure")))
    (should (equal loaded '("/synthetic/vox.el")))
    (should-not vox--reloading)))

(ert-deftest vox-reload-removes-bootstrap-guards-after-error-and-quit ()
  :tags '(vox-unit)
  (dolist (condition '(error quit))
    (let ((vox--active-session nil) entered)
      (cl-letf (((symbol-function 'vox-start) (lambda (&rest _) (push 'public entered)))
                ((symbol-function 'vox-core-start) (lambda (&rest _) (push 'core entered)))
                ((symbol-function 'vox-device--check-idle) (lambda () (push 'device entered)))
                ((symbol-function 'vox-reload--sources) (lambda (_) '("/synthetic/vox.el")))
                ((symbol-function 'load)
                 (lambda (&rest _)
                   (should-error (vox-start) :type 'user-error)
                   (should-error (vox-core-start) :type 'user-error)
                   (should-error (vox-device--check-idle) :type 'user-error)
                   (signal condition '("Synthetic interruption")))))
        (should (eq (condition-case err (vox-reload)
                      (error (car err)) (quit (car err)))
                    condition))
        (should-not entered)
        (should-not vox--reloading)
        (vox-start)
        (vox-core-start)
        (vox-device--check-idle)
        (should (equal entered '(device core public)))))))

;; Reload real modules in a fresh Emacs so redefinitions cannot replace suite mocks.
(ert-deftest vox-reload-real-sources-preserve-state-and-refresh-definitions ()
  :tags '(vox-unit)
  (vox-reload-test--directory
    (dolist (file (directory-files vox-test-root-directory t "\\`vox.*\\.el\\'"))
      (copy-file file (expand-file-name (file-name-nondirectory file) directory)))
    (with-temp-buffer
      (let ((status
             (call-process
              (expand-file-name invocation-name invocation-directory) nil t nil
              "-Q" "--batch" "-L" directory
              "-L" (expand-file-name ".deps" vox-test-root-directory)
              "-l" "vox.el" "--eval"
              (prin1-to-string
               `(progn
                  (require 'ert)
                  (require 'bytecomp)
                  ;; Model an older core loaded without the UI feature.
                  (makunbound 'vox--reloading)
                  (makunbound 'vox--starting)
                  (setq features (delq 'vox-ui features))
                  (load (expand-file-name "vox-reload.el" ,directory) nil t t)
                  (should (boundp 'vox--reloading))
                  (should (featurep 'vox-ui))
                  (let* ((directory ,directory)
                         (fixture (expand-file-name "vox-reload-fixture.el" directory))
                         (vox-audio-input '("synthetic-input"))
                         (vox-selection '("Synthetic" "synthetic-model"))
                         (vox-backends (list (vox-make-qwen "Synthetic" :models '(synthetic-model))))
                         (vox-selection-history '("keep-history"))
                         (vox--selection-revision 7)
                         (vox--generation 40)
                         (vox-event-log-enabled t)
                         (vox-log--entries (make-ring 10))
                         (global-mode-string '("before" "after"))
                         (config vox-backends)
                         (registry vox--backends)
                         (log vox-log--entries)
                         ready emit)
                    (vox-register-backend
                     'synthetic
                     (list :connect (lambda (_s r e _f) (setq ready r emit e))
                           :finish #'ignore :cancel #'ignore :close #'ignore))
                    (with-temp-buffer
                      (let ((first (vox-core-start 'synthetic nil)))
                        (funcall ready)
                        (funcall emit '(:type :snapshot :text "retained transcript"))
                        (vox-core-stop)
                        (funcall emit '(:type :completed))
                        (should (eq vox--last-session first)))
                      (insert "buffer text")
                      (goto-char 5)
                      (set-mark 2)
                      (narrow-to-region 2 9)
                      (set-buffer-modified-p nil)
                      (setq-local mode-line-format '("custom" (:eval (vox-ui--mode-line-text))))
                      (setq-local vox-ui--mode-line-face-color "stale")
                      (setq vox-ui--mode-line-images 'stale
                            vox-ui--mode-line-images-color "stale"
                            vox-ui--mode-line-idle-image 'stale
                            vox-ui--mode-line-idle-color "stale")
                      (with-temp-file fixture
                        (insert ";;; -*- lexical-binding: t; -*-\n"
                                "(require 'vox)\n"
                                "(defvar vox-reload-fixture-state 1)\n"
                                "(defvar vox-reload-fixture-map (let ((map (make-sparse-keymap))) (define-key map (kbd \"a\") #'ignore) map))\n"
                                "(defconst vox-reload-fixture-constant 1)\n"
                                "(defun vox-reload-fixture-value () 1)\n"
                                "(provide 'vox-reload-fixture)\n"))
                      (load fixture nil t t)
                      (byte-compile-file fixture)
                      (set 'vox-reload-fixture-state 99)
                      (with-temp-file fixture
                        (insert ";;; -*- lexical-binding: t; -*-\n"
                                "(require 'vox)\n"
                                "(defvar vox-reload-fixture-state 2)\n"
                                "(defvar vox-reload-fixture-map (let ((map (make-sparse-keymap))) (define-key map (kbd \"b\") #'ignore) map))\n"
                                "(defconst vox-reload-fixture-constant 2)\n"
                                "(defun vox-reload-fixture-value () (let ((value 2)) (lambda () value)))\n"
                                "(provide 'vox-reload-fixture)\n"))
                      (set-file-times fixture (seconds-to-time 1))
                      ;; Bootstrap the command over a core predating its guards.
                      (makunbound 'vox--reloading)
                      (makunbound 'vox--starting)
                      (load (expand-file-name "vox-reload.el" directory) nil t t)
                      (should-not vox--reloading)
                      (should-not vox--starting)
                      (let ((last vox--last-session)
                            (old-emit emit)
                            (map (symbol-value 'vox-reload-fixture-map))
                            (ui-map vox-ui--mode-line-map)
                            (before (buffer-string))
                            (format-before mode-line-format)
                            (expected (length (vox-reload--sources directory))))
                        (define-key ui-map (kbd "x") #'ignore)
                        (let ((original (symbol-function 'vox-core-start)) attempts)
                          ;; Synthetic legacy entrypoint ignores the reload flag.
                          (fset 'vox-core-start
                                (lambda (&rest args)
                                  (let ((vox--reloading nil)) (apply original args))))
                          (let ((after-load-functions
                                 (list (lambda (file)
                                         (when (string-suffix-p "/vox-activity.el" file)
                                           (push
                                            (condition-case nil
                                                (progn (vox-core-start 'synthetic nil) 'started)
                                              (user-error 'blocked))
                                            attempts))))))
                            (dotimes (_ 2)
                              (should (= (vox-reload) expected))))
                          (should (equal attempts '(blocked blocked))))
                        (should (= (funcall (funcall 'vox-reload-fixture-value)) 2))
                        (should (= (symbol-value 'vox-reload-fixture-constant) 2))
                        (should (= (symbol-value 'vox-reload-fixture-state) 99))
                        (should (eq map (symbol-value 'vox-reload-fixture-map)))
                        (should-not (lookup-key map (kbd "a")))
                        (should (eq (lookup-key map (kbd "b")) #'ignore))
                        (should (eq ui-map vox-ui--mode-line-map))
                        (should-not (lookup-key ui-map (kbd "x")))
                        (should (eq (lookup-key ui-map [mode-line mouse-1]) 'vox-toggle))
                        (should (equal global-mode-string '("before" "after")))
                        (should (equal mode-line-format format-before))
                        (should (equal (buffer-string) before))
                        (should (= (point) 5))
                        (should (= (mark) 2))
                        (should (equal (list (point-min) (point-max)) '(2 9)))
                        (should-not (buffer-modified-p))
                        (should-not vox-ui--mode-line-images)
                        (should-not vox-ui--mode-line-images-color)
                        (should-not vox-ui--mode-line-idle-image)
                        (should-not vox-ui--mode-line-idle-color)
                        (should-not vox-ui--mode-line-face-color)
                        (should (eq vox-backends config))
                        (should (equal vox-selection '("Synthetic" "synthetic-model")))
                        (should (equal vox-audio-input '("synthetic-input")))
                        (should (equal vox-selection-history '("keep-history")))
                        (should (= vox--selection-revision 7))
                        (should (eq vox--backends registry))
                        (should (gethash 'synthetic registry))
                        (should (eq vox-log--entries log))
                        (should vox-event-log-enabled)
                        (should (eq vox--last-session last))
                        (should (equal (vox-session-final-text last) "retained transcript"))
                        (should (= vox--generation 41))
                        (should-not vox--reloading)
                        (should-not (vox-current-session))
                        (let ((second (vox-core-start 'synthetic nil)))
                          (funcall old-emit '(:type :snapshot :text "stale"))
                          (should (equal (vox-session-text second) ""))
                          (should (= (vox-session-generation second) 42))
                          (funcall ready)
                          (funcall emit '(:type :snapshot :text "new transcript"))
                          (vox-core-stop)
                          (funcall emit '(:type :completed))
                          (should (equal (vox-session-final-text second) "new transcript")))
                        (with-temp-file fixture
                          (insert "(defun vox-reload-fixture-value () 3)\n(error \"Synthetic load failure\")\n"))
                        (should-error (vox-reload))
                        (should (= (funcall 'vox-reload-fixture-value) 3))
                        (should-not vox--reloading)
                        (with-temp-file fixture (insert "(signal 'quit nil)\n"))
                        (should (eq (condition-case nil (vox-reload) (quit 'quit)) 'quit))
                        (should-not vox--reloading)
                        (with-temp-file fixture
                          (insert "(defun vox-reload-fixture-value () 4)\n(provide 'vox-reload-fixture)\n"))
                        (should (= (vox-reload) expected))
                        (should (= (funcall 'vox-reload-fixture-value) 4))))))))))
        (ert-info ((buffer-string))
          (should (equal status 0)))))))

(provide 'vox-test-reload)
;;; vox-test-reload.el ends here
