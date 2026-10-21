# Architecture

Vox is an independent Emacs package. Production modules stay at the repository
root; the development layout does not add a runtime dependency or change the API.

## Module ownership

| Module | Owns |
| --- | --- |
| [vox.el](../vox.el) | Public commands, `vox-select` pair completion and reentry checks, explicit transcript recovery |
| [vox-backend.el](../vox-backend.el) | Backend objects/factories, `vox-backends` directory and `vox-selection` resolution, registration/contracts, JSON helpers, lazy credentials, endpoint validation |
| [vox-core.el](../vox-core.el) | Session lifecycle, callback generations, transcript reconciliation, PCM queue/chunker, automatic stop requests, completion and cleanup |
| [vox-log.el](../vox-log.el) | Opt-in bounded event metadata, strict safe-field schema, in-memory snapshots and explicit clearing |
| [vox-activity.el](../vox-activity.el) | Pure bounded PCM energy analysis, 20 ms windows, speech arming and quiet-duration eligibility; no timers, I/O, or transcript decisions |
| [vox-device.el](../vox-device.el) | On-demand bounded FFmpeg listings, platform parsers, explicit minibuffer input selection and opt-in persistence |
| [vox-audio.el](../vox-audio.el) | FFmpeg capture process, binary PCM delivery, stop-to-sentinel handling |
| [vox-transport.el](../vox-transport.el) | Guarded WebSocket I/O, fragments, message limits, TLS and asynchronous-handshake compatibility |
| [vox-backend-qwen.el](../vox-backend-qwen.el) | Qwen VAD configuration, provider messages, normalized recognition events |
| [vox-backend-doubao.el](../vox-backend-doubao.el) | Experimental Doubao binary/gzip protocol, snapshot events, final packet |
| [vox-backend-cli.el](../vox-backend-cli.el) | Trusted external process, NDJSON v1 framing and explicit completion/exit contract |
| [vox-ui.el](../vox-ui.el) | Preview overlay and captured-buffer sink, read-only checks, one undoable insertion |
| [vox-reload.el](../vox-reload.el) | Idle-only source reload, dependency/read preflight, keymap refresh and mode-line cache invalidation |
| [vox-pkg.el](../vox-pkg.el) | Emacs package descriptor |

## Boundaries

```text
public commands -> session core -> backend contract -> provider / CLI
                         |
                         +-> audio capture -> bounded PCM queue -> provider
                         |
                         +-> sink callbacks -> preview / final insertion
```

- Core owns lifecycle and transcript state, not provider-specific wire branches
  or buffer insertion. Session generations reject stale callbacks. Transcript
  characters, segment count and retained ID bytes have independent budgets;
  empty segments do not bypass metadata limits.
- Backends translate wire events into normalized data. They never insert into
  user buffers. Cloud adapters use the shared transport; the CLI owns its process.
- Activity analysis retains only bounded numeric state and at most one pending
  byte, not PCM chunks. Core checks the queue limit first, analyzes a whole PCM
  callback, then rechecks eligibility after sending to account for reentrant
  speech/cancellation. A silence verdict only requests the existing graceful
  stop path; it is never authoritative completion. Self-recording CLI stays manual.
- Audio capture supplies binary PCM and a terminal process signal. A stop request
  is not proof that capture ended; core drains before dispatching finish once.
  One per-session pump owns all sends and finish across reentrant callbacks.
  Nested capture can queue bytes but cannot start a second send; cancellation
  cannot block a newer session behind an old session's unwinding pump.
- Transport consumes incoming callbacks in arrival order, including when pong
  writes dispatch nested input or terminal process notifications. A close cannot
  overtake bytes already received. Its retained-input FIFO has separate byte and
  callback-count limits, in addition to upstream frame/message bounds. Backends
  must not restore state after a yielding write may have cleaned their session.
- Sinks own display and insertion. The default sink uses the captured buffer and
  marker, not the callback's current buffer or narrowing boundary. It temporarily
  widens for marker operations and restores the user's restriction. Point follows
  final text only if still at the insertion marker; otherwise it is preserved.
  Custom sinks enforce their own editability boundaries and cleanup.
- Authoritative completion permits one final insertion. Cancellation, socket
  closure, and process exit alone cannot turn a partial transcript into success.
- Device selection runs before interactive startup only when input is unset.
  It never guesses an input, touches a recognizer, or persists settings without
  an explicit save request. Startup captures its target buffer/marker and backend
  before completion, then rechecks ownership/editability afterward. Programmatic
  startup and self-recording CLI do not prompt for devices.
- `vox-selection` is the sole next-session choice: nil resolves the first directory
  entry/model, a name/model pair resolves exactly, and a registered protocol symbol
  resolves that backend with no model choice. Directory names are unique and a
  malformed entry blocks every resolution. Explicit backend/core APIs bypass this
  selection. Completion validates snapshots and rejects reentrant configuration
  changes without overwriting newer choices; it never connects or reads credentials.
- Backend factories are pure configuration construction. Core captures a detached
  backend object and selected model in method metadata before state callbacks;
  public startup also snapshots them before the device picker. Key functions stay
  lazy and their returned secrets are never cached in those objects. Adapters
  approve the captured endpoint before resolving credentials, recheck session
  ownership after approval/key callbacks, and capture the initial provider request
  before asynchronous transport opening. Model selection affects future sessions.
- Loading Vox is silent and does not start capture or connect. Backend registration
  is package setup, not permission to send audio.
- Source reload refuses active ownership, pending startup and device interaction.
  Core/public startup and device discovery refuse reentry while reload is active.
  Exact source loads preserve settings, session generations and retained history;
  they do not migrate structures, unload definitions, or restart sessions.
- Event logging is disabled by default. Its input boundary accepts fixed event
  names/enums and bounded integers only, never raw provider data, text, PCM,
  credentials or configuration strings. A bounded ring stores memory-only lines;
  showing it creates a snapshot buffer. Audio progress is sampled by byte count,
  and cleanup summaries capture per-session totals at teardown. A send returning
  after reentrant teardown is separately logged with its terminal state.
- CLI stdout callbacks and terminal notifications share a per-session bounded
  FIFO. A nested callback cannot overtake earlier lines or overwrite a partial
  line. Startup rechecks session ownership after callable backend options, before
  allocating another session.

Use the existing owner before adding a module or wrapper. Keep the public
`vox-*` API stable when reorganizing tools or tests. Embedding examples and the
CLI contract are in [Customization](customization.md#embedding--composer-boundary).

## Development layout

- `test/vox-test.el`: batch runner only.
- `test/vox-test-<subsystem>.el`: subsystem ERT cases.
- `test/vox-test-support.el`: shared test macros and load-path setup.
- `test/fixtures/`: explicitly sourced fixtures, not fabricated live recordings.
- `scripts/`: verification, static checks, compilation, benchmark, dependency
  setup, and packaging; not production modules.
- `docs/`: user/developer guides and evidence-bearing audits.

See [Development](development.md) for the common local/CI gate and commands,
and [fixture provenance](../test/fixtures/README.md) for fixture boundaries.

## Evidence and limits

Architecture describes ownership, not a claim of successful live recognition.
Qwen's authenticated flow remains unvalidated; Doubao is experimental. FFmpeg
interruption can truncate capture tails. Bounded PCM queues cannot prevent a
native socket write from blocking, and native gzip decompression has no hard
in-call allocation cap. Preserve the distinctions in the
[protocol audit](protocol-audit.md) and [transport audit](transport-audit.md).
