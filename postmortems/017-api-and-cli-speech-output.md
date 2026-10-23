# 017 - Optional API and CLI speech output

_Superseded for TTS protocols/public surface by [022](022-bidirectional-only-speech-output.md); historical file links below may refer to removed uncommitted sources._

_Date: 2026-10-22. Status: Implemented in uncommitted work based on `cf4ff1d`._

> Configuration surface superseded by [018](018-shared-speech-service-configuration.md):
> shared services use separate ASR/TTS capability plists and selection state.

> ASR-only doctor limitation superseded by [019](019-speech-output-self-check.md).

> Complete-before-playback and Qwen result-download decisions superseded by
> [020](020-streaming-speech-playback.md).

## Background

Vox's public workflow was streaming speech input followed by one final insertion.
The user requested TTS through APIs and CLI, and selected OpenAI-compatible,
Qwen and Doubao API support together. Recognition's session core assumes audio
capture and transcript reconciliation; synthesis reverses the data direction.

## Decision

Add a separate optional speech-output owner in [vox-tts.el](../vox-tts.el), with
public speak/stop commands in [vox.el](../vox.el). Reuse backend configuration
validation and lazy credential resolution. Keep TTS selection separate from ASR.
Use Emacs URL through [vox-tts-http.el](../vox-tts-http.el) for the three HTTP
protocols and a UTF-8 stdin / encoded-audio stdout contract for trusted CLIs.
Collect bounded complete audio before playback through a configurable player,
defaulting to FFmpeg's ffplay. Starting recording cancels output; TTS refuses
active recognition and recognition startup. Reload requires both owners idle.

## Why

Separate ownership preserves recognition's authoritative-completion and insertion
rules without teaching its PCM capture queue about playback. Shared configuration
and credentials avoid a second key-management convention. Distinct protocol
adapters are necessary because OpenAI returns binary audio, Qwen returns a result
URL, and Doubao returns SSE with Base64 audio and a completion code.

Complete synthesis before playback gives API and CLI a common first workflow,
including nonzero CLI exits and incomplete provider responses that must not play
partial results. The cost is first-audio latency and bounded utterance length.
Stdin/stdout integration avoids shell interpolation and temporary audio files.
An external player avoids relying on Emacs's platform-dependent sound support.

## Consequence

Users configure TTS services and a player only when they need speech output.
Existing dictation commands retain their purpose. Credentials stay lazy, result
downloads receive no API key, and cancellation clears owned requests/processes.
Setup and limits belong in the [speech output guide](../docs/speech-output.md).
[TTS regressions](../test/vox-test-tts.el) and
[HTTP regressions](../test/vox-test-tts-http.el) supply synthetic offline evidence.

## Known limitations

No incremental text input, automatic document splitting, streaming playback,
voice cloning or full-duplex conversation. ffplay may be absent from an FFmpeg
installation, so playback is a separate optional executable check. Native calls
can delay event-loop timeouts. Trusted CLI tools own their child processes and
external side effects. The doctor remains an ASR diagnostic. No authenticated
provider, physical speaker or multi-version CI acceptance is claimed here.
