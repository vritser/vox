# 002 - Explicit audio-device selection with opt-in persistence

_Date: 2026-10-20. Status: Implemented. Retrospective record of `3afd60c`._

## Background

Native capture required an explicit FFmpeg input argv list. That was safe but
made first use depend on discovering platform-specific device names and argument
syntax outside Vox. A picker could remove that setup work, but guessing a device
or silently saving its identifier would change the user's privacy and persistence
choices. Discovery and minibuffer completion also process callbacks, so the
buffer current when a prompt finishes need not be the original insertion target.

## Decision

Discover supported inputs on demand in [vox-device.el](../vox-device.el),
require an explicit minibuffer choice, and save through Customize only when the
user supplies a prefix argument.

[vox-start](../vox.el) invokes the picker only for interactive, Vox-owned
capture with an unset input. Existing argv remains authoritative; headless calls
and self-recording CLI sessions do not acquire an implicit prompting workflow.

## Why

FFmpeg is already the capture dependency. Reusing its AVFoundation, DirectShow,
and PulseAudio listings avoids another discovery service or runtime. Treating the
result as exact argv tokens, not a shell command, preserves device identities
without introducing shell interpolation. Discovery has bounded time/output and
waits for the terminal sentinel so final listing bytes are not mistaken for
missing devices.

An explicit choice is required even for one candidate: discovering a microphone
is not permission to select it. Emacs-session-only configuration is the default;
persistence is a separate action. Ambiguous case-insensitive completion must
fail rather than guess between distinct identities, and identifiers must not
enter generic minibuffer history.

Two less visible ownership boundaries shaped the implementation. Startup captures
the buffer, marker and backend selection before prompting, then rechecks session
ownership and editability afterward. Persistence rollback must restore Customize
metadata as well as the variable value, or a later unrelated save could persist
the rejected input. The pre-commit regression exercises that risk with synthetic
values and a temporary file; it is not evidence of an actual user-config leak.

## Consequence

First interactive use gains a task-specific setup path without changing manual
configuration or silently taking over a device. Failed/canceled persistence
restores this option's state while preserving unrelated Customize changes.
The parser/discovery owner remains separate from recording and recognition.

[Device regressions](../test/vox-test-device.el) cover bounded discovery,
explicit choices and persistence rollback;
[startup regressions](../test/vox-test-start.el) cover prompt cancellation and
captured insertion ownership. Local runs reported 189 tests initially and 190
after the persistence regression. See the
[changelog entry](../CHANGELOG.md#added). The later backend-object work in
[003](003-backend-objects-and-model-selection.md) extends capture to detached
configuration fields and the selected model; that extension is not attributed
to `3afd60c`.

## Known limitations

FFmpeg listings are human-readable and platform-dependent, not a stable discovery
protocol. Unsupported systems/builds still need explicit argv configuration, and
native permission prompts may appear. Real hardware enumeration and writes to
user configuration were not validated; the persistence test writes only to a
temporary file. Restoring in-memory Customize state is not a claim that an
arbitrary partially completed filesystem write can be rolled back atomically.
