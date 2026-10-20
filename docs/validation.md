# Validation ledger

## P0 / P1 - 2026-10-20

- Environment: macOS arm64, GNU Emacs 31.1.50 (2026-10-19 build), FFmpeg 7.1.1.
- FFmpeg advertises avfoundation and lavfi input. No microphone was opened.
- Clean `emacs -Q` has no websocket library. Audited upstream library is downloaded to ignored `.deps/`, not vendored into the package.
- Initial repository had no commits and only the user-provided specification.
- Core/backend/UI/CLI files compile with warnings treated as errors on the local Emacs.
- First 16 core/security/UI ERT tests pass, including undo, reentrant completion latch, stale callbacks, buffer switching, read-only output, and kill-buffer cleanup.
- Emacs 31 `with-temp-buffer` inhibits buffer hooks; kill-buffer regression uses a normal generated buffer instead.
- Pending: provider and transport tests, real virtual-audio process, compatibility CI, performance regression, authenticated provider handshakes and microphone recognition.
- No API credentials read or cloud recognition attempted in this phase.

## Integrated P2-P7 - 2026-10-20

`make check` completed successfully on Emacs 31.1.50:

- All nine implementation files compiled with warnings treated as errors.
- **82 ERT tests passed, zero failures and zero skips** (5.108 seconds in the recorded full run).
- Coverage includes Core, PCM queue/chunker, Qwen, Doubao, CLI, UI, and upstream-backed WebSocket transport.
- Real local FFmpeg lavfi capture and stop-to-sentinel tests passed. No microphone was used. This FFmpeg build required one bounded second SIGINT; the implementation records tail-loss risk and the default UI warns about it.
- Real synthetic CLI processes verified explicit completion plus zero exit, nonzero exit rejection, and exit-alone rejection.
- Independent review reproduced and fixed premature reentrant completion and cancelled CLI-tail retention. Dedicated regressions now cover both.
- Package loading under `emacs -Q -L .` succeeds without websocket on the load path, without creating a session or opening audio/network.
- Only environment-variable presence was checked: `DASHSCOPE_API_KEY` and `DOUBAO_API_KEY` were absent. No user auth-source store was inspected for this audit.

`make benchmark` processed 6000 synthetic 100 ms frames / 19,200,000 PCM bytes:

| Metric | Recorded result |
| --- | --- |
| Simulated audio duration | 600 seconds |
| Accelerated elapsed time | 0.160999 seconds |
| GC count | 19 |
| GC time | 0.126764 seconds |
| Core PCM queue peak | 3200 bytes |
| Queue after cleanup | 0 bytes |

These numbers are one local accelerated run, not a wall-clock latency, CPU-utilization, microphone, network, or UI-responsiveness measurement. The benchmark checks exact frame/byte counts, one commit, and cleaned resources. UI scheduling and a real ten-minute recording remain manual acceptance items.

## Acceptance boundary

Implemented and locally checked: independent `vox-*` package, asynchronous capture/setup, bounded PCM queue, fragment-safe transport, snapshot/segment replacement, preview-only partials, one final undoable insertion, captured-target ownership, stop/cancel distinction, late-event suppression, credential resolver/endpoint validation, CLI protocol, docs and source release target.

**Not claimed complete:**

- Qwen authenticated real-time speech and actual `session.finished` sequence.
- Doubao authenticated `bigmodel_async` acceptance of stored-block gzip, microphone stream, empty-audio finish, and authoritative final response. It remains **experimental**.
- Actual microphone permission/device validation, account region/resource entitlement, wrong-key/network-loss/silence live scenarios.
- Live TLS bad-certificate/hostname rejection (boot parameters are tested with a mocked native stream).
- Emacs 28.2/29.4/30.2 runtime results: the CI matrix is provided but has not run locally or on a remote CI service in this session.
- Strict socket backpressure or interruption of a blocked native write; the upstream API cannot provide these guarantees.
- Hard allocation limits inside native gzip decompression.

Tests are offline and fixtures are explicitly labeled. No test result here establishes cloud protocol acceptance, microphone permission, or live ASR accuracy.
