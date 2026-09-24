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

## Sync format transition

`LampModuleKit` defines the shared WebDAV directory names, archive path, and
portable backup paths in `LampSyncLayout` and `LampPortableBackupLayout`.
`LampPortableBackupManifest` owns the versioned backup metadata.
`LampSyncArchive` is the shared file snapshot codec: Mac now
writes version 2 archives with per-file SHA-256 checks and reads both version 1
and version 2. Archive validation happens before extraction.

iOS reads installed modules from the validated archive using IDs stored inside
the `.lamp` databases. Mac also includes the exact notes, devotionals, and
highlights `.lamp` payloads it publishes to iOS WebDAV folders under
`Compatibility/<folder>/<filename>` in the archive. iOS imports those payloads
through its existing module merge path, then scans the legacy folders for older
clients and any files not yet represented in the archive. A compatibility
manifest records the folder ETag read before Mac committed the archive. Both
apps ignore a folder file still at that older revision and import a changed file
for reconciliation. The archive's conditional write commits its compatible
payloads and iOS settings database together for current WebDAV clients.
Both app adapters use `LampSyncModuleFiles.preferredCandidateIndices` to choose
one active folder candidate per module identity after archive supersession and
format ranking. The chosen index keeps the payload paired with its listing.
`LampSyncModuleFolder.list` filters WebDAV folder listings to supported module
files for both apps and keeps listing errors visible to the pull stage.
The standalone settings mirror and legacy folder writes still happen as
separate compatibility writes for older clients.

`LampSyncConditionalWrite` owns the shared WebDAV revision decision and
confirms writes when PUT omits an ETag. iOS uses it for its standalone SQLite
compatibility mirror; Mac uses the same strong ETag rule before publishing its archive and
compatibility files. The local settings formats remain different: iOS stores
readings and preferences in SQLite, while Mac exports selected preferences
from UserDefaults to the archive plist.
The shared WebDAV existence check returns false for HTTP 404, retries with GET
when HEAD is unsupported, and propagates authorization or server errors.

iOS backend migration also runs through `LampSyncEngine`: it copies and merges,
publishes settings to the target, then records the backend choice. Failed file
listing, failed copies, or a settings conflict leave the configured backend
unchanged. Files already copied to a destination before a later failure may
remain there; the migration is not an atomic multi-file commit.
Foreground sync captures one `SyncCoordinator.SyncSession` for settings and module
work. Legacy editable reconciliation pulls all editable types before its
separate export step; a failed later pull cannot publish an earlier type.
Settings and modules still publish in separate steps, so a later module failure
can follow an earlier settings upload.
`LampSyncBackendTransition` orders the Switch Only operation. It persists the
new provider choice after target publication, then wipes local notes,
devotionals, and highlights, and finally activates the new provider in memory.
A failed remote setup or provider persistence cannot wipe local modules. A
failed wipe attempts to restore the previous provider choice before reporting
the error. A recovery record containing the previous provider choice is written
to the local module database before provider persistence. The content wipe
removes that record in the same transaction. If the wipe or rollback fails, the
next launch restores the previous provider from the record and keeps sync
disabled until recovery succeeds. The two local databases remain separate.
The wipe clears the hashes for note, devotional, and highlight modules in the
same transaction as their rows. The next sync then imports those modules from
the selected provider even when its file revision matches the old provider's.

Mac folder sync uses core's `LampSyncFolderPublisher`. It captures the selected
folder for the pull, including downloaded iCloud placeholders, then compares
that snapshot with the folder before publishing. Each file is checked again
inside its coordinated write so a locally visible edit after the pull is not
replaced. Publication remains a sequence of files: a later error can leave an
earlier file committed, and coordination does not give an atomic transaction
across iCloud devices.

`LampSyncArchiveRemote` reads and validates the archive from a single GET,
keeps that response's revision with the decoded snapshot, and publishes with
the matching conditional write. Both apps use it for archive reads and writes;
iOS passes its module import snapshot to preference merging so the two imports
see the same archive contents. A cached module import checks its revision
against a fresh archive read before merging preferences.
`LampSyncSettingsArchive` defines an opaque iOS settings database entry, reads
it with the archive revision, and publishes it by replacing only that entry.
It also owns the paired archive and legacy read, legacy edit classification,
and paired strong-revision poll check used by iOS.
Mac retains an observed settings entry when it rebuilds its archive, so a Mac
publish cannot drop settings written by iOS. iOS now treats this entry as the
WebDAV settings source, using the standalone file only when an archive entry
has not yet been published. A manifest records the legacy file revision and
digest observed before each archive commit. iOS ignores that unchanged older
copy or an exact mirror, and reports a conflict if an older client later writes
different bytes. The mirror uses its own conditional write after the archive
commit, so a failed mirror may temporarily leave the old file behind; a later
sync retries an unchanged old copy. An existing local baseline for the
standalone file can seed an archive merge only when the manifest names that
same legacy revision and provider. The periodic iOS poll checks strong
revisions for both files before skipping their downloads; a missing or weak
revision triggers a full read.

`LampSyncCompatibilityPublisher` owns the ordered conditional writes for
Mac's older-client module files and iOS's standalone settings mirror. A failed
write stops the batch; previously written files remain for a later retry.

`LampSyncObservedWrite` protects iOS legacy module exports. It reads the
current file, compares it with the ETag or SHA-256 saved when the module was
imported, and writes with the revision from that read. A changed remote file
stops the export so it can be merged before publication. When iOS imported a
compatibility payload from the archive, its validated manifest may authorize
replacing only the older folder revision that the archive superseded. Mac
confirms each legacy compatibility file after its conditional write. These
files remain separate from the archive commit for older clients.
The same observed-write rule now covers iOS WebDAV media: a new file is
created conditionally, and repeating identical bytes is allowed, but an
unobserved different remote file is not replaced.

iOS WebDAV settings now merge archive database bytes and the ETag from the same
GET response. A later remote revision fails the conditional upload; the settings
manager cannot accidentally label an older database body with a later HEAD
revision. iCloud still exposes only a separate content-digest check.
Its settings read compares SHA-256 digests before and after the coordinated
read through `LampSyncStableRead` and retries when they differ;
an existing file without a token reports a conflict. Its later write remains without
an atomic server precondition.
The periodic iOS poll reads the file when its change token is unavailable,
so an unversioned existing file cannot be mistaken for a missing file.
iCloud module listings include hidden placeholders and wait for their content
before hashing or importing. Listing failures stop the pull stage. Coordinated
reads and writes reject unresolved file versions reported by iCloud.

iOS keeps a local baseline of completed-reading IDs and the settings row for
the last published or applied database revision. Its settings sync reads remote
first and calls the shared `LampSyncSettingsPlanner` before publishing the
result conditionally. Independent completions survive and a deletion of a
previously observed reading propagates. When both copies retain a reading,
the later completion time wins; tied times with different row data conflict.
The uploaded SQLite copy omits the device's
sync provider configuration, and saving that configuration does not advance
the shared settings revision. Concurrent different edits to the
settings row stop with a conflict. Older installs without a baseline use one
guarded upload when local changes are pending, then save the baseline for
subsequent three-way merges. Archive and legacy baselines have distinct source
identities so an old file token cannot authorize an archive write. If reading rows differ and there is no baseline,
sync reports a conflict because it cannot identify deletions. The baseline
belongs to the configured source and
is not copied into the remote SQLite database.

`LampPortableSettingsCodec` now owns the archive plist allowlist and binary
property list encoding. Mac reads and writes that file through the shared
codec, and malformed settings stop Mac from publishing another archive. A
versioned ledger at `Settings/shared-preferences.json` carries seven preferences
with the same meaning on both apps. Core compares each field with the version
last applied by the device. Independent edits merge; concurrent edits to the
same field report a conflict. Mac keeps its legacy plist for Mac-only settings;
iOS keeps its SQLite database for readings and the remaining preferences. iOS
updates only the ledger entry in the archive with a conditional write, leaving
module payloads intact. It uses the module import's archive snapshot for the
ledger, or checks the revision before using a cached module import. Older
archives without a ledger remain readable.

The ledger covers reader and devotional font size, default translation,
Strong's hints, and plan reminder state and time. The other settings have no
cross-platform mapping yet. The iCloud settings file, WebDAV compatibility
mirror, and legacy WebDAV folders still publish separately from the archive.
