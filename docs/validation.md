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

Tests are offline and fixtures are explicitly labeled. No test result here establishes cloud protocol acceptance, microphone permission, or live ASR accuracy.
