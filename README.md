# Vox

Independent, native Emacs streaming speech input. All public symbols and implementation files use the `vox-` prefix. No Python, Node, local ASR bridge, or dsh-emacs dependency is required.

**Status: 0.1.0 pre-release.** Offline tests and synthetic-process checks are implemented. Authenticated cloud recognition has **not** been validated in this environment. Qwen is a VAD-only adapter; **Doubao is experimental** until its real handshake, microphone stream, and final packet are verified. A socket close is never considered successful recognition.

## Requirements

- Emacs 28.1 or later, with native GnuTLS for WSS; Doubao additionally needs native zlib.
- `websocket.el` 1.15/1.16-compatible API. Development tests use an exact audited upstream revision; see [transport audit](docs/transport-audit.md).
- FFmpeg with an input device supported by your OS. A CLI backend that captures its own audio needs neither FFmpeg nor WebSocket at runtime.
- A provider account, enabled model/resource, and region-matched credentials for cloud use.

Load without installing the package:

```elisp
(add-to-list 'load-path "/path/to/vox")
(require 'vox)
(global-set-key (kbd "C-c v") #'vox-toggle)
(global-set-key (kbd "C-c C-v") #'vox-cancel)
```

Or:

```elisp
(use-package vox
  :load-path "/path/to/vox"
  :ensure nil
  :commands (vox-toggle vox-start vox-stop vox-cancel)
  :custom
  (vox-backend 'qwen)
  (vox-qwen-language "zh")
  (vox-preview t)
  :bind (("C-c v" . vox-toggle)
         ("C-c C-v" . vox-cancel)))
```

Install `websocket` through your normal Emacs package manager. Do not add `.deps` to your normal load path unless intentionally using the audited development copy.

## Choose an Audio Device

Vox does **not** guess microphone device numbers. Configure `vox-audio-input` before starting a cloud session. Arguments are an argv list, never a shell command. PCM is signed 16-bit little-endian, 16 kHz mono, without a WAV header.

### macOS

Enumerate AVFoundation devices in a terminal:

```sh
ffmpeg -hide_banner -f avfoundation -list_devices true -i ""
```

This device-enumeration command commonly exits nonzero after printing the list. Select the **audio** device number from its output, then configure, for example:

```elisp
(setq vox-audio-input '("-f" "avfoundation" "-i" ":0"))
```

`:0` is only an example, not an automatically selected default. Enable microphone permission for the responsible Emacs/terminal application in macOS Privacy & Security. Your FFmpeg build must expose `avfoundation` in `ffmpeg -devices`.

### Linux

Use the appropriate input backend compiled into your FFmpeg:

```elisp
;; PulseAudio / PipeWire PulseAudio compatibility:
(setq vox-audio-input '("-f" "pulse" "-i" "default"))
;; Or ALSA, after selecting the actual capture device:
(setq vox-audio-input '("-f" "alsa" "-i" "hw:0,0"))
```

For an explicit, non-microphone development source:

```elisp
(setq vox-audio-input
      '("-re" "-f" "lavfi" "-i" "sine=frequency=440:sample_rate=16000"))
```

Starting a **cloud** backend with that virtual source still sends audio to the provider and can incur charges. Offline ERT tests replace the provider with a local fake.

## Credentials and Regions

Secrets resolve through `auth-source` first (host matching the endpoint, user `apikey`), then the provider environment variable. Prefer an encrypted auth-source file; configure it outside this repository. Example entry structure, **not a real key**:

```text
machine dashscope.aliyuncs.com login apikey password YOUR_KEY
machine openspeech.bytedance.com login apikey password YOUR_KEY
```

Alternatively provide `DASHSCOPE_API_KEY` or `DOUBAO_API_KEY` in the environment that starts Emacs. Do not put real keys in shell history, source code, issues, or command-line arguments. GUI Emacs may not inherit your terminal's environment. `vox-doubao-key-environment` changes the latter variable's name.

Qwen defaults to the Beijing public endpoint and model `qwen3-asr-flash-realtime`. For Singapore:

```elisp
(setq vox-qwen-endpoint
      "wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime?model=qwen3-asr-flash-realtime")
```

Confirm model availability, account permissions, region, and business-space requirements in the current provider documentation. Workspace-specific or otherwise custom hosts require explicit confirmation for each connection; batch mode rejects unapproved custom hosts. Only WSS is accepted, and certificate/hostname verification is not disabled.

To choose Doubao:

```elisp
(setq vox-backend 'doubao
      vox-doubao-resource-id "volc.seedasr.sauc.duration"
      vox-doubao-second-pass t
      vox-doubao-chunk-ms 200)
```

The resource ID must match your account's entitlement/billing mode. Doubao uses the audited `bigmodel_async` binary framing, `model_name="bigmodel"`, and full snapshots only. It keeps one PCM frame to use as the final negative-sequence packet. Python and Go examples are protocol references, not dependencies.

## Interaction and Safety

- `vox-toggle`: start when idle, stop when recording; while connecting/draining/finalizing, only report status.
- `vox-stop`: stop the recorder, wait for its sentinel, flush valid PCM, send provider finish once, and wait for authoritative completion. During connection it cancels.
- `vox-cancel`: discard transcript and tear down processes, connection, timers, markers, and preview. It never commits.
- `vox-show-transcript`: explicitly display the current/last in-memory text. Incomplete text is labeled **UNCONFIRMED**. Error recovery never silently inserts it.
- `vox-copy-confirmed-text`: explicitly copy only confirmed/final text to the kill ring (and possibly your system clipboard).
- `vox-forget-transcript`: forget the last session and remove the explicit recovery buffer.

Preview is a throttled, one-line overlay, not buffer text. Typing at the captured insertion point moves its marker **after** your typing. Successful final text inserts once at that marker with an undo boundary. Switching buffers does not redirect insertion; killing the original buffer cancels; read-only insertion fails without overriding protection, retaining final text for manual recovery. Vox never presses Return or submits to an agent.

The default duration limit is 300 seconds (`vox-max-session-seconds`) and triggers graceful stop. Default readiness/stop deadlines are 20/15 seconds. Continuous cloud audio may incur charges. FFmpeg interruption can truncate the last capture block. If the first interrupt does not stop capture, one guarded retry runs after 0.5 seconds; statistics record `:audio-tail-risk`, and the default UI warns that tail audio may be truncated. Forced cleanup or odd trailing PCM samples fail rather than pretend the stream is lossless.

## Queueing, Transport, and Privacy Limits

Core slices arbitrary binary process chunks into 100 ms frames (Qwen) or 100/200 ms frames (Doubao). The upstream PCM queue defaults to two seconds, configurable from 0.5 to 5 with `vox-audio-backlog-seconds`. It fails on overflow without silently dropping bytes. Each drain tick does bounded work; no extra sleep is added to real-time capture.

`websocket.el` does not expose reliable socket buffered-byte counts, and Emacs `process-send-string` can block on a slow peer. Vox bounds its own queues and detects slow sends after they return; **this is not strict network backpressure or a guarantee of a nonblocking socket write**. See the [transport audit](docs/transport-audit.md) for the narrowly scoped asynchronous-handshake compatibility shim and TLS requirements. No RFC 6455 encoder is reimplemented.

No recording/transcript is written to disk by normal operation. Last-session recovery is in memory; explicit copy/display is user initiated. Provider error bodies and FFmpeg/CLI stderr are discarded rather than risking key/audio/transcript leakage. Errors are intentionally coarse. WebSocket debug logging is suppressed for Vox-owned I/O, including the upstream filter. Do not enable arbitrary debugger/packet tracing for production speech. The optional CLI is a trusted external program and can implement its own logging or network behavior; inspect it yourself.

Native gzip decoding checks encoded length, advertised size, and decoded size. The native zlib call is not a streaming bounded-memory decompressor; it cannot enforce a hard allocation cap during decompression of malicious compressed data. Custom endpoints therefore remain a trust decision.

## Optional CLI Backend

```elisp
(setq vox-backend 'cli
      vox-cli-command '("/absolute/path/to/your-streaming-asr" "--ndjson"))
```

The executable must record its own audio and speak UTF-8 NDJSON v1 on stdout:

```jsonl
{"v":1,"type":"started"}
{"v":1,"type":"partial","segment_id":"1","text":"candidate"}
{"v":1,"type":"final","segment_id":"1","text":"final transcript"}
{"v":1,"type":"completed"}
```

Vox writes `{"v":1,"type":"stop"}` plus newline to stdin for graceful stop, and `{"v":1,"type":"cancel"}` for cancellation before teardown. `started` is required before text. `partial` replaces the same segment; `final` confirms it. `completed` is valid only after stop and must be followed by successful process exit; nonzero exit, incomplete JSON, or exit without `completed` fails. Arbitrary legacy CLIs are not automatically compatible. Lines are bounded by `vox-cli-max-line-bytes`; stderr is never parsed as text.

## Embedding / Composer Boundary

Use `vox-start` with a sink, or `vox-core-start` with a nil sink for headless use:

```elisp
(vox-start
 'qwen
 (list :on-preview (lambda (session text status)
                     ;; Update your own transient display only.
                     (ignore session text status))
       :on-finish (lambda (session text)
                    ;; Call your integration's verified editable-input API.
                    ;; Use session target-buffer/target-marker, not current-buffer.
                    (ignore session text))
       :on-state (lambda (session state) (ignore session state))
       :on-error (lambda (session safe-error) (ignore session safe-error))))
```

Callbacks must be short and nonblocking. Exceptions stop the session safely. A sink is responsible for its own display cleanup and read-only/edit-boundary checks. No dsh-emacs files are modified and no Composer internals are assumed. `vox-register-backend` registers a capability/method plist; see its docstring and the included adapters.

## Development and Acceptance

```sh
make test       # ERT; does not read cloud keys or open a microphone
make compile    # all implementation files, warnings are errors
make check      # both
make benchmark  # accelerated 600-second synthetic PCM model, NOT real-time UI proof
make dist       # check, then build dist/vox-0.1.0.tar
```

The resulting tar is a multi-file Emacs package with a package descriptor. Install it with `M-x package-install-file` after making the `websocket` dependency available; building the archive does not install it into your user profile.

Transport tests need the audited `websocket.el` on the load path (`.deps` is included by the Makefile). CI downloads a pinned source revision with SHA-256 validation and runs Emacs 28.2/29.4/30.2. A missing optional executable/dependency skips only explicitly dependent tests, so inspect skipped counts. The local environment's results are documented in [validation](docs/validation.md); a CI configuration is not evidence that CI has run.

See [protocol audit](docs/protocol-audit.md), [transport audit](docs/transport-audit.md), and [fixture provenance](test/fixtures/README.md) for exact sources and unresolved interoperability details. Fixtures are synthetic or official reference bytes as labeled, never fabricated live recordings.

Before claiming production acceptance, manually verify both providers with region-correct credentials and microphone consent: 30-60 seconds of Chinese/English speech, multiple revisions, final event after stop, silence, invalid key, network loss, cancellation, and no duplicate insertion. Doubao's no-audio final packet and actual gzip acceptance remain explicit integration checks. Also run a ten-minute **wall-clock** UI responsiveness/capture/network test; the accelerated benchmark does not replace it.

## Troubleshooting

- Setup failure: check `vox-audio-input`, `executable-find`, installed `websocket`, native GnuTLS/zlib, auth-source host/user, key region, and model/resource entitlement.
- Capture failure: use device enumeration and OS microphone settings. Run your device-only FFmpeg check separately if raw diagnostics are needed; Vox deliberately does not retain stderr.
- Stop timeout: the process or provider did not produce the required terminal event; no incomplete text is committed. Inspect recovery text explicitly, then start a new session.
- Backlog/send failure: stop and retry on a stable connection. Automatic reconnect is intentionally absent because it cannot preserve audio context or deduplicate final results reliably.
- Read-only target: recover final text using `vox-show-transcript` or `vox-copy-confirmed-text`; Vox never bypasses read-only protection.

Vox implementation license: GPL-3.0-or-later. See [LICENSE](LICENSE). Downloaded official reference materials retain their upstream ownership; see [fixture provenance](test/fixtures/README.md).
