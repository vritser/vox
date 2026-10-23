# 019 - Read-only speech output self-check

_Date: 2026-10-22. Status: Implemented in uncommitted work based on `cf4ff1d`._

## Background

The doctor from [014](014-read-only-doctor.md) diagnosed speech input. TTS in
[017](017-api-and-cli-speech-output.md) added a separate output owner, while
[018](018-shared-speech-service-configuration.md) introduced optional capabilities
in a shared service directory. The user requested TTS self-check coverage after
testing speech generation and investigating playback that was not audible.

## Decision

Extend [vox-doctor.el](../vox-doctor.el) with seven TTS results while retaining
the existing ASR result IDs and the read-only contract. Resolve capabilities
through the runtime selection path and share the pure TTS limits and trusted-host
policy with [vox-tts.el](../vox-tts.el). An unconfigured direction is skipped
when its selection is nil; an explicit invalid selection remains a failure.

## Why

Shared configuration permits input-only and output-only setups. Requiring both
directions would turn valid configurations into false failures. Reusing admission
rules keeps readiness checks aligned with startup without contacting a provider.
Executable lookup identifies a missing player, but it cannot establish whether
the program consumes stdin or whether sound reaches the user's speakers. Keeping
that boundary explicit avoids presenting a passing self-check as live acceptance.

## Consequence

The existing command reports selection/model/voice, player and synthesis CLI
availability, HTTPS trust, credential-source kind, limits, and output state.
It does not print keys or argv values, approve hosts, resolve credentials, start
processes, play audio, or alter active sessions. Errors in selection do not hide
independent player and limit failures. Runtime ownership conflicts are advisory
with a hint to finish the current operation.

[Doctor regressions](../test/vox-test-doctor.el) use synthetic configurations and
forbidden-I/O stubs. They cover optional directions, API/CLI configurations,
invalid selections, privacy, host/port classification, limits and active state.
Current setup belongs in the [self-check guide](../docs/customization.md#self-check).

## Known limitations

No account, voice/resource, proxy, CLI stdin-contract, audio routing or physical
speaker acceptance is performed. State describes the current session, not the
last failed request. Checks do not repair configuration or provide device discovery.
Offline regressions do not establish live-provider or multi-version CI outcomes.
