# Lamp Bible Core

Shared Swift code for the Lamp Bible iOS and macOS applications.

## Products

- `LampModuleKit`: module detection, validation, SQLite compilation, and `.lamp` packaging.
- `LampCore`: persistent module installation, translation reading and full-text search, rich verse annotation and poetry metadata, study lookups, reading-plan progress, personal notes and span-based highlights, portable study-data import/export and deterministic merging, plus shared database, sync, and domain services as they are extracted from the iOS app.

The package currently provides JSON module detection, structural validation, BBCCCVVV reference validation, duplicate and span checks, summary statistics, and installable `.lamp` compilation for translations, dictionaries, commentaries, reading plans, devotionals, quizzes, notes, and highlights. Compiler output is SQLite with a versioned format marker, integrity checked, zlib compressed, round-trip verified, and SHA-256 hashed.

`LampCore` can also open a combined `bundled_modules.db.zlib` archive, lazily expand and cache it, and merge its read-only modules with user-installed `.lamp` files. A user-installed module with the same type and ID takes precedence over its bundled counterpart.

## Repository responsibilities

- [`lamp-bible-modules`](../lamp-bible-modules) owns JSON Schemas, source material, conversion scripts, and large/generated fixtures.
- `lamp-bible-core` owns the reusable Swift implementation of the module contract and application runtime.
- [`lamp-bible-ios`](../lamp-bible-ios) and [`lamp-bible-macos`](../lamp-bible-macos) own platform-specific UI and lifecycle code.

## Development

```sh
swift test
swift run lamp-module inspect ../lamp-bible-modules/outputs/ESV.json
swift run lamp-module build ../lamp-bible-modules/outputs/ESV.json /tmp/ESV.lamp
swift run lamp-module verify /tmp/ESV.lamp
```

The output filename must match the module ID because Lamp Bible uses the `.lamp` filename as part of its import identity.

The app repositories use this package by local path during coordinated development. Release branches should use a tagged Git dependency so builds remain reproducible.
