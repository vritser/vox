;;; vox-test-device.el --- Device picker tests -*- lexical-binding: t; no-byte-compile: t; -*-

;;; Commentary:
;; Every listing below is synthetic, modeled on FFmpeg listing formats.
;; These tests never enumerate actual devices, capture audio, use a shell,
;; contact providers, or save user configuration.  Process APIs are mocked;
;; the Customize rollback regression writes only to a temporary file.

;;; Code:

(require 'vox-test-support)
(require 'vox-device)

(defconst vox-device-test--avfoundation
  (concat "unrelated diagnostic [9] not an input\n"
          "[AVFoundation indev @ 0x1] AVFoundation video devices:\n"
          "[AVFoundation indev @ 0x1] [0] Camera\n"
          "[AVFoundation indev @ 0x1] AVFoundation audio devices:\n"
          "[AVFoundation indev @ 0x1] [0] Same microphone\n"
          "[AVFoundation indev @ 0x1] [2] Same microphone [uid:synthetic-id]\n"
          "[other @ 0x2] [8] Unrelated source\n"
          "[AVFoundation indev @ 0x1] [0] Same microphone\n")
  "Synthetic AVFoundation section, index, and metadata fixture.")

(defconst vox-device-test--dshow
  (concat "[dshow @ 0x1] \"Camera\" (video)\n"
          "[dshow @ 0x1]   Alternative name \"@video\"\n"
          "[dshow @ 0x1] \"Same microphone\" (audio)\n"
          "[dshow @ 0x1]   Alternative name \"@audio_one\"\n"
          "[dshow @ 0x1] \"Same microphone\" (audio)\n"
          "[dshow @ 0x1]   Alternative name \"@audio_two\"\n"
          "[other @ 0x2] \"Not DirectShow\" (audio)\n"
          "[dshow @ 0x1] \"Unknown\" (none)\n"
          "[dshow @ 0x1] \"Combined\" (video, audio)\n"
          "[dshow @ 0x1]   Alternative name \"@combined\"\n"
          "[dshow @ 0x1] \"Same microphone\" (audio)\n"
          "[dshow @ 0x1]   Alternative name \"@audio_one\"\n")
  "Synthetic modern DirectShow duplicate names and alternative IDs.")

(defconst vox-device-test--pulse
  (concat "Auto-detected sources for pulse:\n"
          "  alsa_input.usb [USB microphone] (audio)\n"
          "* default [Default audio source] (none)\n"
          "  sink.monitor [Monitor of speakers (system audio)] (audio)\n"
          "  camera [Camera] (video)\n"
          "  secondary_input [Secondary microphone] (none)\n"
          "warning: private diagnostic\n"
          "  alsa_input.usb [USB microphone] (audio)\n")
  "Synthetic FFmpeg show_sources records; not a real device capture.")

(defun vox-device-test--inputs (devices)
  "Return input argument lists from DEVICES."
  (mapcar (lambda (device) (plist-get device :input)) devices))

(defmacro vox-device-test--process (&rest body)
  "Run BODY with entirely synthetic discovery process APIs.
BODY may replace STEP to simulate events during each output wait."
  (declare (indent 0) (debug t))
  `(let* ((vox--active-session nil)
          (vox-device--busy nil)
          (vox-audio-program "synthetic-ffmpeg")
          (vox-device-discovery-timeout 5)
          (status 'run) (clock 0.0) (waits 0) (notify t)
          (chunks (list vox-device-test--avfoundation))
          (fake-process 'vox-device-test-process)
          command options filter sentinel deleted
          (step (lambda ()
                  (when chunks
                    (funcall filter fake-process (pop chunks)))
                  (unless chunks (setq status 'exit)))))
     (cl-letf (((symbol-function 'executable-find)
                (lambda (name)
                  (should (equal name "synthetic-ffmpeg"))
                  "/synthetic/ffmpeg"))
               ((symbol-function 'make-process)
                (lambda (&rest args)
                  (setq options args command (plist-get args :command)
                        filter (plist-get args :filter)
                        sentinel (plist-get args :sentinel))
                  fake-process))
               ((symbol-function 'process-live-p)
                (lambda (process)
                  (should (eq process fake-process))
                  (eq status 'run)))
               ((symbol-function 'process-status) (lambda (_) status))
               ((symbol-function 'process-exit-status) (lambda (_) 17))
               ((symbol-function 'float-time) (lambda (&optional _) clock))
               ((symbol-function 'accept-process-output)
                (lambda (process seconds &rest _)
                  (should-not process)
                  (should (<= 0 seconds 0.1))
                  (cl-incf waits)
                  (funcall step)
                  (when (and notify (not (eq status 'run)))
                    (funcall sentinel fake-process "synthetic terminal event"))))
               ((symbol-function 'set-process-filter)
                (lambda (process function)
                  (should (eq process fake-process))
                  (setq filter function)))
               ((symbol-function 'set-process-sentinel)
                (lambda (process function)
                  (should (eq process fake-process))
                  (setq sentinel function)))
               ((symbol-function 'delete-process)
                (lambda (process)
                  (should (eq process fake-process))
                  (should (eq filter #'ignore))
                  (should (eq sentinel #'ignore))
                  (setq deleted t status 'signal))))
       (ignore command options filter sentinel deleted waits)
       ,@body)))

(ert-deftest vox-device-avfoundation-audio-only-and-duplicates ()
  :tags '(vox-unit)
  (let ((devices (vox-device--parse-avfoundation vox-device-test--avfoundation)))
    (should (equal (vox-device-test--inputs devices)
                   '(("-f" "avfoundation" "-i" ":0")
                     ("-f" "avfoundation" "-i" ":2"))))
    (should-not (equal (plist-get (car devices) :label)
                       (plist-get (cadr devices) :label)))))

(ert-deftest vox-device-dshow-modern-audio-and-alternative-ids ()
  :tags '(vox-unit)
  (let ((devices (vox-device--parse-dshow vox-device-test--dshow)))
    (should (equal (vox-device-test--inputs devices)
                   '(("-f" "dshow" "-i" "audio=@audio_one")
                     ("-f" "dshow" "-i" "audio=@audio_two")
                     ("-f" "dshow" "-i" "audio=@combined"))))
    (should (= 3 (length (delete-dups (mapcar (lambda (d) (plist-get d :label))
                                            devices)))))))

(ert-deftest vox-device-dshow-legacy-sections ()
  :tags '(vox-unit)
  (should
   (equal
    (vox-device-test--inputs
     (vox-device--parse-dshow
      (concat "[dshow @ x] DirectShow video devices (some may be both video and audio devices)\n"
              "[dshow @ x]  \"Camera\"\n"
              "[dshow @ x]     Alternative name \"@camera\"\n"
              "[dshow @ x] DirectShow audio devices\n"
              "[dshow @ x]  \"Friendly\"\n"
              "[dshow @ x]     Alternative name \"@stable\"\n"
              "[dshow @ x]  \"Fallback microphone\"\n")))
    '(("-f" "dshow" "-i" "audio=@stable")
      ("-f" "dshow" "-i" "audio=Fallback microphone")))))

(ert-deftest vox-device-pulse-source-records-and-monitor-label ()
  :tags '(vox-unit)
  (let ((devices (vox-device--parse-pulse vox-device-test--pulse)))
    (should (equal (vox-device-test--inputs devices)
                   '(("-f" "pulse" "-i" "alsa_input.usb")
                     ("-f" "pulse" "-i" "default")
                     ("-f" "pulse" "-i" "sink.monitor")
                     ("-f" "pulse" "-i" "secondary_input"))))
    (should (string-match-p "Monitor.*system audio"
                            (plist-get (nth 2 devices) :label)))))

(ert-deftest vox-device-unicode-and-quotes-stay-single-arguments ()
  :tags '(vox-unit)
  ;; Unicode is constructed to keep source portable; these names are synthetic.
  (let* ((name (concat (string #x9ea6 #x514b #x98ce) " \"quoted\" ; $(false)"))
         (dshow (vox-device--parse-dshow
                 (format "[dshow @ x] \"%s\" (audio)\n" name)))
         (pulse (vox-device--parse-pulse
                 (format "  %s [Synthetic source] (audio)\n" name))))
    (should (equal (plist-get (car dshow) :input)
                   (list "-f" "dshow" "-i" (concat "audio=" name))))
    (should (equal (plist-get (car pulse) :input)
                   (list "-f" "pulse" "-i" name)))))

(ert-deftest vox-device-parser-ignores-unrelated-diagnostics ()
  :tags '(vox-unit)
  (dolist (parser '(vox-device--parse-avfoundation vox-device--parse-dshow
                   vox-device--parse-pulse))
    (should-not (funcall parser "private diagnostic\n[0] camera\n\"fake\" (audio)\n"))))

(ert-deftest vox-device-discovery-process-contract-and-normal-nonzero ()
  :tags '(vox-unit)
  (vox-device-test--process
    (should (equal (vox-device--discover '("-i" "")) vox-device-test--avfoundation))
    (should (equal command '("/synthetic/ffmpeg" "-i" "")))
    (should (eq (plist-get options :connection-type) 'pipe))
    (should (eq (plist-get options :coding) 'utf-8-unix))
    (should-not (plist-get options :buffer))
    (should (plist-member options :stderr))
    (should-not (plist-get options :stderr))
    (should (plist-get options :noquery))
    (should (= waits 1))
    (should (eq filter #'ignore))
    (should (eq sentinel #'ignore))
    (should-not deleted)))

(ert-deftest vox-device-discovery-bounds-output-bytes ()
  :tags '(vox-unit)
  (vox-device-test--process
    (setq chunks (list (make-string 32768 #x00e9)))
    (should (= 65536 (string-bytes (vox-device--discover nil)))))
  (vox-device-test--process
    (setq step (lambda () (funcall filter fake-process
                                  (make-string 32769 #x00e9))))
    (let ((error (should-error (vox-device--discover nil) :type 'user-error)))
      (should (string-match-p "safe output limit" (error-message-string error))))
    (should deleted)
    (should (= waits 1))))

(ert-deftest vox-device-discovery-timeout-discards-partial-and-cleans ()
  :tags '(vox-unit)
  (vox-device-test--process
    (setq step (lambda ()
                 (funcall filter fake-process vox-device-test--avfoundation)
                 (setq clock 6.0)))
    (let ((error (should-error (vox-device--discover nil) :type 'user-error)))
      (should (string-match-p "timed out" (error-message-string error))))
    (should deleted)))

(ert-deftest vox-device-discovery-quit-cleans-own-process ()
  :tags '(vox-unit)
  (vox-device-test--process
    (setq step (lambda () (signal 'quit nil)))
    (should (eq 'quit (condition-case nil
                         (vox-device--discover nil)
                       (quit 'quit))))
    (should deleted)
    (should (eq filter #'ignore))
    (should (eq sentinel #'ignore))))

(ert-deftest vox-device-discovery-signal-and-spawn-errors-are-safe ()
  :tags '(vox-unit)
  (vox-device-test--process
    (setq step (lambda ()
                 (funcall filter fake-process vox-device-test--avfoundation)
                 (setq status 'signal)))
    (should-error (vox-device--discover nil) :type 'user-error)
    (should-not deleted))
  (vox-device-test--process
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _) (error "PRIVATE_DEVICE_DIAGNOSTIC"))))
      (let ((error (should-error (vox-device--discover nil) :type 'user-error)))
        (should-not (string-match-p "PRIVATE" (error-message-string error)))))))

(ert-deftest vox-device-discovery-timeout-validation ()
  :tags '(vox-unit)
  (dolist (value '(nil "5" 0 -1 0.09 31 1.0e+INF 0.0e+NaN))
    (let ((vox-device-discovery-timeout value))
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest _) (ert-fail "Unexpected process creation"))))
        (should-error (vox-device--discover nil) :type 'user-error)))))

(ert-deftest vox-device-discovery-missing-executable ()
  :tags '(vox-unit)
  (cl-letf (((symbol-function 'executable-find) (lambda (_) nil))
            ((symbol-function 'make-process)
             (lambda (&rest _) (ert-fail "Unexpected process creation"))))
    (should-error (vox-device--discover nil) :type 'user-error)))

(ert-deftest vox-device-list-platform-commands ()
  :tags '(vox-unit)
  (let ((vox--active-session nil) (vox-device--busy nil))
    (dolist (spec `((darwin ,vox-device-test--avfoundation
                            ("-hide_banner" "-f" "avfoundation" "-list_devices" "true" "-i" ""))
                    (windows-nt ,vox-device-test--dshow
                                ("-hide_banner" "-list_devices" "true" "-f" "dshow" "-i" "dummy"))
                    (gnu/linux ,vox-device-test--pulse
                               ("-hide_banner" "-sources" "pulse"))))
      (let ((system-type (nth 0 spec)))
        (cl-letf (((symbol-function 'vox-device--discover)
                   (lambda (args)
                     (should (equal args (nth 2 spec)))
                     (nth 1 spec))))
          (should (vox-device-list)))))))

(ert-deftest vox-device-list-unsupported-and-no-candidates ()
  :tags '(vox-unit)
  (let ((vox--active-session nil) (vox-device--busy nil) (system-type 'berkeley-unix))
    (cl-letf (((symbol-function 'vox-device--discover)
               (lambda (_) (ert-fail "Unexpected discovery"))))
      (should-error (vox-device-list) :type 'user-error)))
  (let ((vox--active-session nil) (vox-device--busy nil) (system-type 'gnu/linux))
    (cl-letf (((symbol-function 'vox-device--discover)
               (lambda (_) "PRIVATE_DEVICE_DIAGNOSTIC")))
      (let ((error (should-error (vox-device-list) :type 'user-error)))
        (should (string-match-p "vox-audio-input" (error-message-string error)))
        (should-not (string-match-p "PRIVATE" (error-message-string error)))))))

(ert-deftest vox-device-list-active-and-reentrant-discovery ()
  :tags '(vox-unit)
  (let ((vox--active-session 'synthetic-session))
    (cl-letf (((symbol-function 'vox-device--discover)
               (lambda (_) (ert-fail "Unexpected discovery"))))
      (should-error (vox-device-list) :type 'user-error)))
  (let ((vox--active-session nil) (vox-device--busy nil) (system-type 'darwin))
    (cl-letf (((symbol-function 'vox-device--discover)
               (lambda (_)
                 (should-error (vox-device-list) :type 'user-error)
                 vox-device-test--avfoundation)))
      (should (vox-device-list)))
    (should-not vox-device--busy)))

(defmacro vox-device-test--selection (&rest body)
  "Run BODY with synthetic candidates and mocked persistence."
  (declare (indent 0) (debug t))
  `(let* ((vox--active-session nil)
          (vox-audio-input '("-f" "lavfi" "-i" "custom-source"))
          (previous vox-audio-input)
          (chosen '("-f" "pulse" "-i" "synthetic-id"))
          (devices (list (list :label "Synthetic microphone" :input chosen)))
          (completions 0) saves)
     (cl-letf (((symbol-function 'vox-device-list) (lambda () devices))
               ((symbol-function 'completing-read)
                (lambda (_prompt collection predicate require-match
                         &optional initial history &rest _)
                  (cl-incf completions)
                  (should-not predicate)
                  (should require-match)
                  (should-not initial)
                  (should (eq history t))
                  (should (equal vox-audio-input previous))
                  (caar collection)))
               ((symbol-function 'customize-save-variable)
                (lambda (variable value &rest _)
                  (push (list variable value) saves)
                  (set variable value))))
       (ignore completions saves)
       ,@body)))

(ert-deftest vox-device-selection-explicit-singleton-without-persistence ()
  :tags '(vox-unit)
  (vox-device-test--selection
    (should (equal (vox-select-input-device) chosen))
    (should (equal vox-audio-input chosen))
    (should (= completions 1))
    (should-not saves)))

(ert-deftest vox-device-selection-prefix-persists-only-input ()
  :tags '(vox-unit)
  (should (equal (interactive-form #'vox-select-input-device) '(interactive "P")))
  (vox-device-test--selection
    (should (equal (vox-select-input-device '(4)) chosen))
    (should (equal saves (list (list 'vox-audio-input chosen))))
    (should (= completions 1))))

(ert-deftest vox-device-selection-cancel-error-or-empty-retains-input ()
  :tags '(vox-unit)
  (dolist (result '(quit error empty))
    (vox-device-test--selection
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _)
                   (pcase result
                     ('quit (signal 'quit nil))
                     ('error (error "Synthetic completion failure"))
                     ('empty "")))))
        (condition-case nil
            (progn (vox-select-input-device t) (ert-fail "Selection unexpectedly succeeded"))
          ((quit error) nil)))
      (should (equal vox-audio-input previous))
      (should-not saves))))

(ert-deftest vox-device-selection-save-error-retains-input ()
  :tags '(vox-unit)
  (vox-device-test--selection
    (cl-letf (((symbol-function 'customize-save-variable)
               (lambda (_ value &rest _)
                 (setq vox-audio-input value)
                 (error "Synthetic save failure"))))
      (should-error (vox-select-input-device t)))
    (should (equal vox-audio-input previous))))

(ert-deftest vox-device-selection-failed-save-restores-customize-state ()
  :tags '(vox-unit)
  (require 'cus-edit)
  ;; Use real Customize metadata updates and later persistence, but fail the
  ;; initial write.  All values are synthetic and the only file is temporary.
  (dolist (failure '(error quit))
    (dolist (configured '(nil t))
      (let* ((original-properties (copy-tree (symbol-plist 'vox-audio-input)))
             (original-settings (copy-tree (get 'user 'theme-settings)))
             (real-save (symbol-function 'customize-save-variable))
             (custom-file (make-temp-file "vox-device-test-custom-"))
             (user-init-file custom-file)
             (make-backup-files nil))
        (unwind-protect
            (vox-device-test--selection
              (dolist (property '(saved-value customized-value
                                 customized-variable-comment theme-value))
                (cl-remprop 'vox-audio-input property))
              (put 'user 'theme-settings nil)
              (when configured
                (put 'vox-audio-input 'saved-value (list (custom-quote previous)))
                (put 'vox-audio-input 'customized-value (list (custom-quote previous)))
                (put 'vox-audio-input 'customized-variable-comment "Synthetic comment")
                (custom-push-theme 'theme-value 'vox-audio-input 'user 'set
                                   (custom-quote previous)))
              (let ((before-properties (copy-tree (symbol-plist 'vox-audio-input)))
                    (before-settings (copy-tree (get 'user 'theme-settings))))
                (cl-letf (((symbol-function 'customize-save-variable) real-save)
                          ((symbol-function 'custom-save-all)
                           (lambda ()
                             ;; Exercise preservation of unrelated theme changes.
                             (custom-push-theme 'theme-value 'vox-device-test-unrelated
                                                'user 'set 'synthetic)
                             (signal failure '("Synthetic save failure")))))
                  (should
                   (eq failure
                       (condition-case condition
                           (progn (vox-select-input-device t) nil)
                         ((error quit) (car condition))))))
                (should (equal vox-audio-input previous))
                (dolist (property '(saved-value customized-value
                                   customized-variable-comment theme-value))
                  (should (equal (get 'vox-audio-input property)
                                 (plist-get before-properties property)))
                  (should (eq (not (null (plist-member (symbol-plist 'vox-audio-input)
                                                      property)))
                              (not (null (plist-member before-properties property))))))
                (should (equal (get 'user 'theme-settings)
                               (append before-settings
                                       '((theme-value vox-device-test-unrelated user
                                                      synthetic)))))
                ;; A later unrelated save must not persist the rejected input.
                (custom-save-all)
                (with-temp-buffer
                  (insert-file-contents custom-file)
                  (should-not (search-forward "synthetic-id" nil t))
                  (when configured
                    (goto-char (point-min))
                    (should (search-forward "custom-source" nil t))))))
          (setplist 'vox-audio-input original-properties)
          (put 'user 'theme-settings original-settings)
          (cl-remprop 'vox-device-test-unrelated 'theme-value)
          (when-let* ((buffer (get-file-buffer custom-file)))
            (with-current-buffer buffer (set-buffer-modified-p nil))
            (kill-buffer buffer))
          (delete-file custom-file))))))

(ert-deftest vox-device-selection-active-before-discovery-or-after-prompt ()
  :tags '(vox-unit)
  (vox-device-test--selection
    (setq vox--active-session 'synthetic-session)
    (cl-letf (((symbol-function 'vox-device-list)
               (lambda () (ert-fail "Unexpected discovery"))))
      (should-error (vox-select-input-device t) :type 'user-error))
    (should (equal vox-audio-input previous))
    (should-not saves))
  (dolist (save '(nil t))
    (vox-device-test--selection
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _)
                   (setq vox--active-session 'synthetic-session)
                   "Synthetic microphone")))
        (should-error (vox-select-input-device save) :type 'user-error))
      (should (equal vox-audio-input previous))
      (should-not saves))))

(ert-deftest vox-device-load-does-not-discover-or-persist ()
  :tags '(vox-unit)
  (let ((vox-audio-input '("custom")))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _) (ert-fail "Unexpected process creation")))
              ((symbol-function 'executable-find)
               (lambda (&rest _) (ert-fail "Unexpected executable discovery")))
              ((symbol-function 'customize-save-variable)
               (lambda (&rest _) (ert-fail "Unexpected persistence"))))
      (load (expand-file-name "vox-device.el" vox-test-root-directory) nil t t))
    (should (equal vox-audio-input '("custom")))))

(ert-deftest vox-device-pulse-legacy-records ()
  :tags '(vox-unit)
  (should
   (equal (vox-device-test--inputs
           (vox-device--parse-pulse
            (concat "Auto-detected sources for pulse:\n"
                    "  legacy_input [Legacy microphone]\n"
                    "* default [Default audio source]\n")))
          '(("-f" "pulse" "-i" "legacy_input")
            ("-f" "pulse" "-i" "default")))))

(ert-deftest vox-device-dshow-colon-needs-alternative-id ()
  :tags '(vox-unit)
  (should
   (equal (vox-device-test--inputs
           (vox-device--parse-dshow
            (concat "[dshow @ x] \"Name: cannot map\" (audio)\n"
                    "[dshow @ x] \"Name: mapped\" (audio)\n"
                    "[dshow @ x] Alternative name \"@stable_id\"\n"
                    "[dshow @ x] \"Camera\" (video)\n"
                    "[dshow @ x] Alternative name \"@video_id\"\n")))
          '(("-f" "dshow" "-i" "audio=@stable_id")))))

(ert-deftest vox-device-discovery-completion-after-deadline-fails ()
  :tags '(vox-unit)
  (vox-device-test--process
    (setq step (lambda ()
                 (funcall filter fake-process vox-device-test--avfoundation)
                 (setq clock 6.0 status 'exit)))
    (let ((error (should-error (vox-device--discover nil) :type 'user-error)))
      (should (string-match-p "timed out" (error-message-string error))))
    (should-not deleted)))

(ert-deftest vox-device-list-never-parses-failed-discovery ()
  :tags '(vox-unit)
  (dolist (failure '(timeout overflow signal))
    (vox-device-test--process
      (let ((system-type 'darwin))
        (setq step (lambda ()
                     (funcall filter fake-process vox-device-test--avfoundation)
                     (pcase failure
                       ('timeout (setq clock 6.0))
                       ('overflow (funcall filter fake-process (make-string 65537 ?x)))
                       ('signal (setq status 'signal)))))
        (cl-letf (((symbol-function 'vox-device--parse-avfoundation)
                   (lambda (_) (ert-fail "Parsed failed discovery output"))))
          (should-error (vox-device-list) :type 'user-error))
        (should-not vox-device--busy)))))

(ert-deftest vox-device-list-quit-releases-busy-guard ()
  :tags '(vox-unit)
  (vox-device-test--process
    (let ((system-type 'darwin))
      (setq step (lambda () (signal 'quit nil)))
      (should (eq 'quit (condition-case nil (vox-device-list) (quit 'quit))))
      (should-not vox-device--busy)
      (should deleted))))

(ert-deftest vox-device-discovery-drains-output-before-terminal-sentinel ()
  :tags '(vox-unit)
  (vox-device-test--process
    (setq notify nil
          step (lambda ()
                 (if (= waits 1)
                     (progn
                       (funcall filter fake-process "listing prefix\n")
                       (setq status 'exit))
                   (funcall filter fake-process "listing tail\n")
                   (setq notify t))))
    (should (equal (vox-device--discover nil) "listing prefix\nlisting tail\n"))
    (should (= waits 2))
    (should-not deleted)))

(ert-deftest vox-device-selection-reentrant-command-rejected ()
  :tags '(vox-unit)
  (vox-device-test--selection
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _)
                 (should-error (vox-select-input-device t) :type 'user-error)
                 "Synthetic microphone")))
      (should (equal (vox-select-input-device) chosen)))
    (should-not vox-device--selecting)
    (should-not saves)))

(ert-deftest vox-device-selection-canonicalizes-unique-case-insensitive-input ()
  :tags '(vox-unit)
  (vox-device-test--selection
    (let ((completion-ignore-case t))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _)
                   (should (test-completion "synthetic microphone" collection))
                   "synthetic microphone")))
        (should (equal (vox-select-input-device) chosen)))
      (should (equal vox-audio-input chosen))
      (should-not saves))))

(ert-deftest vox-device-selection-case-folding-never-guesses-between-identities ()
  :tags '(vox-unit)
  (vox-device-test--selection
    (let ((completion-ignore-case t)
          (other '("-f" "pulse" "-i" "case-distinct-id")))
      (setq devices (append devices (list (list :label "synthetic microphone" :input other))))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _)
                   (should (test-completion "SYNTHETIC MICROPHONE" collection))
                   "SYNTHETIC MICROPHONE")))
        (should-error (vox-select-input-device t) :type 'user-error))
      (should (equal vox-audio-input previous))
      (should-not saves)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "synthetic microphone")))
        (should (equal (vox-select-input-device) other))))))

(provide 'vox-test-device)
;;; vox-test-device.el ends here
