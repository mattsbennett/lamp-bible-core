# 0015. Writing revision history keeps its policy and its format

Status: Accepted, 2026-11-24 — the decision is to change nothing, so the code
already holds it. Three sub-options rejected, each for its own reason. The
measurements are in `../ScalabilityPlan.md`; the defect they turned up is
`0016`.

## Context

A writing's revision history is one self-contained JSON file per revision,
each carrying the whole document on both sides (`beforeMarkdown`,
`afterMarkdown`), in `.lamp/revisions/` inside the workspace. The store is
`lamp-bible-macos/Sources/LampBibleMacSupport/AgentRevisionSupport.swift`;
revision history is **Mac-only** — the phone carries the files through sync
but never decodes one.

The scalability pass asked whether that costs too much, and left three
sub-options open: cap the count, store diffs, or compress the two Markdown
fields.

Measured on the owner's real library, with their permission: 14 writing
workspaces, 4 of them carrying history, **125 revision files, 9.03 MB,
against 0.25 MB of live Markdown — 36×**. 75 of the 125 carry
`replacedRevisionIDs`, so this is a figure *after* tiered compaction has run,
not a backlog.

## Decision

**Leave the policy and the format.**

- **A count cap is rejected on mechanics.** Revision folders merge by union,
  and only a file that names what it replaced stays dropped
  (`removingReplaced`), so a capped revision comes back. It comes back from
  two directions, not one: another Mac of the same owner still holding the
  original, and — `0016` — the server, which never compacts and which no
  tombstone covers. A cap would need its own tombstones for revision files,
  which is the format change it was meant to avoid. Tiered compaction is
  already a convergent cap by time; a count cap adds nothing it can do
  convergently.

- **Diffs are rejected.** No `apply` exists, and a chain breaks when a
  predecessor is compacted away on one Mac while another holds its child.
  Today every revision is self-contained and a restore is a copy.

- **Compression is rejected on its saving.** gzip over the actual 125 files
  gives 9.03 MB → 3.55 MB: **2.5×**, so about 5.5 MB. The same workspaces
  hold 401 MB on disk, nearly all of it context PDFs a writing was given —
  one is 87 MB alone. The saving is ~1.4% of what a workspace already weighs,
  less than one context PDF, in exchange for a breaking format change, a
  fixture and coverage prose.

## What was wrong on the way here

**The fixture promised 44× compression.** `measuresWhatRevisionHistoryCostsAtRest`
built its before/after pairs with `String(repeating:)`, so each pair was
near-duplicate synthetic text, which zlib crushes. Real prose gives 2.5×. The
error is about eighteenfold and it is the whole of the case for compression:
with 44× the plan held compression as the cheap standby, and at 2.5× there is
nothing to be standby *for*. A conclusion that rests on a fixture's
compressibility is worth re-taking on real files.

The same fixture writes 50 contiguous `userEdit` singles an hour apart and
reads them straight back, which the standard policy would merge on first
open — so its "at rest" is pre-compaction history the store never leaves at
rest. Its 17× is not comparable to the real 36×, and the real figure being
the *larger* of the two is the surprise.

**And a rejection was taken for the wrong reason, then withdrawn.** An
earlier revision of the plan (core `99f5d5a`) rejected compression because
`storedRevisions` decodes with `compactMap`/`try?`, so a Mac on an older
build would omit, silently, history it could not read — no error, no mark —
and `compact(in:)` is deliberate that *"history this version cannot read is
not history it is entitled to discard."* Both facts are true. The reasoning
was not:

- The plan had already described that behaviour and counted it a **virtue**
  ("an older Mac that cannot read it leaves it alone rather than deleting
  it"). Relabelling it "the one real cost" added no new fact.
- Version skew is a **sequencing constraint**, not a property of a format. A
  breaking change to a synced write-once file has a standard remedy, below.
- It proves too much. Taken as a veto it would reject almost any format
  change to a synced file.

What it does establish is the distinction the plan needed: an additive
optional field on a write-once file is forward-compatible, and revisions have
taken four of those without a side list. Compression changes the
representation of a **required** field, so an older reader's decode fails.
Breaking, not additive. The side-list rule for merged records applies to
records both sides rewrite; revisions are not those.

## What follows

- **A breaking change to a synced write-once format ships its reader a
  release ahead of its writer.** One line, costs nothing, and it is the whole
  of what the skew argument was reaching for.
- **No version marker in the revision JSON.** A marker only helps a reader
  that already knows it, so it would have to ship ahead of a change nobody is
  planning — which is what reader-first already covers. The phone treats
  these files as opaque.
- **The existing 9 MB carries no migration duty.** The owner's position,
  2026-11-24: "I don't care about my existing revision history." It may be
  deleted outright if it is ever in the way.
- **History's cost is not bytes at rest**, which is what this record's
  measurements were about. See `0016`.
