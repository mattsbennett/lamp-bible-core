# 0032. No marks drawn from a record that is being written

Status: Accepted, 2026-11-26. Mac d860e96 (`WritingReviewSession`), held by
`nothingSentWhileAClearIsWrittenPutsItsMarkBack`.

## Context

The owner saw a ✓ accept its passage, then unaccept it, then accept it
again about a second later. The writing page takes a block's marks off as
its ✓ is pressed. The Mac's review session then writes the clear to the
marks file, off the main actor; that can take a second on a long writing.
When the write lands, the session draws the marks again and sends them to
the page. The page always takes marks sent after a clear, even if they
match the last ones sent, because only they can put back a mark it took
off wrongly.

Two things in the gap before the write landed drew from the record as it
was before the clear, and sent its marks back to the page:

- A draw already being worked out when the ✓ was pressed, or one asked for
  meanwhile (typing settling, the page refusing marks, a ✓ that could not
  be placed).
- The once-a-second poll of the marks file: a read that overlapped the
  write could carry the earlier record, under a date other than the one
  the write left, and be taken up as news.

The clear's own draw then took the marks off again. In a test, the cleared
marks were sent back in nearly every round.

## Decision

While a change to a document's marks file is being written, nothing is
drawn for that document from the record in memory, and nothing read from
the file is taken up.

- Starting a write drops any draw being worked out, and owes one in its
  place.
- A draw asked for while the write is in flight waits for it to land.
- A poll is skipped if a write is in flight when it starts, and dropped if
  one began during its read or is in flight at its end. The next poll
  reads again.

## Consequences

- After a ✓, the page hears nothing until the clear has landed. Then it
  hears the marks as the clear left them.
- The count, restore offers and agent note also wait for the write. A
  write that changes nothing still ends in a draw, because the one it
  dropped is owed.
- Writes are rare and short, so a poll skipped for one costs a second at
  most.

## Rejected

- **Ignoring the page's own clear in later draws by matching text.** The
  page's text can be ahead of the session's, and two passages can read the
  same. The record is the only thing that knows what was cleared.
- **Applying the clear to the record in memory before writing it.** The
  edit is worked out against the file under its lock, carrying marks from
  texts the writer has held. Done twice, the two results could disagree,
  and the in-memory one would be drawn without ever having been stored.
