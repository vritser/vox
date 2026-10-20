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

## Repository tooling refresh - 2026-10-20

Environment remains macOS arm64, Emacs 31.1.50 and FFmpeg 7.1.1. The nine runtime
modules and public commands are unchanged; the package descriptor only gains a
source-only compilation marker.

- `scripts/setup-deps.sh` verified the pinned cached SHA-256 without network I/O.
- `scripts/verify.sh` passed from outside the repository (`/tmp`) and through
  `scripts/package.sh`: 24 Lisp files checked, 11 checker self-tests, 4 runner
  self-tests, 9 strictly compiled runtime modules, dependency preflight, silent
  loading, whitespace and source-tree hygiene.
- Final product suite: **82 expected, 0 unexpected, 0 skipped** (1.328266 seconds).
- The gate first exposed an intermittent CLI fixture wait stuck in `finalizing`.
  An isolated run reproduced it. Waiting on all process events instead of only
  the exited stdout process fixes sentinel dispatch; 10 consecutive isolated
  runs passed without changing the timeout, assertions, or production code.
- Fresh package staging builds `dist/vox-0.1.0.tar` without Makefile, old bytecode,
  local dependencies, or the user's implementation specification. Versions are
  read from the main header and checked against the descriptor.
- A real `package-install-file` in a temporary, isolated `package-user-dir`
  installed the pinned websocket library and Vox, compiled all 9 runtime modules,
  and loaded `vox` without starting a session. The initial install exposed
  unwanted recursive compilation of development files. The descriptor, scripts
  and tests now carry standard `no-byte-compile` markers; the repeat installation
  has no compile errors or warnings and leaves development files source-only.
  The isolated installation is removed afterward; the user's Emacs setup is not
  modified.
- Current CI invokes the same gate on Emacs 28.1/29.4/30.2; those CI jobs have not
  been executed here. No microphone, credential store, or cloud endpoint was used.
- Authorized commit-message normalization retains every original commit tree,
  author/committer identity and timestamp. Original history is retained on
  `backup/pre-layout-20261020`; no push was performed.

The new benchmark entry `emacs -Q --batch -l scripts/benchmark.el` processed 6000
frames / 19,200,000 bytes: elapsed 0.295546 seconds, 21 GCs / 0.170659 GC seconds,
queue peak 3200 bytes. This is still an accelerated model, not real-time evidence.

## Acceptance boundary

Implemented and locally checked: independent `vox-*` package, asynchronous capture/setup, bounded PCM queue, fragment-safe transport, snapshot/segment replacement, preview-only partials, one final undoable insertion, captured-target ownership, stop/cancel distinction, late-event suppression, credential resolver/endpoint validation, CLI protocol, docs and source release target.

**Not claimed complete:**

- Qwen authenticated real-time speech and actual `session.finished` sequence.
- Doubao authenticated `bigmodel_async` acceptance of stored-block gzip, microphone stream, empty-audio finish, and authoritative final response. It remains **experimental**.
- Actual microphone permission/device validation, account region/resource entitlement, wrong-key/network-loss/silence live scenarios.
- Live TLS bad-certificate/hostname rejection (boot parameters are tested with a mocked native stream).
- Emacs 28.1/29.4/30.2 runtime results: the CI matrix is provided but has not run locally or on a remote CI service in this session.
- Strict socket backpressure or interruption of a blocked native write; the upstream API cannot provide these guarantees.
- Hard allocation limits inside native gzip decompression.

Tests are offline and fixtures are explicitly labeled. No test result here establishes cloud protocol acceptance, microphone permission, or live ASR accuracy.
