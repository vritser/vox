# Vox

Speak in Emacs, and Vox turns your voice into text at the cursor.

Vox is a native streaming speech input package with Qwen, Doubao, and an optional
CLI backend. It previews recognition as you speak, then inserts the final text
once with an undo boundary. It never presses Return or submits on your behalf.
No Python or Node bridge is required.

## Quick start

Requires Emacs, `websocket.el`, and FFmpeg for cloud recording. Emacs needs
native GnuTLS support; Doubao also needs native zlib.

Install `websocket` through your Emacs package manager, then use the following
configuration to install Vox directly from Git:

```elisp
(use-package vox
  :vc (:url "https://github.com/vritser/vox" :rev :newest)
  :demand t
  :config
  (setq vox-backends
        (list
         (vox-make-qwen "DashScope"
           :key "YOUR_DASHSCOPE_API_KEY"
           :host "dashscope.aliyuncs.com"
           :endpoint "/api-ws/v1/realtime"
           :models '(qwen3-asr-flash-realtime)
           :language nil) ; Auto-detect, or use "zh" / "en".
         (vox-make-doubao "SeedASR"
           :key "YOUR_DOUBAO_API_KEY"
           :host "openspeech.bytedance.com"
           :endpoint "/api/v3/sauc/bigmodel_async"
           :models '(bigmodel)
           :resource-id "volc.seedasr.sauc.duration"))
        ;; Default backend/model; use M-x vox-select to switch later.
        vox-selection '("DashScope" qwen3-asr-flash-realtime)))
```

Replace the key placeholder for the backend you want to use; the other entry
can be removed. The defaults select Qwen in Beijing. For Doubao, set
`vox-selection` to `'("SeedASR" bigmodel)` or run `M-x vox-select`; its resource ID
must match your enabled service. Keep the endpoint/model pairing unless you know
the provider supports your changes. See [regions and provider settings](docs/customization.md#credentials-and-regions).

For `qwen-audio-3.0-asr-flash-streaming`, use `vox-make-qwen-audio`
instead of `vox-make-qwen`: the models use different wire protocols. See the
[streaming configuration](docs/customization.md#qwen-audio-task-streaming).

No key bindings are installed by this configuration; use `M-x` or bind commands
to keys of your choice. Loading Vox does not start recording.

### API key configuration

Literal keys make a quick trial easy, but are visible in your init file and
`C-h v vox-backends`. Never commit them or put them in shared configuration.
For persistent use, replace `:key "..."` with `:key nil` to use `auth-source`
(provider host, login `apikey`), or with a function such as
`:key (lambda () (getenv "MY_ASR_KEY"))` to read an environment variable available
to Emacs. See the [credential setup guide](docs/customization.md#credentials-and-regions).

Starting a cloud recording sends audio to the selected provider and may incur
charges.

## Usage

1. Run `M-x vox-select-input-device` to select an audio input: one discovered input
   is selected automatically; multiple inputs prompt. The first interactive
   recording does the same if input is unset. Only `C-u M-x vox-select-input-device`
   saves the choice across Emacs restarts.
2. In an editable buffer, run `M-x vox-toggle`, speak, then pause. By default,
   recording stops after about 1.2 seconds of quiet audio; text is inserted after
   the provider finishes processing.
3. Run `M-x vox-toggle` again to finish early, or `M-x vox-cancel` to discard the
   recording without insertion.

| Command | Action |
| --- | --- |
| `vox-select` | Choose a backend and model for the next recording |
| `vox-start` / `vox-stop` | Start recording / finish gracefully |
| `vox-show-transcript` | View current or last text; unfinished text is marked unconfirmed |
| `vox-copy-confirmed-text` | Copy confirmed text to the kill ring |
| `vox-forget-transcript` | Clear the last session and its recovery buffer |
| `vox-doctor` | Check dependencies and configuration without side effects |

For longer dictation, set `(setq vox-stop-mode 'manual)` and stop explicitly.
Both modes insert once at the end of the session, not after each sentence. The
self-recording CLI backend always requires manual stop. See
[silence detection](docs/customization.md#short-phrase-silence-detection) for tuning.

Switching buffers does not redirect the insertion target. Normal operation keeps
audio and transcripts off disk; transcript recovery is in memory.

## Documentation

- [Customization](docs/customization.md): devices, credentials, languages,
  backends, diagnostics, and troubleshooting.
- [Development](docs/development.md): verification, packaging, and live acceptance.
- [Architecture](docs/architecture.md): module ownership and extension points.
- [Protocol audit](docs/protocol-audit.md) and [transport audit](docs/transport-audit.md):
  verification evidence and known limits.
- [Changelog](CHANGELOG.md) and [decision records](postmortems/).

For contributions, follow [AGENTS.md](AGENTS.md) and run `scripts/verify.sh`.

Licensed under [GPL-3.0-or-later](LICENSE).
