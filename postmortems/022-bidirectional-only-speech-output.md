# 022 - Bidirectional-only speech output

_Date: 2026-10-23. Status: Implemented in uncommitted work based on `cf4ff1d`._

## Background

[021](021-incremental-speech-text-input.md) added incremental input for Doubao and
CLI but retained one-shot HTTP adapters. The user identified Qwen's Realtime
interface and chose to retain only bidirectional TTS. The intended workflow is
producer text arriving during playback with interruption that discards unsent text.

## Decision

Make Qwen Realtime the default Qwen TTS capability and retain only Qwen Realtime,
Doubao bidirectional WSS and streaming CLI. Remove the preliminary OpenAI TTS,
Qwen HTTP and Doubao SSE protocols, `vox-make-openai`, and the private HTTP
transport. No released compatibility surface or committed implementation is
being migrated; earlier uncommitted designs are recorded in 017–021.

[vox-tts-qwen.el](../vox-tts-qwen.el) owns the native application protocol over
[vox-transport.el](../vox-transport.el). It waits for configuration acknowledgement,
uses ServerCommit text appends, correlates response audio/completion and requires
session.finished after producer finish. Shared bounded queues, playback ownership
and cancellation remain in [vox-tts.el](../vox-tts.el).

## Why

Streaming returned audio alone still submits the entire text upfront. Keeping
those adapters adds configuration and transport maintenance without meeting this
workflow. A persistent bidirectional session accepts actual producer fragments.
ServerCommit lets Qwen choose synthesis boundaries without artificial pacing or
client sentence splitting. Model identifiers do not select unrelated wire protocols.

Stopping Qwen attempts input_text_buffer.clear, then closes the socket. It never
uses session.finish for cancellation because finish flushes remaining text.
Clearing is best effort and is skipped during an in-flight or failed write, whose
delivery is uncertain. As with Doubao, no cancellation or billing acknowledgement
is inferred from disposal.

## Consequence

Qwen's default model and endpoint change; explicit preliminary HTTP settings must
be migrated. Removed definitions and session layout changes require restarting
Emacs. Current setup lives in the [speech guide](../docs/speech-output.md).
HTTP-specific tests are removed with their implementation; player, timeout,
privacy, ownership and configuration regressions are retained with streaming
sources. [Qwen protocol tests](../test/vox-test-tts-qwen.el) add synthetic offline
evidence alongside [Doubao/input tests](../test/vox-test-tts-input.el) and
[player/CLI tests](../test/vox-test-tts.el).

## Known limitations

Clearing a text buffer does not establish cancellation of synthesis already
accepted by the service. Charges remain provider-controlled. Native writes and
speaker buffering can delay interruption. No LLM client or automatic acoustic
barge-in is included. CLI streaming behavior is a trusted contract, not something
Vox can infer from an executable. Qwen Audio/CosyVoice task-based TTS is a separate
protocol and remains unsupported. Cloud acceptance, billing behavior, physical
speaker output and supported Emacs-version CI are not proven by offline tests.
