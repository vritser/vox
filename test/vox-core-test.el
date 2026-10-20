;;; vox-core-test.el --- Core and sink regressions -*- lexical-binding: t; -*-
(require 'ert)
(require 'vox-core)
(require 'vox-ui)

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

(ert-deftest vox-core-lifecycle-idempotent ()
  (vox-test-session
    (should (eq (vox-session-state session) 'connecting))
    (funcall ready)
    (funcall emit '(:type :segment-partial :id "a" :text "part" :revision 1))
    (funcall emit '(:type :segment-final :id "a" :text "final"))
    (should-not commits)
    (vox-core-stop) (vox-core-stop)
    (should (= finishes 1))
    (funcall emit '(:type :completed)) (funcall emit '(:type :completed))
    (should (equal commits '("final")))
    (should (= closes 1))
    (should (equal (reverse states) '(connecting recording draining finalizing completed)))
    (should-not vox--active-session)
    (should-not (marker-buffer (vox-session-target-marker session)))
    (should-not (vox-session-stop-timer session))))

(ert-deftest vox-core-segment-revisions-order-and-late-partial ()
  (vox-test-session
    (funcall ready)
    (dolist (event '((:type :segment-partial :id "b" :text "B" :revision 2)
                     (:type :segment-partial :id "a" :text "A")
                     (:type :segment-partial :id "b" :text "old" :revision 1)
                     (:type :segment-final :id "b" :text "B!")
                     (:type :segment-partial :id "b" :text "late" :revision 9)))
      (funcall emit event))
    (should (equal (vox-session-text session) "B!A"))
    (should (equal (vox-session-text session t) "B!"))))

(ert-deftest vox-core-snapshot-replaces-two-pass-and-deduplicates ()
  (vox-test-session
    (funcall ready)
    (funcall emit '(:type :snapshot :text "first" :revision 1))
    (funcall emit '(:type :snapshot :text "revised whole" :revision 2))
    (funcall emit '(:type :snapshot :text "stale" :revision 1))
    (should (equal (vox-session-text session) "revised whole"))
    (should (equal (vox-session-text session t) ""))
    (vox-core-stop) (funcall emit '(:type :completed))
    (should (equal commits '("revised whole")))))

(ert-deftest vox-core-cancel-ignores-late-events ()
  (vox-test-session
    (funcall ready) (vox-core-cancel) (vox-core-cancel)
    (funcall emit '(:type :segment-final :id "a" :text "late"))
    (funcall ready) (funcall emit '(:type :completed))
    (should (eq (vox-session-state session) 'cancelled))
    (should-not commits) (should (= closes 1))))

(ert-deftest vox-core-old-generation-cannot-touch-new-session ()
  (vox-test-session
    (let ((old-emit emit) (old-ready ready) (old-session session))
      (vox-core-cancel)
      (setq session (vox-core-start 'mock nil))
      (funcall old-ready)
      (funcall old-emit '(:type :snapshot :text "obsolete"))
      (should (eq (vox-session-state session) 'connecting))
      (should-not (vox-session-live-p session (vox-session-generation old-session)))
      (should (equal (vox-session-text session) "")))))

(ert-deftest vox-core-error-never-commits-and-cleans ()
  (vox-test-session
    (funcall ready) (funcall emit '(:type :snapshot :text "unconfirmed"))
    (funcall fail "Safe failure")
    (should (eq (vox-session-state session) 'error))
    (should-not commits) (should (= closes 1))
    (should (equal (vox-session-preview-text session) "unconfirmed"))))

(ert-deftest vox-core-premature-completion-errors ()
  (vox-test-session
    (funcall ready) (funcall emit '(:type :completed))
    (should (eq (vox-session-state session) 'error))
    (should-not commits)))

(ert-deftest vox-core-killed-target-cancels ()
  (vox-test-session
    (vox-core-cancel)
    (let ((target (generate-new-buffer "vox-test-target")))
      (setq session (vox-core-start 'mock nil target))
      (funcall ready)
      (kill-buffer target)
      (should (eq (vox-session-state session) 'cancelled))
      (funcall emit '(:type :completed)) (should-not commits))))

(ert-deftest vox-core-connect-and-stop-timeouts-clean ()
  (dolist (phase '(connecting finalizing))
    (vox-test-session
      (when (eq phase 'finalizing) (funcall ready) (vox-core-stop))
      (let ((timer (if (eq phase 'connecting) (vox-session-connect-timer session)
                     (vox-session-stop-timer session))))
        (apply (timer--function timer) (timer--args timer)))
      (should (eq (vox-session-state session) 'error))
      (should (= closes 1)) (should-not commits))))

(ert-deftest vox-core-sink-exception-is-contained ()
  (vox-test-session
    (funcall ready)
    (setf (vox-session-sink session) '(:on-finish (lambda (&rest _) (error "private text"))))
    (vox-core-stop) (funcall emit '(:type :completed))
    (should (eq (vox-session-state session) 'error))
    (should-not (string-match-p "private" (vox-session-last-error session)))
    (should (= closes 1))))

(ert-deftest vox-core-transcript-limit ()
  (vox-test-session
    (funcall ready)
    (let ((vox-max-transcript-chars 3))
      (funcall emit '(:type :snapshot :text "long")))
    (should (eq (vox-session-state session) 'error))))

(ert-deftest vox-ui-preview-never-edits-and-finish-undoes-once ()
  (vox-test-session
    (buffer-enable-undo)
    (insert "typed")
    (set-marker (vox-session-target-marker session) (point))
    (let* ((sink (vox-make-buffer-sink))
           (preview (plist-get sink :on-preview))
           (before (buffer-string)) (before-undo buffer-undo-list)
           (before-point (point)) (before-mark (mark)))
      (setf (vox-session-sink session) sink)
      (dotimes (_ 1000) (funcall preview session "preview\nsecond line" 'recording))
      (should (equal before (buffer-string)))
      (should (equal before-undo buffer-undo-list))
      (should (= before-point (point))) (should (equal before-mark (mark)))
      (funcall ready)
      (insert " keyboard")
      (funcall emit '(:type :segment-final :id "a" :text " voice"))
      (vox-core-stop) (funcall emit '(:type :completed))
      (should (equal (buffer-string) "typed keyboard voice"))
      (should-not (overlays-in (point-min) (point-max)))
      (let ((inhibit-message t)) (undo 1))
      (should (equal (buffer-string) "typed keyboard")))))

(ert-deftest vox-ui-switch-buffer-does-not-redirect-insertion ()
  (vox-test-session
    (setf (vox-session-sink session) (vox-make-buffer-sink))
    (let ((target (current-buffer)))
      (funcall ready) (funcall emit '(:type :snapshot :text "original"))
      (with-temp-buffer
        (insert "other")
        (vox-core-stop) (funcall emit '(:type :completed))
        (should (equal (buffer-string) "other")))
      (should (equal (with-current-buffer target (buffer-string)) "original")))))

(ert-deftest vox-ui-read-only-preserves-recoverable-final ()
  (vox-test-session
    (setf (vox-session-sink session) (vox-make-buffer-sink))
    (funcall ready) (funcall emit '(:type :snapshot :text "recover"))
    (setq buffer-read-only t)
    (vox-core-stop) (funcall emit '(:type :completed))
    (should (eq (vox-session-state session) 'error))
    (should (equal (buffer-string) ""))
    (should (equal (vox-session-final-text session) "recover"))))

(ert-deftest vox-security-endpoints-and-json ()
  (should-error (vox-check-endpoint "ws://example.com" '("example.com")))
  (should-error (vox-check-endpoint "wss://user:secret@example.com" '("example.com")))
  (should-error (vox-check-endpoint "wss://evil.test" '("example.com")))
  (should (equal (vox-check-endpoint "wss://example.com/path" '("example.com"))
                 "wss://example.com/path"))
  (let ((json (vox-json-read (vox-json-encode '(:nullvalue :null :falsevalue :false)))))
    (should (eq (plist-get json :nullvalue) :null))
    (should (eq (plist-get json :falsevalue) :false))))

(ert-deftest vox-security-auth-source-precedes-env ()
  (cl-letf (((symbol-function 'auth-source-search)
             (lambda (&rest _) (list (list :secret (lambda () "auth-secret")))))
            ((symbol-function 'getenv) (lambda (_) "env-secret")))
    (should (equal (vox-secret "host" "ENV") "auth-secret"))))

(ert-deftest vox-core-reentrant-finish-commits-once ()
  (vox-test-session
    (funcall ready)
    (setf (vox-session-sink session)
          (list :on-finish (lambda (_s text)
                             (push text commits)
                             (funcall emit '(:type :completed)))))
    (funcall emit '(:type :segment-final :id "a" :text "once"))
    (vox-core-stop) (funcall emit '(:type :completed))
    (should (equal commits '("once")))
    (should (= closes 1))
    (should (eq (vox-session-state session) 'completed))))

(ert-deftest vox-core-cancel-discards-transcript ()
  (vox-test-session
    (funcall ready)
    (funcall emit '(:type :snapshot :text "private hypothesis"))
    (vox-core-cancel)
    (should (equal (vox-session-text session) ""))
    (should (equal (vox-session-preview-text session) ""))))

(ert-deftest vox-core-finalizing-notification-cannot-complete-before-finish ()
  (vox-test-session
    (funcall ready)
    (funcall emit '(:type :segment-partial :id "a" :text "partial"))
    (setf (vox-session-sink session)
          (list :on-state (lambda (_s state)
                            (when (eq state 'finalizing) (funcall emit '(:type :completed))))
                :on-finish (lambda (_s text) (push text commits))))
    (vox-core-stop)
    (should-not commits)
    (should (= finishes 0))
    (should (eq (vox-session-state session) 'error))))

(ert-deftest vox-core-synchronous-backend-completion-supported ()
  (vox-test-session
    (funcall ready)
    (setf (vox-session-methods session)
          (plist-put (vox-session-methods session) :finish
                     (lambda (_s) (funcall emit '(:type :completed)))))
    (vox-core-stop)
    (should (equal commits '("")))
    (should (eq (vox-session-state session) 'completed))))

(ert-deftest vox-ui-narrow-window-cjk-preview-stays-on-one-line ()
  (vox-test-session
    (let* ((sink (vox-make-buffer-sink)) (preview (plist-get sink :on-preview))
           (text (concat (string #x4e2d #x6587 #x1f399) "\nsecond line")))
      (setf (vox-session-sink session) sink)
      (cl-letf (((symbol-function 'get-buffer-window-list) (lambda (&rest _) (list (selected-window))))
                ((symbol-function 'window-body-width) (lambda (&rest _) 6))
                ((symbol-function 'window-hscroll) (lambda (_) 0)))
        (funcall preview session text 'recording)
        (let* ((overlay (car (append (car (overlay-lists)) (cdr (overlay-lists)))))
               (display (overlay-get overlay 'after-string)))
          (should overlay)
          (should (<= (string-width display) 5))
          (should-not (string-match-p "\n" display))
          (should (equal (buffer-string) "")))))))

(provide 'vox-core-test)
