# Changelog

## 0.1.0 - Unreleased

### Added

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

- **Short-phrase capture by default:** Qwen and Doubao recordings stop gracefully
  after 1.2 seconds of local PCM quiet, once 100 ms of consecutive active windows
  arms detection. Configure `vox-stop-mode`, `vox-silence-seconds`, and
  `vox-silence-threshold`; manual mode bypasses analysis. The bounded energy
  detector does not classify human speech, and initial silence does not arm it.
  Authoritative completion still gates one final insertion. Self-recording CLI
  remains manual, with the effective mode shown in recording status.

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
- **Measurements remain scoped:** the earlier 82-test result is historical,
  not a new run count. Accelerated benchmark figures do not measure wall-clock
  capture/network/UI responsiveness. See the [validation ledger](docs/validation.md)
  and [manual acceptance checklist](docs/development.md#benchmark-and-acceptance).
