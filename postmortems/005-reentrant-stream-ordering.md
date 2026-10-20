# 005 - Serialize reentrant stream callbacks per session

_Date: 2026-10-20. Status: Implemented in uncommitted work based on `42bbec9`._

## Background

An intermittent-recognition investigation exposed deterministic ordering bugs in
synthetic tests. Emacs network writes may dispatch process filters, sentinels,
and timers before returning; a single-threaded event loop is not a guarantee
against reentry. The existing generation guards rejected stale sessions but did
not serialize callbacks belonging to the same live session.

The PCM pump could nest sends, resend a retained tail, or dispatch finish before
an earlier send returned. A WebSocket pong write could admit newer received
frames before the unread suffix of an older callback, reversing message order
or rejecting a valid fragmented message. Doubao could restore retained PCM after
cancellation had already cleaned its session. These are offline reproductions,
not evidence that a specific microphone or provider incident took these paths.

## Decision

Give each session one PCM drain owner and each transport context one ordered
input consumer. Preserve bounded queues, generation checks, and authoritative
completion; do not add threads, waits, or a second protocol implementation.
Terminal process notifications share the input FIFO so they cannot overtake
already-received bytes. Interrupted input processing tears down the connection
rather than keeping a live stream after abandoning part of its input.

[Core](../vox-core.el) owns the send/finish latch. Reentrant recorder callbacks
can still enqueue bytes and mark recorder completion, but only the outer pump
sends them. [Transport](../vox-transport.el) serializes incoming callbacks
before invoking the existing upstream parser. [Doubao](../vox-backend-doubao.el)
updates retained-packet state before a yielding send, with no post-send writes
that could undo cleanup. Quitting a PCM send cancels rather than continuing with
an already-dequeued frame whose delivery is unknown.

## Why

A latch only around the final remainder would leave ordinary sends and finish
ordering exposed. Session-local ownership also permits a newly started session
to make progress while a cancelled predecessor's callback unwinds. Removing a
frame from the queue before sending it prevents a second owner from replaying it.

For receive ordering, an earlier callback's unread suffix must precede nested
arrivals. The FIFO retains callback strings without repeatedly copying that
suffix. Separate retained-input byte and callback-count limits bound this
additional buffering; they are not replacements for message, fragment, or
handshake limits. Empty input does not create queue entries.

## Consequence

No command or backend configuration migration is required. Native writes remain
potentially blocking. The transport's new 2 MiB retained-input default may reject
a large coalesced read even when its individual messages are legal; overload
fails safely instead of silently dropping bytes.

The [PCM regressions](../test/vox-test-core-audio.el),
[transport regressions](../test/vox-test-transport.el), and
[Doubao regressions](../test/vox-test-doubao.el) preserve the ordering and
cleanup invariants. [Capture tests](../test/vox-test-audio.el) additionally
compare exact samples from two successive synthetic FFmpeg sources. Dated
verification evidence belongs in the [transport audit](../docs/transport-audit.md),
not in a claim of live-provider acceptance.

## Known limitations

The microphone path, provider accuracy, real network timing, and FFmpeg's
interrupt-related tail risk still need separate live acceptance. A valid empty
Qwen completion does not prove speech was detected. This change neither adjusts
VAD thresholds nor claims to explain unrelated filler in a provider transcript.
