# 010 - Keep lifecycle messages quiet and diagnostics opt-in

_Date: 2026-10-21. Status: Implemented in uncommitted work based on `ad21487`._

## Background

The default buffer sink printed every lifecycle transition and repeated recording
instructions for each session. A recorder requiring a second interrupt produced
the same tail-risk warning during both finalizing and completion. The mode-line
indicator already provides ongoing status, while [decision 006](006-session-event-diagnostics.md)
provides a separate, opt-in metadata log for diagnosis.

## Decision

Remove routine lifecycle messages rather than gating them on the event-log
option or adding another verbosity setting. Keep empty-recognition and failure
messages. Report possible tail truncation only at successful completion, combined
with the empty-recognition message when applicable.

## Why

Progress indicators, diagnostic retention, and actionable messages have distinct
purposes. Enabling diagnostics should not reintroduce echo-area noise, and
turning diagnostics off must not hide a failure. Waiting until completion avoids
repeating the tail warning; a failed session already reports recovery guidance.

## Consequence

[The default sink](../vox-ui.el) remains responsible for messages and overlay
cleanup. Core lifecycle, insertion, mode-line updates, and the event-log option
are unchanged. Explicit command feedback remains available. Recording-mode
instructions live in the [configuration guide](../docs/customization.md#interaction-and-safety)
instead of being repeated on every start.

[Synthetic UI regressions](../test/vox-test-autostop.el) cover quiet states,
empty results, single tail warnings and single failure messages, including event
logging enabled and disabled. These are offline tests, not microphone or provider
acceptance. See the [changelog](../CHANGELOG.md#changed).

## Known limitations

With the mode-line indicator disabled, there is no automatic routine status
message fallback. Cancellation remains quiet. Tail-risk warnings describe a
possible truncation, not measured audio loss; failed or cancelled sessions do
not additionally emit that warning. Real recorder behavior is unchanged and
requires separate live acceptance.
