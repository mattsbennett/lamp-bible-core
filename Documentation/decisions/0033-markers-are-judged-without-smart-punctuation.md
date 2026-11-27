# 0033. Markers are judged without smart punctuation

Status: Accepted, 2026-11-26. Held by
`aMarkerBesideAStraightQuoteKeepsItsPlace`
(`WritingReviewMarkdownRoundTripTests`).

## Context

Before a writing's marks go to the editor's page, `drawable` checks that
the marked Markdown reads as it does without markers. It parses both and
compares their structure. Where a line reads differently, its markers all
become points at the line's start. That loses where each passage is, but
never changes what the page shows.

The two parses used swift-markdown's default options, which turn on smart
punctuation. A marker is a private-use character, which cmark treats as a
letter, so a marker after `hell."` turned that closing quote into an
opening one. The line then "read differently", and every mark in the
paragraph became one point at its start. The owner saw a whole paragraph
of the assistant's changes shown as a single sliver (2026-11-26). In that
writing, one paragraph's 17 passages were affected.

## Decision

`LampMarkdownModel.structure(of:)` and `rendering(of:)` parse with
`.disableSmartOpts`. The judge reads as the editor's page does: it shows
quotes and dashes as written. `LampProse` already parsed this way.

## Consequences

- Markers beside straight quotes, apostrophes and `--` stay in place.
- A difference in curling was never something the writer could see, so
  nothing the page shows can now pass the check that failed it before.

## Rejected

- **Making quotes uniform before comparing.** That copies cmark's
  punctuation rules by hand, which is the kind of hand-written reader of
  Markdown the earlier rounds of review kept finding wrong.
