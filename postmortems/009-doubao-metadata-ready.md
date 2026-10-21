# 009 - Doubao metadata-only ready response

_Date: 2026-10-21. Status: Implemented, uncommitted work based on
`e4f87a4dd493a9b3289f630fe858a24332596fa7` (`e4f87a4`)._

## Background

A live Doubao `bigmodel_async` connection failed during readiness with the
transport's generic `WebSocket message rejected or callback failed`. Capturing
the first binary frame with the configured key, without microphone or audio,
showed a valid successful full response: type 9, sequence flag clear, and an
uncompressed JSON body containing only `result.additions.log_id`. There was no
`result.text` field.

[vox-backend-doubao.el](../vox-backend-doubao.el) treated every nonempty
`result` object as a transcript snapshot and required `text` to be a string. The
metadata-only acknowledgement therefore raised `Invalid Doubao full result`
before `on-ready` ran. The transport correctly hid the raw exception, so the
user saw only the fixed safe message.

## Decision

Treat a missing or null `result.text` as a metadata-only successful response:
signal readiness from the envelope, emit no snapshot, and let audio start. Keep
rejecting a present non-string `text`, and still reject non-object `result`
shapes. The adapter helper owns this distinction; core and transport behavior do
not change.

## Why

The envelope, not transcript availability, establishes readiness. The provider
can return a metadata acknowledgement before it has text, so requiring text
turned a legal first response into a failed session. Emitting an empty snapshot
was the other plausible tolerance, but full-snapshot semantics would then erase
any earlier hypothesis on a response that contained no recognition result. The
Go reference SDK likewise discards results with no text and no utterances.
Malformed text remains an error so a schema change cannot silently become an
empty transcript.

## Consequence

A metadata-only first response now proceeds to capture, and later text-bearing
full responses still replace the snapshot in receive order. The decision is
exercised by the regression in
[vox-test-doubao.el](../test/vox-test-doubao.el) using a synthetic response
with the observed shape. The protocol audit records the tolerance. This is
offline coverage only; the fix was not exercised with a microphone or a live
transcription stream.

## Known limitations

Only the observed metadata-only shape is covered. Other valid response variants,
live readiness timing, the audio stream, and final recognition remain separate
acceptance checks. A malformed result still fails the session with the
transport's fixed safe message rather than exposing provider details; use the
optional event log and `vox-session-last-error` for the adapter-level category
when diagnosing another shape.
