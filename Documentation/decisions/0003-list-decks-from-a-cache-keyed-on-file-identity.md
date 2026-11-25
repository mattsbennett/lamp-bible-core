# 0003. Listing decks decodes only the files that changed

Status: Accepted, 2026-11-24, held by `LampPresentationDeckListingCacheTests`.
The owner's call the first draft asked for turned out not to be needed — see
**Decision**: what is trusted is not a modification date. Amended twice since
it was written, and both amendments were review findings rather than mine: a
Codex review changed what a save does, and a Fable review found the
filesystem gate missing.

## Context

`LampPresentationDeckStore.decks()` reads, decodes and fully validates every
`.lampdeck` file in the library. Validation is the bulk of it: measured in
Release, 400 forty-slide decks take 364 ms through `decks()` against 111 ms
through `decodeUnvalidated`, because every slide is replanned, re-crowded and
contrast-checked. A stat of each of those files takes 0.4 ms — three orders of
magnitude under the listing, which is what this decision is buying.

Four surfaces call it on a timer: Slide Studio once a second, the writings list
and the writing editor every two seconds each (for "which decks came from this
writing?"), and the manuscript-notes refresh after every autosave burst. Deck
sync calls it two or three more times per pass. Nothing in either app watches a
directory; the polls exist because an agent or a sync pass can write a deck from
outside the process, and in-process writers already announce themselves through
`SlideStudioInbox.deckFilesChanged()`.

## Decision

Keep one cache of decoded, validated decks, keyed on the file's identity as
`stat` reports it — device, inode, size, modification time **and change time**
— which is what `LampDatabaseFileRevision` already captures for module files. A
listing stats the directory and decodes only the files whose identity moved.

The change time is why this needed no owner's indulgence. `decisions/0001`
refused to trust a modification date because a file replaced at the same size
with its date preserved — `cp -p`, `rsync -t`, a restore — would be skipped for
ever. `st_ctime` is the kernel's own: it is set on any change to the inode and
there is no call that sets it to a chosen value. A deck rewritten in place with
its date put back therefore reads as changed. There is a test that does exactly
that and watches the listing notice.

`decode` still validates — a deck that reaches the app's memory is still a
checked deck. `save`, `encoded` and the bytes sync merges on are untouched. A
deck the running build cannot decode or validate is left out of the listing, as
before, and nothing is remembered about it, so it is reported again rather than
disappearing from one listing and not the next.

**A save forgets what was held for that file rather than remembering what it
wrote.** The first version of this record said the opposite, and so did the
first version of the code: remember the deck just written, against the file
as it stands afterwards, so a listing that follows a save reads nothing. A
Codex review found the hole — the identity would be taken *after* the write,
and another writer (an agent, a sync pass) could replace the file in between,
at which point the cache would hand out the deck this app saved for as long
as the file sat still. So a save drops the entry and the next listing reads
the file. Held by `aSavedDeckIsReadBackOnceAndThenNotAgain`. What the cache
is for is the decks nobody touched, which is nearly all of them.

**The cache answers only for a volume whose identities mean something.** It
went in without that gate, which was an oversight and the awkward one:
`0007` had kept decks out of the *digest* cache for being mutable, while this
cached them against identity on any filesystem — exFAT, a share, or a volume
mounted inside the library (`0011`'s case), where the key degrades to size
and a synthesised change time. `decks()` and `deck(id:)` now ask
`LampSyncIdentityTrust.trustedDevice(ofVolumeAt:)` once per call — one open
and two stats of the directory, against four hundred stats of the files in
it — and the cache neither answers nor keeps anything for a file on another
device. On such a library every listing decodes every deck again, which is
what it cost before this record and what `0007` accepts for sync.

Found by a Fable review, which also corrected the severity: a stale listing
is not merely cosmetic. Four callers read a deck from the cache, change it
and save it back — Slide Studio as somebody types, the manuscript-notes
refresh, the writing-import compare-and-swap, and the Strong's analysis —
so a stale read means the next edit overwrites whatever arrived from
outside. One tier below a stale digest, which loses a file silently and
needs nothing else to go wrong, but not harmless.

The cache is one per process, shared by every store, because the store is a
value that callers make wherever they need one. Pruning a listed directory's
vanished files is therefore scoped to that directory: a first attempt pruned
everything else as well, which would have had the phone's two deck stores — a
synced root and an imported one — empty each other's entries on every listing.
A test over two libraries caught it.

## Consequences

- A poll over an unchanged library becomes one directory listing and a stat per
  deck, which is what the cadence was always meant to cost.
- Nothing in the codebase trusted a file's metadata to decide whether to re-read
  it before this. What makes it safe is the change time rather than the
  modification date, and that distinction is worth keeping in mind elsewhere:
  it also means `decisions/0001`'s objection to a digest cache for sync was
  aimed at a weaker key than the one available. Whether that changes 0001 is a
  separate question, and it is being asked rather than assumed.
- The cache is bounded at 512 decks, least-recently-used first. A library's
  decks decoded are tens of megabytes, and the values handed out are the same
  values the caller holds, so the cost is one copy rather than two.
- Invalidation is tested three ways: a rewrite in place at the same size with
  the date put back, a wholesale replacement, and a removal. A file that will
  not decode is tested too, since the absence of a negative cache is what lets
  a repaired deck appear.
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
