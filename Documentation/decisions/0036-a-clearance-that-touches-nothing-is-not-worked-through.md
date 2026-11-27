# 0036. A clearance that touches nothing is not worked through

Status: Accepted, 2026-11-27. `LampWritingReview.located`, held by
`locatesUntrimmedPiecesAsTheReferenceDoes`, `locatesWhatTheReferenceLocates`
and the goldens' merged fixture. R2 of `../ReviewMarksPerformancePlan.md`.

## Context

`located` takes each of a mark's clearances out of each of its ranges, one
step at a time. Each step allocates. On the owner's writing, one mark has
453 pieces and 4,136 clearance pieces, so a draw took about 1.9 million
steps. After 0035, that was 147 of a draw's 173 ms.

Almost none of them changed anything. A clear made here rewrites the mark's
own pieces, so the words it cleared are no longer in the mark. A clearance
is only still in a mark when another device's copy of that mark won the
merge. The goldens showed this first: taking the subtraction out entirely
changed no answer until a fixture of two merged devices was added.

## Decision

The first step runs as before, over every range. It trims each range,
touched or not, and after it every range is what `remainder` leaves it as.
A later step whose clearance touches none of the ranges would leave them
all as they are, so it is skipped. Any step that touches a range runs as
before.

After it: `located` took 2.0 ms instead of 147 ms, and a draw 19 ms instead
of 173 ms. A ✓'s clear took 8–12 ms. The private record's answers were the
same as before.

## Consequences

- The first step still runs where it touches nothing, because its trimming
  is what the later steps' "touches" is asked of.

## Rejected

- **Trimming every range before the first step.** A point cleared at the
  space on an untrimmed piece's edge takes the piece today, when that
  clearance comes first. Trimmed first, the point would stand outside the
  piece and keep it. `locatesUntrimmedPiecesAsTheReferenceDoes` holds both
  orders.
- **Dropping clearances from the record.** That is compaction, and
  `../ReviewMarksPerformancePlan.md` R6 records why it waits.
