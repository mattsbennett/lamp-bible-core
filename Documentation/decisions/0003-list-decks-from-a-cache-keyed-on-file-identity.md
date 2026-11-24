# 0003. Listing decks decodes only the files that changed

Status: Proposed. Needs the owner's call on trusting a modification date, below.

## Context

`LampPresentationDeckStore.decks()` reads, decodes and fully validates every
`.lampdeck` file in the library. Validation is the bulk of it: measured in a
Debug build, 400 forty-slide decks take 1 750 ms through `decks()` and 109 ms
through `decodeUnvalidated` — about sixteen times the cost of decoding, because
every slide is replanned, re-crowded and contrast-checked.

Four surfaces call it on a timer: Slide Studio once a second, the writings list
and the writing editor every two seconds each (for "which decks came from this
writing?"), and the manuscript-notes refresh after every autosave burst. Deck
sync calls it two or three more times per pass. Nothing in either app watches a
directory; the polls exist because an agent or a sync pass can write a deck from
outside the process, and in-process writers already announce themselves through
`SlideStudioInbox.deckFilesChanged()`.

## Decision

Keep one cache of decoded, validated decks, keyed on each file's size,
modification date and resource identifier (inode). A listing stats the directory
and decodes only the files whose key moved.

`decode` still validates — a deck that reaches the app's memory is still a
checked deck. `save`, `encoded` and the bytes sync merges on are untouched.

## Consequences

- A poll over an unchanged library becomes one directory listing and a stat per
  deck, which is what the cadence was always meant to cost.
- **This is the first place in the codebase that trusts a modification date for
  anything.** 0001 rejected exactly that for sync digests. The difference: this
  decides whether to re-read a file for display, not whether a file has been
  published, and a listing that misses a change self-corrects on the next write
  or launch rather than losing data. Writers replace a deck atomically, so the
  inode moves even when the date and size do not. **The owner should agree to
  the principle, not just the code.**
- The cache must be invalidated by: a rewrite at the same size with the date
  preserved (caught by the inode), a replacement with a new inode, and a removal.
  All three need a test.
- Validation errors must stay attached to the deck they came from, so a deck that
  has gone bad on disk still reports its problems rather than vanishing from a
  listing.

## Rejected

- **Dropping validation from listings** (`decodeUnvalidated` for the shelf,
  validate on open). The cheapest change by far, and it means a deck can be
  listed, presented from a list, or sent to sync without having been checked.
  Not worth the saving once the cache removes the repetition.
- **A directory watch instead of the poll.** Still worth doing later — it would
  take the idle cost to zero rather than to a stat — but it is a new mechanism in
  a codebase that has none, and the cache is the cheaper first step. Revisit if
  agent-edit latency with stat-only polling is judged too slow.
- **An index file holding id, title and `writingID`.** A fourth copy of the
  truth to keep current; the cache gives the same answer without a new file to go
  stale.
