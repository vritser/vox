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

3. Run `M-x vox-select-input-device` and choose your input in the minibuffer, or
   let the first interactive `C-c v` ask when `vox-audio-input` is unset.
   Selection lasts for this Emacs session; `C-u M-x vox-select-input-device`
   saves it through Customize. Existing explicit input settings are preserved.
   See [device setup and platform support](docs/customization.md#choose-an-audio-device).
4. [Configure an API key](#api-key-configuration) for Qwen (default) or
   experimental Doubao, and check the [provider region](docs/customization.md#credentials-and-regions).
   Starting a cloud session sends
   audio to the provider and may incur charges. An
   [optional CLI backend](docs/customization.md#optional-cli-backend) can instead
   capture its own audio.
5. In an editable buffer, press `C-c v` **once**, speak, then pause. For Qwen and
   Doubao, Vox stops after about 1.2 seconds of quiet audio and inserts only after
   authoritative completion. Press `C-c v` again to finish early, or `C-c C-v`
   to cancel without insertion. The self-recording CLI still requires manual stop.

A [use-package example](docs/customization.md#example-configuration) and all
setup details are in the customization guide.

## Short-phrase and manual modes

The default for Vox-owned capture is short-phrase input:

```elisp
(setq vox-stop-mode 'silence
      vox-silence-seconds 1.2)
```

To record continuously and stop manually, use `(setq vox-stop-mode 'manual)`.
Both modes insert **once after the whole session finishes**, not once per sentence.
Settings apply to the next recording. You can always stop early or cancel.

Automatic stopping uses local PCM energy, not delayed recognition text. Initial
silence alone does not stop recording. Background noise can prevent stopping;
quiet speech or long pauses can cause early stopping. Adjust the silence duration
or `vox-silence-threshold`, or choose manual mode. See
[silence detection](docs/customization.md#short-phrase-silence-detection) for tuning
and the CLI limitation. Capture shutdown and provider finalization add latency
after the quiet interval; 1.2 seconds is not a deadline for text insertion.

## API key configuration

Vox reads `auth-source` first, then the provider's environment variable. It does
not load a `.env` file. An existing `auth-source` key takes priority over an
environment key; configure the account and region you actually use. The default
environment names below have no legacy aliases or automatic fallback.

| Backend / region | Environment variable | `auth-source` host |
| --- | --- | --- |
| Qwen, Beijing (default) | `VOX_QWEN_API_KEY` | `dashscope.aliyuncs.com` |
| Qwen, Singapore | `VOX_QWEN_API_KEY` | `dashscope-intl.aliyuncs.com` |
| Doubao (experimental) | `VOX_DOUBAO_API_KEY` | `openspeech.bytedance.com` |

### Try it in the current Emacs session

For Qwen, press `M-:` and evaluate this expression, then enter your key at the
masked prompt. The expression does not contain or print the key:

```elisp
(progn
  (setenv "VOX_QWEN_API_KEY" (read-passwd "DashScope API key: "))
  (message "Vox: Qwen API key configured"))
```

This sets the environment of the running Emacs, including GUI Emacs, until it
exits. The message confirms local configuration, not successful authentication.
For Doubao, use `VOX_DOUBAO_API_KEY` instead and select `(setq vox-backend 'doubao)`;
check its [resource ID and experimental status](docs/customization.md#doubao-experimental).
If you supply environment variables outside Emacs, set them before launching
Emacs. A running Emacs does not pick up later terminal exports, and GUI Emacs
may not inherit the terminal's environment.

### Keep a key across restarts (recommended)

Use an encrypted auth-source file outside the repository. Add this to your Emacs
configuration; it contains only the file location, not a secret:

```elisp
(require 'auth-source)
(add-to-list 'auth-sources "~/.authinfo.gpg")
```

Open that file in Emacs and add the entry for your provider, replacing the
placeholder with your real key. These examples are **not real credentials**:

```text
machine dashscope.aliyuncs.com login apikey password YOUR_QWEN_API_KEY
machine dashscope-intl.aliyuncs.com login apikey password YOUR_SINGAPORE_API_KEY
machine openspeech.bytedance.com login apikey password YOUR_DOUBAO_API_KEY
```

Save it encrypted using Emacs/GnuPG; this requires a working GnuPG setup. Keep
only the entries you need. The host must match the selected endpoint, and the
login must be `apikey`. After changing an entry, run
`M-x auth-source-forget-all-cached` before retrying. Do not put real keys in your
Emacs config, repository, shell history, or issue reports. See the
[credential and region guide](docs/customization.md#credentials-and-regions)
for endpoint selection.

## Keys and commands

The keys below are suggestions installed by the configuration above, not global
bindings enabled when Vox loads.

| Key / command | Action |
| --- | --- |
| `M-x vox-select-input-device` | Choose an input; prefix `C-u` saves through Customize |
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
