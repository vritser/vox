# 003 - Backend objects and per-session model selection

_Date: 2026-10-20. Status: Implemented, uncommitted work based on `3afd60c`._

## Background

Provider API addresses, models and credential-source settings were spread across
provider globals. A custom Qwen endpoint also bypassed the separate model setting.
The request to customize an ASR API/model initially suggested another setup
command, but the user explicitly preferred gptel's backend-object/model pattern
and then approved direct migration without old-variable compatibility.

## Decision

Group connection configuration in pure backend objects, select the backend with
`vox-backend` and the model with `vox-model`, and snapshot both for each session.

[vox-backend.el](../vox-backend.el) owns `vox-make-qwen`, `vox-make-doubao`,
validation, model membership, snapshots, and deferred credential resolution.
[vox.el](../vox.el) owns `vox-select-model` and captures configuration before
the device picker; [vox-core.el](../vox-core.el) captures session method
metadata before callbacks. The Qwen and Doubao adapters retain their separate
native wire protocols.

## Why

A backend object keeps host, endpoint, configured model IDs, key source and
provider-specific resource options together without multiplying global variables.
The gptel influence is a configuration convention, not a dependency or a claim
that ASR protocols are interchangeable. Doubao's resource ID selects an
entitlement/billing resource; it is not a Qwen model identifier.

Keeping old API/model globals as aliases was considered and explicitly rejected.
It would leave two configuration surfaces and unclear precedence instead of one
place to configure the connection. Device, silence, language/VAD and packet-size
options remain independent; this is not a blanket removal of all customization.

Configuration must be copied, not just referenced: prompts and asynchronous
callbacks can run after the user changes a model or mutates the original object.
A custom Qwen path still receives the selected model as its effective `model`
query parameter. Model completion uses the configured list without connecting or
reading credentials; an unlisted model is rejected rather than silently replaced.

Keys remain lazy functions or the default auth-source/environment lookup, not
plaintext constructor arguments or cached results in configuration records.
Endpoint approval precedes lookup. Approval and key functions can themselves
cancel the session, so adapters recheck ownership before further credential
access or transport opening. Unifying configuration must not weaken the existing
cancel/cleanup boundary.

## Consequence

Users configure objects in Lisp, optionally select a model with completion, and
migrate the five removed API/model/source globals without compatibility aliases.
An active session retains its captured configuration. See the
[migration guide](../docs/customization.md#backends-and-models) and
[changelog entry](../CHANGELOG.md#added).

[Configuration tests](../test/vox-test-config.el),
[model tests](../test/vox-test-model.el), and
[startup tests](../test/vox-test-start.el) cover the new public surface and
snapshot boundaries. [Qwen tests](../test/vox-test-qwen.el) and
[Doubao tests](../test/vox-test-doubao.el) cover captured requests, model/resource
wiring, and cancellation during approval/key callbacks. A local
`scripts/verify.sh` run passed 237 tests with no failures or skips and strict
compilation. This record identifies an uncommitted implementation against
`3afd60c`, not a new commit hash.

## Known limitations

Configured model IDs are an allowlist, not remote discovery or proof of account
access. Arbitrary OpenAI-compatible HTTP ASR APIs need their own adapter; changing
a host or model cannot make them speak Qwen/Doubao realtime protocols. Key-function
identity is retained, not its external environment: lookup is deliberately deferred.
There is no backend-profile editor or automatic configuration migration. Real
credentials, provider model availability, custom gateways, microphones and the
configured multi-version CI matrix remain unvalidated by these offline tests.
