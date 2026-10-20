# Vox development rules

Independent native Emacs streaming speech input. Public entry: `vox.el`.
Runtime module ownership: [architecture](docs/architecture.md). Keep production
Elisp at the repository root, shared test fixtures under `test/`, executable
checks under `scripts/`, detailed documentation under `docs/`, and decision
records under `postmortems/`.

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
- Compilation must not leave `.elc` files beside source. Test with source, not
  stale bytecode. Packaging stages fresh files, never a previous output tree.
- Provider integration, microphone permissions, Emacs-version CI outcomes, and
  real-time performance are separate evidence; record unverified items honestly.

## Testing

- Tests must fail when the code is wrong: assert specific, distinguishable
  values. If breaking the function under test leaves the suite green, the test
  proves nothing.
- A bug fix starts with a reproducing regression. A small expectation change may
  extend an existing test that already exercises the path.
- Mechanical moves retain test meaning and count; do not add behavior during a
  structural cleanup. Docs, comments, and cosmetic refactors need no new tests.
- Use unconditional `should`, `should-not`, or `should-error` assertions. A
  conditional body that never reaches its assertion can still pass ERT.
- Keep each test independent: bind or copy the globals and hash tables it
  mutates, and never rely on another test having run first.
- Use `skip-unless` only for a genuinely absent optional dependency, never to
  hide a broken or stale install.
- The offline suite must not open a microphone, read real credentials, or call a
  provider. Live acceptance remains a separate, explicit check.
- Optional coverage report:
  `emacs -Q --batch -l scripts/check-coverage.el [-- THRESHOLD] [--all]`
  instruments production modules with testcover, runs the suite, and lists
  definitions below the threshold (default 80%). It is diagnostic, not part of
  `scripts/verify.sh`; unexpected test failures still exit nonzero.

## Documentation

Keep README focused on quick start and navigation. Put configuration, module
ownership, and contributor workflows in their dedicated docs. Update CHANGELOG
for user-visible or developer-entry changes. Keep historical audit results dated;
add new results rather than silently changing the meaning of old evidence.

## Postmortems (decision records)

[Postmortems](postmortems/README.md) preserve the historical why; current
behavior belongs in the guides, and measured results belong with the change that
produced them (commit message or test output). Use the
[template](postmortems/000-template.md) for short, numbered records.

- Read relevant records before significant changes, then check current code;
  records constrain reasoning but are not proof of current behavior.
- Write one for a changed user-visible workflow, non-obvious architecture,
  abandoned approach, removed public surface, or deliberately accepted limitation.
  Routine bug-fix-only changes do not require one unless they expose such a choice.
- Use Background / Decision / Why / Consequence / Known limitations. Explain
  rationale and tradeoffs, not a code walkthrough; keep records factual and free
  of private data. Do not invent historical alternatives or incident impact.
- Cite actual commits and relative source/test/evidence links. Label uncommitted
  work against its base commit; distinguish offline coverage from live acceptance.
- Add each record to the index and link user-visible changelog entries back to it
  with a rationale link. Keep setup instructions in the guides and test-run
  details with the change, rather than duplicating them here.
- Preserve historical bodies. A superseding decision gets a new numbered record
  and a short linked "Superseded by NNN" note on the old one, not a rewrite.

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
