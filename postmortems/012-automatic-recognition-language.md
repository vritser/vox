# 012 - Configure Qwen recognition language per backend

_Date: 2026-10-21. Status: Implemented in uncommitted work based on `d159323`._

## Background

The Qwen adapter used the global `vox-qwen-language`, defaulting to `"zh"` and
accepting nil for automatic recognition. The initial uncommitted approach only
changed that global's default to nil and kept its Lisp/Customize interface. The
user rejected the global setting and requested language at backend construction
instead. That global-default-only approach is abandoned, not a compatibility
layer retained by this decision.

## Decision

Use `(vox-make-qwen NAME :language STRING-OR-NIL)`, with nil or omission meaning
automatic detection, and remove `vox-qwen-language` without an alias or fallback.
Each Qwen backend owns its language independently. This supersedes the language
exception in [decision 003](003-backend-objects-and-model-selection.md), while
leaving that historical record and the separate VAD options unchanged.

[vox-backend.el](../vox-backend.el) owns the shared `vox-backend` language field,
constructor configuration, and detached copies. Public startup in
[vox.el](../vox.el) and session setup in [vox-core.el](../vox-core.el) capture
language with the rest of backend configuration before device prompts, state
callbacks, or credential lookup can mutate it. The
[Qwen adapter](../vox-backend-qwen.el) serializes only that captured language;
nil omits the hint. No language support is added to Doubao or the CLI.

## Why

Automatic detection avoids imposing Chinese on every new configuration. A
constructor option lets named Qwen backends retain different language choices
and use the existing backend/model selection workflow. A shared global would
make otherwise independent backend configurations depend on ambient state.
Keeping it as a fallback would also introduce two configuration surfaces and
unclear precedence, contrary to the requested direct migration.

Copying the language string, not just referencing it, preserves the established
startup/session snapshot boundary across reentrant device and credential
callbacks. A shared struct field does not imply shared wire semantics or new
language support in every adapter. No extra picker, UI, or command is needed.

## Consequence

Users move explicit language settings into Qwen constructors and remove obsolete
init-file or saved Customize settings. Nil/omitted language selects automatic
detection; named backend selection can switch languages for a later recording
without changing an already captured session. The
[configuration guide](../docs/customization.md#recognition-language) gives examples.

Adding a struct field requires restarting Emacs. As recorded in
[decision 011](011-idle-source-reload.md), `vox-reload` does not migrate retained
structs or remove obsolete definitions. No reload migration is promised.

[Configuration tests](../test/vox-test-config.el),
[startup tests](../test/vox-test-start.el), and
[Qwen request tests](../test/vox-test-qwen.el) are the relevant offline
regression surfaces for construction, snapshot isolation, and wire serialization.
These offline checks do not establish live acceptance.

## Known limitations

The selected Qwen model determines supported language codes and recognition
quality. Automatic detection is provider behavior, not a local language detector.
Doubao language support and the CLI contract are unchanged; an external CLI
continues to own its language options. Offline configuration/request checks
cannot establish live multilingual accuracy.
