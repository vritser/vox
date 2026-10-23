# 018 - Shared speech service configuration

_Superseded for TTS protocols/public surface by [022](022-bidirectional-only-speech-output.md); historical file links below may refer to removed uncommitted sources._

_Date: 2026-10-22. Status: Implemented in uncommitted work based on `cf4ff1d`,
following the uncommitted TTS implementation in [017](017-api-and-cli-speech-output.md)._

## Background

The initial TTS implementation introduced a separate service directory and
constructors alongside the ASR configuration from [003](003-backend-objects-and-model-selection.md)
and [008](008-unified-selection.md). The user asked whether configuration could
be shared instead of simply adding an ASR prefix, then approved shared host/key
defaults with separate capabilities and selection state.

## Decision

Keep one `vox-backends` directory. `vox-make-qwen`, `vox-make-doubao`,
`vox-make-openai` and `vox-make-cli` construct shared `vox-provider` objects.
Optional `:asr` and `:tts` plists own their protocols, endpoints, models and
specialized options. Omitted capability host/key inherits; an explicit nil key
uses auth-source for the effective host. Each direction retains independent
selection and lifecycle ownership.

[vox-backend.el](../vox-backend.el) validates shared configuration and resolves
a selected capability into a detached `vox-backend` connection record. Existing
ASR adapters retain that record and their protocol contracts. TTS uses the same
record instead of a second connection wrapper. Named CLIs capture separate argv
lists for ASR's NDJSON protocol and TTS's UTF-8 text / encoded-audio contract.

## Why

A shared service definition removes duplicate credentials and hosts while keeping
the wire protocols explicit. Independent selections allow one provider for input
and another for output. Capability overrides handle different regional endpoints
or service credentials without adding an implicit lookup precedence chain.

Resolved connection records keep common configuration changes out of the runtime
session owners. Validating both capabilities before copying preserves early
configuration errors; copying before callbacks preserves snapshot semantics.
The tradeoff is a direct configuration migration and a required restart.

## Consequence

Rename `vox-selection`/`vox-select` to `vox-asr-selection`/`vox-asr-select`; move
recognition options into `:asr`. Replace `vox-make-qwen-audio` with Qwen's
`:protocol qwen-audio` ASR capability. Replace preliminary TTS constructors and
directory with shared services and `:tts` plists. No aliases are added. Existing
ASR registry extensions, resolved records and the `cli`/`vox-cli-command` shortcut
remain supported. Current setup is in the
[configuration guide](../docs/customization.md#backends-and-models).

[Shared-service tests](../test/vox-test-provider.el) cover inheritance, overrides,
capability filtering, cross-capability mutation, independent selection and CLI
configuration. Existing protocol tests retain their assertions through resolved
synthetic fixtures in [test support](../test/vox-test-support.el).

## Known limitations

One service entry selects one protocol per capability; multiple configurations
need distinct names. OpenAI implements TTS only. No automatic migration of loaded
objects, remote model discovery, new provider protocol or real-time playback is
introduced. Offline tests do not establish authenticated provider access, physical
playback, microphone behavior or multi-version CI outcomes.
