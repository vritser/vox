;;; vox-test-log.el --- Safe event logging tests -*- lexical-binding: t; no-byte-compile: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; All payloads and event sequences below are synthetic.  No microphone,
;; credentials, provider, or log file is used.

;;; Code:

(require 'vox-test-support)
(require 'vox-log)

(ert-deftest vox-test-log-disabled-has-no-side-effects ()
  :tags '(vox-unit)
  (let ((vox-event-log-enabled nil)
        (vox-log--entries nil)
        calls)
    (cl-letf (((symbol-function 'make-ring)
               (lambda (&rest _) (push 'make-ring calls) nil))
              ((symbol-function 'format-time-string)
               (lambda (&rest _) (push 'format-time-string calls) "TIME"))
              ((symbol-function 'get-buffer-create)
               (lambda (&rest _) (push 'get-buffer-create calls) nil)))
      (should-not (vox-log-event 1 'start :backend 'qwen))
      (should-not calls)
      (should-not vox-log--entries))))

(ert-deftest vox-test-log-distinguishes-rounds-and-metadata ()
  :tags '(vox-unit)
  (let ((vox-event-log-enabled t)
        (vox-event-log-max-entries 1000)
        (vox-log--entries nil))
    (cl-letf (((symbol-function 'format-time-string)
               (lambda (&rest _) "2026-10-20T09:08:07.006+0800")))
      (vox-log-event 41 'audio-send :bytes 3200 :sent 6400 :queued 0
                     :state 'recording :tail-risk nil)
      (vox-log-event 42 'start :backend 'doubao :stop-mode 'silence)
      (should
       (equal (reverse (ring-elements vox-log--entries))
              '("2026-10-20T09:08:07.006+0800 g=41 audio-send bytes=3200 sent=6400 queued=0 state=recording tail-risk=nil"
                "2026-10-20T09:08:07.006+0800 g=42 start backend=doubao stop-mode=silence"))))))

(ert-deftest vox-test-log-identifies-qwen-audio-without-task-data ()
  :tags '(vox-unit)
  (let ((vox-event-log-enabled t) (vox-event-log-max-entries 10)
        (vox-log--entries nil))
    (cl-letf (((symbol-function 'format-time-string) (lambda (&rest _) "TIME")))
      (vox-log-event 1 'start :backend 'qwen-audio :task-id "synthetic-private-id")
      (should (equal (ring-elements vox-log--entries)
                     '("TIME g=1 start backend=qwen-audio"))))))

(ert-deftest vox-test-log-never-formats-private-or-unknown-values ()
  :tags '(vox-unit)
  (let ((vox-event-log-enabled t)
        (vox-event-log-max-entries 1000)
        (vox-log--entries nil)
        (secret "synthetic-private-text-and-token")
        (unknown (make-symbol "synthetic-private-symbol"))
        (cycle (list "synthetic-private-object")))
    (setcdr cycle cycle)
    (cl-letf (((symbol-function 'format-time-string) (lambda (&rest _) "TIME")))
      (vox-log-event 1 'error :reason secret :state unknown :bytes secret
                     :backend (vector secret) :url secret :key secret
                     :diagnostic cycle :tail-risk secret :sent 3200)
      (vox-log-event 2 'state :state 'recording :state secret
                     unknown secret secret secret cycle secret)
      (should
       (equal (reverse (ring-elements vox-log--entries))
              '("TIME g=1 error sent=3200" "TIME g=2 state state=recording"))))))

(ert-deftest vox-test-log-rejects-invalid-event-identity-and-numbers ()
  :tags '(vox-unit)
  (let ((vox-event-log-enabled t)
        (vox-event-log-max-entries 1000)
        (vox-log--entries nil))
    (dolist (generation '(nil 0 -1 1.5 1000000000001 "private-generation"))
      (vox-log-event generation 'start))
    (dolist (event '(nil private-event "private-event" (:private "value")))
      (vox-log-event 1 event))
    (should-not vox-log--entries)
    (cl-letf (((symbol-function 'format-time-string) (lambda (&rest _) "TIME")))
      (vox-log-event 3 'audio-exit :bytes -1 :sent 1000000000001
                     :received 1.5 :queue-peak 1.0e+INF :queued 0.0e+NaN
                     :exit-code 256 :tail-risk 'unknown)
      (vox-log-event 4 'audio-exit :exit-code 17 :received 123 :tail-risk t)
      (should
       (equal (reverse (ring-elements vox-log--entries))
              '("TIME g=3 audio-exit"
                "TIME g=4 audio-exit exit-code=17 received=123 tail-risk=t"))))))

(ert-deftest vox-test-log-bounds-capacity-and-keeps-newest-events ()
  :tags '(vox-unit)
  (let ((vox-event-log-enabled t)
        (vox-event-log-max-entries 3)
        (vox-log--entries nil))
    (cl-letf (((symbol-function 'format-time-string) (lambda (&rest _) "TIME")))
      (dotimes (index 5) (vox-log-event (1+ index) 'start))
      (should (= (ring-size vox-log--entries) 3))
      (should (equal (ring-elements vox-log--entries)
                     '("TIME g=5 start" "TIME g=4 start" "TIME g=3 start")))
      (setq vox-event-log-max-entries 2)
      (vox-log-event 6 'start)
      (should (= (ring-size vox-log--entries) 2))
      (should (equal (ring-elements vox-log--entries)
                     '("TIME g=6 start" "TIME g=5 start")))
      (setq vox-event-log-max-entries 999999999999999999999)
      (vox-log-event 7 'start)
      (should (= (ring-size vox-log--entries) 10000))
      (dolist (invalid '(nil 0 -1 2.5 "private-setting"))
        (setq vox-event-log-max-entries invalid)
        (vox-log-event 8 'start)
        (should (= (ring-size vox-log--entries) 1000))))))

(ert-deftest vox-test-log-bounds-and-deduplicates-fields ()
  :tags '(vox-unit)
  (let ((vox-event-log-enabled t)
        (vox-event-log-max-entries 1000)
        (vox-log--entries nil))
    (cl-letf (((symbol-function 'format-time-string) (lambda (&rest _) "TIME")))
      (apply #'vox-log-event 1 'audio-send
             (append '(:sent 3200) (apply #'append (make-list 100 '(:sent 6400)))
                     '(:bytes 1234)))
      (should (equal (ring-elements vox-log--entries)
                     '("TIME g=1 audio-send sent=3200"))))))

(ert-deftest vox-test-log-contains-diagnostic-failures ()
  :tags '(vox-unit)
  (let ((vox-event-log-enabled t)
        (vox-event-log-max-entries 1000)
        (vox-log--entries nil))
    (cl-letf (((symbol-function 'format-time-string)
               (lambda (&rest _) (error "Synthetic diagnostic failure"))))
      (should-not (vox-log-event 1 'start)))
    (cl-letf (((symbol-function 'format-time-string)
               (lambda (&rest _) (signal 'quit nil))))
      (should-not (vox-log-event 2 'start)))
    (should-not vox-log--entries)))

(ert-deftest vox-test-log-toggle-retains-events-while-disabled ()
  :tags '(vox-unit)
  (let ((vox-event-log-enabled nil)
        (vox-event-log-max-entries 1000)
        (vox-log--entries nil))
    (cl-letf (((symbol-function 'message) #'ignore)
              ((symbol-function 'format-time-string) (lambda (&rest _) "TIME")))
      (should (vox-toggle-event-log))
      (should-not vox-log--entries)
      (vox-log-event 1 'start)
      (should-not (vox-toggle-event-log))
      (vox-log-event 2 'start)
      (should (equal (ring-elements vox-log--entries) '("TIME g=1 start")))
      (should (vox-toggle-event-log 1))
      (should-not (vox-toggle-event-log 0))
      (should-not (vox-toggle-event-log -1)))))

(ert-deftest vox-test-log-show-snapshot-and-clear-without-enabling ()
  :tags '(vox-unit)
  (let ((vox-event-log-enabled t)
        (vox-event-log-max-entries 1000)
        (vox-log--entries nil)
        (buffer (generate-new-buffer " *vox synthetic log*")))
    (unwind-protect
        (cl-letf (((symbol-function 'format-time-string) (lambda (&rest _) "TIME"))
                  ((symbol-function 'get-buffer-create)
                   (lambda (name)
                     (should (equal name "*Vox events*"))
                     buffer))
                  ((symbol-function 'display-buffer)
                   (lambda (shown &rest _)
                     (should (eq shown buffer)))))
          (vox-log-event 1 'start)
          (vox-log-event 1 'complete :chars 12)
          (setq vox-event-log-enabled nil)
          (should (eq (vox-show-event-log) buffer))
          (with-current-buffer buffer
            (should (eq major-mode 'special-mode))
            (should buffer-read-only)
            (should-not (buffer-modified-p))
            (should-not buffer-file-name)
            (should
             (equal (buffer-string)
                    (concat "Vox event log: disabled; 2 events (metadata only)\n\n"
                            "TIME g=1 start\nTIME g=1 complete chars=12\n"))))
          (setq vox-event-log-enabled t)
          (vox-log-event 2 'start)
          (with-current-buffer buffer
            (should-not (string-match-p "g=2" (buffer-string))))
          (setq vox-event-log-enabled nil)
          (let ((real-get-buffer (symbol-function 'get-buffer)))
            (cl-letf (((symbol-function 'get-buffer)
                       (lambda (name)
                         (if (equal name "*Vox events*") buffer
                           (funcall real-get-buffer name)))))
              (vox-clear-event-log)))
          (should-not vox-log--entries)
          (should-not vox-event-log-enabled)
          (with-current-buffer buffer
            (should (equal (buffer-string) "No retained events.\n"))))
      (kill-buffer buffer))))

(ert-deftest vox-test-log-clear-does-not-create-resources ()
  :tags '(vox-unit)
  (let ((vox-event-log-enabled nil)
        (vox-log--entries nil))
    ;; Do not stub `get-buffer': under native-comp its subr trampoline calls
    ;; `get-buffer-create', which this test intentionally makes fatal.
    (when-let* ((buffer (get-buffer "*Vox events*")))
      (kill-buffer buffer))
    (cl-letf (((symbol-function 'get-buffer-create)
               (lambda (&rest _) (ert-fail "Clearing created a buffer"))))
      (vox-clear-event-log)
      (should-not vox-log--entries)
      (should-not vox-event-log-enabled))))

(ert-deftest vox-test-log-rejects-file-buffer-without-changing-data ()
  :tags '(vox-unit)
  (let* ((vox-event-log-enabled nil)
         (entries (make-ring 2))
         (vox-log--entries entries)
         (buffer (generate-new-buffer " *vox synthetic file log*"))
         (real-get-buffer (symbol-function 'get-buffer))
         displayed)
    (ring-insert entries "TIME g=7 start")
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (insert "synthetic original")
            (setq buffer-file-name "/synthetic/user-file"))
          (cl-letf (((symbol-function 'get-buffer-create)
                     (lambda (name)
                       (should (equal name "*Vox events*"))
                       buffer))
                    ((symbol-function 'get-buffer)
                     (lambda (name)
                       (if (equal name "*Vox events*") buffer
                         (funcall real-get-buffer name))))
                    ((symbol-function 'display-buffer)
                     (lambda (&rest _) (setq displayed t))))
            (dolist (command '(vox-show-event-log vox-clear-event-log))
              (should-error (funcall command) :type 'user-error)
              (should (eq vox-log--entries entries))
              (should (equal (ring-elements entries) '("TIME g=7 start")))
              (should-not displayed)
              (with-current-buffer buffer
                (should (equal buffer-file-name "/synthetic/user-file"))
                (should (equal (buffer-string) "synthetic original"))))))
      (with-current-buffer buffer
        (setq buffer-file-name nil)
        (set-buffer-modified-p nil))
      (kill-buffer buffer))))

(ert-deftest vox-test-log-rejects-indirect-file-buffer ()
  :tags '(vox-unit)
  (let* ((vox-event-log-enabled nil)
         (base (generate-new-buffer " *vox base*"))
         (indirect (make-indirect-buffer base "*Vox events*" t))
         (vox-log--entries (make-ring 2)))
    (unwind-protect
        (progn
          (with-current-buffer base
            (insert "base text")
            (setq buffer-file-name "/synthetic/base"))
          (dolist (command '(vox-show-event-log vox-clear-event-log))
            (should-error (funcall command) :type 'user-error)
            (with-current-buffer base
              (should (equal (buffer-string) "base text")))))
      (with-current-buffer base
        (setq buffer-file-name nil)
        (set-buffer-modified-p nil))
      (kill-buffer indirect)
      (kill-buffer base))))

(ert-deftest vox-test-log-clear-keeps-enabled-and-refresh ()
  :tags '(vox-unit)
  (let ((vox-event-log-enabled t)
        (vox-log--entries nil)
        buffer)
    (when-let* ((existing (get-buffer "*Vox events*")))
      (kill-buffer existing))
    (unwind-protect
        (cl-letf (((symbol-function 'format-time-string)
                   (lambda (&rest _) "TIME")))
          (vox-log-event 1 'start)
          (vox-clear-event-log)
          (should vox-event-log-enabled)
          (should-not vox-log--entries)
          (vox-log-event 2 'start)
          (setq buffer (vox-show-event-log))
          (with-current-buffer buffer
            (should (string-match-p "Vox event log: enabled" (buffer-string)))
            (should (string-match-p "g=2 start" (buffer-string)))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest vox-test-log-field-cap-boundary ()
  :tags '(vox-unit)
  (let ((vox-event-log-enabled t)
        (vox-event-log-max-entries 1000)
        (vox-log--entries nil))
    (cl-letf (((symbol-function 'format-time-string)
               (lambda (&rest _) "TIME")))
      ;; The 32nd pair is inspected; the 33rd is not.
      (apply #'vox-log-event 1 'audio-send
             (append (apply #'append (make-list 31 '(:unknown 1)))
                     '(:bytes 1234)))
      (apply #'vox-log-event 2 'audio-send
             (append (apply #'append (make-list 32 '(:unknown 1)))
                     '(:bytes 1234)))
      (should
       (equal (reverse (ring-elements vox-log--entries))
              '("TIME g=1 audio-send bytes=1234"
                "TIME g=2 audio-send"))))))

(provide 'vox-test-log)
;;; vox-test-log.el ends here
