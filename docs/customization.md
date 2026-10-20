# Customization

See the [quick start](../README.md#quick-start) for loading Vox. Options belong to
`M-x customize-group RET vox RET`; transport options also have a `vox-transport`
group. Cloud recognition is not live-validated; Doubao remains experimental.

## Example configuration

```elisp
(use-package vox
  :load-path "/path/to/vox"
  :ensure nil
  :commands (vox-toggle vox-start vox-stop vox-cancel vox-select-input-device vox-select-model)
  :custom
  (vox-qwen-language "zh")
  (vox-preview t)
  :bind (("C-c v" . vox-toggle)
         ("C-c C-v" . vox-cancel))
  :config
  (setq vox-backend (vox-make-qwen "DashScope")
        vox-model 'qwen3-asr-flash-realtime))
```

Install `websocket` through your normal Emacs package manager. Do not add `.deps`
to your normal load path unless intentionally using the audited development copy.
The CLI backend needs neither FFmpeg nor WebSocket at runtime when it captures
its own audio.

## Choose an audio device

Vox enumerates inputs but never silently guesses or selects the first microphone.
Run `M-x vox-select-input-device`, select a device with minibuffer completion,
and press Return. Even a single result requires a choice. If `vox-audio-input`
is nil, the first **interactive** `vox-start` or `vox-toggle` opens this picker
before connecting to a recognizer. Cancel with `C-g` to abort without starting
recognition. Existing non-nil input configurations are not replaced automatically.

A normal selection changes `vox-audio-input` for the current Emacs session only.
Use `C-u M-x vox-select-input-device` to save that option through Customize, using
your configured `custom-file` or Emacs init file. Saving is explicit; discovery
and ordinary selection do not edit configuration files. Stop or cancel an active
Vox session before choosing a different input.

| System | Enumerated inputs | Requirements / limitations |
| --- | --- | --- |
| macOS | AVFoundation audio devices, excluding video-only entries | FFmpeg AVFoundation support; numeric indices may change after hardware changes |
| Windows | DirectShow audio devices | FFmpeg DirectShow support; reported alternative identifiers distinguish duplicate names |
| GNU/Linux | PulseAudio sources, including PipeWire's PulseAudio compatibility service | FFmpeg PulseAudio support and a reachable server; sources may include system-audio monitors |

Rerun the picker after changing devices. Saving an AVFoundation index does not
make it a stable physical-device identity. Known PulseAudio monitor sources are
labelled as system audio; the list is not guaranteed to contain only microphones.
ALSA-only systems, unsupported platforms, or builds without listing support still
use explicit `vox-audio-input` configuration as shown below; there is no silent
fallback to a default input.

Discovery starts a local FFmpeg listing process only on request, not when Vox is
loaded. It collects stdout/stderr without logging the listing, limits retained
output to 64 KiB, and defaults to a 5-second timeout. Set
`vox-device-discovery-timeout` from 0.1 to 30 seconds if needed. Quit, timeout, or
failure cleans up that listing process. Listing may contact local audio services,
initialize device drivers, or cause native permission prompts; it is not a
promise of zero hardware interaction. Grant required permissions and retry if
needed. No recognizer is contacted until a first-start choice succeeds.

Noninteractive/programmatic `vox-start` and headless `vox-core-start` do not open
a picker; configure their input explicitly. The self-recording CLI backend has
its own device handling and does not use this picker automatically. The manual
input remains an argv list, never a shell command. PCM is signed 16-bit
little-endian, 16 kHz mono, without a WAV header. `vox-audio-program` defaults to
`ffmpeg` and is also used for listing.

The parsers cover older and current human-readable FFmpeg listing forms; these
are not a stable machine protocol. See the official
[FFmpeg device documentation](https://ffmpeg.org/ffmpeg-devices.html). Tests use
synthetic listings, not real-device acceptance on each platform.

### macOS

Enumerate AVFoundation devices in a terminal:

```sh
ffmpeg -hide_banner -f avfoundation -list_devices true -i ""
```

This command commonly exits nonzero after printing the list. Select the **audio**
device number from its output, then configure, for example:

```elisp
(setq vox-audio-input '("-f" "avfoundation" "-i" ":0"))
```

`:0` is only an example, not an automatically selected default. Enable microphone
permission for the responsible Emacs/terminal application in macOS Privacy &
Security. Your FFmpeg build must expose `avfoundation` in `ffmpeg -devices`.

### Linux

Use the appropriate input backend compiled into your FFmpeg:

```elisp
;; PulseAudio / PipeWire PulseAudio compatibility:
(setq vox-audio-input '("-f" "pulse" "-i" "default"))
;; Or ALSA, after selecting the actual capture device:
(setq vox-audio-input '("-f" "alsa" "-i" "hw:0,0"))
```

### Windows

The picker uses DirectShow enumeration. For manual setup, use a reported audio
name or alternative identifier as a single argument:

```elisp
(setq vox-audio-input '("-f" "dshow" "-i" "audio=YOUR_DEVICE_NAME_OR_ID"))
```

Replace the placeholder with the exact identifier, preferably the reported
alternative name for duplicate friendly names. Do not add shell quotes around
its value inside the Lisp string. A friendly name containing a colon needs a
usable alternative identifier; the picker does not guess how to escape it.

### Synthetic development source

For an explicit, non-microphone source:

```elisp
(setq vox-audio-input
      '("-re" "-f" "lavfi" "-i" "sine=frequency=440:sample_rate=16000"))
```

Starting a **cloud** backend with that virtual source still sends audio to the
provider and can incur charges. Offline ERT tests use a local fake provider.

## Backends and models

Configuration follows the backend-object/model-selection pattern used by
[gptel](https://github.com/karthink/gptel), without depending on gptel or sharing
its HTTP protocols. API settings belong to a backend object, not a separate set
of provider globals:

```elisp
(setq vox-backend
      (vox-make-qwen "DashScope"
        :host "dashscope.aliyuncs.com"
        :endpoint "/api-ws/v1/realtime"
        :models '(qwen3-asr-flash-realtime)))
(setq vox-model 'qwen3-asr-flash-realtime)
```

`vox-backend` is configured in Lisp initialization code. It is a plain variable,
not a `defcustom`, so it no longer appears in Customize; `setq`,
`:custom (vox-backend 'qwen)`, and saved `custom-set-variables` forms still set it.
The constructors are pure: they do not connect, read keys, enumerate devices, or
modify files. `vox-model` accepts a symbol/string; nil uses the first model in
the backend's `:models` list. Run `M-x vox-select-model` to choose among those
configured IDs without querying a server or saving settings; it reports the
chosen model and keeps the choice in `vox-model-history`. An unlisted model is
rejected, not silently replaced. The list is an explicit allowlist, not proof
that your account can access each model. Configure only models supported by the
selected provider's realtime protocol.

Both constructors accept a display NAME, `:host`, `:endpoint`, `:models`, and
`:key`. Hosts are DNS names or IPv4 addresses with an optional port, without a
scheme or path. Endpoints are absolute paths, optionally with query parameters;
Vox always uses WSS. For Qwen the selected model replaces any existing `model`
query parameter, including on custom endpoints; it is never ignored just because
a custom endpoint is supplied. Doubao sends the selected ID in `model_name` and
also accepts the separate `:resource-id` entitlement/billing option.

Omit `:key` (or use nil) for the default auth-source/environment behavior below.
For a custom credential source, provide a zero-argument function, not a plaintext
key string. It is called only when connecting, after endpoint approval:

```elisp
(setq vox-backend
      (vox-make-qwen "Custom credential source"
        :key (lambda () (getenv "MY_ASR_KEY"))))
```

An explicit `:key` function replaces default credential lookup; it has no hidden
fallback. The result is checked for empty values and header control characters,
and callback errors are redacted. Do not capture a literal key in a saved lambda.
Backend/model configuration is copied before startup callbacks and the device
picker. Editing the original object or selecting another model affects the next
recording, not an active one. Canceling during credential acquisition tears down
the pending session without opening transport afterward.

**Direct migration:** remove uses of `vox-qwen-model`, `vox-qwen-endpoint`,
`vox-doubao-endpoint`, `vox-doubao-resource-id`, and
`vox-doubao-key-environment`. There are no compatibility aliases. Move their
settings into the constructor and `vox-model`; use a `:key` function for a custom
environment name. Update your init and restart Emacs rather than mixing old
loaded adapter definitions with the new configuration API. Audio-device,
silence-detection, language/VAD, and packet-size options are unchanged. The
self-recording CLI remains `(setq vox-backend 'cli)` and manages its own model.
Built-in `qwen`/`doubao` registry symbols still select factory defaults, but custom
API configuration uses objects.

## Credentials and regions

The [README API key setup](../README.md#api-key-configuration) includes a masked
prompt for the current Emacs session and a complete encrypted-file setup. Neither
method requires placing a real key in your Emacs configuration or repository.

Secrets resolve through `auth-source` first (host matching the endpoint, user
`apikey`), then the provider environment variable. Prefer an encrypted auth-source
file configured outside this repository. Example structure, **not real keys**:

```text
machine dashscope.aliyuncs.com login apikey password YOUR_KEY
machine dashscope-intl.aliyuncs.com login apikey password YOUR_KEY
machine openspeech.bytedance.com login apikey password YOUR_KEY
```

Keep only the entries for endpoints you use. When changing a stored entry, run
`M-x auth-source-forget-all-cached` before retrying; an existing auth-source key
takes priority over environment variables.

Alternatively provide `VOX_QWEN_API_KEY` or `VOX_DOUBAO_API_KEY` in the environment
that starts Emacs. Do not put real keys in shell history, source code, issues,
or command-line arguments. GUI Emacs may not inherit your terminal's environment.
There are no legacy-name aliases or automatic fallbacks. For a different
credential source, configure the backend's explicit `:key` function.

### Qwen

Qwen defaults to the Beijing public endpoint and model
`qwen3-asr-flash-realtime`. It is a VAD-only adapter. For Singapore:

```elisp
(setq vox-backend
      (vox-make-qwen "DashScope Singapore"
        :host "dashscope-intl.aliyuncs.com"
        :models '(qwen3-asr-flash-realtime))
      vox-model 'qwen3-asr-flash-realtime)
```

Confirm model availability, account permissions, region, and business-space
requirements in current provider documentation. Workspace-specific or otherwise
custom hosts require explicit confirmation for each connection; batch mode
rejects unapproved custom hosts. Only WSS is accepted; certificate and hostname
verification are not disabled.

### Doubao (experimental)

```elisp
(setq vox-backend
      (vox-make-doubao "SeedASR"
        :models '(bigmodel)
        :resource-id "volc.seedasr.sauc.duration")
      vox-model 'bigmodel
      vox-doubao-second-pass t
      vox-doubao-chunk-ms 200)
```

The resource ID must match your account's entitlement/billing mode. Doubao uses
the audited `bigmodel_async` binary framing, defaults to `model_name="bigmodel"`,
and accepts full snapshots only. It keeps one PCM frame for the final negative-sequence packet.
Python and Go examples are protocol references, not dependencies. The real
handshake, microphone stream, stored-block gzip acceptance, empty-audio finish,
and authoritative final response remain live integration checks.

## Interaction and safety

- `vox-toggle` starts when idle and stops when recording; during connection,
  draining, or finalizing it only reports status.
- `vox-stop` stops the recorder, waits for its sentinel, flushes valid PCM, sends
  provider finish once, and waits for authoritative completion. During connection
  it cancels.
- `vox-cancel` discards the transcript and tears down processes, connection,
  timers, markers, and preview. It never commits text.
- `vox-show-transcript` explicitly displays current/last in-memory text.
  Incomplete text is labeled **UNCONFIRMED**, never silently inserted on error.
- `vox-copy-confirmed-text` explicitly copies only confirmed/final text to the
  kill ring and possibly the system clipboard.
- `vox-forget-transcript` forgets the last session and removes the recovery buffer.

Preview is a throttled one-line overlay, not buffer text. Typing at the captured
insertion point moves its marker **after** your typing. Successful final text
inserts once at that marker with an undo boundary. Switching buffers does not
redirect insertion; killing the original buffer cancels. If you narrow the buffer
during recording, Vox temporarily widens for marker-based preview measurements
and final insertion, then restores the restriction and point. Text still lands
at the captured marker, even outside the currently visible region. Buffer and
text-property read-only protection remain in force; failed insertion retains
final text for manual recovery. Vox never presses Return or submits to an agent.

### Short-phrase silence detection

`vox-stop-mode` defaults to `silence` for Vox-owned PCM capture (Qwen and Doubao).
Press start once, speak, then pause. The detector uses 20 ms PCM16LE windows;
five consecutive above-threshold windows (100 ms) enable automatic stopping.
After that, `vox-silence-seconds` of below-threshold audio requests the same
graceful stop as `vox-stop`: recorder exit, PCM drain, provider finish, then
**authoritative completion before one insertion**. A quiet interval itself never
commits a transcript. Errors retain accepted text for explicit recovery.

```elisp
(setq vox-stop-mode 'silence
      vox-silence-seconds 1.2
      vox-silence-threshold 0.01)
```

- `vox-silence-seconds` accepts 0.2 through 10 seconds, rounded up to 20 ms windows.
  Increase it, for example to 2.0, if you pause while thinking. Provider response
  and capture-shutdown time are additional latency, not part of this interval.
- `vox-silence-threshold` is RMS relative to signed PCM16 full scale (32768),
  greater than zero and at most 1. The default 0.01 is about -40 dBFS. Lower it for
  quiet speech; raising it can ignore noise but can also mistake speech for quiet.
- This is **energy detection, not human-speech classification**. Fans, typing,
  microphone gain and short utterances can affect it. Initial silence does not
  arm it, and an utterance shorter than the arming interval may require manual
  stop. The existing maximum-session duration remains the safety limit.
- No incoming PCM does not count as silence. Detection consumes actual samples,
  checks the entire input callback, and accounts for new audio received during
  a reentrant send. It cannot foresee audio still buffered outside Emacs.
- Set `vox-stop-mode` to `manual` to bypass analysis entirely and keep recording
  until `vox-stop`/`vox-toggle` or the duration limit. Mode and thresholds are
  captured when the session starts. Cancel remains available in either mode.
- A self-recording backend such as CLI does not supply PCM to Vox, so its effective
  mode is always manual, shown in the recording status. Text-event arrival gaps
  are never treated as acoustic silence; the CLI protocol is unchanged.

Local stopping is separate from `vox-qwen-silence-ms`, which controls server-side
VAD segmentation. No provider turn-final or `utterances[].definite` flag is
reinterpreted as whole-session completion. `:stop-reason` in session statistics
is `silence` when the local detector requested the stop.

### Other interaction limits

| Option | Default | Purpose |
| --- | --- | --- |
| `vox-preview` | `t` | Enable the transient preview |
| `vox-preview-width` | `72` | Maximum preview display columns |
| `vox-preview-interval` | `0.1` | Minimum seconds between preview notifications |
| `vox-max-session-seconds` | `300` | Duration limit triggering graceful stop |
| `vox-connect-timeout` | `20` | Seconds allowed for backend readiness |
| `vox-stop-timeout` | `15` | Seconds allowed for drain and completion |
| `vox-audio-backlog-seconds` | `2` | PCM queue limit, configurable from 0.5 to 5 seconds |
| `vox-max-transcript-chars` | `200000` | Maximum live transcript characters |
| `vox-max-segments` | `1024` | Maximum distinct retained transcript segments, including empty ones |
| `vox-max-segment-id-bytes` | `1024` | Maximum bytes in one segment ID |
| `vox-max-segment-id-total-bytes` | `65536` | Maximum total bytes in distinct retained segment IDs |

Continuous cloud audio may incur charges. FFmpeg interruption can truncate the
last capture block. If the first interrupt does not stop capture, one guarded
retry runs after 0.5 seconds (`vox-audio-interrupt-retry-delay`); statistics record
`:audio-tail-risk`, and the default UI warns that tail audio may be truncated.
Forced cleanup or odd trailing PCM samples fail rather than pretend the stream
is lossless.

## Queueing, transport, and privacy limits

Core slices arbitrary binary process chunks into 100 ms frames (Qwen) or
100/200 ms frames (Doubao). Its bounded PCM queue fails on overflow without
silently dropping bytes. Each drain tick does bounded work; no extra sleep is
added to real-time capture.

Transcript limits also bound metadata: empty-text segments still consume the
segment-count and ID-byte budgets. Updating an existing ID does not charge it
again; an accepted full snapshot replaces the segment set and resets those
budgets. All four transcript/segment limits must be positive integers. An event
that would exceed a limit fails the session instead of silently dropping a
segment; previously accepted text remains available for explicit recovery.

`websocket.el` does not expose reliable socket buffered-byte counts, and Emacs
`process-send-string` can block on a slow peer. Vox bounds its own queues and
detects slow sends after they return; **this is not strict network backpressure
or a guarantee of a nonblocking socket write**. See the
[transport audit](transport-audit.md) for the narrowly scoped asynchronous
handshake compatibility shim and TLS requirements. No RFC 6455 encoder is
reimplemented.

No recording/transcript is written to disk by normal operation. Last-session
recovery is in memory; explicit copy/display is user initiated. Provider error
bodies and FFmpeg/CLI stderr are discarded rather than risking key, audio, or
transcript leakage. Errors are intentionally coarse. WebSocket debug logging is
suppressed for Vox-owned I/O, including the upstream filter. Do not enable
arbitrary debugger/packet tracing for production speech. The optional CLI is a
trusted external program and can implement its own logging or network behavior;
inspect it yourself.

Native gzip decoding checks encoded length, advertised size, and decoded size.
The native zlib call is not a streaming bounded-memory decompressor; it cannot
enforce a hard allocation cap during decompression of malicious compressed data.
Custom endpoints therefore remain a trust decision.

## Optional CLI backend

```elisp
(setq vox-backend 'cli
      vox-cli-command '("/absolute/path/to/your-streaming-asr" "--ndjson"))
```

The executable records its own audio, so Vox cannot perform local silence
detection for this backend. Its recording status explicitly says manual stop;
use `vox-stop` or `vox-toggle` to finish. It must speak UTF-8 NDJSON v1 on stdout:

```jsonl
{"v":1,"type":"started"}
{"v":1,"type":"partial","segment_id":"1","text":"candidate"}
{"v":1,"type":"final","segment_id":"1","text":"final transcript"}
{"v":1,"type":"completed"}
```

Vox writes `{"v":1,"type":"stop"}` plus newline to stdin for graceful stop, and
`{"v":1,"type":"cancel"}` for cancellation before teardown. `started` is required
before text. `partial` replaces the same segment; `final` confirms it. `completed`
is valid only after stop and must be followed by successful process exit;
nonzero exit, incomplete JSON, or exit without `completed` fails. Arbitrary
legacy CLIs are not automatically compatible. Lines are bounded by
`vox-cli-max-line-bytes`; stderr is never parsed as text.

## Embedding / composer boundary

Use `vox-start` with a sink, or `vox-core-start` with a nil sink for headless use:

```elisp
(vox-start
 'qwen
 (list :on-preview (lambda (session text status)
                     ;; Update your own transient display only.
                     (ignore session text status))
       :on-finish (lambda (session text)
                    ;; Use your integration's verified editable-input API.
                    ;; Use session target-buffer/target-marker, not current-buffer.
                    (ignore session text))
       :on-state (lambda (session state) (ignore session state))
       :on-error (lambda (session safe-error) (ignore session safe-error))))
```

Callbacks must be short and nonblocking. Exceptions stop the session safely.
A sink owns its display cleanup and read-only/edit-boundary checks. No dsh-emacs
files are modified and no Composer internals are assumed. `vox-register-backend`
registers a capability/method plist; see its docstring and the included adapters.
See [Architecture](architecture.md) for ownership boundaries.

## Troubleshooting

- Setup failure: check `vox-audio-input`, `executable-find`, installed `websocket`,
  native GnuTLS/zlib, auth-source host/user, key region, and model/resource entitlement.
- Capture failure: use device enumeration and OS microphone settings. Run a
  device-only FFmpeg check separately for raw diagnostics; Vox does not retain stderr.
- Stop timeout: a process or provider did not produce the required terminal event;
  no incomplete text is committed. Inspect recovery text explicitly, then restart.
- Backlog/send failure: stop and retry on a stable connection. Automatic reconnect
  is absent because it cannot reliably preserve audio context or deduplicate results.
- Read-only target: recover final text with `vox-show-transcript` or
  `vox-copy-confirmed-text`; Vox never bypasses read-only protection.
