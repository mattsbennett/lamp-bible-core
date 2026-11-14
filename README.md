# Lamp Bible Core

Shared Swift code for the Lamp Bible iOS and macOS applications. A Swift 6 package for iOS 18 and macOS 15.

## Products

- `LampModuleKit`: module detection, validation, SQLite compilation, and `.lamp` packaging, and importing a Bible the user already has into a translation module.
- `LampCore`: persistent module installation, translation reading and full-text search, rich verse annotation and poetry metadata, study lookups, reading-plan progress, personal notes and span-based highlights, portable study-data import/export and deterministic merging, plus shared database, sync, and domain services as they are extracted from the iOS app.
- `LampPresentationUI`: the SwiftUI slide canvas shared by the Mac's Slide Studio and presenter and by the iOS deck viewer and remote, including deck image loading and caching. Kept apart from `LampCore` so the module CLI and the MCP server do not link a UI framework.
- `LampIntelligence`: the reading-plan assistant, which asks the on-device Apple Intelligence model (macOS 26 / iOS 26) what plan a person's words describe and lays out the days itself. Kept apart from `LampCore` for the same reason: the apps ask the model, the headless tools never do.
- `lamp-module`: the command-line tool for inspecting, building, verifying, importing, and converting modules (see [Development](#development)).

`LampCore` also owns the versioned, semantic `.lampdeck` presentation model, validation, and library-backed document store shared by the Mac Slide Studio and the iOS/iPadOS deck viewer and remote, plus the portable deck paths, deletion ledger, and merge decision that keep the Mac's read-write deck sync and the read-only iOS mirror in agreement. The versioned remote contract defines QR/manual pairing material, fresh connection challenges, and length-prefixed ChaCha20-Poly1305 frames for commands and presenter state, so both apps use the same authenticated framing and slide semantics.

`LampAgentLibrary` in `LampCore` is a bounded, read-only, agent-facing view of a Lamp library. It offers semantic operations rather than database tables, under an access policy, and backs local MCP clients without tying `LampCore` to MCP itself.

The package currently provides JSON module detection, structural validation, BBCCCVVV reference validation, duplicate and span checks, summary statistics, and installable `.lamp` compilation for translations, dictionaries, commentaries, reading plans, devotionals, quizzes, notes, and highlights. Compiler output is SQLite with a versioned format marker, integrity checked, zlib compressed, round-trip verified, and SHA-256 hashed.

`LampTranslationImporter` reads USFM, OSIS, Zefania and plain book/chapter/verse XML Bibles — a file, a folder, or a zip — and CrossWire SWORD modules (zText and RawText, OSIS, ThML, GBF or plain text, KJV/KJVA/NRSV/NRSVA verse numbering), including locked ones opened with the key the user bought, into the 66-book grid every translation shares, with headings, paragraphs, poetry, footnotes, words of Christ, added words, the divine name, Selah and Strong's numbers where the source has them. Books outside the 66, bridged and repeated verses, and markup it doesn't know are listed in the import's report. Copyrighted translations reach Lamp only this way, from a copy the user owns; they are never bundled.

`LampCore` can also open a combined `bundled_modules.db.zlib` archive, lazily expand and cache it, and merge its read-only modules with user-installed `.lamp` files. A user-installed module with the same type and ID takes precedence over its bundled counterpart.

## Repository responsibilities

- `lamp-bible-core` owns the module contract — the JSON Schemas in [`Schemas/`](Schemas/README.md) — and its reusable Swift implementation, along with the application runtime.
- `lamp-bible-modules` (a private repository) owns source material, conversion scripts, and large/generated fixtures.
- [`lamp-bible-ios`](https://github.com/mattsbennett/lamp-bible-ios) and [`lamp-bible-macos`](https://github.com/mattsbennett/lamp-bible-macos) own platform-specific UI and lifecycle code.

## Documentation

- [Module schemas](Schemas/README.md): the JSON Schemas for every module type, with examples.
- [Architecture](Documentation/Architecture.md): dependency direction, extraction order, `.lamp` format compatibility, and the sync format transition.
- [Sync design](Documentation/SyncDesignB.md)
- [Color rules](Documentation/ColorRules.md)
- [Sync verification](Verification/README.md): the Lean 4 model of sync's merge decisions, and how the test suite keeps it in step with the Swift code.

## Development

```sh
swift test
```

`swift test` also checks the Lean proofs in `Verification/`, so it needs Lean, installed through elan and pinned by `lean-toolchain` (`brew install elan-init`). On a machine without elan, `LAMP_SKIP_LEAN=1 swift test` skips the Lean-backed tests by name. See [Verification/README.md](Verification/README.md).

The `lamp-module` tool:

```sh
swift run lamp-module import ~/Downloads/engwebp_usfm.zip /tmp --abbreviation WEB --name "World English Bible"
swift run lamp-module import ~/Downloads/ESV2011.zip /tmp --key UNLOCK-KEY
```

| Command | What it does |
| --- | --- |
| `inspect <module.json> [module.json ...]` | Detect and validate module JSON and print summary statistics. |
| `build <module.json> [output.lamp]` | Compile module JSON into an installable `.lamp`. |
| `verify <module.lamp>` | Open a compiled `.lamp` and check it. |
| `search-words <database.sqlite>` | Build the word lists partial-word search uses, for each full-text index of an SQLite database made outside `build` (such as the bundle). |
| `import <bible> <output folder>` | Import a Bible file, folder, zip, or SWORD module into a `.lamp`. |
| `convert <bible> <output.json> --id ID` | Write the translation JSON instead of a `.lamp`. |
| `versify <from scheme> <to scheme>` | Map BBCCCVVV references read on stdin from one versification to another. |
| `parse` | Decode `morphology-code<tab>strongs-key` lines read on stdin. |

`import` and `convert` take `--name`, `--abbreviation`, `--language`, `--key` (to unlock a locked SWORD module) and `--septuagint`. `convert` also takes `--license`.

`lamp-bible-modules` builds its bundled USFM translations with `convert`, so users and the bundle read Bibles the same way. It also checks its morphology sources with `parse` and maps source numbering with `versify`. If you have access to that private repository and have it checked out next to this one, you can work on its outputs directly:

```sh
swift run lamp-module inspect ../lamp-bible-modules/outputs/ESV.json
swift run lamp-module build ../lamp-bible-modules/outputs/ESV.json /tmp/ESV.lamp
swift run lamp-module verify /tmp/ESV.lamp
swift run lamp-module convert ../lamp-bible-modules/sources/bibles/BSB_strongs_usfm /tmp/BSBs.json --id BSBs
```

The output filename must match the module ID because Lamp Bible uses the `.lamp` filename as part of its import identity.

During coordinated development, the app repositories use this package by local path, so check out `lamp-bible-core`, `lamp-bible-ios`, and `lamp-bible-macos` side by side in the same parent folder. Release branches should use a tagged Git dependency so builds remain reproducible.
