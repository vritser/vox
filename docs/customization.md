# Customization

See the [quick start](../README.md#quick-start) for loading Vox. Options belong to
`M-x customize-group RET vox RET`; transport options also have a `vox-transport`
group. Cloud recognition is not live-validated; Doubao remains experimental.
For optional text-to-speech, see [speech output](speech-output.md); its backend
selection and voices are independent of recognition.

## Example configuration

Install directly from Git with `use-package :vc`:

```elisp
(use-package vox
  :vc (:url "https://github.com/vritser/vox" :rev :newest)
  :demand t
  :config
  (setq vox-backends
        (list
         (vox-make-qwen "DashScope"
           :key "YOUR_DASHSCOPE_API_KEY"
           :host "dashscope.aliyuncs.com"
           :asr '(:models (qwen3-asr-flash-realtime)
                  :language nil)) ; Auto-detect, or use "zh" / "en".
         (vox-make-doubao "SeedASR"
           :key "YOUR_DOUBAO_API_KEY"
           :host "openspeech.bytedance.com"
           :asr '(:models (bigmodel)
                  :resource-id "volc.seedasr.sauc.duration")))
        ;; Default backend/model; use M-x vox-asr-select to switch later.
        vox-asr-selection '("DashScope" qwen3-asr-flash-realtime)))
```

Replace the key for your selected backend; you can remove the unused entry.
For Doubao, select `("SeedASR" bigmodel)` and check that the resource ID matches
your enabled service. Literal keys are visible in your configuration and
`C-h v vox-backends`; never commit them. For persistent use, prefer `:key nil`
for auth-source or a key function; see [credentials](#credentials-and-regions).
Loading the package does not start recording or contact a provider.

Install `websocket` through your normal Emacs package manager. Do not add `.deps`
to your normal load path unless intentionally using the audited development copy.
The CLI backend needs neither FFmpeg nor WebSocket at runtime when it captures
its own audio.

## Recognition language

Set recognition language when constructing each Qwen backend:
`(vox-make-qwen NAME :asr (list :language STRING-OR-NIL))`.
For task streaming, add `:protocol 'qwen-audio` inside the ASR plist.
Nil or an omitted `:language` means automatic detection: Vox omits the hint.
Realtime sends `input_audio_transcription.language` in `session.update`;
task-streaming sends a one-element `parameters.language_hints` array in `run-task`.
A string requests a language supported by the selected Qwen model. Codes use
ASCII letters, optionally followed by hyphen-separated alphanumeric subtags;
local syntax validation does not establish model support. For example, keep
automatic, English, and Chinese configurations together:

```elisp
(setq vox-backends
      (list (vox-make-qwen "Qwen Auto" :asr '(:language nil))
            (vox-make-qwen "Qwen English" :asr '(:language "en"))
            (vox-make-qwen "Qwen Chinese" :asr '(:language "zh"))))
(setq vox-asr-selection '("Qwen Auto" qwen3-asr-flash-realtime))
;; Select another configuration for the next recording:
;; (setq vox-asr-selection '("Qwen English" qwen3-asr-flash-realtime))
;; Or select Chinese:
;; (setq vox-asr-selection '("Qwen Chinese" qwen3-asr-flash-realtime))
```

The commented selection assignments are alternatives; choose one, or use the
existing `M-x vox-asr-select` backend/model picker. `(vox-make-qwen "Qwen Auto")` is equivalent
to the explicit nil example. Each backend has its own independent language; no
global language setting is consulted. Codes are passed through to Qwen; supported
languages and recognition quality depend on the selected model.

Language strings are copied with backend configuration into the startup/session
snapshot before device prompting or credential callbacks. Changing a backend,
mutating its original language string, or selecting another backend affects a
later recording, not the startup/session already using that snapshot.

**Migration:** remove `vox-qwen-language` from your init file and saved Customize
settings; the global variable is removed without an alias or compatibility
fallback. Put explicit language inside the relevant `:asr` plist, or omit it
for automatic detection. Restart Emacs after migrating configuration objects;
`vox-reload` does not migrate existing structs or remove old definitions.

This constructor option is Qwen-specific. It does not add language support to
Doubao or change the CLI contract; configure a self-recording CLI's language
through that program's own options.

## Choose an audio device

Run `M-x vox-select-input-device` to discover supported audio inputs. Exactly one
result is selected automatically without minibuffer completion; with multiple
results, choose a device in the minibuffer and press Return. Vox does not choose
an arbitrary first device from multiple results. If `vox-audio-input` is nil, the
first **interactive** `vox-start` or `vox-toggle` uses the same selection rule for
Vox-owned capture before connecting to a recognizer. Existing non-nil input
configurations are not replaced on startup. No supported inputs or a discovery
error still fails without changing the input or starting recognition. Cancel
ongoing discovery or a multiple-device prompt with `C-g` to abort startup.

A normal selection, including automatic selection of one input, changes
`vox-audio-input` for the current Emacs session only. Use
`C-u M-x vox-select-input-device` to save that option through Customize, using
your configured `custom-file` or Emacs init file. Saving is explicit even for one
input; discovery and ordinary selection do not edit configuration files. First
interactive startup never requests persistence. Stop or cancel an active Vox
session before choosing a different input.

| System | Enumerated inputs | Requirements / limitations |
| --- | --- | --- |
| macOS | AVFoundation audio devices, excluding video-only entries | FFmpeg AVFoundation support; numeric indices may change after hardware changes |
| Windows | DirectShow audio devices | FFmpeg DirectShow support; reported alternative identifiers distinguish duplicate names |
| GNU/Linux | PulseAudio sources, including PipeWire's PulseAudio compatibility service | FFmpeg PulseAudio support and a reachable server; sources may include system-audio monitors |

Rerun the picker after changing devices. Saving an AVFoundation index does not
make it a stable physical-device identity. Known PulseAudio monitor sources are
labelled as system audio; even a sole automatically selected input may be a
system-audio monitor, not a microphone.
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
needed. No recognizer is contacted until first-start input selection succeeds,
whether automatically or through completion.

Noninteractive/programmatic `vox-start` and headless `vox-core-start` do not
discover or auto-select inputs or open a picker; configure their input explicitly.
The self-recording CLI backend has its own device handling and does not use this
picker automatically. The manual
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

`vox-backends` is the shared directory of named service configurations. Each
service has optional `:asr` and `:tts` capabilities. Top-level `:host` and `:key`
are defaults; the corresponding capability can override either. Omitted `:key`
inherits; an explicit `:key nil` requests auth-source for the effective host.

```elisp
(setq vox-backends
      (list
       (vox-make-qwen "DashScope"
         :key (lambda () (getenv "DASHSCOPE_API_KEY"))
         :asr '(:models (qwen3-asr-flash-realtime) :language nil)
         :tts '(:models (qwen3-tts-flash-realtime) :voice "Cherry"))
       (vox-make-doubao "Doubao"
         :asr '(:resource-id "volc.seedasr.sauc.duration")
         :tts '(:resource-id "seed-tts-2.0"
                :voice "zh_female_vv_uranus_bigtts"))))
(setq vox-asr-selection '("DashScope" qwen3-asr-flash-realtime)
      vox-tts-selection '("Doubao" seed-tts-2.0))
```

Qwen and Doubao enable default ASR when `:asr` is omitted; add `:tts t` or a
TTS plist to enable output. `:asr nil` disables input. `vox-make-cli` requires explicit capability plists
with independent `:command` argv lists. A service must enable at least one
capability. Nil disables a capability, t enables its defaults, and a plist
specifies its options. Unknown, duplicate or protocol-inapplicable options fail.

`vox-asr-selection` and `vox-tts-selection` are independent `(NAME MODEL)` choices.
Nil selects the first service supporting that direction and its first model;
`(NAME nil)` selects the named capability's first model. CLI capabilities have
no model and use `(NAME nil)`. Doubao TTS selects its resource ID. Selecting a
service without the requested capability is an error, never a fallback.

`M-x vox-asr-select` and `M-x vox-tts-select` offer only the matching capabilities.
Names and model IDs are case-sensitive. Selection reads no keys, opens no device
or connection, and does not persist configuration. A changed configuration or
newer picker supersedes a pending prompt. Reordering the shared directory changes
nil defaults; explicit names continue to select their named services.

Names are unique across the whole directory, including ASR-only and TTS-only
entries. Every entry and both of its capabilities are validated before directory
selection, so an invalid unused capability must also be fixed. The directory
contains configuration, not a registry of wire protocols. Models are a local
allowlist, not remote discovery or evidence of service access.

### Capability options

| Protocol | Direction | Options beyond `:host`, `:key` and `:endpoint` |
| --- | --- | --- |
| `qwen` | ASR | `:models`, `:language` |
| `qwen-audio` | ASR | `:models`, `:language` |
| `doubao` | ASR | `:models`, `:resource-id` |
| `tts-qwen-realtime` | TTS | `:models`, `:voice` |
| `tts-doubao-ws` | TTS | `:resource-id`, `:voice` |
| `cli`, `tts-cli` | ASR / TTS | `:command` only; no network configuration or model |

The constructor supplies the default `:protocol`. For Qwen task streaming, use
`:asr '(:protocol qwen-audio)`. Model IDs alone never switch protocols. Recognition
and API speech output use WSS. Qwen TTS defaults to `tts-qwen-realtime` with
`qwen3-tts-flash-realtime`; Doubao defaults to `tts-doubao-ws`. Only bidirectional
TTS protocols are supported. Region-specific services can override `:host` and `:key`
within either capability. For example:

```elisp
(vox-make-qwen "Split regions"
  :key (lambda () (getenv "SHARED_KEY"))
  :asr t
  :tts '(:host "dashscope-intl.aliyuncs.com" :key nil))
```

The TTS side above uses auth-source for its own host, without calling the shared
key function. A literal key string is also accepted, but remains visible in the
init file, `C-h v vox-backends`, and backtraces; use auth-source or a key function
for persistent configuration. Nothing reads environment variables implicitly.
Endpoint approval precedes key lookup, and cancellation during lookup prevents
connection. Key-function failures and raw provider errors are redacted.

### Programmatic use and migration

```elisp
(vox-start provider sink model) ; selects its ASR capability
(vox-speak "Hello" provider model) ; selects its TTS capability
(vox-core-start provider sink buffer marker model)
(vox-backend-capability provider 'asr) ; detached runtime connection record
```

The constructors return `vox-provider` objects containing shared defaults and
capability plists. Runtime adapters still receive `vox-backend` connection records.
Snapshots detach both capability plists and the selected connection before
callbacks; later mutation cannot change an active session. Explicit calls do not
consult either global selection. Extensions may still pass resolved connection
records or use the ASR protocol registry. Registered `qwen`, `qwen-audio`, `doubao`
and `cli` symbols remain ASR shortcuts; `cli` uses the existing `vox-cli-command`
setting and is also offered by the ASR picker.

**Migration:** rename `vox-selection` to `vox-asr-selection`, `vox-select` to
`vox-asr-select`, and `vox-selection-history` to `vox-asr-selection-history`.
Move constructor `:endpoint`, `:models`, `:language` and `:resource-id` options into
`:asr`. Replace `vox-make-qwen-audio` with `vox-make-qwen` and
`:asr '(:protocol qwen-audio ...)`. Replace the preliminary `vox-tts-backends` and
`vox-make-tts-*` setup with the shared directory and each service's `:tts` options.
Named TTS CLIs replace `vox-tts-cli-command` and the TTS `cli` selection symbol.
There are no aliases for these removed names. Update your init and restart Emacs;
`vox-reload` does not migrate existing configuration objects or struct layouts.

Older `vox-backend`/`vox-model` globals, `vox-select-model`, provider model/endpoint
variables and `vox-qwen-language` remain removed. Their values belong in the
shared directory, capability plists and per-direction selection. Recording
commands, audio-device configuration, silence detection, VAD and packet sizes
are unchanged. See [speech output](speech-output.md) for TTS playback and limits.

## Credentials and regions

`:key nil` reads `auth-source` for the host matching the endpoint, using user
`apikey`. Prefer an encrypted auth-source file outside this repository. Configure
its location in Emacs:

```elisp
(require 'auth-source)
(add-to-list 'auth-sources "~/.authinfo.gpg")
```

Open that file in Emacs and save the relevant entries encrypted with Emacs/GnuPG
(a working GnuPG setup is required). Example structure, **not real keys**:

```text
machine dashscope.aliyuncs.com login apikey password YOUR_KEY
machine dashscope-intl.aliyuncs.com login apikey password YOUR_KEY
machine openspeech.bytedance.com login apikey password YOUR_KEY
```

Keep only the entries for endpoints you use. When changing a stored entry, run
`M-x auth-source-forget-all-cached` before retrying.

Vox does not read `VOX_QWEN_API_KEY`, `VOX_DOUBAO_API_KEY`, or any other
environment variable itself. A `:key` function makes such a lookup explicit:
`(lambda () (getenv "MY_ASR_KEY"))`. Do not put real keys in shell history,
source code, issues, or command-line arguments. GUI Emacs may not inherit your
terminal's environment.

### Qwen

Qwen Realtime defaults to the Beijing public endpoint and model
`qwen3-asr-flash-realtime`. It is a VAD-only adapter. For Singapore:

```elisp
(setq vox-backends
      (list (vox-make-qwen "DashScope Singapore"
              :host "dashscope-intl.aliyuncs.com"
              :asr '(:models (qwen3-asr-flash-realtime))))
      vox-asr-selection '("DashScope Singapore" qwen3-asr-flash-realtime))
```

Confirm model availability, account permissions, region, and business-space
requirements in current provider documentation. Workspace-specific or otherwise
custom hosts require explicit confirmation for each connection; batch mode
rejects unapproved custom hosts. Only WSS is accepted; certificate and hostname
verification are not disabled.

### Qwen Audio task-streaming

Use `vox-make-qwen` with `:asr '(:protocol qwen-audio)`; the registered
ASR protocol is `qwen-audio`. This names the ASR task-streaming adapter, not every Qwen Audio
API.

```elisp
(setq vox-backends
      (list (vox-make-qwen "Qwen Audio 3.0"
              :asr '(:protocol qwen-audio
                     :models (qwen-audio-3.0-asr-flash-streaming)
                     :language nil)))
      vox-asr-selection '("Qwen Audio 3.0" qwen-audio-3.0-asr-flash-streaming))
```

This example uses auth-source for `dashscope.aliyuncs.com` (login `apikey`).
Use `:host "dashscope-intl.aliyuncs.com"` with Singapore credentials, or a
complete workspace-specific hostname from the
[official WebSocket guide](https://help.aliyun.com/zh/model-studio/qwen-audio-asr-streaming-websocket-api).
Workspace hosts still require per-connection confirmation; Vox does not expand
`{WorkspaceId}` or trust arbitrary subdomains. The endpoint defaults to
`/api-ws/v1/inference`; there is no `model` query parameter added by Vox.
The example replaces the directory; add this object alongside your existing
backends instead if you want to switch between them with `M-x vox-asr-select`.

Recording starts after `task-started`. Stop drains PCM, sends `finish-task` once,
and waits for `task-finished` before inserting. Per-sentence revisions replace
their earlier preview; final sentences cannot be overwritten by late events.
If the task ends while a sentence is still provisional, Vox fails without
inserting; use explicit transcript recovery rather than treating that text as
confirmed. No-sentence completion inserts no text. Cancel closes without finish.

`vox-qwen-audio-silence-ms` controls server sentence segmentation (default
800 ms, range 200-6000), not local silence-stop timing. `:language "en"` or
`"zh"` sends one language hint; nil keeps automatic detection. Context injection,
hotwords, multiple simultaneous hints, and other advanced provider parameters
are not exposed. Authenticated recognition and microphone behavior remain
unverified; see the [dated protocol addendum](protocol-audit.md#qwen-task-streaming-addendum-2026-10-22).

### Doubao (experimental)

```elisp
(setq vox-backends
      (list (vox-make-doubao "SeedASR"
              :asr '(:models (bigmodel)
                     :resource-id "volc.seedasr.sauc.duration")))
      vox-asr-selection '("SeedASR" bigmodel)
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

Preview is a throttled overlay in the shadow face, without added brackets
or spacing, not buffer text. It carries the whole hypothesis on one logical line
without Vox-imposed width truncation; newlines, carriage returns, and tabs become
spaces. Emacs display settings determine wrapping and clipping, and a preview
may extend beyond the visible window. Typing at the captured insertion point moves its
marker **after** your typing. Successful final text inserts once at that marker
with an undo boundary. If point is still at the marker, it advances to the end
of the inserted text; if you moved it elsewhere, Vox preserves that position.
Switching buffers does not redirect insertion; killing the original buffer
cancels. If you narrow the buffer during recording, Vox temporarily widens for
marker-based final insertion, then restores the restriction. Text still lands at
the captured marker, even outside the currently
visible region, without moving point from elsewhere in the buffer. Buffer and
text-property read-only protection remain in force; failed insertion retains
final text for manual recovery. Vox never presses Return or submits to an agent.

A persistent microphone icon is appended to `global-mode-string`, so it sits at
the end of the mode line. Clicking it starts or stops recording. While a
session is connecting, recording, draining, or finalizing, the target buffer's
icon animates four sound-wave phases pulsing outward on both sides; other
buffers show a static active icon. Animation uses the optional `motion-line`
package; without it, the icon stays on one static sound-wave frame. A one-cell
glyph is used when the display cannot render SVG. The icon inherits the state
face color. Set `vox-mode-line` to nil to hide it; `vox-mode-line-icon` changes
the fallback glyph.

Routine lifecycle transitions do not print messages or repeat recording
instructions. Empty recognition and failures still report an actionable message;
possible recorder tail truncation is reported once at completion. These messages
do not depend on `vox-event-log-enabled`, which controls only the opt-in memory
log viewed with `vox-show-event-log`. Explicit command feedback, such as invoking
`vox-toggle` while finalizing, is unchanged.

To place the icon somewhere else, remove `vox-mode-line-construct` from
`global-mode-string` and insert it into your own `mode-line-format`.  For the
default mode line, this puts it at the front:

```elisp
(with-eval-after-load 'vox
  (setq global-mode-string
        (remove vox-mode-line-construct global-mode-string))
  (setq-default mode-line-format
                (cons vox-mode-line-construct
                      (default-value 'mode-line-format))))
```

`doom-modeline` already renders `global-mode-string` in its right-hand misc
segment, so the default end placement works there without extra setup.  To put
the icon somewhere else in `doom-modeline`, register the construct through its
own segment or layout API instead of editing `mode-line-format`.

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
- The interval is counted in delivered 20 ms PCM windows, not a wall-clock
  `run-at-time` timer; a stalled capture cannot advance it. About 100 ms of
  above-threshold activity (five windows) arms detection. A short noise burst,
  such as a Bluetooth pop, can arm it, and a following 1.2 s of quiet can stop
  before you speak; conversely, steady noise above the threshold prevents the
  quiet interval from accumulating. For noisy input, use manual mode or tune
  `vox-silence-threshold` and `vox-silence-seconds`.
- No incoming PCM does not count as silence. Detection consumes actual samples,
  checks the entire input callback, and accounts for new audio received during
  a reentrant send. It cannot foresee audio still buffered outside Emacs.
- Set `vox-stop-mode` to `manual` to bypass analysis entirely and keep recording
  until `vox-stop`/`vox-toggle` or the duration limit. Mode and thresholds are
  captured when the session starts. Cancel remains available in either mode.
- A self-recording backend such as CLI does not supply PCM to Vox, so its effective
  mode is always manual. Text-event arrival gaps
  are never treated as acoustic silence; the CLI protocol is unchanged.

Local stopping is separate from `vox-qwen-silence-ms` (Realtime) and
`vox-qwen-audio-silence-ms` (task-streaming), which control server-side
VAD segmentation. No provider turn-final or `utterances[].definite` flag is
reinterpreted as whole-session completion. `:stop-reason` in session statistics
is `silence` when the local detector requested the stop.

A successful provider completion with no transcript now reports "no speech
recognized" instead of a generic completed status. That usually means the capture
delivered silence, not that a later session lost its state. Bluetooth headsets
are a common cause: the first capture negotiates the HFP microphone profile, and
an immediate second capture can receive a silent stream while macOS renegotiates.
Select a wired or USB microphone with `vox-select-input-device`, or reconnect the
headset before retrying. `vox-show-transcript` still distinguishes confirmed text
from an unconfirmed hypothesis; it cannot create text the provider did not return.

### Other interaction limits

| Option | Default | Purpose |
| --- | --- | --- |
| `vox-preview` | `t` | Enable the transient preview |
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
`:audio-tail-risk`, and the default UI warns once on successful completion that
tail audio may be truncated, combining this with the empty-recognition message
when needed. Failed sessions retain their recovery message instead.
Forced cleanup or odd trailing PCM samples fail rather than pretend the stream
is lossless.

## Queueing, transport, and privacy limits

Core slices arbitrary binary process chunks into 100 ms frames (Qwen) or
100/200 ms frames (Doubao). Its bounded PCM queue fails on overflow without
silently dropping bytes. Each drain tick does bounded work; no extra sleep is
added to real-time capture. Nested callbacks may enqueue audio but cannot send
another frame or finish until the current send returns. Quitting an in-progress
PCM send cancels the recording because delivery of that frame is uncertain.

Incoming WebSocket callbacks are consumed in arrival order even when writes
reenter the event loop. `vox-transport-max-retained-input-bytes` defaults to
2 MiB; `vox-transport-max-retained-input-chunks` defaults to 1024 active/queued
callbacks, including deferred terminal process notifications. A close notification
cannot overtake already-received input. Both limits must be positive integers.
An active callback retains its full
byte charge until consumed, even after some frames are dispatched. These limits
are separate from the 1 MiB message limit and can reject a large coalesced read
of individually legal messages. Exceeding either bound fails the session rather
than dropping or reordering input; empty input does not consume queue entries.

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
(setq vox-backends
      (list (vox-make-cli "Local"
              :asr '(:command ("/absolute/path/to/your-streaming-asr" "--ndjson"))
              :tts '(:command ("/absolute/path/to/your-tts" "--stdout"))))
      vox-asr-selection '("Local" nil)
      vox-tts-selection '("Local" nil))
```

The ASR executable records its own audio, so Vox cannot perform local silence
detection for this backend. Use `vox-stop` or `vox-toggle` to finish manually.
It must speak UTF-8 NDJSON v1 on stdout:

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
Reentrant stdout and terminal callbacks are consumed in arrival order.
`vox-cli-max-retained-input-bytes` (2 MiB) and
`vox-cli-max-retained-input-chunks` (1024) separately bound active/queued
callbacks. An oversized coalesced callback can therefore fail even if each
individual line fits; queued data is discarded on cancellation or failure.

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

### Self-check

Run `M-x vox-doctor` before changing configuration or reporting a setup problem.
It opens and selects a memory-only `*Vox doctor*` buffer with one line per check
plus an optional hint: Emacs version, `websocket`, native GnuTLS and zlib, the FFmpeg
executable, `vox-backends` and `vox-asr-selection` validity, endpoint trust, the
credential-source kind, `vox-audio-input` shape, effective stop mode, numeric
limits, session state and the event-log setting. `FAIL` means the selected path
cannot work as configured; `WARN` is advisory; `SKIP` means the item was
deliberately not probed. The report ends with a pass/fail summary.

Seven `TTS-*` checks also report the selected service/model and voice, player
argv/executable, synthesis CLI argv/executable, WSS host/port trust, credential
source, text/audio/response/time limits, and synthesis/playback state. They use
the same selection and limit validation as speech startup. A direction with no
configured capability and no explicit selection is `SKIP`, so ASR-only and
TTS-only setups are valid. An explicit missing service or invalid model is `FAIL`.
Existing ASR result IDs are unchanged; TTS IDs are `tts-selection`, `tts-player`,
`tts-cli`, `tts-endpoint`, `tts-key`, `tts-limits`, and `tts-session`.

The command is read-only. It never calls a `:key` function, reads auth-source,
opens a microphone, lists audio devices, contacts a provider, or writes a file.
It does not play sound, run a synthesis CLI, or print command arguments. Finding
a player executable does not prove stdin compatibility, working audio routing,
or audible output. It cannot prove that credentials are accepted, that a
voice/resource is available, or that live recognition works; those remain
acceptance checks. A literal key is reported as
`WARN` without printing its value. A custom endpoint is also `WARN` regardless
of reachability, because every connection still needs explicit approval.

Device discovery remains an explicit `M-x vox-select-input-device` action: it
can trigger native permission prompts and is not a readiness proof. For
scripted checks, `vox-doctor-check` returns the same results as plists with
`:id`, `:status`, `:summary`, and an optional `:hint`.

### Event log for repeated recordings

Run `M-x vox-toggle-event-log` before reproducing a problem across two or more
recordings, then `M-x vox-show-event-log`. The `*Vox events*` buffer is a
chronological snapshot; run the show command again to refresh it. Each `g=NUMBER`
identifies one local session, including callbacks rejected from older sessions.
Use `M-x vox-toggle-event-log` again to disable logging and
`M-x vox-clear-event-log` to discard retained events and clear the display.

You can also enable it with `(setq vox-event-log-enabled t)`. Logging defaults
to off, keeps at most `vox-event-log-max-entries` events (1000 by default, capped
at 10000), and writes no files. Oldest events are evicted when full. Disabling
logging retains the existing log for inspection; clearing does not disable it.
Enable before starting the first round to capture the full sequence.

The log records lifecycle events, sampled PCM byte counts, stop reasons,
FFmpeg exit status/retry risk, recognition event kinds and text lengths. For
Qwen it also records the fixed server VAD events `speech-start` / `speech-stop`
and readiness. These map to the documented
[Qwen server events](https://help.aliyun.com/zh/model-studio/qwen-asr-realtime-server-events).
It never records PCM, transcripts, provider error messages, item IDs, device
names, backend/model configuration strings, URLs or credentials.

| Evidence in one generation | What it establishes |
| --- | --- |
| `start` without `ready` / `audio-start` | Recording has not reached a ready provider and running recorder; inspect timeout/error events |
| `cleanup received=0` | Core received no PCM in this round |
| `audio-receive` / `audio-send` | First block and approximately each second of PCM; `sent` means accepted by the adapter, not confirmed remote delivery |
| `provider-event kind=speech-start` | Qwen reported speech activity; absence alone does not prove a silent microphone |
| `finish-dispatch queued=0` | The local queue was drained before requesting provider completion |
| `complete chars=0` | Authoritative completion yielded no text; this is not proof of stale state or silent audio |
| `audio-retry tail-risk=t` | FFmpeg needed a second interrupt and tail truncation is possible |
| `cleanup queued=0 received=... sent=...` | Local cleanup completed; counts at that moment belong only to this generation |
| `stale-callback` | A callback from a former session was rejected |

Counts cannot establish what was spoken or whether captured audio contains
speech. `received` counts PCM delivered by the recorder even when a backlog check
rejected that chunk after receipt; it is not the number admitted to the send
queue. Repeated-call tests use distinct synthetic PCM and text; microphone,
provider accuracy and real network timing require separate live acceptance.
An in-progress adapter send can dispatch cancellation before returning. Its
later `audio-send state=cancelled` (or another terminal state) records that
earlier call returning, not a new send after cleanup. The earlier cleanup
summary cannot include a send that had not yet returned.
The previous transcript retained for explicit recovery is never input to a new
session. No connection or provider conversation is reused across recordings.

### Other failures

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
