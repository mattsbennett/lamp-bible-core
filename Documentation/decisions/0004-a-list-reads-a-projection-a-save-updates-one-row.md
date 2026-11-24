# 0004. A list reads a projection; a save updates one row

Status: Proposed. One piece of it landed early on 2026-11-24:
`LampLibrary.devotional(moduleID:id:)`, the single-entry read the agent tools
needed, held by `LampSingleDevotionalReadTests`. The projection and the save
path are still to do.

## Context

Both apps draw their writings list from the whole corpus, in memory, with every
writing's body in hand.

- `LampLibrary.devotionals()` selects every column of every row of
  `personal_devotionals` — body, content JSON, media JSON — plus the entire
  `devotional_entries` table of every installed devotional collection, decoding
  those rows' content JSON to plain text, then sorts the lot inside one actor
  call.
- The Mac reassigns `LibraryModel.devotionals` from that call after **every**
  save, and autosave fires 1.5 s after a change. The published array re-runs the
  list body, which filters the corpus again — in the same frame, on the main
  actor, over full body text (155 ms at 4 000 writings, Debug).
- iOS decodes every writing's content JSON to draw a list of titles, and its
  filter uses `lowercased().contains`, measured as four times slower than
  `localizedCaseInsensitiveContains` on the same text.

So the cost of showing a list, and the cost of typing one sentence, are both
proportional to everything the person has ever written.

## Decision

A list reads only what a row draws: id, title, subtitle, date, category, series,
last-modified and a snippet. Bodies are read when a writing is opened.

A save updates the one row it saved and splices it into the list in place, rather
than reloading the corpus.

## Consequences

- Two properties of the current reload have to be kept, and they are why it was
  written that way (see the comments at `LibraryModel.swift:1707`): a save must
  still notice that a newer copy arrived from another device, and a
  first-ever save must still appear in the list. Keep the full reload on the
  refusal path and after a sync pass; splice only on the ordinary success path.
- The error fallback stays: a list that will not read is not a writing that was
  not saved, and the writer must never be told otherwise.
- A projection means a second shape for a writing. Better that than a
  `LampDevotional` whose body is sometimes absent and sometimes not — a
  half-populated model is a bug waiting for the one caller that reads the field
  nobody filled.
- The snippet has to come from somewhere cheap. Either store it at save time or
  take it from the first n characters of the body column in SQL; do not decode
  content JSON to produce it.

## Open, for the owner

Routing the **text search** through the existing FTS index
(`devotional_entries_fts`, and iOS's unused `devotional_fts`) instead of a
substring scan would make search cheap at any size, but it changes what matches:
tokens and prefixes, not arbitrary substrings. "ggle" would stop finding
"struggle". That is a product decision, not an optimisation, and it is separate
from everything above — the projection alone removes the memory and the reload
cost whether or not search moves.

## Rejected

- **Keeping the corpus in memory but filtering off the main actor.** Helps the
  frame, keeps the memory, and on a phone memory is the constraint that ends with
  the app being killed.
- **Paging the list.** The list is sorted and grouped by things a page boundary
  cannot see; a projection makes paging unnecessary at the sizes in question.
