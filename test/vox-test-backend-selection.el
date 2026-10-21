;;; vox-test-backend-selection.el --- Backend picker tests -*- lexical-binding: t; no-byte-compile: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Synthetic configurations, completion and providers; no microphone or cloud.
;;; Code:
(require 'vox-test-support)
(require 'vox)

(defmacro vox-backend-selection-test--with (&rest body)
  "Run BODY with isolated candidates and synthetic provider methods."
  (declare (indent 0) (debug t))
  `(let* ((first (vox-make-qwen "First" :models '(first-a first-b)))
          (second (vox-make-doubao "Second" :models '(second-a)))
          (vox-backends (list first second))
          (vox-selection (list "First" 'first-b))
          (vox--backends (copy-hash-table vox--backends))
          (vox--active-session nil) (vox--last-session nil)
          (vox--generation 0) (vox-selection-history nil)
          (vox--selection-revision 0)
          (connections 0) (cancels 0))
     (dolist (type '(qwen doubao cli))
       (vox-register-backend
        type (list :connect (lambda (_session ready &rest _)
                              (cl-incf connections) (funcall ready))
                   :finish #'ignore :close #'ignore
                   :cancel (lambda (_) (cl-incf cancels)))))
     (cl-letf (((symbol-function 'vox-backend-secret)
                (lambda (&rest _) (ert-fail "Selection read credentials")))
               ((symbol-function 'auth-source-search)
                (lambda (&rest _) (ert-fail "Selection read auth-source")))
               ((symbol-function 'vox-transport-open)
                (lambda (&rest _) (ert-fail "Selection opened transport")))
               ((symbol-function 'vox-audio-start)
                (lambda (&rest _) (ert-fail "Selection opened microphone")))
               ((symbol-function 'customize-save-variable)
                (lambda (&rest _) (ert-fail "Selection persisted settings"))))
       (with-temp-buffer
         (unwind-protect (progn ,@body)
           (when vox--active-session (vox-core-cancel)))))))

(ert-deftest vox-selection-interactive-pairs-and-no-side-effects ()
  :tags '(vox-unit)
  (vox-backend-selection-test--with
    (let (reported)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection predicate require-match &optional initial history)
                   (should (equal collection
                                  '(("\"First\" / \"first-a\"" "First" "first-a")
                                    ("\"First\" / \"first-b\"" "First" "first-b")
                                    ("\"Second\" / \"second-a\"" "Second" "second-a")
                                    ("cli (no remote model)" . cli))))
                   (should-not predicate)
                   (should require-match)
                   (should-not initial)
                   (should (eq history 'vox-selection-history))
                   "\"Second\" / \"second-a\""))
                ((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (setq reported (apply #'format format-string args)))))
        (should (equal (call-interactively #'vox-select) '("Second" "second-a"))))
      (should (string-match-p "Second.*second-a" reported)))
    (should (equal vox-selection '("Second" "second-a")))
    (should (equal vox-backends (list first second)))
    (should (= connections 0))))

(ert-deftest vox-selection-same-backend-selects-explicit-model ()
  :tags '(vox-unit)
  (vox-backend-selection-test--with
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) "\"First\" / \"first-a\"")))
      (should (equal (vox-select) '("First" "first-a"))))
    (should (equal vox-selection '("First" "first-a")))))

(ert-deftest vox-selection-quit-and-invalid-input-preserve-state ()
  :tags '(vox-unit)
  (dolist (answer '(quit "" "Missing" "\"First\" / \"missing\""))
    (vox-backend-selection-test--with
      (let ((original vox-selection))
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (&rest _) (if (eq answer 'quit) (signal 'quit nil) answer))))
          (if (eq answer 'quit)
              (should (eq (condition-case nil (progn (vox-select) nil) (quit 'quit))
                          'quit))
            (should-error (vox-select) :type 'user-error)))
        (should (eq vox-selection original)))
      (should (equal vox-selection '("First" first-b)))
      (should (= vox--selection-revision 0))
      (should (= connections 0)))))

(ert-deftest vox-selection-invalid-directory-fails-before-prompt-or-start ()
  :tags '(vox-unit)
  (dolist (kind '(empty dotted symbol invalid bad-object duplicate repeated))
    (vox-backend-selection-test--with
      (setq vox-backends
            (pcase kind
              ('empty nil) ('dotted (cons first second)) ('symbol '(qwen))
              ('invalid (list first "synthetic-secret"))
              ('bad-object
               (let ((broken (vox-make-doubao "Broken")))
                 (setf (vox-backend-models broken) nil)
                 (list first broken)))
              ('duplicate (list first (vox-make-doubao "First")))
              ('repeated (list first first))))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) (ert-fail "Invalid directory prompted"))))
        (dolist (operation '(vox-select vox-start))
          (let ((err (should-error (funcall operation) :type 'user-error)))
            (should (string-match-p
                     (pcase kind
                       ((or 'duplicate 'repeated) "Duplicate Vox backend name: First")
                       ('invalid "vox-backends entry 2 must be a backend object")
                       ('bad-object "Invalid vox-backends entry 2: Invalid Vox backend models")
                       (_ "vox-backends"))
                     (error-message-string err)))
            (should-not (string-match-p "synthetic-secret" (error-message-string err))))))
      (should (equal vox-selection '("First" first-b)))
      (should-not vox--active-session)
      (should (= connections 0)))))

(ert-deftest vox-selection-rechecks-directory-after-completion ()
  :tags '(vox-unit)
  (dolist (change '(remove replace rename duplicate invalid model host reorder))
    (vox-backend-selection-test--with
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _)
                   (pcase change
                     ('remove (setq vox-backends (list first)))
                     ('replace (setq vox-backends (list first (vox-backend-snapshot second))))
                     ('rename (aset (vox-backend-name second) 0 ?X))
                     ('duplicate (push (vox-make-qwen "Second") vox-backends))
                     ('invalid (setf (vox-backend-models second) nil))
                     ('model (aset (car (vox-backend-models second)) 0 ?X))
                     ('host (setf (vox-backend-host second) "changed.example"))
                     ('reorder (setq vox-backends (list second first))))
                   "\"Second\" / \"second-a\"")))
        (should-error (vox-select) :type 'user-error))
      (should (equal vox-selection '("First" first-b)))
      (should (= connections 0)))))

(ert-deftest vox-selection-exact-case-for-names-and-models ()
  :tags '(vox-unit)
  (vox-backend-selection-test--with
    (setf (vox-backend-name second) "first"
          (vox-backend-models first) '("Model-A" "model-a"))
    (let ((completion-ignore-case t))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _)
                   (should-not completion-ignore-case)
                   "\"first\" / \"second-a\"")))
        (should (equal (vox-select) '("first" "second-a"))))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "\"First\" / \"MODEL-A\"")))
        (should-error (vox-select) :type 'user-error))
      (should (equal vox-selection '("first" "second-a")))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "\"First\" / \"model-a\"")))
        (should (equal (vox-select) '("First" "model-a")))))))

(ert-deftest vox-selection-next-recording-keeps-active-snapshot ()
  :tags '(vox-unit)
  (vox-backend-selection-test--with
    (let* ((session (vox-start)) (methods (vox-session-methods session)))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "\"Second\" / \"second-a\"")))
        (vox-select))
      (should (eq (vox-current-session) session))
      (should (eq (vox-session-state session) 'recording))
      (should (eq (vox-session-methods session) methods))
      (should (equal (vox-backend-name (vox-session-backend session)) "First"))
      (should (equal (plist-get methods :model) "first-b"))
      (should (= connections 1))
      (should (= cancels 0))
      (vox-cancel)
      (let ((next (vox-start)))
        (should (equal (vox-backend-name (vox-session-backend next)) "Second"))
        (should (equal (plist-get (vox-session-methods next) :model) "second-a"))
        (should (= connections 2))))))

(ert-deftest vox-selection-default-named-and-symbol-or-string-model ()
  :tags '(vox-unit)
  (dolist (case '((nil "First" "first-a")
                  (("Second" nil) "Second" "second-a")
                  (("First" first-b) "First" "first-b")
                  (("First" "first-b") "First" "first-b")))
    (vox-backend-selection-test--with
      (setq vox-selection (car case))
      (let ((session (vox-start)))
        (should (equal (vox-backend-name (vox-session-backend session)) (nth 1 case)))
        (should (equal (plist-get (vox-session-methods session) :model) (nth 2 case))))
      (should (equal vox-selection (car case))))))

(ert-deftest vox-selection-no-config-default-is-qwen-directory ()
  :tags '(vox-unit)
  ;; A separate clean Emacs proves the actual defvar defaults, not a test binding.
  (with-temp-buffer
    (should (= 0 (call-process
                  (expand-file-name invocation-name invocation-directory) nil t nil
                  "-Q" "--batch" "-L" vox-test-root-directory "-l" "vox-backend"
                  "--eval"
                  "(let ((r (vox--resolve-selection))) (princ (list vox-selection (vox-backend-name (car r)) (vox-backend-type (car r)) (cdr r))))")))
    (should (equal (buffer-string) "(nil Qwen qwen qwen3-asr-flash-realtime)"))))

(ert-deftest vox-selection-invalid-values-never-fall-back ()
  :tags '(vox-unit)
  (dolist (value '("First" ("First") ("First" nil extra) (First nil)
                   ("Missing" nil) ("first" nil) ("First" unknown)
                   ("First" 3) ("First" "bad\nmodel") (cli model)
                   3 unregistered-backend))
    (vox-backend-selection-test--with
      (setq vox-selection value)
      (should-error (vox-start) :type 'user-error)
      (should-not vox--active-session)
      (should (= connections 0)))))

(ert-deftest vox-selection-removed-or-renamed-backend-errors-clearly ()
  :tags '(vox-unit)
  (dolist (change '(remove rename))
    (vox-backend-selection-test--with
      (if (eq change 'remove) (setq vox-backends (list second))
        (setf (vox-backend-name first) "Renamed"))
      (let ((err (should-error (vox-start) :type 'user-error)))
        (should (string-match-p "backend name is missing.*vox-selection" (error-message-string err))))
      (should (= connections 0)))))

(ert-deftest vox-selection-explicit-start-bypasses-selection-and-directory ()
  :tags '(vox-unit)
  (vox-backend-selection-test--with
    (setq vox-backends '(invalid) vox-selection '("Missing" invalid))
    (let ((session (vox-start first nil 'first-b)))
      (should (equal (plist-get (vox-session-methods session) :model) "first-b")))
    (vox-cancel)
    (let ((session (vox-start second)))
      (should (equal (vox-backend-name (vox-session-backend session)) "Second"))
      (should (equal (plist-get (vox-session-methods session) :model) "second-a")))
    (vox-cancel)
    (should (eq (vox-session-backend (vox-start 'cli)) 'cli))
    (vox-cancel)
    (should-error (vox-start nil nil 'first-b) :type 'user-error)
    (should (equal vox-selection '("Missing" invalid)))))

(ert-deftest vox-selection-cli-has-no-model-and-bypasses-directory ()
  :tags '(vox-unit)
  (vox-backend-selection-test--with
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) "cli (no remote model)")))
      (should (eq (vox-select) 'cli)))
    (setq vox-backends nil)
    (let ((session (vox-start)))
      (should (eq (vox-session-backend session) 'cli))
      (should-not (plist-member (vox-session-methods session) :model)))
    (should (= connections 1))))

(ert-deftest vox-selection-registered-symbols-need-no-directory ()
  :tags '(vox-unit)
  (vox-backend-selection-test--with
    (vox-register-backend
     'custom-symbol
     (list :connect (lambda (_session ready &rest _)
                      (cl-incf connections) (funcall ready))
           :finish #'ignore :close #'ignore
           :cancel (lambda (_) (cl-incf cancels))))
    ;; Extensions and the CLI bypass directory resolution entirely.
    (setq vox-backends nil vox-selection 'custom-symbol)
    (let ((session (vox-start)))
      (should (eq (vox-session-backend session) 'custom-symbol))
      (should-not (plist-member (vox-session-methods session) :model)))
    (vox-cancel)
    ;; Built-in symbols keep factory configuration and their first model.
    (setq vox-selection 'qwen)
    (let ((session (vox-start)))
      (should (eq (vox-backend-type (vox-session-backend session)) 'qwen))
      (should (equal (vox-backend-name (vox-session-backend session)) "Qwen"))
      (should (equal (plist-get (vox-session-methods session) :model)
                     "qwen3-asr-flash-realtime")))
    (vox-cancel)
    (setq vox-selection 'unregistered-backend)
    (let ((err (should-error (vox-start) :type 'user-error)))
      (should (string-match-p "Vox backend unregistered-backend is not registered"
                              (error-message-string err))))
    (should (= connections 2))))

(ert-deftest vox-selection-picker-recovers-invalid-current-selection ()
  :tags '(vox-unit)
  (dolist (invalid '(unknown ("Missing" nil) ("First" not-advertised)))
    (vox-backend-selection-test--with
      (setq vox-selection invalid)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "\"First\" / \"first-a\"")))
        (should (equal (vox-select) '("First" "first-a")))))))

(ert-deftest vox-selection-reentrant-changes-are-not-overwritten ()
  :tags '(vox-unit)
  (dolist (change '(assign mutate nested nested-cli))
    (vox-backend-selection-test--with
      (setq vox-selection (if (eq change 'nested-cli) 'cli
                            (list (copy-sequence "First") (copy-sequence "first-b"))))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _)
                   (pcase change
                     ('assign (setq vox-selection 'cli))
                     ('mutate (aset (cadr vox-selection) 0 ?X))
                     ('nested-cli
                      (cl-letf (((symbol-function 'completing-read)
                                 (lambda (&rest _) "cli (no remote model)")))
                        (vox-select)))
                     ('nested
                      (cl-letf (((symbol-function 'completing-read)
                                 (lambda (&rest _) "\"First\" / \"first-b\"")))
                        (vox-select))))
                   "\"Second\" / \"second-a\"")))
        (should-error (vox-select) :type 'user-error))
      (should (equal vox-selection
                     (pcase change ((or 'assign 'nested-cli) 'cli) ('mutate '("First" "Xirst-b"))
                            ('nested '("First" "first-b")))))
      (should (= connections 0)))))

(ert-deftest vox-selection-pair-labels-cannot-collide ()
  :tags '(vox-unit)
  (vox-backend-selection-test--with
    (setf (vox-backend-name first) "A / B" (vox-backend-models first) '("C")
          (vox-backend-name second) "A" (vox-backend-models second) '("B / C"))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt choices &rest _)
                 (should (= (length (delete-dups (mapcar #'car choices))) 3))
                 "\"A\" / \"B / C\"")))
      (should (equal (vox-select) '("A" "B / C"))))))

(ert-deftest vox-selection-stored-pair-is-detached-from-directory ()
  :tags '(vox-unit)
  (vox-backend-selection-test--with
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) "\"First\" / \"first-b\"")))
      (vox-select))
    (should-not (eq (car vox-selection) (vox-backend-name first)))
    (should-not (eq (cadr vox-selection) (cadr (vox-backend-models first))))
    (aset (car vox-selection) 0 ?X)
    (aset (cadr vox-selection) 0 ?X)
    (should (equal (vox-backend-name first) "First"))
    (should (equal (vox-backend-models first) '("first-a" "first-b")))))

(ert-deftest vox-selection-named-choice-survives-reordering ()
  :tags '(vox-unit)
  (vox-backend-selection-test--with
    (setq vox-backends (list second first))
    (let ((resolved (vox--resolve-selection)))
      (should (equal (vox-backend-name (car resolved)) "First"))
      (should (equal (cdr resolved) "first-b")))
    (setq vox-selection nil)
    (let ((resolved (vox--resolve-selection)))
      (should (equal (vox-backend-name (car resolved)) "Second"))
      (should (equal (cdr resolved) "second-a")))))

(ert-deftest vox-selection-invalid-model-errors-before-device-prompt ()
  :tags '(vox-unit)
  (vox-backend-selection-test--with
    (setq vox-selection '("First" missing))
    (cl-letf (((symbol-function 'vox-select-input-device)
               (lambda (&rest _) (ert-fail "Invalid model prompted for device"))))
      (let ((err (should-error (call-interactively #'vox-start) :type 'user-error)))
        (should (string-match-p "Vox model missing is not configured"
                                (error-message-string err)))))
    (should-not vox--active-session)
    (should (= connections 0))))

(ert-deftest vox-selection-obsolete-state-and-commands-absent ()
  :tags '(vox-unit)
  (dolist (variable '(vox-backend vox-model vox-backend-history vox-model-history))
    (should-not (boundp variable)))
  (dolist (command '(vox-select-backend vox-select-model))
    (should-not (fboundp command)))
  (should (vox-backend-p (vox-make-qwen "Struct still supported"))))

(provide 'vox-test-backend-selection)
;;; vox-test-backend-selection.el ends here
