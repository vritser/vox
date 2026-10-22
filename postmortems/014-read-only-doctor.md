# 014 - Read-only environment self-check

_Date: 2026-10-22. Status: Implemented in uncommitted work._

_Implementation evidence: Uncommitted work based on `5ff4719`. The doctor module,
its offline regressions, and the startup-limit extraction belong to this work;
this record does not claim a live-provider or real-device acceptance result._

## Background

Setup failures were diagnosed by reading the customization guide and checking
separate pieces by hand: Emacs capabilities, `websocket`, FFmpeg, the backend
directory, the selected endpoint, the credential source, the input shape, stop
options and session state. The event log covers a running session but not
readiness before one starts, and `vox-select-input-device` intentionally probes
hardware. There was no single read-only answer to "is this configuration able to
start, and if not, which part is wrong?"

## Decision

Add [vox-doctor.el](../vox-doctor.el) with the interactive `M-x vox-doctor` and
the programmatic `vox-doctor-check`. Fifteen checks report Emacs, `websocket`,
native GnuTLS, native zlib, the FFmpeg executable, `vox-backends`,
`vox-selection`, endpoint trust, credential-source kind, `vox-audio-input`
shape, effective stop mode, numeric limits, session/reload state, event-log
setting, and (as a skip) device discovery. Each result has `ok`, `warn`, `fail`
or `skip`, a summary, and an optional hint. The command opens and selects a
memory-only `*Vox doctor*` buffer; the function returns the same plists for
tooling.

The doctor is read-only by construction. It never calls a `:key` function,
`vox-backend-secret`, auth-source, capture, transport, or device listing. It
prints neither credential values nor input argv nor device names. The selected
backend is resolved through the same pure snapshot and model paths startup
uses; the built-in adapters are required so configuration types resolve even
when only this module is loaded.

Numeric limit validation moves into `vox-core--limits-error`, shared with
`vox-core-start`, so the report and admission cannot drift. Startup still
signals the existing `Invalid Vox limits` error; the helper additionally
accepts malformed non-numeric values instead of raising a type error.

## Why

Read-only checks are safe to run at any time, including before any credential
exists, and cannot trigger microphone permission prompts. Reporting the
credential *kind* rather than resolving it preserves the rule that secrets are
only touched at connection time. Skipping device discovery keeps a diagnostic
from doing exactly the hardware interaction it is meant to explain. A
machine-readable result list lets offline tests assert every branch without
starting a session, so the report cannot silently become empty or always green.

## Consequence

Users get one readiness report and actionable hints; the command does not modify
configuration, choose a device, retry a connection, or repair anything. A
literal key is warned about without disclosure. A custom endpoint is warned
about because per-connection approval remains mandatory. A failed check blocks
the affected path; warnings and skips are advisory, and device discovery remains
an explicit picker action. The report cannot substitute for live acceptance.

The behavioral owners are [doctor tests](../test/vox-test-doctor.el) for every
status branch, privacy boundaries, and the no-side-effect contract, plus the
existing [limit tests](../test/vox-test-limits.el) for startup rejection. The
current workflow is documented in the
[self-check guide](../docs/customization.md#self-check) and the
[architecture map](../docs/architecture.md#module-ownership).

## Known limitations

The doctor checks shape and availability, not correctness: it does not read
auth-source or validate an account, does not connect to a provider, does not
list devices or verify vendor formats, and cannot establish recognition quality.
`websocket` is reported as loaded, not compared against the declared version
requirement. FFmpeg is reported as found, not as compiled with the platform's
capture device. Dormant directory entries are validated for shape, but only the
selected backend's endpoint and capture needs are reported. Emacs version is
compared against 28.1, which is not a compatibility test. The report timestamp
is informational, and no check is cached across configuration changes.
