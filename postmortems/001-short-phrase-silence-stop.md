# 001 - Local silence requests graceful stop, not insertion

_Date: 2026-10-20. Status: Implemented. Retrospective record of `fd599e2`._

## Background

Vox already separated recording, audio drain, provider finalization, and final
insertion. Short-phrase input still required a second manual action to stop
capture. Removing that action must not turn a quiet microphone, a partial
transcript, or a provider's provisional event into permission to insert text.

## Decision

Use a bounded local PCM energy detector to request the existing graceful-stop
path, while keeping authoritative provider completion as the only permission
for final insertion.

[vox-activity.el](../vox-activity.el) owns pure PCM analysis;
[vox-core.el](../vox-core.el) owns lifecycle and decides when to stop. The
default is 1.2 seconds of quiet after five consecutive active 20 ms windows arm
detection. Manual mode remains available; the self-recording CLI stays manual
because Vox does not receive its PCM stream.

## Why

Measuring the audio already flowing through Vox avoids another runtime, another
recorder, or provider-specific definitions of silence. Fixed sample windows make
the result independent of arbitrary process chunk boundaries. The detector keeps
numeric state and at most one incomplete sample byte, not an audio history.
Arming after activity avoids ending a recording before the user starts speaking.

The important boundary is stop versus completion: quiet audio can justify
closing capture, but only the provider can finish recognition of the drained
tail. Reusing the existing stop path preserves the recorder sentinel, queued PCM,
one finish request, and the final insertion latch instead of creating a parallel
"automatic completion" path.

Processing the whole callback and rechecking after sends are equally important.
Resumed speech later in a chunk, or reentrant delivery during a send, can revoke
silence eligibility. A timer based only on callback arrival would conflate missing
audio delivery with actual silence. These are architectural comparisons, not
claims that separate timer- or provider-driven prototypes were implemented.

## Consequence

Users can start, speak, and pause without pressing stop again. They retain manual
stop/cancel and configurable duration/energy thresholds. Future changes must keep
activity analysis separate from transcript decisions and recheck session ownership
before applying an automatic stop.

[Detector tests](../test/vox-test-activity.el) and
[lifecycle tests](../test/vox-test-autostop.el) cover chunk boundaries, arming,
resumed speech, reentrancy, drain, cancellation, and no insertion before completion.
The behavior landed in `fd599e2`; a local run at that stage reported 144 passing
product tests, which is historical evidence rather than the current suite count.
See the corresponding [changelog entry](../CHANGELOG.md#changed).

## Known limitations

RMS energy is not speech classification. Steady noise can prevent stopping;
quiet speech or deliberate pauses can end capture early. The quiet interval is
not a text-insertion deadline: recorder shutdown and provider finalization add
latency. Real microphone threshold calibration, provider timing, and the supported
Emacs-version matrix were not validated by the synthetic tests recorded here.
