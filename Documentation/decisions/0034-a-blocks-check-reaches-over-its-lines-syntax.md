# 0034. A block's ✓ reaches over its line's syntax

Status: Accepted, 2026-11-26. `LampWritingReviewMarkdown.wholeBlock`, held by
`aBlocksCheckReachesOverItsLinesSyntax`; the Mac's
`aFootnotesCheckClearsItsLabelAndOpeningEmphasis`.

## Context

The writing page's ✓ beside a block asks to clear the block's words. The
page draws the line's syntax apart from those words, or doesn't draw it:
a heading's `#`, a list's marker, a footnote's `[^1]:`, and the emphasis
or link the words open and close with. A mark on that syntax therefore
stayed after the ✓. The owner hit it on a footnote: an assistant's
passage ran through the label, and the label stayed marked, drawn as a
sliver at the start of the footnote's text that no ✓ could clear. Only
Mark All cleared it.

## Decision

A block's own ✓, as opposed to a selection, reaches to the start of its
first line and the end of its last, but only over syntax. Syntax is judged
from the characters on the line, not from the parser:

- **Before the words:** indentation, `>`, `#`, a list's marker or number,
  footnote labels, an escaping `\`, and the `*` `_` `~` `` ` `` `[` `!` that
  open emphasis, code or a link.
- **After the words:** the same closing marks, `]`, and a link's
  `(destination)`. A closing `#` counts only on a heading's line.
- **On the next line:** a Setext heading's underline. The parser decides
  whether a following line of `-` or `=` underlines this block or is a rule
  of its own, and it is asked only when such a line follows. Reading this
  by hand mistook the rule under `# H`, `> q`, `- item` and `[^1]: n` for
  an underline. Then it mistook the underline under `#hashtag` and under a
  list item's own heading for a rule. The iOS session's Codex review and
  ours found these.

Anything else stops the reach at that end: a word, or another table cell's
`|`. A caret is left where it is. The clear is still made in the stored
text.

The Mac's `WritingReviewSession` applies this for `wholeBlock` clears,
which only the page's per-block ✓ sends.

## Consequences

- The ✓ never takes in words the writer did not see, or a neighbouring
  cell's content.
- Syntax on the line is cleared with the block's words.
- A selection reaches only over block syntax, as before.

## Rejected (each caught in review, 2026-11-26)

- **Teaching `takingInSyntax` the footnote label.** It applied to
  selections too, and widened into a code line that only looked like a
  footnote.
- **Reaching over emphasis by parsing.** The parser reads
  `[^1]: **Note**` as a link's definition, starts indented code after its
  indent, and doesn't take in `***`. Each inference from the formatting
  missed a case.
- **The block's whole lines, unconditionally.** That widens a ✓ into words
  a newer draft added to the same line, words the writer never saw.
- **Making the clear in the page's own text.** That loses marks on syntax
  the page writes differently: the assistant's `+ Item` is shown as
  `- Item`, so a clear made there cannot find the `+`.

## Not addressed

- **An empty footnote directly above a heading** (`[^1]:`, then `Title`,
  then `---`). The parser reads `Title` as a link's destination, so the
  underline is not taken in.
- **The parse for an underline runs on the main actor.** It is only asked
  when such a line follows, and it costs about 170 ms on a 430 KB Debug
  document. It belongs with the ✓ path's work, R4 in
  `ReviewMarksPerformancePlan.md`.

A table cell's ✓ asks the host for the whole row. That is how the page
already behaves, and is left as it is.
