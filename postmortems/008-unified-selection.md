# 008 - One backend/model selection

_Date: 2026-10-21. Status: Implemented, uncommitted work based on
`b84cded5d964aaa4685c694ef93e95abe9b284b8` (`b84cded`)._

## Background

[003](003-backend-objects-and-model-selection.md) separated connection objects
from model selection. The uncommitted candidate-directory implementation in
[007](007-backend-candidate-selection.md) added a backend picker but retained two
current globals and two commands. The direct user request supersedes that design:
keep the candidate directory, select a backend/model pair in one command, and
remove the obsolete global state without historical compatibility.

## Decision

Use `vox-selection` as the sole next-session choice and `vox-select` as its
interactive command. Nil resolves the first backend and first model in
`vox-backends`; `(NAME nil)` resolves that named backend's first model;
`(NAME MODEL)` resolves an explicit symbol/string model; a registered protocol
symbol (`cli`, the built-in `qwen`/`doubao` factories, or an extension) selects
that backend with no model choice. The default directory contains Qwen.

[vox-backend.el](../vox-backend.el) owns directory validation and detached
selection resolution. [vox.el](../vox.el) owns pair completion, stale-prompt
checks, and capture before device prompting. [vox-core.el](../vox-core.el)
retains session ownership and captures method metadata before callbacks.
Explicit backend/core APIs accept their own model and default to that backend's
first model independently of global selection. The backend struct, constructors,
accessors, registry, and provider contracts remain.

## Why

One name/model value removes precedence between independent current settings and
lets a single completion choose exactly the pair the user intends. The directory
owns endpoint and credential configuration; the selection does not duplicate it.
Names are unique and case-sensitive. Missing or renamed names, unregistered
symbols, and invalid models are errors, so stale configuration cannot silently
select a different provider.

Completion uses quoted pair labels to avoid ambiguity when names contain
separators. It compares directory object identity and detached configuration,
as well as the current selection and successful-picker revision, after the
prompt. Reentrant changes invalidate the older prompt without undoing a newer
choice. This also detects a nested successful selection that chooses the same
pair. Configuration snapshots protect the running session from later mutations.

## Consequence

Users migrate old backend/model globals and picker bindings to the directory,
selection, and unified command as described in the
[configuration guide](../docs/customization.md#backends-and-models). A former
`(setq vox-backend 'qwen)` and other registered symbols keep a default role as
`(setq vox-selection 'qwen)`. There are no aliases or migration shims. Omitted
models in explicit backend/core calls no longer read global state. Selection reads
no keys, opens no connection, and persists no configuration. The
[changelog](../CHANGELOG.md#added) links this decision.

[Selection tests](../test/vox-test-backend-selection.el),
[startup tests](../test/vox-test-start.el),
[core model tests](../test/vox-test-model.el), and
[configuration tests](../test/vox-test-config.el) exercise defaults, exact
resolution, rejection, reentry, and snapshot ownership with synthetic offline
fixtures. Provider tests retain captured-model and credential/transport guards.
The verification gate is [scripts/verify.sh](../scripts/verify.sh); run output
is evidence for this uncommitted change, not live-provider acceptance.

## Known limitations

The directory requires backend objects and a nonempty list for pair completion;
registered symbols stay valid as a selection value but are not directory entries
and are not offered by the picker. CLI-only users can set `vox-selection` to
`cli` directly without a directory. Validation is all-or-nothing: a malformed
entry blocks every directory resolution, including named ones, until it is
fixed. Any
directory change during a prompt requires retrying, including changes to an
unchosen entry. There is no remote model discovery, persistence, profile editor,
or compatibility layer for already loaded old definitions; restart Emacs after
migration. Configured models are an allowlist, not proof of provider support or
account access. Microphones, cloud authentication, real-time performance, and
the multi-version Emacs CI matrix remain separate acceptance checks.
