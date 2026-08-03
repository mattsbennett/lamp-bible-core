# Architecture and extraction plan

## Dependency direction

```text
lamp-bible-modules (schemas and authoring fixtures)
                 │
                 ▼ compatibility tests
         lamp-bible-core
          ├─ LampModuleKit
          └─ LampCore
             ▲       ▲
             │       │
 lamp-bible-ios   lamp-bible-macos
```

Neither application repository may define a second `.lamp` schema or compiler. Platform UI calls into `LampModuleKit`; module compatibility tests are shared at the package boundary.

## Extraction order

1. Module format contracts, validation, compilation, and import inspection.
2. Module-native installation and translation reading services.
3. Foundation-only reference and text models.
4. GRDB module records and database migrations.
5. Search and richer reader data services.
6. Notes, highlights, devotionals, plans, and quizzes. Personal notes, highlight spans, and plan progress now share the user-data store; notes and highlights also have canonical JSON round-tripping, deterministic editable-data merging, and iOS-compatible portable compilers, while the remaining formats continue incrementally.
7. Storage and sync protocols, followed by platform-specific provider adapters.

UIKit, AppKit, WidgetKit, application lifecycle, camera/photo pickers, share sheets, and platform background execution remain in their app repositories.

## Module format compatibility

The current installable `.lamp` format is raw-DEFLATE-compressed SQLite. Version 1 output must remain readable by the shipping iOS importer. New metadata columns must be additive, and legacy files without them must remain supported.

Before a compiler is considered complete, fixture tests must perform this round trip:

```text
JSON → validate → temporary SQLite → integrity checks → .lamp → production importer → record assertions
```

The JSON Schemas under `lamp-bible-modules/schemas` remain canonical until an automated release process publishes them as versioned resources.
