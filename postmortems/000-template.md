# NNN - One-line decision title

_Date: YYYY-MM-DD. Status: Implemented / Proposed / Superseded._

_Implementation evidence: cite actual seven-character commit IDs. For unfinished
or uncommitted work, write "Uncommitted work based on COMMIT" and identify which
parts are implemented versus proposed. A retrospective record should say so._

## Background

What existed before, and what concrete problem motivated the change? Identify
the owning layer and distinguish an observed failure from a potential risk.
Link the relevant implementation or prior record; do not include private data.

## Decision

State the choice in one sentence. Identify module ownership and any public
surface added, changed, or removed. A decision can document successful feature
work; it does not require an outage or bug.

## Why

Explain why this approach solves the problem, rather than repeating the code.
Describe meaningful alternatives and the tradeoffs accepted. Do not invent a
historical debate: label retrospective comparisons when they were not recorded
at the time.

## Consequence

Describe the effects on users and future contributors, including migration or
invariants that later changes must preserve. Link the owning source and tests,
and the dated validation evidence without treating offline tests as live
acceptance. Add a rationale backlink from the relevant changelog entry.

## Known limitations

Record deliberately deferred behavior, accepted costs, and unverified acceptance
checks. If a later decision changes these, create a new record and add a linked
"Superseded by NNN" note at the top of this file; do not rewrite the historical
body to claim the new behavior was always present.

---

Use the [writing rules](../AGENTS.md#postmortems-decision-records).
Keep the finished record about one page; remove these instructional paragraphs
when filling it in. Current setup belongs in the configuration guide, and test
run details belong with the change that produced them, not duplicated here.
