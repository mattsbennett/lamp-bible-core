# 0030. No uneditable button inside the writing's text

Status: Accepted, 2026-11-26. iOS 7487861 (the editor's `reviewButton`) and
Mac b384a42 (the same page, and the Mac's stylesheet for it).

## Context

The owner found that "--" and a space no longer became an em dash in the Mac's
writing editor, and that the space landed after the caret. A WKWebView harness
with the editor's own page showed the cause. WebKit makes no smart dash, smart
quote or text replacement in a paragraph that holds a `<button>` with
`contenteditable="false"`: no `insertReplacementText` is ever sent. ProseMirror
makes every widget's outer element uneditable, and the review ✓ and ↺ were
buttons, so every paragraph with a review mark lost the system's substitutions.
In a writing with 171 marks, that is most of the paragraphs being worked on.

The same harness showed what does not stop them: an uneditable `<span>`, a
`<button>` with no `contenteditable` of its own, and an uneditable span holding
a button.

## Decision

A control the page places inside the text is an uneditable span, with any
`<button>` inside it. The span carries the class and is what is placed, styled,
measured and pressed. The button fills it, for keyboard focus and a screen
reader's label. This holds for every widget drawn in a paragraph, not only the
review buttons.

## Consequences

- Each stylesheet's rules for `.review-clear` and `.review-restore` style a
  span. A button's built-in centring and focus ring are gone, so each is
  stated: `text-align: center` on the phone, and the Mac's focus ring on the
  inner button.
- Code that presses or measures these controls uses the span: `posAtDOM`, the
  restore preview's anchor, and the WebKit checks' `pointerdown` on
  `.review-clear`. A press on the inner button bubbles up to the span.

## Rejected

- **A button with no `contenteditable`, using the widget's `raw` option.** It
  keeps the substitutions, but the button is then editable content, and the
  caret can be put inside it.
- **A button with `contenteditable="true"`.** It also keeps them, for the same
  cost.
- **Doing the em dash in the page.** That copies one of the system's
  substitutions and still loses the others: smart quotes, and the person's own
  text replacements.
