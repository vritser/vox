# Postmortems: decision records

These numbered records preserve why Vox chose an approach, including successful
feature work. They are not runtime diagnostic reports or an incident-only log.
The convention follows dsh-emacs: one short record per significant decision,
with Background, Decision, Why, Consequence, and Known limitations.

Current behavior belongs in [Customization](../docs/customization.md) and
[Architecture](../docs/architecture.md); measured outcomes belong with the change that
produced them. These records preserve rationale across refactors. Read relevant
records before significant changes, but verify the current implementation rather
than assuming an old record still describes it.

## Records

| Record | Decision | Implementation evidence at writing |
| --- | --- | --- |
| [001](001-short-phrase-silence-stop.md) | Local silence requests graceful stop, not insertion | `fd599e2` |
| [002](002-explicit-input-device-selection.md) | Explicit device choice with opt-in persistence | `3afd60c` |
| [003](003-backend-objects-and-model-selection.md) | Backend objects and per-session model selection | Uncommitted work based on `3afd60c` |

The first two records are retrospective, written on 2026-10-20 from committed
implementation and dated validation evidence. Record 003 describes the existing
uncommitted backend migration, not a new commit or a live-provider acceptance run.

## Writing and maintaining records

Start with [000-template.md](000-template.md) and allocate the next unused
three-digit number. Keep one decision per record, preferably about one page.
Write when changing a user-visible workflow, choosing a non-obvious architecture,
abandoning an approach, removing a public surface, or deliberately accepting a
known limitation. Routine bug-fix-only changes do not require a record unless
they expose a broader decision worth preserving.

Explain why, including meaningful alternatives and accepted tradeoffs; do not
turn the record into a source-code walkthrough. Distinguish observed failures
from potential risks, and confirmed historical choices from retrospective
analysis. Cite real commit IDs and relative links to the owning implementation,
regressions and dated evidence. Mark uncommitted work against its actual base
commit; never invent a commit or imply tests establish microphone/cloud acceptance.
Do not include credentials, private transcripts, device identifiers, or raw logs.

Link user-visible changes from the [changelog](../CHANGELOG.md) using a
rationale link to the specific record, and add new records to this index. Preserve
old records as historical evidence. When a later decision supersedes one, create
a new numbered record and add only a short linked "Superseded by NNN" note at
the top of the old record instead of rewriting its body to match current code.
Contributor requirements also live in [AGENTS.md](../AGENTS.md#postmortems-decision-records).
