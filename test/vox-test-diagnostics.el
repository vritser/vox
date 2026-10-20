;;; vox-test-diagnostics.el --- Session diagnostic integration tests -*- lexical-binding: t; no-byte-compile: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Synthetic PCM and provider events only; no recorder, network or credentials.
;;; Code:
(require 'vox-test-support)
(require 'vox-backend-qwen)

(ert-deftest vox-diagnostics-rounds-have-independent-counts-and-no-content ()
  :tags '(vox-unit)
  (let ((vox-event-log-enabled t) (vox-event-log-max-entries 1000)
        (vox-log--entries nil) (vox--generation 0))
    (vox-test-session
      (setf (vox-session-methods session)
            (plist-put (vox-session-methods session) :send-pcm #'ignore))
      (funcall ready)
      (vox-core-audio session (make-string 3202 ?A))
      (funcall emit '(:type :snapshot :text "round-A" :revision 1))
      (vox-core-stop session)
      (funcall emit '(:type :completed))
      (let ((old-emit emit))
        (setq session (vox-core-start 'mock nil))
        (funcall ready)
        (vox-core-audio session (unibyte-string 1 2 3 4))
        (funcall old-emit '(:type :snapshot :text "PRIVATE_OLD_RESULT" :revision 2))
        (vox-core-cancel session))
      (let ((log (mapconcat #'identity (reverse (ring-elements vox-log--entries)) "\n")))
        (should (string-match-p "g=1 start state=connecting" log))
        (should (string-match-p "g=1 audio-receive bytes=3202 received=3202 queued=3202" log))
        (should (string-match-p "g=1 finish-dispatch queued=0 sent=3202" log))
        (should (string-match-p "g=1 complete state=completed chars=7" log))
        (should (string-match-p "g=1 cleanup state=completed queued=0 received=3202 sent=3202" log))
        (should (string-match-p "g=2 start state=connecting" log))
        (should (string-match-p "g=2 audio-receive bytes=4 received=4 queued=4" log))
        (should (string-match-p "g=1 stale-callback state=completed" log))
        (should (string-match-p "g=2 cancel state=cancelled queued=4" log))
        (should (string-match-p "g=2 cleanup state=cancelled queued=0 received=4 sent=0" log))
        (should-not (string-match-p "round-A\\|PRIVATE_OLD_RESULT\\|AAAA" log))))))

(ert-deftest vox-diagnostics-qwen-vad-uses-fixed-metadata-only ()
  :tags '(vox-unit)
  (let* ((vox-event-log-enabled t) (vox-event-log-max-entries 1000)
         (vox-log--entries nil) (readies 0)
         (session (vox--make-session
                   :generation 9 :state 'connecting
                   :backend-state (list :on-ready (lambda () (cl-incf readies))))))
    (cl-letf (((symbol-function 'format-time-string) (lambda (&rest _) "TIME")))
      (dolist (type '("session.created" "session.updated"
                      "input_audio_buffer.speech_started"
                      "input_audio_buffer.speech_stopped"
                      "input_audio_buffer.committed" "PRIVATE_UNKNOWN_EVENT"))
        (vox-qwen--message
         session (vox-json-encode (list :type type :item_id "PRIVATE_ITEM"
                                        :session '(:id "PRIVATE_ID" :model "PRIVATE_MODEL")
                                        :text "PRIVATE_TRANSCRIPT" :audio "PRIVATE_PCM"))
         'text))
      (should (= readies 1))
      (should
       (equal (reverse (ring-elements vox-log--entries))
              '("TIME g=9 provider-event kind=session-created"
                "TIME g=9 provider-event kind=ready"
                "TIME g=9 provider-event kind=speech-start"
                "TIME g=9 provider-event kind=speech-stop"
                "TIME g=9 provider-event kind=buffer-committed"))))))

(ert-deftest vox-diagnostics-send-return-after-cancel-is-labelled ()
  :tags '(vox-unit)
  (let ((vox-event-log-enabled t) (vox-event-log-max-entries 1000)
        (vox-log--entries nil) (vox--generation 0))
    (vox-test-session
      (setf (vox-session-methods session)
            (plist-put (vox-session-methods session) :send-pcm
                       (lambda (current _bytes) (vox-core-cancel current))))
      (funcall ready)
      (vox-core-audio session (make-string 3200 ?A))
      (let* ((lines (reverse (ring-elements vox-log--entries)))
             (cleanup (cl-position-if
                       (lambda (line) (string-match-p "cleanup.*sent=0" line)) lines))
             (returned (cl-position-if
                        (lambda (line)
                          (string-match-p "audio-send bytes=3200 sent=3200 queued=0 state=cancelled"
                                          line))
                        lines)))
        (should (integerp cleanup))
        (should (integerp returned))
        (should (< cleanup returned))
        (should-not (vox-current-session))
        (should (= (plist-get (vox-session-statistics session) :sent-bytes) 3200))))))

(ert-deftest vox-diagnostics-error-keeps-raw-message-out-of-log ()
  :tags '(vox-unit)
  (let ((vox-event-log-enabled t) (vox-event-log-max-entries 1000)
        (vox-log--entries nil) (vox--generation 0))
    (vox-test-session
      (vox-core-fail session "PRIVATE_ERROR_DETAIL" 'timeout)
      (let ((log (mapconcat #'identity (ring-elements vox-log--entries) "\n")))
        (should (string-match-p "g=1 error state=error reason=timeout" log))
        (should (string-match-p "g=1 cleanup state=error queued=0 received=0 sent=0" log))
        (should-not (string-match-p "PRIVATE_ERROR_DETAIL" log))))))

(provide 'vox-test-diagnostics)
;;; vox-test-diagnostics.el ends here
