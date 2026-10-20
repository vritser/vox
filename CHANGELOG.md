# Changelog

## 0.1.0 - Unreleased

### Added

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
  key is visible in the initialization file and `C-h v vox-backend`.
  (rationale: [postmortem 004](postmortems/004-key-sources.md)).

- **Backend objects and model selection (breaking configuration change):**
  `vox-make-qwen` / `vox-make-doubao` group host, endpoint, available models,
  deferred key source and provider resource options. `vox-backend` selects the
  object; `vox-model` or `vox-select-model` chooses a configured model. The former
  provider API/model globals are removed without aliases; `vox-backend` itself is
  now a plain variable rather than a Customize option, though `setq`, `:custom`,
  and saved settings still apply it. Configuration is
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
  remains manual, with the effective mode shown in recording status
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

### Fixed

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
  source-only; package.el compiles the nine runtime modules without trying to
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
