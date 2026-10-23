# 021 - Incremental speech text input

_Superseded for TTS protocols/public surface by [022](022-bidirectional-only-speech-output.md); historical file links below may refer to removed uncommitted sources._

_Date: 2026-10-22. Status: Implemented in uncommitted work based on `cf4ff1d`._

## Background

[020](020-streaming-speech-playback.md) streamed returned audio while submitting
all text at request start. The user clarified that text must also stream to the
service, so interruption can discard future input. Stopping local playback or
closing HTTP does not establish that already accepted work is unbilled.

## Decision

Expose open/send/finish through [vox.el](../vox.el), with captured session handles
and a bounded text queue in [vox-tts.el](../vox-tts.el). Doubao defaults to its
bidirectional WSS protocol, implemented in [vox-tts-doubao.el](../vox-tts-doubao.el).
CLI stdin remains open between fragments. HTTP-only protocols retain complete-text
speech and explicitly reject incremental input. Legacy Doubao SSE remains an
explicit protocol choice.

Reuse [vox-transport.el](../vox-transport.el) with an optional opaque-owner liveness
predicate. Its default ASR ownership, websocket.el framing, TLS checks, receive
serialization and limits remain in place. The provider adapter owns only the
application protocol and its handshake state.

## Why

An open session accepts real producer fragments without artificial sentence
splitting or repeated HTTP requests. Captured handles reject stale writes and
cannot stop a successor. Separate input/output pumps keep finish behind prior
text writes and avoid nesting sends when callbacks reenter the event loop.
Sharing transport guards avoids a second WebSocket implementation or fabricated
ASR session used solely to borrow a socket.

A normal stop releases local audio first, then attempts CancelSession and closes
the socket. During an in-flight or interrupted write it closes directly: another frame could
corrupt message ordering. Waiting indefinitely for cancellation acknowledgement
would make interruption depend on a stalled network. This deliberately provides
best-effort cancellation, not a billing guarantee.

## Consequence

Existing Doubao resource/voice configuration uses bidirectional input by default.
Explicit old HTTP endpoints need the legacy protocol or an endpoint update.
`vox-speak` queues already-complete text through the same writer; it does not
pace submission to audio playback. Producer integrations use open/send/finish
as text becomes available. The doctor retains WebSocket prerequisites for TTS-only
setups and identifies WSS destinations. See the [speech guide](../docs/speech-output.md)
for setup, limits and migration.

[Input regressions](../test/vox-test-tts-input.el) exercise framing, readiness,
finish/cancel separation, reentrant writes, bounds and stale handles with synthetic
messages and local processes. [Transport regressions](../test/vox-test-transport.el)
exercise opaque ownership through the real upstream frame parser.

## Known limitations

No LLM client or automatic acoustic barge-in is added. Producers must stop
forwarding text when their captured session ends. HTTP Qwen/OpenAI adapters do not
support incremental text. Native writes can delay cancellation; accepted text may
still incur provider charges. Connections are not pooled and cancellation is not
acknowledged before disposal. Live-provider, billing, physical speaker and
supported Emacs-version acceptance remain separate from offline evidence.
