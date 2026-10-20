# Architecture

Vox is an independent Emacs package. Production modules stay at the repository
root; the development layout does not add a runtime dependency or change the API.

## Module ownership

| Module | Owns |
| --- | --- |
| [vox.el](../vox.el) | Public commands, default backend, explicit transcript recovery |
| [vox-backend.el](../vox-backend.el) | Backend registration/contracts, JSON helpers, credentials, endpoint validation |
| [vox-core.el](../vox-core.el) | Session lifecycle, callback generations, transcript reconciliation, PCM queue/chunker, automatic stop requests, completion and cleanup |
| [vox-activity.el](../vox-activity.el) | Pure bounded PCM energy analysis, 20 ms windows, speech arming and quiet-duration eligibility; no timers, I/O, or transcript decisions |
| [vox-audio.el](../vox-audio.el) | FFmpeg capture process, binary PCM delivery, stop-to-sentinel handling |
| [vox-transport.el](../vox-transport.el) | Guarded WebSocket I/O, fragments, message limits, TLS and asynchronous-handshake compatibility |
| [vox-backend-qwen.el](../vox-backend-qwen.el) | Qwen VAD configuration, provider messages, normalized recognition events |
| [vox-backend-doubao.el](../vox-backend-doubao.el) | Experimental Doubao binary/gzip protocol, snapshot events, final packet |
| [vox-backend-cli.el](../vox-backend-cli.el) | Trusted external process, NDJSON v1 framing and explicit completion/exit contract |
| [vox-ui.el](../vox-ui.el) | Preview overlay and captured-buffer sink, read-only checks, one undoable insertion |
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
- Sinks own display and insertion. The default sink uses the captured buffer and
  marker, not the callback's current buffer or narrowing boundary. It temporarily
  widens for marker operations and restores the user's restriction and point.
  Custom sinks enforce their own editability boundaries and cleanup.
- Authoritative completion permits one final insertion. Cancellation, socket
  closure, and process exit alone cannot turn a partial transcript into success.
- Loading Vox is silent and does not start capture or connect. Backend registration
  is package setup, not permission to send audio.

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
[protocol audit](protocol-audit.md), [transport audit](transport-audit.md), and
[validation ledger](validation.md).
