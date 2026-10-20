# 006 - Diagnose recording rounds with bounded metadata

_Date: 2026-10-20. Status: Implemented in uncommitted work based on `42bbec9`._

## Background

A repeated-recognition investigation asked whether audio from one recording
could remain in the next, specifically using Qwen. The working tree already
contained the ordering changes described in [005](005-reentrant-stream-ordering.md).
Neither those offline findings nor this investigation establish the cause of
the reported live recognition error.

The code creates a fresh core session and provider connection per recording,
but its visible status did not show per-round audio counts, provider VAD events,
or cleanup. Inspecting raw audio or provider payloads would expose private data.
Checking the reported `qwen-audio-3.0-asr-flash-streaming` model also exposed a
protocol mismatch with the configured `/api-ws/v1/realtime` endpoint: its
[official task API](https://help.aliyun.com/zh/model-studio/qwen-audio-asr-streaming-websocket-api)
is distinct from the adapter implemented here. This configuration finding is
not proof of the cause of the reported transcription.

## Decision

Add an explicitly enabled, bounded, in-memory event log whose write boundary
accepts only fixed event names, enums and bounded numbers. Identify rounds by
local generation, sample audio progress, and retain byte counts at cleanup and
after a send returns. A terminal-state send-return event does not mean a new
send began after cleanup.

## Why

These fields separate missing capture, incomplete finalization, empty results,
late callbacks and possible recorder tail loss without storing speech content.
A ring limits retention; explicit snapshot display avoids buffer hooks or UI
updates in streaming callbacks. The default remains silent, and logging errors
cannot interrupt recognition. Raw diagnostic strings and configuration names
are excluded because they can contain private data even without PCM.

## Consequence

[vox-log.el](../vox-log.el) owns the safe schema and commands. Core, audio,
transport and Qwen emit metadata at their existing lifecycle boundaries. See
the [configuration guide](../docs/customization.md#event-log-for-repeated-recordings)
for operation and interpretation.

The same investigation found two additional reproducible reentry defects:
callable backend options could start a session that outer startup overwrote,
and CLI nested input could reorder lines, lose a partial line or process exit
before an already-received completion. Ownership is now rechecked before
allocation, and CLI input/exit share a bounded FIFO. These paths are distinct
from a demonstrated cross-round Qwen audio leak.

Evidence is in the [multi-round tests](../test/vox-test-sessions.el),
[core regression](../test/vox-test-core.el),
[CLI tests](../test/vox-test-cli.el), [Qwen tests](../test/vox-test-qwen.el),
[log tests](../test/vox-test-log.el) and
[diagnostic integration tests](../test/vox-test-diagnostics.el).
Current run outcomes belong with the change, not a live-provider acceptance
claim. See the [changelog](../CHANGELOG.md#added).

## Known limitations

Metadata cannot establish what the microphone heard or whether a provider
transcribed it correctly. Adapter acceptance is not confirmed remote audio
delivery. Enabling midway omits earlier events, and a full ring evicts its
oldest events. CLI's independent retained-callback limits can reject a large
coalesced read even when each line is legal. Real microphone, permissions,
provider accuracy and network timing remain separate acceptance checks.
The Qwen tests exercise the implemented Realtime protocol; they do not validate
the separate Qwen-Audio-ASR-Streaming model family. Its task protocol requires a
separate adapter, not a model-name substitution.
