# Vox

Independent, native Emacs streaming speech input. Vox previews recognition at
point and inserts authoritative final text once, with an undo boundary. It never
presses Return or submits to an agent. No Python, Node, local ASR bridge, or
dsh-emacs dependency is required.

**Status: 0.1.0 pre-release.** Offline and synthetic-process checks exist;
authenticated cloud recognition has **not** been validated. Qwen is VAD-only;
**Doubao is experimental** until its real handshake, microphone stream, and final
packet are verified. A socket close is not successful recognition.

## Quick start

1. Use Emacs 28.1+ and install `websocket` through your Emacs package manager
   (1.15/1.16-compatible API). Cloud backends need native GnuTLS and FFmpeg with
   an input backend supported by your OS; Doubao also needs native zlib.
2. Add the checkout to your configuration:

   ```elisp
   (add-to-list 'load-path "/path/to/vox")
   (require 'vox)
   (global-set-key (kbd "C-c v") #'vox-toggle)
   (global-set-key (kbd "C-c C-v") #'vox-cancel)
   ```

3. [Select an audio device](docs/customization.md#choose-an-audio-device).
   `vox-audio-input` must be an explicit FFmpeg argv list; Vox does not guess
   microphone numbers. Grant microphone permission to the responsible app.
4. [Configure credentials and region](docs/customization.md#credentials-and-regions)
   for Qwen (default) or experimental Doubao. Starting a cloud session sends
   audio to the provider and may incur charges. An
   [optional CLI backend](docs/customization.md#optional-cli-backend) can instead
   capture its own audio.
5. In an editable buffer, press `C-c v` to start and again to stop. Wait for
   authoritative completion before treating the text as final; `C-c C-v`
   cancels without insertion.

A [use-package example](docs/customization.md#example-configuration) and all
setup details are in the customization guide.

## Keys and commands

The keys below are suggestions installed by the configuration above, not global
bindings enabled when Vox loads.

| Key / command | Action |
| --- | --- |
| `C-c v` / `M-x vox-toggle` | Start when idle, stop when recording; otherwise report status |
| `C-c C-v` / `M-x vox-cancel` | Discard the session without inserting text |
| `M-x vox-start` / `M-x vox-stop` | Explicit start / graceful stop; stop while connecting cancels |
| `M-x vox-show-transcript` | Display current/last in-memory text; unfinished text is UNCONFIRMED |
| `M-x vox-copy-confirmed-text` | Explicitly copy confirmed/final text to the kill ring |
| `M-x vox-forget-transcript` | Forget the last session and remove the recovery buffer |

Preview is an overlay, not buffer text. Switching buffers does not redirect the
captured insertion target; read-only protection is never bypassed. The default
duration limit is 300 seconds. Normal operation does not write audio or
transcripts to disk. See [interaction and safety](docs/customization.md#interaction-and-safety)
for recovery, capture-tail risks, and privacy details.

**Transport limits:** queues are bounded, but native socket writes can block;
native gzip decoding cannot enforce a hard allocation cap during decompression.
See [transport and privacy limits](docs/customization.md#queueing-transport-and-privacy-limits).

## Documentation

- [Customization](docs/customization.md): devices, credentials, providers,
  limits, CLI protocol, embedding, and troubleshooting.
- [Development](docs/development.md): verification, tests, packaging, commit
  conventions, and manual acceptance.
- [Architecture](docs/architecture.md): module ownership and boundaries.
- [Protocol audit](docs/protocol-audit.md), [transport audit](docs/transport-audit.md),
  and [fixture provenance](test/fixtures/README.md): evidence and open questions.
- [Validation ledger](docs/validation.md): recorded results, not live-cloud acceptance.
- [Changelog](CHANGELOG.md): unreleased changes.

## Contributing

Keep changes focused and follow [AGENTS.md](AGENTS.md). Run
`scripts/setup-deps.sh` to obtain the pinned, checksum-verified development
WebSocket dependency, then `scripts/verify.sh`. CI uses the same verification
entry point. See [Development](docs/development.md) for individual commands and
short English Conventional Commit subjects. Commit only when explicitly asked;
do not infer permission to push.

Vox is licensed under [GPL-3.0-or-later](LICENSE). Official reference materials
retain their upstream ownership; see [fixture provenance](test/fixtures/README.md).
