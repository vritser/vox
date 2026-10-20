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

(ert-deftest vox-cli-reentrant-input-preserves-lines-and-fragments ()
  :tags '(vox-unit)
  ;; Synthetic NDJSON: later process input must follow this callback's suffix.
  (vox-cli-test-parser
    (setf (vox-session-backend-state session)
          (plist-put
           (vox-session-backend-state session) :on-event
           (lambda (event)
             (push (plist-get event :text) events)
             (when (equal (plist-get event :text) "first")
               (vox-cli--feed
                session
                (concat "{\"v\":1,\"type\":\"partial\",\"segment_id\":\"1\",\"text\":\"third\"}\n"
                        "{\"v\":1,\"type\":\"partial\","))))))
    (vox-cli--feed
     session
     (concat "{\"v\":1,\"type\":\"started\"}\n"
             "{\"v\":1,\"type\":\"partial\",\"segment_id\":\"1\",\"text\":\"first\"}\n"
             "{\"v\":1,\"type\":\"partial\",\"segment_id\":\"1\",\"text\":\"second\"}\n"))
    (should (equal (reverse events) '("first" "second" "third")))
    (should (equal (plist-get (vox-session-backend-state session) :pending)
                   "{\"v\":1,\"type\":\"partial\","))
    (vox-cli--feed session "\"segment_id\":\"1\",\"text\":\"fourth\"}\n")
    (should (equal (reverse events) '("first" "second" "third" "fourth")))))

(ert-deftest vox-cli-reentrant-exit-follows-received-completion ()
  :tags '(vox-unit)
  (let* ((session (vox--make-session :generation 1 :state 'finalizing))
         (vox--active-session session)
         (vox-cli-command '("synthetic-cli"))
         filter sentinel events errors)
    (cl-letf (((symbol-function 'executable-find) (lambda (_) t))
              ((symbol-function 'make-pipe-process) (lambda (&rest _) 'stderr))
              ((symbol-function 'make-process)
               (lambda (&rest args)
                 (setq filter (plist-get args :filter)
                       sentinel (plist-get args :sentinel))
                 'cli))
              ((symbol-function 'process-status) (lambda (_) 'exit))
              ((symbol-function 'process-exit-status) (lambda (_) 0)))
      (vox-cli--connect
       session #'ignore
       (lambda (event)
         (push (plist-get event :type) events)
         (when (eq (plist-get event :type) :segment-final)
           (funcall sentinel 'cli "finished\n")))
       (lambda (message) (push message errors)))
      (setf (vox-session-backend-state session)
            (plist-put (vox-session-backend-state session) :stopping t))
      (funcall
       filter 'cli
       (concat "{\"v\":1,\"type\":\"started\"}\n"
               "{\"v\":1,\"type\":\"final\",\"segment_id\":\"1\",\"text\":\"synthetic\"}\n"
               "{\"v\":1,\"type\":\"completed\"}\n"))
      (should-not errors)
      (should (equal (reverse events) '(:segment-final :completed))))))

(ert-deftest vox-cli-reentrant-input-byte-budget-and-cleanup ()
  :tags '(vox-unit)
  (vox-cli-test-parser
    (let ((vox-cli-max-retained-input-bytes 200) queue)
      (setf (vox-session-backend-state session)
            (plist-put
             (vox-session-backend-state session) :on-ready
             (lambda ()
               (setq queue (plist-get (vox-session-backend-state session) :input))
               (vox-cli--feed session (make-string 200 ?x)))))
      ;; The active started line is still charged when nested input arrives.
      (should-error (vox-cli--feed session "{\"v\":1,\"type\":\"started\"}\n"))
      (should (vox-cli--input-p queue))
      (should-not (vox-cli--input-queue queue))
      (should-not (vox-cli--input-tail queue))
      (should-not (vox-cli--input-feeding queue))
      (should (= (vox-cli--input-bytes queue) 0))
      (should (= (vox-cli--input-count queue) 0)))))

(ert-deftest vox-cli-reentrant-input-count-budget-ignores-empty-reads ()
  :tags '(vox-unit)
  (vox-cli-test-parser
    (let ((vox-cli-max-retained-input-chunks 2) queue empty-count queued-count)
      (setf (vox-session-backend-state session)
            (plist-put
             (vox-session-backend-state session) :on-ready
             (lambda ()
               (setq queue (plist-get (vox-session-backend-state session) :input))
               (dotimes (_ 3) (vox-cli--feed session (unibyte-string)))
               (setq empty-count (vox-cli--input-count queue))
               (vox-cli--feed
                session "{\"v\":1,\"type\":\"partial\",\"segment_id\":\"1\",\"text\":\"queued\"}\n")
               (setq queued-count (vox-cli--input-count queue))
               (should-error (vox-cli--feed session "x")))))
      (vox-cli--feed session "{\"v\":1,\"type\":\"started\"}\n")
      (should (= empty-count 1))
      (should (= queued-count 2))
      (should (equal (mapcar (lambda (event) (plist-get event :text)) events)
                     '("queued")))
      (should (= (vox-cli--input-count queue) 0))
      (should (= (vox-cli--input-bytes queue) 0)))))

(ert-deftest vox-cli-reentrant-cancel-releases-queued-input ()
  :tags '(vox-unit)
  (vox-test-session
    (let (queue)
      (setf (vox-session-backend-state session)
            (list :on-ready
                  (lambda ()
                    (setq queue (plist-get (vox-session-backend-state session) :input))
                    (vox-cli--feed
                     session "{\"v\":1,\"type\":\"partial\",\"segment_id\":\"1\",\"text\":\"discarded\"}\n")
                    (vox-core-cancel session))
                  :on-event emit :on-error fail :pending (unibyte-string)))
      (vox-cli--feed session "{\"v\":1,\"type\":\"started\"}\n")
      (should (eq (vox-session-state session) 'cancelled))
      (should-not (vox-session-backend-state session))
      (should-not (vox-session-segments session))
      (should-not (vox-cli--input-queue queue))
      (should-not (vox-cli--input-feeding queue))
      (should (= (vox-cli--input-count queue) 0))
      (should (= (vox-cli--input-bytes queue) 0)))))

(ert-deftest vox-cli-startup-terminal-callback-cleans-processes ()
  :tags '(vox-unit)
  (let* ((vox--active-session nil) (vox--last-session nil)
         (vox-cli-command '("synthetic-cli"))
         (vox-event-log-enabled nil)
         (real-pipe (symbol-function 'make-pipe-process))
         (real-status (symbol-function 'process-status))
         (real-exit (symbol-function 'process-exit-status))
         session proc stderr-proc)
    (cl-letf (((symbol-function 'executable-find) (lambda (_) t))
              ((symbol-function 'make-pipe-process)
               (lambda (&rest args)
                 (setq stderr-proc (apply real-pipe args))
                 stderr-proc))
              ((symbol-function 'make-process)
               (lambda (&rest args)
                 (setq proc (funcall real-pipe :name "vox-cli-test-proc"
                                     :buffer nil :noquery t))
                 ;; Simulate a terminal callback before make-process returns.
                 (cl-letf (((symbol-function 'process-status)
                            (lambda (process)
                              (if (eq process proc) 'failed
                                (funcall real-status process))))
                           ((symbol-function 'process-exit-status)
                            (lambda (process)
                              (if (eq process proc) 1
                                (funcall real-exit process)))))
                   (funcall (plist-get args :sentinel) proc "finished\n"))
                 proc)))
      (unwind-protect
          (progn
            (setq session (vox-core-start 'cli nil))
            (should (eq (vox-session-state session) 'error))
            (should (vox-session-cleaned session))
            (should-not (vox-session-backend-state session))
            (should-not (process-live-p proc))
            (should-not (process-live-p stderr-proc)))
        (vox-core-cancel)
        (dolist (process (list proc stderr-proc))
          (when (processp process) (ignore-errors (delete-process process))))))))

(provide 'vox-test-cli)
