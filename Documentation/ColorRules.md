# Colour Rules

Lamp Bible looks the same on iPhone, iPad and Mac. Red is Lamp's accent everywhere, and it belongs to the app: the things you press and the things you've chosen. The words on the page keep their own colours, so a red never has to mean two things at once.

**Red is the app. Blue takes you somewhere in the text. Every other colour carries one meaning, and only that one.**

The values live in `LampColorRole` and `LampHighlightPalette` (`Sources/LampCore/LampPalette.swift`). Use the role, not a hue: `Color.blue` says nothing about why it's blue.

## Roles

| Role | Light | Dark | Use for | Never for |
|---|---|---|---|---|
| Accent | `#DB344A` | `#EF4F63` | Controls and the app's own chrome: buttons, toolbar and tab icons, toggles. What's selected or current: a checkmark in a list, today, the current slide. A control's own state, such as a reading's tick or "All read". Your own things in a conversation, such as your chat bubble. | Links inside text, search matches, tags, status. Anything inside scripture text: a selected verse shows as a tinted background, not red numerals. |
| Link | system blue | | Anything in Bible, module, note, devotional or chat text that takes you somewhere: verse references, cross-references, footnote markers and labels, web links, dictionary and topic links. | Controls: anything in a toolbar or styled as a button is the accent. Text that opens nothing: no blue that doesn't tap. |
| Original language | system purple | | Strong's numbers, Greek and Hebrew words, lexicon references. Links of one kind, kept apart from verse references where both run together, as in commentary. | Anything else. |
| Words of Christ | `#BF4848` | `#E07272` | Red-letter text, and only that. Text colour, never a sign of something to tap. | Anything else in scripture. This is why scripture holds no accent: a red footnote marker beside red-letter text reads as part of Jesus's words. |
| Find match | system yellow | | The words searched for, as a background at 40% (`findMatchOpacity`) behind text that keeps its colour, as Safari marks them; the current match solid, with black text. In documents and in search results alike. | Bold accent text, which reads as a link or a selection. |
| Status | system green, orange, red | | How something went. Green: synced, saved, connected. Orange: waiting, a conflict, something missing. Red: failed or unavailable, destructive buttons (through the platform's destructive role), recording while live. | Hue alone: always an icon or words too, since system red sits close to the accent. A control's own state, which is the accent. |
| Highlights | the person's palette | | Highlights the person makes, in the colours they choose. Offered from `LampHighlightPalette`. | App meaning: the app never uses a highlight colour to say anything. |
| Kinds | a fixed hue per kind | | Telling kinds of things apart at a glance: module-type badges, devotional categories, note markers in the reader. Always with a word or a distinct glyph, and legible text on the fill. | Tags people write themselves, which are neutral chips. The accent. |

Two things keep their own colours outside these rules: a slide deck's theme (the deck's palette, not the app's), and code and diff colouring in the writing tools.

## Each platform

- **System colours.** Link, original language, find match and the statuses are the platform's own system colours (`systemBlue`, `systemPurple`, `systemYellow`, `systemGreen`, `systemOrange`, `systemRed`). In app UI, ask the platform for them. The values in `LampColorRole` are those colours', for the places with no system colour to ask: the writing editor's CSS, exported files, the widget.
- **The accent** is each app's `AccentColor` asset, set as the global accent colour (`ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`), with the values above. macOS uses an app's own accent when the person's accent in System Settings is Multicolor, the default; someone who chose a specific accent there keeps it for standard controls, as Mac apps do. Lamp's own red moments, such as Start Reading and the reading ticks, ask for the accent role directly and stay red either way.
- **Links take their colour explicitly.** SwiftUI draws a `.link` run and a link-styled button in the tint, which is the accent, so content links set the link role's colour themselves.
- **The writing editor** (TipTap, built in the iOS repo and copied to the Mac) uses `--link-color` for links, verse references and footnotes, with a dark value, and the accent for its caret.
