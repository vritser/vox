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

## Correctness hardening - 2026-10-20

All three reported failures were reproduced offline before their fixes. The
shared `scripts/verify.sh` gate now passes with 25 checked Lisp files, 11 checker
self-tests, 4 runner self-tests, and 9 strictly compiled runtime modules.

The final product run reports **106 expected, 0 unexpected, 0 skipped**
(2.325412 seconds), including 24 new regressions:

- Three UI tests cover captured markers on either side of a narrowed region,
  preserved restriction/point/mark, one undoable insertion, preview columns and
  overlay position, and hidden read-only text with recoverable final output.
- Ten transport tests cover every split of two coalesced frames, large batches,
  handshake/data transitions, preserved wire limits, independent control-frame
  budgets, byte-split masked frames, and reentrant close before later input.
- Eleven resource-limit tests cover empty-text floods, UTF-8 ID byte counts,
  exact count/byte/text boundaries, repeated IDs, snapshot reset/stale snapshots,
  rejection before mutating recovery text, terminal recovery/cancellation,
  invalid configuration, and Qwen final-item cleanup at overflow.

Default metadata limits are 1024 retained segments, 1024 bytes per ID, and 65536
ID bytes in total. Ordered-list traversal is now bounded by that segment cap;
this change does not claim constant-time lookup or remove all repeated text
assembly. Transport probes and then reuses the upstream filter, so its extra
bounded parsing/copying cost is explicit rather than a claim of zero overhead.

The accelerated 600-second model still sends 6000 frames / 19,200,000 bytes:
0.270313 seconds elapsed, 19 GCs / 0.145528 GC seconds, queue peak 3200 bytes.
These are local synthetic measurements, not wall-clock capture or network data.
No live cloud, microphone, credential-store, or multi-version CI test was run;
this repair makes no new claims about those acceptance boundaries.

## 2026-10-20 short-phrase automatic stop

The default Vox-owned Qwen/Doubao capture path now requests graceful stop after
local energy silence. `scripts/verify.sh` passed: syntax for 28 Lisp files,
tooling/runner self-tests, strict compilation of 10 runtime modules, dependency
checks, the product suite, silent loading, whitespace, and source-tree hygiene.
A separate full ERT run reported **144 passed, 0 unexpected, 0 skipped** in
3.273001 seconds on the same local Emacs 31.1.50 environment.

New coverage comprises 19 pure detector tests and 17 lifecycle/UI tests:

- Fixed 20 ms RMS windows, 100 ms arming, exact/rounded quiet thresholds, initial
  silence, clicks, resumed speech, signed PCM, odd-byte cuts, partial windows,
  tiny positive thresholds, independent state, and bounded counters/storage.
- Automatic drain without early insertion, valid capture tails, the default
  1.2-second interval spanning the eight-frame send budget, and one finish only.
- Whole-callback analysis and post-send rechecking when sends reenter with new
  speech, cancellation, or failure; old-session callbacks cannot stop a new one.
- Manual bypass, explicit self-recording-backend fallback, captured settings,
  validation before connection, queue overflow before analysis, error recovery,
  and the effective recording-mode message.

All audio here is synthetic. This is energy detection, not speech classification;
noise can delay stopping and low-volume speech/pauses can cause early stopping.
Real microphone threshold calibration, cloud finalization latency, and other
Emacs versions remain unverified. No actual credential store, microphone, or
cloud recognizer was accessed for this change.

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
