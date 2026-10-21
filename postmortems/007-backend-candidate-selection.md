# 007 - Backend candidates with a single current selection

_Date: 2026-10-21. Status: Superseded before commit by
[008](008-unified-selection.md); uncommitted work based on
`b84cded5d964aaa4685c694ef93e95abe9b284b8` (`b84cded`)._

> Selection workflow superseded by [008](008-unified-selection.md).

## Background

[003](003-backend-objects-and-model-selection.md) introduced backend objects and
interactive model selection. Switching providers or endpoint configurations still
required assigning `vox-backend` in Lisp. The approved workflow adds a candidate
list and a backend picker while preserving that single current value and existing
configuration forms.

## Decision

Add `vox-backends` as a list of backend objects and `vox-select-backend` as a
completion command that sets `vox-backend` to the chosen object and resets
`vox-model` to nil for the next recording.

[vox-backend.el](../vox-backend.el) owns candidate validation and resolution of
the current backend: a non-nil `vox-backend` wins, otherwise the first candidate
is used without assigning the variable. The default Qwen object is retained.
[vox.el](../vox.el) owns selection and applies that fallback consistently to
startup and model completion. Explicit startup arguments still take precedence.

## Why

Keeping candidates separate from the current backend preserves configurations
and callers that expect one object or a registered protocol symbol. The existing
session snapshot boundary already protects a running recording, so selection
needs no new lifecycle mechanism. Resetting the model avoids carrying a provider's
model ID into a different provider; reselecting the same backend also chooses its
first model. The list supplies configuration, not remote discovery or registration
of new protocols.

Names are the completion identity. Duplicate names are rejected explicitly,
including repeated references to one object, rather than silently selecting the
first match. Case-sensitive completion distinguishes differently cased names.
Revalidation after the prompt prevents selecting a removed, renamed, replaced,
or invalid candidate after callbacks change configuration.

## Consequence

Users can switch configurations without rewriting their initialization code for
each recording. Selection stores the original object, reads no keys, opens no
connection, and does not persist settings. Cancellation or invalid selection
does not assign either current setting. See the
[configuration guide](../docs/customization.md#backends-and-models) and
[changelog](../CHANGELOG.md#added).

No regression file specific to this picker was retained. The current
[selection tests](../test/vox-test-backend-selection.el) and
[startup tests](../test/vox-test-start.el) exercise the successor design in
008 with synthetic offline fixtures. The verification entry point is
[scripts/verify.sh](../scripts/verify.sh); no live-provider acceptance exists.

## Known limitations

The picker requires an explicitly configured, nonempty object list; it neither
adds the current backend automatically nor accepts registered symbols as list
entries. Symbols, including `cli`, remain supported through `vox-backend` and
explicit startup arguments. There is no profile editor, automatic persistence,
or remote model discovery. Microphones, provider authentication, model access,
and multi-version Emacs CI acceptance are not established by these offline tests.
