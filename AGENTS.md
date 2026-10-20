# Vox development rules

Independent native Emacs streaming speech input. Public entry: `vox.el`.
Runtime module ownership: [architecture](docs/architecture.md). Keep production
Elisp at the repository root, shared test fixtures under `test/`, executable
checks under `scripts/`, and detailed documentation under `docs/`.

## Scope and compatibility

- Minimum Emacs 28.1. Guard newer APIs and keep package metadata consistent.
- Runtime dependencies are Emacs, websocket.el and FFmpeg, with the documented
  CLI exception. Never introduce a Python/Node bridge or reimplement RFC 6455.
- Do not modify dsh-emacs or any other project for a Vox change.
- Prefer clear module ownership over extra wrappers, layers, or speculative
  abstractions. A structural refactor must improve a concrete workflow.
- Preserve single-session ownership, generation guards, bounded queues,
  stop/cancel separation, and authoritative completion before final insertion.
- No shell interpolation of user inputs. No microphone or cloud tests without
  explicit configuration and consent. Never log keys, PCM, or private text.
- Label fixtures as official static examples, synthetic, or sanitized real
  captures. Never represent offline tests as live-provider acceptance.

## Verification

Run `scripts/verify.sh` after changes. It is the same gate used by CI: syntax,
checker/runner self-tests, strict temporary-output byte compilation, all unit
regressions, silent clean loading, whitespace, and repository hygiene. Failures
block completion; do not weaken assertions or suppress warnings to obtain green.

Useful individual entry points:

```sh
scripts/setup-deps.sh
emacs -Q --batch -l scripts/check-lisp.el
emacs -Q --batch -l scripts/compile.el
emacs -Q --batch -l test/vox-test.el
emacs -Q --batch -l scripts/benchmark.el
scripts/package.sh
```

- Tests live in `test/vox-test-SUBSYSTEM.el` with the `vox-unit` ERT tag.
- Shared helpers belong in `test/vox-test-support.el`; never require another
  subsystem's tests just to reuse a fixture.
- `test/vox-test.el` discovers the suite and rejects empty selections. Loading a
  subsystem defines tests without running them. Runner/tooling self-tests are
  separate from the product suite.
- A bug fix needs a reproducing regression. Mechanical moves should retain test
  meaning and count; avoid adding behavior during a structural cleanup.
- Compilation must not leave `.elc` files beside source. Test with source, not
  stale bytecode. Packaging stages fresh files, never a previous output tree.
- Provider integration, microphone permissions, Emacs-version CI outcomes, and
  real-time performance are separate evidence; record unverified items honestly.

## Documentation

Keep README focused on quick start and navigation. Put configuration, module
ownership, and contributor workflows in their dedicated docs. Update CHANGELOG
for user-visible or developer-entry changes. Keep historical audit results dated;
add new results rather than silently changing the meaning of old evidence.

## Commits

- Commit only when the user explicitly asks. Do not automatically push.
- One concern per commit. Use short English Conventional Commit subjects:
  `<type>: <imperative verb and single topic>`.
- Standard types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`,
  `build`, `ci`, `chore`, `revert`. Do not use module names as types.
- Put rationale or validation in the body when useful, not a multi-clause subject.
- Rewrite existing local history only with explicit user approval. First retain
  a backup ref, verify publication status, and preserve unrelated working changes.
  Never amend, squash, rebase, reset, or force-push implicitly.
