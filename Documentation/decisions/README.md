# Decision records

One file per decision that changes a shape, a rule, or what the code is allowed
to trust. Numbered in the order they were taken, `NNNN-short-title.md`.

A record is worth writing when a reader a year from now would otherwise ask "why
is it done this way?" and the answer is not in the code. That includes decisions
*not* to change something: a rejected shortcut, written down, stops being
re-proposed every time someone notices the cost.

Each record says: the context, the decision, what follows from it, and what was
rejected. Short — a page is plenty. The code says what it does; the record says
why this and not that.

**Status** is one of:

- `Proposed` — the decision is made in principle but not implemented, or it is
  waiting on a measurement or an owner's call. Say which.
- `Accepted` — in the code.
- `Superseded by NNNN` — left in place, never edited away. A record is history;
  it is not documentation of current behaviour, which is the one exception to
  "docs describe current code only".

When a `Proposed` record lands, change its status and name what landed it — an
earlier commit, or the tests that hold it, since a commit cannot cite its own
hash. When a decision turns out to be wrong, write the next record and
supersede this one rather than rewriting it.

A record is also where a *wrong* answer belongs, not only the right one. Three
of these carry the keys and conditions that were tried first and failed, and
why: a reader deciding whether to revisit one needs to know what has already
been ruled out by something other than taste. 0002's first two keys were
useless and then unsound; 0007 trusted a filesystem it should not have; 0008
removed a snapshot without noticing what had depended on it; 0009 is the
answer, with three alternatives measured and rejected, and 0010 is the second
thing that snapshot had been doing silently. 0008 also carries a measurement
that measured the wrong thing, and what it cost to believe it.

Records 0001–0013 come out of the scalability pass of 2026-11-24
(`../ScalabilityPlan.md`), which holds the measurements and the sequencing.
