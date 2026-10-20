;;; vox-test-limits.el --- Transcript resource bounds -*- lexical-binding: t; no-byte-compile: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Synthetic offline events; transport, credentials, and audio are stubbed.
;;; Code:
(require 'vox-test-support)
(require 'vox-backend-qwen)

(defvar vox-max-segments)
(defvar vox-max-segment-id-bytes)
(defvar vox-max-segment-id-total-bytes)

(ert-deftest vox-limits-empty-segment-flood ()
  :tags '(vox-unit)
  (let ((vox-max-segments 4)
        (vox-max-segment-id-bytes 1024)
        (vox-max-segment-id-total-bytes (* 1024 1024)))
    (vox-test-session
      (funcall ready)
      (dotimes (i 1000)
        (funcall emit (list :type :segment-final
                            :id (format "%04d%s" i (make-string 1020 ?x))
                            :text "")))
      (should (eq (vox-session-state session) 'error))
      (should-not commits)
      (should (= (length (vox-session-segments session)) 4))
      (should (= (vox-session-segment-count session) 4)))))

(ert-deftest vox-limits-id-utf8-byte-boundary ()
  :tags '(vox-unit)
  (let ((vox-max-segment-id-bytes 3))
    (vox-test-session
      (funcall ready)
      (funcall emit (list :type :segment-final :id (string #x4e2d) :text "safe"))
      (should (eq (vox-session-state session) 'recording))
      (funcall emit (list :type :segment-final :id (string #x1f399) :text "rejected"))
      (should (eq (vox-session-state session) 'error))
      (should (equal (vox-session-text session) "safe"))
      (should (equal (vox-session-text session t) "safe")))))

(ert-deftest vox-limits-cumulative-id-bytes ()
  :tags '(vox-unit)
  (let ((vox-max-segments 10)
        (vox-max-segment-id-bytes 3)
        (vox-max-segment-id-total-bytes 6))
    (vox-test-session
      (funcall ready)
      (dolist (id (list (string #x4e2d) "abc"))
        (funcall emit (list :type :segment-final :id id :text "")))
      (should (eq (vox-session-state session) 'recording))
      (should (= (vox-session-segment-id-bytes session) 6))
      (funcall emit '(:type :segment-final :id "d" :text "rejected"))
      (should (eq (vox-session-state session) 'error))
      (should (equal (vox-session-text session) "")))))

(ert-deftest vox-limits-exact-boundaries-and-first-seen-order ()
  :tags '(vox-unit)
  (let ((vox-max-segments 3)
        (vox-max-segment-id-bytes 3)
        (vox-max-segment-id-total-bytes 6)
        (vox-max-transcript-chars 5))
    (vox-test-session
      (funcall ready)
      (dolist (item '(("ccc" . "AB") ("a" . "C") ("bb" . "DE")))
        (funcall emit (list :type :segment-final :id (car item) :text (cdr item))))
      (should (eq (vox-session-state session) 'recording))
      (should (= (vox-session-segment-count session) 3))
      (should (= (vox-session-segment-id-bytes session) 6))
      (should (= (vox-session-segment-text-chars session) 5))
      (should (equal (mapcar #'car (vox-session-segments session)) '("ccc" "a" "bb")))
      (vox-core-stop)
      (funcall emit '(:type :completed))
      (should (equal commits '("ABCDE"))))))

(ert-deftest vox-limits-repeat-id-updates-do-not-consume-budget ()
  :tags '(vox-unit)
  (let ((vox-max-segments 1)
        (vox-max-segment-id-bytes 3)
        (vox-max-segment-id-total-bytes 3)
        (vox-max-transcript-chars 4))
    (vox-test-session
      (funcall ready)
      (dotimes (i 20)
        (funcall emit (list :type :segment-partial :id "abc"
                            :text (if (cl-evenp i) "1234" "ok") :revision i)))
      (funcall emit '(:type :segment-final :id "abc" :text "done" :revision 20))
      (funcall emit '(:type :segment-partial :id "abc" :text "ignored oversized" :revision 21))
      (should (eq (vox-session-state session) 'recording))
      (should (= (vox-session-segment-count session) 1))
      (should (= (vox-session-segment-id-bytes session) 3))
      (should (= (vox-session-segment-text-chars session) 4))
      (should (equal (vox-session-text session) "done")))))

(ert-deftest vox-limits-snapshot-resets-segment-budgets ()
  :tags '(vox-unit)
  (let ((vox-max-segments 1)
        (vox-max-segment-id-total-bytes 1)
        (vox-max-transcript-chars 4))
    (vox-test-session
      (funcall ready)
      (funcall emit '(:type :segment-final :id "a" :text "1234"))
      (funcall emit '(:type :snapshot :text "snap" :revision 2))
      (should-not (vox-session-segments session))
      (should (= (vox-session-segment-count session) 0))
      (should (= (vox-session-segment-id-bytes session) 0))
      (should (= (vox-session-segment-text-chars session) 0))
      (funcall emit '(:type :segment-final :id "b" :text "next"))
      (funcall emit '(:type :snapshot :text "stale" :revision 1))
      (should (eq (vox-session-state session) 'recording))
      (should (= (vox-session-segment-count session) 1))
      (should (= (vox-session-segment-id-bytes session) 1))
      (should (equal (vox-session-text session) "next")))))

(ert-deftest vox-limits-reject-text-before-mutating-recovery ()
  :tags '(vox-unit)
  (dolist (event '((:type :segment-final :id "b" :text "x")
                   (:type :segment-final :id "b" :text "too long")
                   (:type :segment-final :id "a" :text "too long")
                   (:type :snapshot :text "too long" :revision 2)))
    (let ((vox-max-transcript-chars 4))
      (vox-test-session
        (funcall ready)
        (funcall emit '(:type :segment-final :id "a" :text "safe"))
        (funcall emit event)
        (should (eq (vox-session-state session) 'error))
        (should-not commits)
        (should (equal (vox-session-preview-text session) "safe"))
        (should (equal (vox-session-text session) "safe"))
        (should (equal (vox-session-text session t) "safe"))))))

(ert-deftest vox-limits-reject-snapshot-before-erasing-old-snapshot ()
  :tags '(vox-unit)
  (let ((vox-max-transcript-chars 4))
    (vox-test-session
      (funcall ready)
      (funcall emit '(:type :snapshot :text "safe" :revision 1 :final-p t))
      (funcall emit '(:type :snapshot :text "too long" :revision 2))
      (should (eq (vox-session-state session) 'error))
      (should (equal (vox-session-preview-text session) "safe"))
      (should (equal (vox-session-text session) "safe"))
      (should (equal (vox-session-text session t) "safe")))))

(ert-deftest vox-limits-cancel-clears-counters-cleanup-preserves-recovery ()
  :tags '(vox-unit)
  (dolist (terminal '(error cancelled completed))
    (vox-test-session
      (funcall ready)
      (funcall emit '(:type :segment-final :id "a" :text "final"))
      (funcall emit '(:type :segment-partial :id "b" :text "partial"))
      (pcase terminal
        ('error (funcall fail "Safe failure"))
        ('cancelled (vox-core-cancel))
        ('completed (vox-core-stop) (funcall emit '(:type :completed))))
      (should (eq (vox-session-state session) terminal))
      (should (= (vox-session-segment-count session)
                 (if (eq terminal 'cancelled) 0 2)))
      (should (= (vox-session-segment-id-bytes session)
                 (if (eq terminal 'cancelled) 0 2)))
      (should (= (vox-session-segment-text-chars session)
                 (if (eq terminal 'cancelled) 0 12)))
      (should (equal (vox-session-text session)
                     (if (eq terminal 'cancelled) "" "finalpartial")))
      (should (equal (vox-session-text session t)
                     (if (eq terminal 'cancelled) "" "final")))
      (vox--cleanup session)
      (should (= closes 1)))))

(ert-deftest vox-limits-invalid-config-rejected-before-connect ()
  :tags '(vox-unit)
  (dolist (variable '(vox-max-segments vox-max-segment-id-bytes
                     vox-max-segment-id-total-bytes vox-max-transcript-chars))
    (dolist (value '(0 -1 1.5 nil "10"))
      (vox-test-session
        (vox-core-cancel)
        (setq ready nil)
        (cl-progv (list variable) (list value)
          (should-error (vox-core-start 'mock nil) :type 'user-error))
        (should-not ready)
        (should-not vox--active-session)))))

(ert-deftest vox-limits-qwen-final-items-released-on-overflow ()
  :tags '(vox-unit)
  (let ((vox--active-session nil) (vox--last-session nil)
        (vox-max-segments 3) (vox-qwen-endpoint nil)
        message session (closed 0) (audio-started 0))
    (cl-letf (((symbol-function 'vox-secret) (lambda (&rest _) "synthetic-secret"))
              ((symbol-function 'vox-transport-open)
               (lambda (_s _url _headers _open on-message _error _close)
                 (setq message on-message)))
              ((symbol-function 'vox-transport-close) (lambda (_) (cl-incf closed)))
              ((symbol-function 'vox-audio-start)
               (lambda (&rest _) (cl-incf audio-started) nil))
              ((symbol-function 'vox-audio-cancel) #'ignore))
      (with-temp-buffer
        (unwind-protect
            (progn
              (setq session (vox-core-start 'qwen nil))
              (funcall message "{\"type\":\"session.updated\"}" 'text)
              (should (= audio-started 1))
              (dotimes (i 3)
                (funcall message
                         (vox-json-encode
                          (list :type "conversation.item.input_audio_transcription.completed"
                                :item_id (number-to-string i) :transcript "")) 'text))
              (should (= (hash-table-count
                          (plist-get (vox-session-backend-state session) :final-items)) 3))
              (funcall message
                       (vox-json-encode
                        '(:type "conversation.item.input_audio_transcription.completed"
                          :item_id "overflow" :transcript "rejected")) 'text)
              (should (eq (vox-session-state session) 'error))
              (should-not vox--active-session)
              (should-not (vox-session-backend-state session))
              (should (= (length (vox-session-segments session)) 3))
              (should (equal (vox-session-text session) ""))
              (should (= closed 1)))
          (vox-core-cancel))))))

(provide 'vox-test-limits)
;;; vox-test-limits.el ends here
