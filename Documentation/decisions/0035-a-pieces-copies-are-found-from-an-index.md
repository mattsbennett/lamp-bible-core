# 0035. A piece's copies are found from an index of the text

Status: Accepted, 2026-11-27. `LampTextSearch`, held by
`LampTextSearchTests` and `LampWritingReviewGoldenTests`. R1 of
`../ReviewMarksPerformancePlan.md`.

## Context

A review mark's piece is found in a text by its words and context. A piece
anchored in another text is found by searching for its context, and
`find` accepts a match only where it stands once. `only` proved that by
scanning the whole text from each match on. A draw places every piece not
anchored in the text, and the owner's writing had 3,957 such pieces: 963
clearances, all of one long passage the owner had read through a word at a
time. One draw was about 4,000 scans of a 57,000-unit text. A carry asks
the same for each piece in each held text.

Measured on that writing in Release, with the R0 harness, before this
change: a draw took 1,627 ms, `anchored` 1,290 ms of it. A ✓'s clear took
1,276 ms, a save's carry 2,038 ms, and a carry after typing a word 1.7–2.5 s.

## Decision

One `LampTextSearch` is made for each text a piece of work searches. The
draw shares one between `anchored` and `located`, and a carry keeps one for
each source and one for the target.

- **Candidates from the index.** It finds a needle's copies from an index
  of where each run of four UTF-16 units stands. The candidates are the places of the
  needle's rarest run.
- **Matches confirmed as before.** Each candidate is confirmed by Core
  Foundation's literal comparison anchored at that place, so what counts as
  a match is decided as before.
- **Short needles and few looks still scan.** A needle shorter than four
  units scans as before. So do a search's first three needles, and every
  needle of a search made for one look (the static `find` and `unique`).
  Building an index costs more than a few scans, and a carry asks some
  held texts about one stale piece and nothing more. Codex's review found
  that the first version built an index for every held text whatever it
  was asked.
- **The needle's units.** These come from its `NSString`, the units Core
  Foundation compares.
- **`exact`'s fast path.** `exact` compares units first and makes a
  substring only when they differ. Swift compares strings canonically, so
  differing units can still be the same words, and that case is still
  asked.

After it: a draw took 173 ms, with `anchored` at 4.8 ms. A ✓'s clear took
167 ms, a save's carry 110 ms, and a carry after typing 65–70 ms. The
private record's 256 answers were the same as before.

## Consequences

- What is left of a draw is `located`'s subtraction (0036).
- A carry across many held texts builds an index for each, which is most
  of the 200 ms that a carry from 24 texts takes.

## Rejected

- **A matcher written in Swift.** It may differ from Core Foundation at
  composed characters, and nothing else in the record is decided that way.
- **Caching anchors by the text's digest, or storing them.** A cache is
  unnecessary once finding is cheap. Storing anchors would resend the record
  on every edit.
- **Reading the needle through Swift's `utf16` view.** The differential
  test caught this. A needle cut inside a surrogate pair reads the half left
  as U+FFFD there, so the index missed copies the comparison finds.
