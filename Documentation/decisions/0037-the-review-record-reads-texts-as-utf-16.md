# 0037. The review record reads its texts as UTF-16

Status: Accepted, 2026-11-27. `LampTextSearch.native`, held by the goldens
(`LampWritingReviewGoldenTests`). R3 of `../ReviewMarksPerformancePlan.md`.

## Context

After 0035 and 0036, a carry after one word typed still took 70 ms on the
owner's writing, and a save's carry 110 ms. The whole-text work in it is
about 13 ms: hashing, tokens, the alignment and an index. A profile showed
most of the rest in Swift's `UTF16View` index lookups and copies, called
from `piece(_:in:)`.

The reason is the wrapping. `text as NSString` wraps a Swift string, which
is UTF-8. Every unit Core Foundation reads through the wrapper, and every
substring it cuts, is worked out from the UTF-8 again. A carry builds 48
characters of context for each piece it moves, which is thousands of
pieces.

## Decision

The texts the record searches and cuts pieces from are copied once into a
string Foundation holds as UTF-16 (`LampTextSearch.native`). That covers:

- a draw's search;
- a carry's target and sources;
- a clear's text;
- the texts `restorable` and `changes` read.

The units are read from the wrapper itself, so they are the ones it would
have reported. Every offset and every comparison is the same.

After it, the measurements were:

- a carry after typing: 35 ms;
- a save's carry: 61 ms;
- instructions retired for that carry: 1.77 billion down to 0.78 billion.

The private record's answers were the same as before.

## Consequences

- One copy of the text, about 114 KB for this writing, for each piece of
  work.
- A carry from many held texts is still about 180 ms. Most of that is one
  alignment and one search for each text a piece is anchored in, and it
  runs off the main thread.

## Rejected

- **Reading the units through `Array(text.utf16)`.** A string that came
  from Foundation and holds half a surrogate pair reads that half there as
  U+FFFD. 0035's differential test caught the same thing for needles.
