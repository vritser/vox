# Development

Vox targets Emacs 28.1+. Production Lisp stays at the repository root; reorganizing
development tools does not change the public API. Follow [AGENTS.md](../AGENTS.md)
and the [module ownership map](architecture.md), and keep changes focused.

## Verification

Run from the repository root:

```sh
scripts/setup-deps.sh
scripts/verify.sh
```

The dependency setup downloads the exact audited `websocket.el` revision to
ignored `.deps/` and checks its pinned SHA-256. It is a development dependency,
not vendored package code or a reason to change your normal Emacs load path.
See the [transport audit](transport-audit.md) for the audited source.

`scripts/verify.sh` is the shared local and CI gate. It runs static Lisp syntax
checks, tool self-tests, strict byte compilation into a temporary directory, the
full ERT suite, silent clean loading, `git diff --check`, and repository junk
checks. Compilation must not leave `.elc` files in the source tree. Investigate
a failure before proceeding; inspect skipped test counts as well as failures.
A configured CI matrix is not evidence that CI has run.

Individual entry points:

```sh
# Full offline ERT suite.
emacs -Q --batch -l test/vox-test.el

# Strict production compilation into a temporary directory.
emacs -Q --batch -l scripts/compile.el

# Accelerated synthetic PCM benchmark, not a wall-clock UI test.
emacs -Q --batch -l scripts/benchmark.el

# Clean load: no output, recording, or connection should occur.
emacs -Q --batch -L . -l vox.el
```

These scripts replace the Makefile entry points. No `make` invocation is needed.
The shell entry points accept `EMACS=/path/to/emacs` and locate the repository
from their own paths, so they also work when called from another directory.
The full gate requires FFmpeg, `sh`, websocket, and native GnuTLS/zlib support;
it fails preflight rather than silently skipping dependency coverage. Direct ERT
runs can skip genuinely unavailable optional dependencies. The suite does not
read cloud credentials or open a microphone.

## Test ownership

- `test/vox-test.el` is only the loader and batch runner.
- Subsystem cases live in `test/vox-test-<subsystem>.el`.
- `test/vox-test-support.el` owns shared test macros and load-path setup.
- Add regressions to the owning subsystem, not the runner or shared support.
- Keep fixtures and cleanup local so individual tests and reruns are meaningful.
- Fixture origins and limitations are in [fixture provenance](../test/fixtures/README.md).

Prefer a failing regression before a behavioral fix. Assert distinguishable
outcomes; do not hide missing assertions behind conditional branches. Unit tests
use offline provider fakes and synthetic processes, not live cloud acceptance.
Tool self-tests exercise the development tools separately from runtime behavior.

## Benchmark and acceptance

The accelerated benchmark models 600 seconds of synthetic PCM. It checks exact
frame/byte counts, one commit of final text, and cleaned resources. It is **not**
a real-time latency, microphone, network, CPU-utilization, or UI-responsiveness
measurement. Keep measured results separate from expectations.

The [validation ledger](validation.md) records an earlier local run of **82 ERT
tests**. That is a historical measurement, not this restructuring's test count.
Record the current run's environment, count, skips, and actual results separately;
do not reuse old figures as proof of a new run. Historical `make` commands in the
ledger describe that earlier workflow.

Before claiming production acceptance, manually verify both providers with
region-correct credentials and microphone consent:

- 30-60 seconds of Chinese/English speech, multiple revisions, and final events
  after stop, without duplicate insertion.
- Silence, invalid keys, network loss, and cancellation.
- Doubao's real `bigmodel_async` handshake, microphone stream, no-audio final
  packet, stored-block gzip acceptance, and authoritative final response.
- A ten-minute **wall-clock** UI responsiveness/capture/network run.
- Live TLS bad-certificate and hostname rejection, plus supported Emacs versions.

Authenticated cloud recognition has not been validated; **Doubao remains
experimental**. Bounded queues do not make native writes nonblocking, and native
gzip decoding cannot impose a hard allocation cap. Preserve these disclosures
when reporting results. See [protocol audit](protocol-audit.md),
[transport audit](transport-audit.md), and
[privacy limits](customization.md#queueing-transport-and-privacy-limits).

## Packaging

```sh
scripts/package.sh
```

The package script runs the verification gate, then builds `dist/vox-VERSION.tar`
in a fresh temporary staging directory. It derives `VERSION` from the header in
[vox.el](../vox.el) and checks [vox-pkg.el](../vox-pkg.el) for agreement; the archive
name is not hard-coded. The tar is a multi-file Emacs package; use
`M-x package-install-file` after making the `websocket` dependency available.
The package descriptor, scripts and tests use `no-byte-compile` markers to avoid
compiling development-only files during package installation. All nine runtime
modules still compile normally and are checked strictly by the gate. Building an
archive does not install it into your user profile. Generated archives are not
source files.

## Commits and history

Commit only when the user explicitly asks. Use a short English Conventional
Commit subject with one theme:

```text
<type>: verb + single topic

fix: reject incomplete CLI output
test: split subsystem coverage
docs: clarify provider setup
```

Standard types are `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`,
`build`, `ci`, `chore`, and `revert`. Do not invent subsystem types such as
`audio`, `core`, or `qwen`; name the subsystem in the subject instead. Split
unrelated concerns rather than enumerating them in one long subject.

Reword existing history only with explicit authorization. Preserve commit trees
and retain a backup reference before authorized rewording; verify the resulting
tree is unchanged. Permission to reorganize or reword local history is not
permission to push, force-push, or discard working-tree changes.

## Documentation

Keep the [README](../README.md) focused on getting started, keys, and navigation.
Put setup and integration details in [Customization](customization.md), workflow
in this guide, and ownership in [Architecture](architecture.md). Add user-visible
changes to [CHANGELOG.md](../CHANGELOG.md) under `0.1.0 - Unreleased` until the
release is cut. Audit records and the validation ledger retain their historical
claims; a documentation refactor does not establish new provider acceptance.
