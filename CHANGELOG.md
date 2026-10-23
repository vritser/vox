# Changelog

## 0.1.0 - Unreleased

### Added

- **Bidirectional TTS only:** Qwen defaults to Realtime (`tts-qwen-realtime`,
  `qwen3-tts-flash-realtime`), alongside Doubao WSS and streaming CLI input/output.
  `vox-speak-open`, `vox-speak-send` and `vox-speak-finish` accept producer text
  while audio plays. Stop drops queued text/audio and closes the source; provider
  cancellation is best effort and accepted text may still be billed. The preliminary
  OpenAI TTS, Qwen HTTP and Doubao SSE adapters, `vox-make-openai`, and the HTTP
  transport are removed. Migrate Qwen models/endpoints and restart Emacs
  (rationale: [postmortem 022](postmortems/022-bidirectional-only-speech-output.md);
  earlier text-input decision: [021](postmortems/021-incremental-speech-text-input.md)).

- **Streaming playback:** Qwen PCM, Doubao MP3 and CLI output feed one persistent
  player through a bounded queue. Replacement speech and recording startup stop
  output; authoritative synthesis completion, queue drain and successful player
  exit remain required. Late failures stop playback but cannot withdraw audio
  already heard. Separate synthesis/playback timeouts and queue limits apply
  (rationale: [postmortem 020](postmortems/020-streaming-speech-playback.md),
  superseded for protocols by [022](postmortems/022-bidirectional-only-speech-output.md)).

- **TTS self-check:** `vox-doctor` now reports speech-output selection, voice,
  player/CLI executable availability, WSS destination trust, credential-source
  kind, limits and session state. Unconfigured directions are skipped; explicit
  invalid selections fail. Checks never resolve credentials, run a CLI, contact
  a provider or play audio; executable availability is not audible-playback
  acceptance (rationale: [postmortem 019](postmortems/019-speech-output-self-check.md)).

- **Shared ASR/TTS configuration (breaking):** `vox-backends` now holds service
  configurations with shared `:host`/`:key` defaults and separate `:asr`/`:tts`
  capability plists. Each capability can override host/key and owns its protocol,
  endpoint, models and options. `vox-make-cli` supports distinct ASR/TTS commands.
  `vox-asr-selection` / `vox-tts-selection` and `vox-asr-select` / `vox-tts-select`
  choose independently from the same directory. Move old constructor options into
  `:asr`, use `:protocol qwen-audio` instead of `vox-make-qwen-audio`, and replace
  the preliminary TTS constructors/directory with shared services. Restart Emacs
  after migration; no aliases or live-object migration are provided (rationale:
  [postmortem 018](postmortems/018-shared-speech-service-configuration.md)).

- **Speech output through APIs and CLI:** `vox-speak`, `vox-speak-stop` and
  `vox-tts-select` add optional speech output with Qwen Realtime
  and Doubao adapters, plus a streaming UTF-8 stdin / encoded-audio stdout CLI.
  Audio is bounded and played from memory (now bidirectional; see 022 above). Recording
  stops speech output; cancellation disposes requests and playback processes.
  Provider acceptance and physical playback remain unverified (rationale:
  [postmortem 017](postmortems/017-api-and-cli-speech-output.md)).

- **Qwen Audio task-streaming:** `vox-make-qwen-audio` adds native support
  for `qwen-audio-3.0-asr-flash-streaming` using DashScope `run-task`, binary PCM,
  and `finish-task` on `/api-ws/v1/inference`. Language hints, named selection,
  lazy credentials, source reload, and diagnostics use the existing interfaces.
  Only matching `task-finished` after local finish and finalized sentences permits
  insertion; cancellation or an unfinished tail never promotes partial text.
  The existing Qwen Realtime backend and default selection remain unchanged.
  Validation is offline, not authenticated provider acceptance (rationale:
  [postmortem 015](postmortems/015-qwen-task-streaming.md)).

- **Read-only self-check:** `M-x vox-doctor` reports Emacs/websocket/GnuTLS/zlib
  availability, the FFmpeg executable, `vox-backends` and `vox-selection`
  validity, endpoint trust, credential-source kind, input shape, effective stop
  mode, numeric limits, session state and event-log setting in a memory-only
  `*Vox doctor*` buffer. It resolves no credential, opens no microphone or
  device listing, attempts no connection and writes no file; device discovery
  stays an explicit `vox-select-input-device` action because it may prompt for
  permissions. `vox-doctor-check` returns the same checks as plists for
  programmatic use (rationale:
  [postmortem 014](postmortems/014-read-only-doctor.md)).

- **Idle source reload:** `M-x vox-reload` reloads local Vox `.el` modules in
  dependency order without restarting Emacs or using stale bytecode. Settings,
  selection, custom backend names, the last transcript and event log survive;
  keymap defaults and mode-line caches refresh without changing icon placement.
  Active sessions, pending startup and device/minibuffer interactions must finish
  first. Source-read/dependency failures precede evaluation; evaluation errors
  can leave partial updates, and struct changes still require an Emacs restart
  (rationale: [postmortem 011](postmortems/011-idle-source-reload.md)).

- **Unified backend/model selection (breaking):** `vox-backends` is the named
  candidate directory, defaulting to Qwen. `vox-selection` is the single choice:
  nil uses the first backend/model, `(NAME nil)` uses that backend's first model,
  `(NAME MODEL)` selects an allowed symbol/string model, and a registered
  protocol symbol such as `cli`, `qwen`, `doubao`, or an extension selects that
  backend without a model choice. `vox-select` shows directory pairs in one
  offline completion list. Missing names, unregistered symbols, duplicate names,
  invalid models, and stale prompts fail without fallback or overwriting newer
  choices; one malformed directory entry blocks every directory selection until
  it is fixed. Active sessions retain their snapshots. The old `vox-backend` /
  `vox-model` variables and the `vox-select-model` picker with
  `vox-model-history` are removed; the backend struct/accessors remain. Explicit
  backend/core calls default to their backend's first model and accept an
  explicit model argument independently of global selection
  (rationale: [postmortem 008](postmortems/008-unified-selection.md)).

- **Clickable mode-line icon:** a persistent microphone icon at the end of the
  mode line starts or stops recording with a mouse click. Vox appends
  `vox-mode-line-construct` to `global-mode-string`; insert that construct into
  your own `mode-line-format` to place the icon elsewhere. While connecting,
  recording, draining, or finalizing, the target buffer's icon pulses four
  sound-wave phases; other buffers show a static active icon. Animation uses the
  optional `motion-line` package; without it the icon stays on one static
  sound-wave frame. A one-cell glyph is used when Emacs cannot render SVG. The
  icon inherits the state face color. Customize `vox-mode-line` and
  `vox-mode-line-icon`.

- **Opt-in event diagnostics:** `vox-toggle-event-log`, `vox-show-event-log` and
  `vox-clear-event-log` expose bounded, memory-only metadata for comparing
  recording rounds. Logs distinguish session generations, PCM counts, Qwen VAD
  activity, stop reasons, empty completion and recorder tail risk, without audio,
  text, configuration strings or credentials
  (rationale: [postmortem 006](postmortems/006-session-event-diagnostics.md)).

- **Historical decision records:** the [postmortem record set and template](postmortems/)
  preserve the rationale for silence stopping, explicit device selection, and
  backend/model configuration. Contributor rules cover when to write a record,
  evidence links, and supersession without rewriting historical conclusions.

- **Optional coverage report:** `scripts/check-coverage.el` instruments production
  modules with testcover, runs the offline suite, and lists definitions below 80%
  coverage. It is diagnostic and stays outside `scripts/verify.sh`.

- **Simpler credential sources (breaking):** `:key` accepts nil, a literal key
  string, or a zero-argument function. nil reads `auth-source` for the connecting
  host and no longer falls back to `VOX_QWEN_API_KEY` / `VOX_DOUBAO_API_KEY`; Vox
  reads no environment variables itself, and `vox-secret` is removed. Use
  `:key (lambda () (getenv "..."))` to keep an environment lookup explicit.
  `vox-api-key-from-auth-source` remains for an explicit host or user. A literal
  key is visible in the initialization file and `C-h v vox-backends`.
  (rationale: [postmortem 004](postmortems/004-key-sources.md)).

- **Backend objects and model selection (breaking configuration change):**
  `vox-make-qwen` / `vox-make-doubao` group host, endpoint, available models,
  deferred key source and provider resource options. Objects now live in
  `vox-backends`; `vox-selection` and `vox-select` choose a backend/model pair.
  Former provider API/model globals are removed without aliases. Configuration is
  captured per session and before device prompting; custom Qwen URLs honor the
  selected model. Endpoint approval precedes key lookup, and cancellation during
  approval or key callbacks cannot open a stale connection. See the migration
  instructions in [Customization](docs/customization.md#backends-and-models)
  (rationale: [postmortem 003](postmortems/003-backend-objects-and-model-selection.md)).

- **Minibuffer input selection:** `vox-select-input-device` enumerates FFmpeg
  AVFoundation, DirectShow, or PulseAudio inputs and requires an explicit choice.
  First interactive start prompts only when input is unset; existing argv,
  headless startup, and CLI behavior stay explicit. Prefix `C-u` opts into
  Customize persistence. Discovery has a bounded timeout/output, safe cleanup,
  and no raw-listing logging; startup preserves its original insertion target
  and backend across the prompt. Failed or canceled saves restore Customize
  metadata so later saves cannot persist the rejected selection.
  Real-device enumeration remains unvalidated
  (rationale: [postmortem 002](postmortems/002-explicit-input-device-selection.md)).

- **Native streaming speech input:** independent Emacs 28.1+ package with Qwen
  VAD, experimental Doubao, and an optional UTF-8 NDJSON v1 CLI backend. No
  Python, Node, local ASR bridge, or dsh-emacs runtime dependency is required.
- **Safe editing lifecycle:** transient preview, captured insertion target,
  authoritative final text inserted once with an undo boundary, separate
  stop/cancel commands, and explicit in-memory transcript recovery.
- **Bounded audio handling:** FFmpeg PCM capture, frame slicing, queue limits,
  timeout/cleanup handling, and capture-tail warnings after a second interrupt.
- **Guarded provider access:** auth-source/environment credentials, WSS endpoint
  validation, guarded WebSocket transport, and normalized backend events.
- **Offline development checks:** ERT coverage, synthetic capture/CLI checks,
  fixtures with provenance, and an accelerated PCM benchmark. These do not
  establish authenticated cloud or microphone acceptance.

### Changed

- **Untruncated preview (breaking):** the recording preview overlay now carries
  the entire hypothesis on one logical line instead of clipping it to a measured
  column width. Whitespace normalization remains unchanged; Emacs display settings
  determine wrapping and visibility. `vox-preview-width` is removed because it
  only bounded that clipping; `vox-preview` and `vox-preview-interval` are
  unchanged. The preview remains read-only, adds no buffer text, and does not
  change the single authoritative insertion (rationale:
  [postmortem 016](postmortems/016-full-preview-layout.md)).

- **Single-input auto-selection:** `M-x vox-select-input-device` selects exactly
  one discovered supported input without minibuffer completion; first interactive
  startup does the same for Vox-owned capture when input is unset. Multiple
  inputs still prompt, and zero-input/discovery failures are unchanged. Startup
  preserves configured input, headless and CLI behavior stays unchanged, and only
  explicit `C-u M-x vox-select-input-device` requests persistence. A sole input
  can be system audio rather than a microphone
  (rationale: [postmortem 013](postmortems/013-single-input-auto-selection.md)).

- **Simpler README:** lead with a one-sentence introduction and a `use-package`
  Git installation setup without key bindings, mirrored in the customization
  guide. Use `:demand t` and editable backend examples with key placeholders,
  hosts, endpoints, models, Qwen language, and the Doubao resource ID. Keep basic
  usage on the front page and link to dedicated guides for detailed configuration
  and validation status.

- **Per-backend Qwen language (breaking):** configure
  `(vox-make-qwen NAME :language STRING-OR-NIL)`; nil or omission uses automatic
  detection instead of the former Chinese default. Each Qwen backend keeps an
  independent language, copied into startup/session configuration before device
  or credential callbacks. `vox-qwen-language` is removed without compatibility
  fallback. Move explicit settings into constructors and restart Emacs: the new
  `vox-backend` struct field cannot be migrated with `vox-reload`. Doubao and CLI
  language support are unchanged
  ([configuration](docs/customization.md#recognition-language),
  [rationale](postmortems/012-automatic-recognition-language.md)).

- **Quiet routine operation:** lifecycle transitions and repeated recording
  instructions no longer print messages. The mode-line indicator remains active;
  opt-in event logging remains independent. Empty recognition and failure recovery
  still produce actionable messages, and recorder tail-risk warnings appear only
  once at completion rather than during both finalizing and completion
  (rationale: [postmortem 010](postmortems/010-quiet-lifecycle-messages.md)).

- **Empty-recognition diagnostic:** a successful provider completion with no
  transcript now reports "no speech recognized" and points at the input device
  instead of claiming a generic completed status. This distinguishes a silent
  capture from a second-session state failure; it does not add speech detection.

- **Short-phrase capture by default:** Qwen and Doubao recordings stop gracefully
  after 1.2 seconds of local PCM quiet, once 100 ms of consecutive active windows
  arms detection. Configure `vox-stop-mode`, `vox-silence-seconds`, and
  `vox-silence-threshold`; manual mode bypasses analysis. The bounded energy
  detector does not classify human speech, and initial silence does not arm it.
  Authoritative completion still gates one final insertion. Self-recording CLI
  remains manual
  (rationale: [postmortem 001](postmortems/001-short-phrase-silence-stop.md)).

- **Namespaced credential environment:** Qwen reads `VOX_QWEN_API_KEY` and
  Doubao defaults to `VOX_DOUBAO_API_KEY`. The previous environment names have
  no aliases or automatic fallback; `auth-source` remains the first choice.

- **API key setup on the README:** direct masked-input and encrypted auth-source
  examples, provider/region host mappings, credential precedence, cache reset,
  and GUI Emacs environment guidance replace a link-only setup step.

- **One verification entry point:** `scripts/verify.sh` replaces Makefile-based
  checks with static syntax validation, tool self-tests, strict temporary-directory
  compilation, full ERT, silent loading, and diff/junk checks. CI calls the same gate.
- **Focused test layout:** `test/vox-test.el` is the runner;
  `test/vox-test-<subsystem>.el` owns cases and `test/vox-test-support.el` owns
  shared helpers. The benchmark moves to `scripts/benchmark.el`; production
  modules remain at the root without public API changes.
- **Scripted packaging and dependencies:** `scripts/package.sh` derives
  `dist/vox-VERSION.tar` from the version in [vox.el](vox.el), and
  `scripts/setup-deps.sh` downloads the pinned, SHA-256-verified audited WebSocket
  dependency into `.deps`.
- **Navigable documentation:** a shorter [README](README.md) links to
  [Customization](docs/customization.md), [Development](docs/development.md),
  and a lightweight [module ownership map](docs/architecture.md).
- **Commit conventions:** short English `<type>: verb + single topic` subjects
  use standard Conventional Commit types. Commits require an explicit request;
  authorized history rewording preserves trees and a backup, without implying
  permission to push.
- **CI Emacs builds:** CI installs pinned nixpkgs Emacs builds with native zlib
  and GnuTLS instead of the minimal nix-emacs-ci binaries, which omitted zlib.
  The test runner also normalizes Emacs 28's direct-debugger assertion for an
  unknown test name.

### Fixed

- **TTS text privacy:** interactive speech reads text in the command body so
  Emacs does not retain it as an argument in `command-history`. Minibuffer
  history remains disabled, and active-region speech uses the same protection.

- **Inline recognition and cursor placement:** previews no longer add square
  brackets or a leading space. After final insertion, point follows the text
  when it is still at the captured insertion marker; a point moved elsewhere
  stays there. Preview remains transient and final insertion remains one undo
  step.

- **Doubao metadata-only ready response:** a successful `bigmodel_async` full
  response may contain only `result.additions` metadata (for example `log_id`)
  and no `text`. Vox now treats it as readiness and emits no snapshot instead of
  failing the session with a generic WebSocket error
  (rationale: [postmortem 009](postmortems/009-doubao-metadata-ready.md)).

- **CI runner notices:** use the Node.js 24-based `actions/checkout@v6` and
  pin the runner to Ubuntu 24.04, avoiding the checkout runtime deprecation
  and automatic `ubuntu-latest` migration to Ubuntu 26.04.

- **Mode-line SVG caching:** reuse the image returned by `create-image` while
  its color is unchanged, without requiring `imagep`. This keeps the icon
  within the supported Emacs 28.1+ API surface.
  The batch runner also lets older ERT versions record optional-test skips and
  failures without aborting the remaining suite.

- **Cross-version verification and stderr isolation:** the strict compile gate
  no longer forces `.el` suffixes for Emacs's own libraries, which recursively
  loaded `jka-compr` on compressed installations. Stderr pipes now detach their
  buffer explicitly, because Emacs 30 and older use the process name when
  `:buffer` is nil.

- **Lifecycle cleanup edges:** a failing Doubao final snapshot callback can no
  longer restore cleared adapter state; CLI startup reclaims its process and
  stderr pipe if a startup callback cleans the session; a callable `:chunk-ms`
  cannot retarget the captured buffer or insertion point; and finishing cancels
  an armed backlog timer. Offline regressions cover each path.

- **Remaining reentrant lifecycle boundaries:** callable backend options can no
  longer overwrite a session started during configuration. CLI callbacks and
  terminal notifications are consumed in arrival order, preserving partial
  lines and completion across nested input, with bounded retained callbacks.
  Multi-round offline regressions cover completion, cancellation and failure,
  stale Qwen socket callbacks, reused item IDs and distinct PCM. These findings
  do not establish the cause of a particular live Qwen recognition error.

- **Reentrant stream ordering:** PCM sends and finish now have one owner per
  session, preventing nested sends, duplicated tails, premature finish, and
  work-budget bypass. WebSocket receive callbacks are consumed in arrival order
  so pong writes cannot reorder messages or invalidate otherwise legal fragments,
  and terminal notifications cannot overtake already-received bytes. Retained
  input has independent byte and callback-count bounds; overload and interrupted
  input processing fail safely. Quitting a PCM send cancels instead of continuing
  with an uncertain frame. Doubao no longer restores retained PCM after
  cancellation during a write
  (rationale: [postmortem 005](postmortems/005-reentrant-stream-ordering.md)).
  These defects were reproduced offline; a live recognition-accuracy improvement
  has not been established.

- **Captured positions survive narrowing:** preview measurements and final
  insertion use the real marker, then restore the user's restriction and point.
  Read-only text outside the visible region still fails safely with recovery.
- **TCP chunking does not change WebSocket acceptance:** legal coalesced messages
  and a handshake followed by data are fed to the upstream parser incrementally;
  incomplete-frame, message and fragment limits remain enforced.
- **Transcript metadata is bounded:** separate segment-count, per-ID byte and
  total-ID byte budgets reject excessive metadata, including empty-text segments,
  before retaining it. Previously accepted transcript text remains recoverable.

- **CLI fixture completion:** integration tests service the whole event loop so
  an exited stdout process cannot starve its final sentinel notification.
- **Clean package installation:** descriptor and development helpers remain
  source-only; package.el compiles the runtime modules without trying to
  compile test fixtures or command-line tools.

### Known limitations

- **No live-cloud acceptance claim:** Qwen authenticated recognition is unvalidated;
  Doubao remains experimental pending real handshake, microphone stream, gzip,
  no-audio finish, and authoritative-final checks.
- **Transport and capture limits remain:** native writes may block despite bounded
  queues; native gzip decoding has no hard allocation cap during decompression;
  FFmpeg interruption may truncate the final capture block.
- **Measurements remain scoped:** earlier test counts are historical, not current
  run counts. Accelerated benchmark figures do not measure wall-clock
  capture/network/UI responsiveness. See the
  [manual acceptance checklist](docs/development.md#benchmark-and-acceptance).
