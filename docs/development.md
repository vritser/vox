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

# Optional per-definition coverage report; diagnostic, outside the gate.
emacs -Q --batch -l scripts/check-coverage.el

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

## Reload without restarting Emacs

After updating this checkout, run `M-x vox-reload`. It reads all root-level Vox
sources first, checks their top-level internal `require` dependencies, then loads
them in dependency order using explicit `.el` paths. The package descriptor is
excluded, and stale `.elc` files do not override the selected sources. This is
similar to dsh-emacs's source reload, without depending on that package.

If your running Emacs predates this command, first evaluate the following while
Vox is idle (adjust the source path), then use `M-x vox-reload` for later updates:

```elisp
(load "/path/to/vox/vox-reload.el" nil t t)
(vox-reload)
```

The default directory is the loaded package's source directory, not the current
buffer's directory. Lisp callers can explicitly use `(vox-reload "/path/to/vox")`;
only trusted local source directories are supported.

- Finish with `vox-stop` and wait for completion, or explicitly discard with
  `vox-cancel`, before reloading. Reload refuses any active session, pending
  startup, device discovery/selection, active minibuffer or nested reload. It
  never stops or restarts a recording on your behalf.
- Settings, backend/model selection, input device, selection history, the last
  transcript, event-log contents and generation counter remain intact. Custom
  backend registrations under independent names survive; built-in registrations
  (`qwen`, `qwen-audio`, `doubao`, `cli`) refresh from source.
- Functions and constants refresh. Package keymap defaults update in place,
  replacing ad-hoc edits to those maps. Mode-line image caches are invalidated,
  but user placement/removal of the indicator is preserved. Buffer text, point,
  narrowing, transcript/log snapshots and user keybindings are not recreated.
- This is not an unload or a state migration. Removed definitions remain
  resident, and retained `defvar`/`defcustom` values do not reset to changed
  defaults. Restart Emacs for struct-layout or state-initialization changes.
- Read errors, missing internal source files and dependency cycles fail before
  evaluation. Evaluation itself is not transactional: an error or quit can leave
  some definitions updated. Fix the source and reload again, or restart Emacs.

Source reload does not run the verification gate; run `scripts/verify.sh` before
using edited code. It does not open a microphone, resolve credentials or start a
provider connection. See [decision 011](../postmortems/011-idle-source-reload.md).

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

`scripts/check-coverage.el` is an optional diagnostic, not a gate. It instruments
the production modules with testcover and lists definitions below 80% coverage.
`vox.el` is excluded because Edebug changes `called-interactively-p` inside the
interactive commands its tests exercise.

## Benchmark and acceptance

The accelerated benchmark models 600 seconds of synthetic PCM. It checks exact
frame/byte counts, one commit of final text, and cleaned resources. It is **not**
a real-time latency, microphone, network, CPU-utilization, or UI-responsiveness
measurement. Keep measured results separate from expectations.

An earlier local run's test count is historical, not the current count. Record
each run's environment, count, skips, and actual results with the change; do not
reuse old figures as proof of a new run.

Before claiming production acceptance, manually verify both providers with
region-correct credentials and microphone consent:

- Exercise both Qwen protocols separately: Realtime `session.finished` and
  task-streaming `task-finished`, including sentence revisions and stop tails.
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
compiling development-only files during package installation. All runtime
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
release is cut. Audit records retain their historical claims; a documentation
refactor does not establish new provider acceptance.

### Postmortems as decision records

Read relevant [postmortems](../postmortems/) before significant changes,
then verify the code still matches the assumptions. For workflow, architecture,
public-surface removal, or deliberately deferred behavior decisions, start from
[the template](../postmortems/000-template.md) and follow the
[contributor rules](../AGENTS.md#postmortems-decision-records). Routine bug fixes
still need regression tests, but do not automatically need a decision record.

Keep records short, numbered and evidence-backed. Add a rationale link from the
corresponding changelog entry. Cite real commits, or explicitly identify
uncommitted work and its base; do not recast a potential failure as an observed
incident. Superseding decisions get a new record and a linked note on the old
one. The guides explain current behavior and records explain historical choices.
