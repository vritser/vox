# 015 - Separate Qwen task-streaming from Realtime

_Date: 2026-10-22. Status: Implemented in uncommitted work based on `c1d1ed8`._

> Configuration surface superseded by [018](018-shared-speech-service-configuration.md):
> shared services use separate ASR/TTS capability plists and selection state.

## Background

Vox's Qwen adapter speaks the Realtime API for `qwen3-asr-flash-realtime`.
The requested `qwen-audio-3.0-asr-flash-streaming` instead uses DashScope's
`run-task` protocol. Changing only the model or endpoint cannot translate
session events, base64 audio, and completion into that protocol. The
[dated protocol addendum](../docs/protocol-audit.md#qwen-task-streaming-addendum-2026-10-22)
records the official references inspected for this change.

## Decision

Add `vox-make-qwen-audio` and the independently registered `qwen-audio`
protocol, preserving the existing Qwen Realtime constructor and defaults.
[vox-backend.el](../vox-backend.el) owns configuration; the new
[streaming adapter](../vox-backend-qwen-audio.el) owns task IDs, request
serialization, binary PCM and sentence-to-core events. Existing transport,
audio capture, selection, credential and sink boundaries remain shared.

Only a matching `task-finished` after local finish with no provisional sentence
remaining produces completion. Unfinished sentence tails fail without insertion;
explicit recovery remains available. Finalized sentence IDs are terminal in
this adapter: duplicate finals and late partials cannot replace them. The
status map is bounded by the existing segment limit.

## Why

The name Qwen Audio matches the model family; "streaming" alone would not
distinguish it from the existing Realtime adapter, which also streams audio.
The name identifies this ASR task-streaming adapter, not every Qwen Audio API.

A distinct protocol keeps incompatible wire formats out of model-name heuristics
and lets the existing directory select both implementations. It requires neither
a bridge process nor a new lifecycle abstraction. Shared configuration already
has the language field, so no struct-layout migration is needed.

Core intentionally permits authoritative completion to finalize snapshots for
other protocols. Changing that global behavior would affect unrelated backends.
The streaming protocol explicitly distinguishes provisional and final sentences;
rejecting an unfinished tail avoids silently promoting provisional text or
silently dropping a spoken suffix. This deliberately prefers visible failure to
inferred success until live provider behavior is established.

## Consequence

Users choose the new constructor for the streaming model; their old Realtime
configuration continues unchanged. Language is an optional one-element
`language_hints` array. The server sentence silence setting is separate from
Realtime VAD and local stop timing. See the
[configuration guide](../docs/customization.md#qwen-audio-task-streaming).

[Synthetic protocol tests](../test/vox-test-qwen-audio.el) cover the adapter;
selection, configuration, doctor, log and reload tests cover its integration.
These are offline checks, not authenticated recognition acceptance. The new
module participates in source discovery, packaging and optional coverage.

## Known limitations

Cloud handshake, account/region/model access, microphone behavior, actual final
sentence timing and recognition quality remain unverified. Workspace-specific
hosts retain per-connection approval rather than wildcard trust. Context,
hotwords, multiple language hints and additional advanced provider parameters
are not exposed. The new factory does not automatically migrate existing model
lists or make unrelated models protocol-compatible.
