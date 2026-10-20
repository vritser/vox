;;; vox-test-cli.el --- CLI parser and subprocess integration -*- lexical-binding: t; no-byte-compile: t; -*-
(require 'vox-test-support)
(require 'vox-backend-cli)

(defconst vox-cli-test--script
  (expand-file-name "support/vox-cli.sh" (file-name-directory (or load-file-name buffer-file-name))))

(defmacro vox-cli-test-parser (&rest body)
  (declare (indent 0) (debug t))
  `(let (events (ready 0))
     (let ((session (vox--make-session
                     :backend-state (list :pending (unibyte-string)
                                          :on-ready (lambda () (cl-incf ready))
                                          :on-event (lambda (e) (push e events))
                                          :on-error #'ignore))))
       ,@body)))

(ert-deftest vox-cli-split-every-byte-including-utf8 ()
  :tags '(vox-unit)
  (vox-cli-test-parser
    (let ((bytes (encode-coding-string
                  (concat "{\"v\":1,\"type\":\"started\"}\n"
                          "{\"v\":1,\"type\":\"partial\",\"segment_id\":\"1\",\"text\":\"\u4eca\u5929\"}\n"
                          "{\"v\":1,\"type\":\"final\",\"segment_id\":\"1\",\"text\":\"\u4eca\u5929\u5929\u6c14\"}\n") 'utf-8)))
      (dotimes (i (length bytes)) (vox-cli--feed session (substring bytes i (1+ i)))))
    (should (= ready 1))
    (should (= (length events) 2))
    (should (equal (plist-get (car events) :text) "\u4eca\u5929\u5929\u6c14"))
    (should (string-empty-p (plist-get (vox-session-backend-state session) :pending)))))

(ert-deftest vox-cli-invalid-lines-and-limits ()
  :tags '(vox-unit)
  (dolist (bytes '("not json\n" "{\"v\":2,\"type\":\"started\"}\n"
                   "{\"v\":1,\"type\":\"unknown\"}\n"
                   "{\"v\":1,\"type\":\"completed\"}\n"))
    (vox-cli-test-parser (should-error (vox-cli--feed session bytes))))
  (vox-cli-test-parser
    (let ((vox-cli-max-line-bytes 8))
      (vox-cli--feed session "1234")
      (should-error (vox-cli--feed session "56789")))))

(ert-deftest vox-cli-real-process-explicit-completion-and-exit ()
  :tags '(vox-unit)
  (skip-unless (executable-find "sh"))
  (dolist (exit-code '("0" "7"))
    (let ((vox--active-session nil) (vox--last-session nil)
          (vox-cli-command (list "sh" vox-cli-test--script exit-code))
          session committed process)
      (with-temp-buffer
        (unwind-protect
            (progn
              (setq session (vox-core-start 'cli (list :on-finish (lambda (_s text) (setq committed text))))
                    process (plist-get (vox-session-backend-state session) :process))
              (let ((deadline (+ (float-time) 5)))
                (while (and (eq (vox-session-state session) 'connecting) (< (float-time) deadline))
                  (accept-process-output nil 0.02)))
              (should (eq (vox-session-state session) 'recording))
              (vox-core-stop)
              ;; A dead stdout process alone may not dispatch the final sentinel.
              ;; Service all process events, including the separate stderr pipe.
              (let ((deadline (+ (float-time) 5)))
                (while (and (vox--live-p session) (< (float-time) deadline))
                  (accept-process-output nil 0.02)))
              (should-not (process-live-p process))
              (if (equal exit-code "0")
                  (progn (should (eq (vox-session-state session) 'completed))
                         (should (equal committed "synthetic CLI")))
                (should (eq (vox-session-state session) 'error))
                (should-not committed)))
          (vox-core-cancel))))))

(ert-deftest vox-cli-exit-alone-is-not-completion ()
  :tags '(vox-unit)
  (skip-unless (executable-find "sh"))
  (let ((vox--active-session nil) (vox--last-session nil)
        (vox-cli-command '("sh" "-c" "exit 0")) session)
    (with-temp-buffer
      (unwind-protect
          (progn
            (setq session (vox-core-start 'cli nil))
            (let ((deadline (+ (float-time) 5)))
              (while (and (vox--live-p session) (< (float-time) deadline))
                (accept-process-output nil 0.02)))
            (should (eq (vox-session-state session) 'error)))
        (vox-core-cancel)))))

(ert-deftest vox-cli-reentrant-cancel-discards-trailing-bytes ()
  :tags '(vox-unit)
  (vox-test-session
    (setf (vox-session-backend-state session)
          (list :on-ready (lambda () (vox-core-cancel session))
                :on-event emit :on-error fail :pending (unibyte-string)))
    (vox-cli--feed session "{\"v\":1,\"type\":\"started\"}\nprivate trailing bytes")
    (should-not (vox-session-backend-state session))
    (should (eq (vox-session-state session) 'cancelled))))

(provide 'vox-test-cli)
