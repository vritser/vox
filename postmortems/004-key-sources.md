# 004 - Credential sources: auth-source default, literal or function override

_Date: 2026-10-20. Status: Implemented, uncommitted work based on `694aaca`._

## Background

[003](003-backend-objects-and-model-selection.md) grouped connection settings into
backend objects but kept the earlier credential policy: `:key` was either nil
(auth-source, then `VOX_QWEN_API_KEY` / `VOX_DOUBAO_API_KEY`) or a zero-argument
function, and a literal string was rejected. gptel instead accepts a string or a
function for `:key` and reads auth-source by default through
`gptel-api-key-from-auth-source`. Vox therefore carried two implicit precedence
rules (auth-source over environment, function over both) and a special-case
rejection for the simplest form.

## Decision

`:key` accepts nil, a literal key string, or a zero-argument function. nil reads
`auth-source` for the connecting host with login `apikey` and signals an error
when no entry exists. Vox itself reads no environment variables; an environment
lookup is the explicit `(lambda () (getenv "MY_ASR_KEY"))`. `vox-secret` and the
per-protocol environment names are removed. `vox-api-key-from-auth-source`
remains for an explicit host or user and is the same lookup as the nil default.
Adapters and snapshotting are unchanged: endpoint approval still precedes key
resolution, and literal keys are copied with the configuration.

## Why

One explicit, precedence-free model is easier to reason about than a built-in
fallback chain, and it matches the backend-object pattern from 003. A literal
keeps the quick-trial path without a library variable; a function remains the
documented way to use an environment variable, password store, or other source.
Keeping auth-source as the nil default preserves the secure path without making
every user write a lambda. The cost is visibility: a literal key appears in the
initialization file and in `C-h v vox-backend`, so that is documented rather than
hidden behind an implicit rule.

## Consequence

Existing `VOX_QWEN_API_KEY` / `VOX_DOUBAO_API_KEY` setups no longer work; users
move to auth-source or an explicit `:key` function. Tests cover the auth-source
default, literal and function keys, missing-entry failure without opening
transport, and error redaction. See the
[configuration guide](../docs/customization.md#backends-and-models) and
[changelog entry](../CHANGELOG.md#added).

## Known limitations

Literal keys are visible to anything that prints the configuration: the init
file, `C-h v vox-backend`, and backtraces. There is no masked interactive prompt
when the default lookup finds no key. Auth-source lookup uses login `apikey` and
the connecting host unless a `:key` lambda passes another host or user. Real
credential stores, microphone capture, and provider authentication remain outside
the offline suite.
