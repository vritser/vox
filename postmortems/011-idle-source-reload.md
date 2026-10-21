# 011 - Reload local source only between recording sessions

_Date: 2026-10-21. Status: Implemented in uncommitted work based on `7194d6c`._

## Background

Updating Vox previously required restarting Emacs or manually loading individual
modules. Reloading only the public entry leaves already-provided dependencies
unchanged. The requested workflow follows the local dsh-emacs source reload:
explicit source loads, dependency ordering, retained configuration and refreshed
presentation, without adding a dependency on dsh-emacs.

Vox retains session structures, backend methods and lexical callbacks during
recording and finalization. [Decision 005](005-reentrant-stream-ordering.md)
explains why a single-threaded event loop does not exclude callback reentry.

## Decision

Add `vox-reload` as an idle-only source reload. Read all local package source
forms and order top-level internal dependencies before evaluation. Preserve
ordinary variables, settings, history and session generations; refresh functions,
constants, package keymap defaults and mode-line caches.

Reject active session ownership, pending startup, device operations, active
minibuffers and nested reloads. Startup and device entry points also reject
reentry during reload. Never automatically stop, cancel or restart a recording.

## Why

An active-session reload would combine captured old callbacks with newly loaded
functions. Requiring an explicit stop or cancel avoids silently discarding speech
and avoids introducing a migration protocol. A pending-start guard covers user
callbacks that run before a session has published ownership. During reload,
temporary entrypoint advice also blocks older loaded implementations that do not
yet check the reload flag; it is removed on success, error or quit.

Explicit `.el` paths avoid stale bytecode without changing Emacs's global suffix
resolution. Ordinary `defvar`/`defcustom` semantics retain user choices; sparse
keymaps refresh in place so existing clickable text keeps working. Suppressing
initial mode-line placement during reload preserves user relocation or removal.

## Consequence

[vox-reload.el](../vox-reload.el) owns source discovery, preflight, loading and
presentation refresh. [Core](../vox-core.el), [public startup](../vox.el)
and [device selection](../vox-device.el) share narrowly scoped exclusion
flags. The registry is retained; built-in protocol registrations refresh while
independently named custom registrations survive.

[Offline regressions](../test/vox-test-reload.el) cover refusal paths, preflight
failures, stale-bytecode bypass, repeated real source loads in a fresh Emacs,
state and keymap preservation, old callback rejection and recovery after load
errors or quit. Fixtures are synthetic, not microphone or live-provider evidence.
Current instructions are in the [development guide](../docs/development.md#reload-without-restarting-emacs)
and the [changelog](../CHANGELOG.md#added).

## Known limitations

Evaluation is not transactional. Read/dependency preflight cannot detect every
runtime error or arbitrary side effect in trusted source or user load hooks.
A failed load can leave partial updates; fix and retry or restart Emacs. Only
top-level quoted `require` forms participate in dependency ordering.

Removed definitions remain resident. Retained structs, state initialization and
changed variable defaults are not migrated; restart Emacs when those change.
Ad-hoc edits to package keymaps and overrides of built-in backend registrations
are replaced. Reload itself provides no live recorder/provider acceptance.
