;;; vox-benchmark.el --- Accelerated ten-minute PCM model -*- lexical-binding: t; -*-
(require 'vox-core)
(require 'benchmark)

(defun vox-benchmark-run ()
  "Measure 600 seconds of synthetic PCM at accelerated speed, without I/O.
This is NOT a ten-minute wall-clock UI, microphone, or network benchmark."
  (let ((vox--active-session nil) (vox--last-session nil)
        (vox--backends (copy-hash-table vox--backends))
        (vox-max-session-seconds 900)
        (bytes 0) (frames 0) session callback committed result)
    (vox-register-backend
     'benchmark (list :connect (lambda (_s ready event _error)
                                  (setq callback event) (funcall ready))
                      :send-pcm (lambda (_s pcm) (cl-incf bytes (length pcm)) (cl-incf frames))
                      :finish #'ignore :cancel #'ignore :close #'ignore))
    (with-temp-buffer
      (unwind-protect
          (progn
            (setq session (vox-core-start 'benchmark (list :on-finish (lambda (_s _text) (setq committed t)))))
            (let ((pcm (make-string 3200 0)))
              (setq result
                    (benchmark-run 1
                      (dotimes (i 6000)
                        (vox-core-audio session (substring pcm 0 31))
                        (vox-core-audio session (substring pcm 31))
                        (funcall callback (list :type :snapshot :text (format "synthetic snapshot %d" i)
                                               :revision i))))))
            (vox-core-stop) (funcall callback '(:type :completed))
            (unless (and committed (= frames 6000) (= bytes 19200000)
                         (zerop (length (vox-session-audio-pending session)))
                         (vox-session-cleaned session))
              (error "Benchmark correctness regression"))
            (princ (format "Emacs %s; synthetic duration=600s; frames=%d; PCM bytes=%d\n"
                           emacs-version frames bytes))
            (princ (format "elapsed=%.6fs; GCs=%d; GC time=%.6fs; queue peak=%d bytes\n"
                           (nth 0 result) (nth 1 result) (nth 2 result)
                           (plist-get (vox-session-statistics session) :queue-peak)))
            (princ "No real-time UI responsiveness, network latency, or microphone claims.\n"))
        (vox-core-cancel)))))
