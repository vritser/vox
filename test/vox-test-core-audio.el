;;; vox-test-core-audio.el --- PCM coordination regressions -*- lexical-binding: t; no-byte-compile: t; -*-
(require 'vox-test-support)

(defmacro vox-test-audio (&rest body)
  "Run BODY with deterministic virtual recorder callbacks."
  (declare (indent 0) (debug t))
  `(vox-test-session
     (let (on-bytes on-ended on-error packets (stops 0))
       (setf (vox-session-methods session)
             (append (list :needs-external-audio t
                           :send-pcm (lambda (_s pcm) (push pcm packets))
                           :finish (lambda (_s) (push :finish packets) (cl-incf finishes)))
                     (vox-session-methods session)))
       (cl-letf (((symbol-function 'vox-audio-start)
                  (lambda (_s bytes ended error)
                    (setq on-bytes bytes on-ended ended on-error error) nil))
                 ((symbol-function 'vox-audio-stop) (lambda (_s) (cl-incf stops)))
                 ((symbol-function 'vox-audio-cancel) #'ignore))
         (funcall ready)
         ,@body))))

(ert-deftest vox-pcm-arbitrary-cuts-preserve-exact-bytes ()
  :tags '(vox-unit)
  (dolist (frame '(3200 6400))
    (vox-test-audio
      (setf (vox-session-chunk-bytes session) frame)
      (let* ((bytes (apply #'unibyte-string (number-sequence 0 255)))
             (pcm (apply #'concat (make-list 50 bytes)))
             (offset 0))
        (dolist (size '(1 31 3000 200 257 4000 1000 4311))
          (funcall on-bytes (substring pcm offset (+ offset size)))
          (cl-incf offset size))
        (should (= offset (length pcm)))
        (vox-core-stop) (should (= stops 1)) (should (= finishes 0))
        (funcall on-ended)
        (should (= finishes 1))
        (should (eq (car packets) :finish))
        (should (cl-every (lambda (p) (and (= (length p) frame)
                                          (not (multibyte-string-p p)))) (cdr packets)))
        (should (equal (apply #'concat (reverse (cdr packets))) pcm))))))

(ert-deftest vox-pcm-stop-waits-for-sentinel-and-flushes-tail ()
  :tags '(vox-unit)
  (vox-test-audio
    (funcall on-bytes (apply #'unibyte-string (make-list 3210 128)))
    (vox-core-stop) (vox-core-stop)
    (should (= stops 1)) (should (= finishes 0))
    (funcall on-bytes (unibyte-string 255 0))
    (funcall on-ended) (funcall on-ended)
    (should (= finishes 1))
    (should (equal (mapcar (lambda (p) (if (stringp p) (length p) p))
                          (reverse packets)) '(3200 12 :finish)))))

(ert-deftest vox-pcm-odd-tail-never-sends-half-sample ()
  :tags '(vox-unit)
  (vox-test-audio
    (funcall on-bytes (unibyte-string 1))
    (vox-core-stop) (funcall on-ended)
    (should (eq (vox-session-state session) 'error))
    (should-not packets) (should (= finishes 0))))

(ert-deftest vox-pcm-overflow-fails-without-growing ()
  :tags '(vox-unit)
  (vox-test-audio
    (funcall on-bytes (make-string 64001 0))
    (should (eq (vox-session-state session) 'error))
    (should (zerop (length (vox-session-audio-pending session))))
    (should-not packets)))

(ert-deftest vox-pcm-tick-work-is-bounded-and-finishes-after-drain ()
  :tags '(vox-unit)
  (vox-test-audio
    (funcall on-bytes (make-string 64000 0))
    (should (= (length packets) 8))
    (should (timerp (vox-session-audio-timer session)))
    (vox-core-stop) (funcall on-ended)
    (should (= (length packets) 16)) (should (= finishes 0))
    (let ((timer (vox-session-audio-timer session)))
      (apply (timer--function timer) (timer--args timer)))
    (should (= (length packets) 21))
    (should (eq (car packets) :finish))
    (should (= (plist-get (vox-session-statistics session) :sent-bytes) 64000))))

(ert-deftest vox-pcm-unexpected-recorder-exit-is-error ()
  :tags '(vox-unit)
  (vox-test-audio
    (funcall on-ended)
    (should (eq (vox-session-state session) 'error))
    (should (= finishes 0))))

(ert-deftest vox-pcm-stale-recorder-callbacks-ignored ()
  :tags '(vox-unit)
  (vox-test-audio
    (vox-core-cancel)
    (funcall on-bytes (make-string 3200 0))
    (funcall on-ended) (funcall on-error "late")
    (should (eq (vox-session-state session) 'cancelled))
    (should-not packets)))

(provide 'vox-test-core-audio)
