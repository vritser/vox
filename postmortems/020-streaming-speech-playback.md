# 020 - Streaming speech playback with interruption

_Superseded for TTS protocols/public surface by [022](022-bidirectional-only-speech-output.md); historical file links below may refer to removed uncommitted sources._

_Date: 2026-10-22. Status: Implemented in uncommitted work based on `cf4ff1d`._

> Complete-text-only input and default Doubao SSE superseded by
> [021](021-incremental-speech-text-input.md).

## Background

[017](017-api-and-cli-speech-output.md) waited for complete synthesis before
starting playback. This made failure handling simple but delayed first audio.
The user requested streaming playback and interruption across the existing API
and CLI capabilities.

## Decision

Keep [vox-tts.el](../vox-tts.el) as the single output owner, with a bounded FIFO
feeding one persistent player. Receive callbacks enqueue audio; a timer writes
small pieces under a reentry latch. [vox-tts-http.el](../vox-tts-http.el) serializes
native URL filters and sentinels, and delivers decoded body prefixes while Emacs
URL retains ownership of HTTP framing and authoritative completion.

Qwen uses its HTTP SSE PCM response, with one streaming WAV header so the existing
encoded-stdin player contract also handles its raw samples. Doubao streams decoded
SSE MP3, OpenAI streams binary MP3, and CLI stdout plays before the process exits.
Stop, replacement speech and recording startup cancel source, player and queues.

## Why

A persistent decoder preserves continuity across arbitrary provider boundaries.
Writing outside receive callbacks keeps player backpressure out of HTTP parsing;
queue bounds and an in-flight charge prevent nested callbacks from bypassing
limits. Identity/generation guards prevent cancelled streams from affecting their
successors. This follows the reentry reasoning in [005](005-reentrant-stream-ordering.md).

Starting playback earlier deliberately permits partial audio before a later error.
Completion still requires valid HTTP/protocol termination or successful CLI exit,
followed by drained output and successful player exit. Already heard audio cannot
be withdrawn. Synthesis and playback deadlines therefore overlap.

## Consequence

Existing provider and selection configuration remains valid. A new pending-byte
limit also appears in the shared runtime/doctor validation. Custom players must
consume streaming stdin; buffering CLIs retain their own startup latency.
Current setup and exact bounds belong in the [speech guide](../docs/speech-output.md).
[Synthesis/playback tests](../test/vox-test-tts.el) cover early playback, ordering,
limits, late failures and interruption; [HTTP tests](../test/vox-test-tts-http.el)
exercise the native parser with synthetic fragmented and proxy responses.

## Known limitations

Input remains one complete text per request. No automatic acoustic barge-in or
full-duplex conversation is added. Native writes can delay event-loop cancellation;
player/device buffers determine audible latency. The bounded native URL response
buffer remains until completion. Trusted CLI tools own their descendants and
external side effects. Offline tests do not establish authenticated provider,
physical speaker or supported Emacs-version CI acceptance.
