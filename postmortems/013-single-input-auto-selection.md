# 013 - Auto-select a single discovered audio input

_Date: 2026-10-21. Status: Implemented in uncommitted work._

_Implementation evidence: Uncommitted work based on `516f004`. The selection
change and accompanying offline regressions belong to this work; this record
does not claim a test-run result or live-device acceptance._

## Background

[002](002-explicit-input-device-selection.md) required minibuffer selection even
when discovery returned one supported input. That extra confirmation offered no
alternative device to choose. It affected both the explicit device command and
the first interactive Vox-owned recording with an unset input.

## Decision

Let [vox-device.el](../vox-device.el) select exactly one discovered supported
input without calling `completing-read`, while retaining completion for multiple
inputs. Both `M-x vox-select-input-device` and the unset-input interactive startup
path in [vox.el](../vox.el) use this rule; no new public command or option is
introduced.

## Why

An invocation of device selection or interactive recording can use the only
available candidate without a redundant minibuffer step. This deliberately
relaxes only the singleton confirmation rule from 002, not the distinction
between selection and persistence. Choosing the first of multiple devices would
still resolve an actual ambiguity on the user's behalf, so it remains disallowed.

## Consequence

Automatic selection sets `vox-audio-input` for the current Emacs session, just
like an ordinary completed choice. Only an explicit save request through
`C-u M-x vox-select-input-device` persists it through Customize, including when
one input is found. Startup does not request persistence or replace a configured
input. Zero candidates and discovery errors retain their failure behavior;
there is no fallback to a platform default. Programmatic/headless startup and
self-recording CLI device handling remain unchanged.

The shared selection path retains idle/reentry guards and persistence rollback;
startup still captures its insertion target and backend before discovery and
rechecks ownership and editability afterward. The relevant offline regression
owners are [device tests](../test/vox-test-device.el) and
[startup tests](../test/vox-test-start.el). Synthetic discovery and mocked
startup cannot establish real-hardware or cloud-provider acceptance. See the
[changelog entry](../CHANGELOG.md#changed) and current
[device guide](../docs/customization.md#choose-an-audio-device).

## Known limitations

One supported input is not necessarily a microphone: it may be a system-audio
monitor, and automatic selection does not classify it as the user's intended
source. Discovery still starts a bounded local FFmpeg listing and may initialize
audio services or trigger OS permission prompts. Human-readable listings and
platform-specific identifiers retain their existing limitations. Real-device
enumeration, permission flows and live recognition are not validated by this
record.
