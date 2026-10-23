;;; vox-test-support.el --- Shared test paths and fixtures -*- lexical-binding: t; no-byte-compile: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Subsystem files require this helper, never another subsystem's tests.
;;; Code:
(require 'ert)
(require 'cl-lib)

(defconst vox-test-directory
  (file-name-directory (or load-file-name buffer-file-name)))
(defconst vox-test-root-directory
  (file-name-directory (directory-file-name vox-test-directory)))
(add-to-list 'load-path vox-test-root-directory)
(add-to-list 'load-path (expand-file-name ".deps" vox-test-root-directory))
(setq load-prefer-newer t)
(require 'vox-core)

(defun vox-test--asr-configuration (factory name protocol options)
  "Build a resolved synthetic ASR fixture using FACTORY, NAME and OPTIONS.
PROTOCOL chooses the wire adapter.  Flat fixture options describe the runtime
record whose accessors the existing provider regressions exercise."
  (let (shared capability)
    (while options
      (let ((key (pop options)) (value (pop options)))
        (if (memq key '(:host :key))
            (setq shared (append shared (list key value)))
          (setq capability (append capability (list key value))))))
    (vox-backend-capability
     (apply factory name (append shared (list :asr (append (list :protocol protocol) capability))))
     'asr)))

(defun vox-test-make-qwen (name &rest options)
  "Build a synthetic resolved Realtime ASR fixture named NAME with OPTIONS."
  (vox-test--asr-configuration #'vox-make-qwen name 'qwen options))

(defun vox-test-make-qwen-audio (name &rest options)
  "Build a synthetic resolved task-streaming fixture named NAME with OPTIONS."
  (vox-test--asr-configuration #'vox-make-qwen name 'qwen-audio options))

(defun vox-test-make-doubao (name &rest options)
  "Build a synthetic resolved Doubao ASR fixture named NAME with OPTIONS."
  (vox-test--asr-configuration #'vox-make-doubao name 'doubao options))

(defun vox-test--tts-configuration (factory name options)
  "Build a resolved synthetic TTS fixture using FACTORY, NAME and OPTIONS."
  (let ((shared '(:asr nil)) capability)
    (while options
      (let ((key (pop options)) (value (pop options)))
        (if (memq key '(:host :key))
            (setq shared (append shared (list key value)))
          (setq capability (append capability (list key value))))))
    (vox-backend-capability
     (apply factory name (append shared (list :tts (or capability t)))) 'tts)))

(defun vox-test-make-tts-qwen (name &rest options)
  "Build synthetic Qwen TTS NAME with OPTIONS."
  (vox-test--tts-configuration #'vox-make-qwen name options))

(defun vox-test-make-tts-doubao (name &rest options)
  "Build synthetic Doubao WebSocket TTS NAME with OPTIONS."
  (vox-test--tts-configuration #'vox-make-doubao name
                               options))

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

(provide 'vox-test-support)
;;; vox-test-support.el ends here
