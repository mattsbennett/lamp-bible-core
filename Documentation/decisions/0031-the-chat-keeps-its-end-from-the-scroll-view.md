# 0031. The chat keeps its end from the scroll view, not from a row

Status: Accepted, 2026-11-26. Mac db57662 (`ChatScrollEndKeeper`).

## Context

SwiftyChat's chat view is a `ScrollView` over a `LazyVStack`, anchored at the
bottom. As the lazy stack re-estimates the rows it has put away, its content
can come out shorter than the place the view is scrolled to. The pane then
draws nothing until the person scrolls. This was seen part way through a long
reply (2026-11-05) and, by the owner, just after sending a message
(2026-11-26).

The guard written for the first case lived in the arriving reply's row. A lazy
stack draws only the rows in view, so once the view stood past the end, no row
was drawn and nothing could bring it back. Just after a send there is no reply
row yet at all.

## Decision

The keeper belongs to the scroll view. It is attached to the `NSScrollView` as
an associated object, so it lives exactly as long as the scroll view, and any
row that can find the scroll view installs it. It watches the list's height,
and the view's bounds and size. It moves the view only when the view is past
the end, only back to the end as the clip view measures it (insets counted),
and never during a live scroll.

## Consequences

- A view put past the end comes back after the row that installed the keeper
  has been put away. A SwiftUI harness showed the view staying blank without
  it and coming back with it.
- A plain AppKit scroll view already pulls the view back when its document
  shrinks, so a harness on one cannot show this failure. It has to be checked
  in a SwiftUI `ScrollView`.

## Rejected

- **The guard in the reply row (the earlier fix).** It cannot act while it is
  not drawn, and that is exactly the failure.
- **Scrolling to the bottom on every change.** It takes a reader who has
  scrolled up away from what they are reading, and a re-pin on each tick still
  ran past the end (2026-11-05).
