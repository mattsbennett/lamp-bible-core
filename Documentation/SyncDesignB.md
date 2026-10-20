# Sync design B: core API

Status, 20 October 2026: batch 1 is implemented in core and uncommitted. That
covers the layout, the manifest, the file plan, the settings bundle and store,
and conditional delete. Batch 2 is the folder store and the Mac's migration,
which are still proposals below. Comments go to `lamp-bible-macos-d8`, which
owns core.

Design B, as the user chose it on 18 October:

- Each module is its own file, and those files are the truth.
- The archive shrinks to a small settings bundle that also lists the library's
  members.
- Only the Mac migrates.

Step 1 (streaming reads and writes, below) keeps the archive affordable until B
replaces it.

## The layout on the server

| What | Path | Bytes |
|---|---|---|
| Settings bundle | `lamp-bible.lampsync` | format 3 (see below) |
| A module | `<Kind>/<id>.lamp`, e.g. `Translations/kjv.lamp` | as the phone writes them today |
| A personal module | `Notes/…`, `Highlights/…`, `Devotionals/…` | as the phone writes them: `LampWebDAVPersonalArchiveAdapter` output, with module IDs rewritten |
| Writing media | `DevotionalMedia/<module>/<writing>/<file>` | the media file |
| Book images | `BookMedia/<module>/<path>` | the image, as the phone uploads it today |
| A deck | `Workspaces/Presentations/<id>.lampdeck` | the deck file |
| A deck image | `Workspaces/Presentations/Assets/<file>` | the image |
| A Mac workspace file | `Workspaces/<relative path>` | the file |

The canonical bytes are the phone's. The Mac keeps converting personal modules
through the adapter on the way out, and back on the way in. A `lamp-modules`
build drops into its kind folder unchanged.

Anything else is outside the library and is never adopted:

- hidden files, which covers iCloud's `.name.icloud` placeholders;
- legacy module formats (`.db`, `.db.zlib`, `.json`);
- the bundle and its old index;
- anything under the deck folder that isn't a deck or a deck image.

The bundle keeps the archive's path but uses format version 3. Archive readers
accept only 1 and 2, so an old client refuses the bundle with "Unsupported sync
archive version: 3" and stops. It never reads an archive with no modules in it
and concludes the library was deleted. bf checked the shipped Mac reader and
ios-92 the shipped phone reader. Both validate the version before reading
entries, and neither writes after a failed read.

## Batch 1, in core

### Layout

```swift
public enum LampSyncFileKind: Hashable, Sendable {
    case module(LampSyncContentKind), devotionalMedia, bookMedia, deck, deckAsset, workspaceFile
    public var isMedia: Bool     // devotionalMedia, bookMedia, deckAsset
    public var isListed: Bool    // module, deck
}

public enum LampSyncFolderLayout {
    public static let bundlePath: String                  // "lamp-bible.lampsync"
    public static let listedDirectories: [String]         // the kind folders and the deck folder
    public static func modulePath(kind:moduleID:) throws -> String
    public static func devotionalMediaPath(moduleID:devotionalID:filename:) throws -> String
    public static func bookMediaPath(moduleID:path:) throws -> String
    public static func deckPath(deckID:) throws -> String
    public static func deckAssetPath(filename:) throws -> String
    public static func workspaceFilePath(relativePath:) throws -> String
    public static func kind(of path: String) -> LampSyncFileKind?
    /// The module ID the server knows the file by: the adapter's rewritten
    /// ID for a personal module, the mapped per-set ID for highlights. Never
    /// the ID an app uses locally.
    public static func remoteModuleID(of path: String) -> String?
}

extension LampSyncContentKind {
    public init(_ kind: LampModuleKind)                   // the folder a kind lives in
}
```

**A module file's stem is its content ID**: `<Kind>/<id>.lamp`, as
`modulePath` builds it and `remoteModuleID` reads it back. A file whose stem
names another module is refused on download (`matchesContentIdentity`), never
misread. The Mac's installed files are named by a storage key, so the Mac
places them by `LampInstalledModuleFile.syncPath()`, from
`LampLibrary.installedModuleFiles()`, never by filename.

**A retired alias is outside the layout.** `Notes/bible-notes.lamp` is the
copy the old sync left under notes' former ID, merged into `notes` long ago
(`LampSyncModuleFiles.canonicalIdentity`). `kind(of:)` returns nil for it, so
no pass lists, adopts or installs it. Adopted, it would arrive as a second
notes module of old notes, and bring back any deleted before the ledger
existed. The migration drops it as bookkeeping and leaves it where it is.

### Membership

```swift
public struct LampSyncLibraryManifest: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let path: String
        public var presentSince: Int64?     // latest add or write, ms since 1970
        public var revision: String?        // the provider's revision for that write
        public var deletedAt: Int64?
        public var deletedRevision: String? // the copy the deletion was of
        public var kind: LampSyncFileKind? { get }
        public var isMember: Bool { get }   // written after its latest deletion; equal times delete
    }
    public static let tombstoneLifetime: Int64              // 180 days, in ms
    public init()                                           // empty; no init from a listing
    public var members: [Entry] { get }
    public var tombstones: [Entry] { get }
    public var paths: Set<String> { get }
    public func entry(at path: String) -> Entry?
    public func recordingWrite(_ path: String, revision: String?, replacing previous: String?, at time: Int64) throws -> Self
    public func adopting(_ path: String, revision: String, at time: Int64) throws -> Self
    public func removing(_ path: String, at time: Int64, revision: String?) throws -> Self
    public func merged(with other: Self) -> Self
    public func pruned(now: Int64, present: Set<String>) -> Self
}
```

**Membership covers user content.** Modules an app bundles are never
published and never offered to the plan: the manifest plus each app's own
bundle is that client's library. The phone keeps its bundled modules in a
database outside the pass, so a bundled module another client published would
arrive as a member it doesn't hold, and download as a duplicate user module.
`installedModuleFiles()` never lists them: they have no file of their own.

**Revisions.** `revision` is the provider's revision for the latest write. On
WebDAV that's the ETag. On the folder provider the store's revision is the
content digest, so there the two coincide. There's one field and one
comparison rule. A revision is meaningful only within one provider, so
clients key their per-path records by provider (see
`LampSyncBackendTransition`). A switch starts with no records, and a file with
no record is downloaded and compared by value, never written over.

**Recording a write.** `previous` is the revision the write was conditioned on,
or nil for a file created where none was.

- When the manifest still holds `previous`, the write is that revision's
  successor, and is stamped `max(time, presentSince + 1)`. A slow clock can't
  make the later write lose.
- Otherwise the later `(time, revision)` stamp wins.

Pass `time` as the later of now and the copy's save time, so a copy saved after
a deletion comes out a member.

**Merging** keeps the later of each stamp: by time, then by revision. It's a
join, for reconciling iCloud conflict versions of the bundle.

### What a pass does with each file

```swift
public enum LampSyncFilePlan {
    public struct Local: Equatable, Sendable {
        public let path: String
        public let changedSinceUpload: Bool   // own export vs. its last upload or install
        public let lastRevision: String?      // last installed or written, this provider only
        public let savedAt: Int64?
    }
    public struct Plan: Equatable, Sendable {
        public var downloads: [String]
        public var merge: [String: String]               // both changed: reconcile, upload under this revision if it differs
        public var uploads: [String: LampSyncWriteCondition]
        public var deleteLocally: [String]
        public var adopt: [String: String]               // record with `adopting` once installed
        public var tombstone: [String: Int64]            // record with `removing`
        public var reap: [String: String]                // delete under this revision, after the bundle is written
    }
    public static func plan(manifest:local:deletedLocally:listing:) -> Plan
    public static func listing(in store: any LampSyncRemoteStore, manifest:) async throws -> [String: String]
}
```

**The invariant batching depends on.** A file and the manifest disagreeing
means the file changed, and is compared by value. It's never a conflict and
never a loss. A pass writes its files, then makes one bundle update recording
everything. A pass that ends between the two leaves files the manifest doesn't
know, and the next pass on any device adopts them. Lean:
`anUnknownFileIsAdopted`, `deletingNeedsATombstone`.

**Change detection** compares the listed revision with `lastRevision`. On WebDAV
the listing's ETags are the truth. On the folder provider, `listing` takes a
member's revision from the manifest, so evicted files are never read. Only a
file the manifest doesn't record as a member is asked for its revision: one
dropped in, or one put back. On the folder provider that read covers one file.

**`changedSinceUpload`.** After installing a download with nothing pending,
take the digest of your export straight after the install. Otherwise every
import comes back as an upload in your own encoding. Exports are byte-stable on
both clients, with every query totally ordered and keys sorted. The SQLite
version in an export's header re-uploads each personal module once after an OS
update, and that's accepted.

**Media.** Media is immutable by path, never probed, never merged, and
uploaded only `.ifAbsent`.

- A copy held here is done.
- An absent copy is fetched, and a 404 means not uploaded yet.
- An `.ifAbsent` refusal over different bytes is a conflict for the executor
  to report. The plan can't see bytes.
- Tombstoned media is reaped by the deleting device against the recorded
  revision. If that device fails, the file is an orphan nobody lists, and it
  never comes back.

**Reaping.** Delete each file in `reap` conditionally, and only after the
bundle that tombstones it is written.

- The deleting device reaps at the revision its listing shows.
- Later reapers match the deleted revision or the last recorded write.
- A copy at any other revision was put back by hand, and is adopted.
- A tombstone for a listed kind is pruned only once its file is gone.

**Workspace files** (Mac only): pass HEAD results for the manifest's workspace
members in `listing`. They're planned like listed files.

### Settings, ledgers and membership in one small object

```swift
public struct LampSyncSettingsBundle: Equatable, Sendable {
    public static let formatVersion: Int                   // 3
    public var userSettings: Data?                         // iOS settings database
    public var macSettings: Data?                          // the Mac's synced settings.plist keys
    public var preferences: LampSharedPreferenceLedger
    public var personalDeletions: Data?                    // per item; separate from the per-file manifest
    public var deckDeletions: Data?
    public var manifest: LampSyncLibraryManifest
    public func encoded() throws -> Data                   // zlib {"formatVersion":3,"entries":[],"bundle":{…}}
    public static func decode(_ data: Data) throws -> Self // .isArchive, .unsupportedVersion, .damaged
}

public enum LampSyncSettingsStore {
    public struct Snapshot: Equatable, Sendable { public let bundle; public let revision: String }
    public enum StoreError: Error, Equatable { case notMigrated(revision: String?), unversioned, tooManyAttempts }
    public static func read(from:knownArchiveRevision:) async throws -> Snapshot?
    public static func hasChanged(since:in:) async throws -> Bool
    @discardableResult
    public static func update(in:attempts:_ change: (inout LampSyncSettingsBundle) throws -> Void) async throws -> Snapshot
}
```

- `read` saves the body to disk and unpacks only its header until it knows the
  body is a bundle. Before migration that body is the whole library. While the
  server still reports `knownArchiveRevision`, it answers `notMigrated` from
  one HEAD.
- `update` is the only read-merge-retry.
  - `change` may run more than once, against newer bundles, so it only
    computes. Apply its result after `update` returns.
  - An error thrown by `change` comes out unchanged and is never retried.
  - A change that changes nothing writes nothing.
  - With nothing at the path it starts from an empty bundle, written
    `.ifAbsent`.
  - Use the returned revision for the rest of the pass, and never re-probe
    after your own write.
- **One update per pass**, never one per file. The Mac and the phone have both
  committed to that shape.
- **Refusals.** `LampSyncConditionalWrite.isRefusal` recognises
  `WriteError.conflict`, WebDAV's `preconditionFailed`, and any error adopting
  `LampSyncRefusal`. An app that wraps store errors in its own type must adopt
  it, or rethrow core's. Otherwise a refusal reads as a failure and `update`
  never retries. The phone had exactly this bug, now fixed.

### Deleting

`LampSyncRemoteStore.delete(path:condition:)` deletes a file only while it is
still at `condition`.

- A file already gone counts as deleted.
- A file at another revision is a refusal, and stays.

The default throws `deleteUnsupported`, so a store that hasn't implemented it
fails its reaps visibly rather than never reaping. `LampWebDAVStorage` sends
DELETE with the PUT's preconditions. Each app should test that its own store
implements it rather than inheriting the default.

## Batch 2, in core

### The folder store (done)

`LampSyncDirectoryStore` runs the folder provider through the same pass as
WebDAV, so `LampSyncArchive` and `LampSyncFolderPublisher` can retire.

- It takes a plain, already-accessible folder URL. The caller holds the
  security scope for the store's whole lifetime, which is now the whole pass.
- `init(root:downloadTimeout:conflictVersions:startDownloading:)`. The last two
  default to iCloud's own (`NSFileVersion`, `startDownloadingUbiquitousItem`)
  and exist so tests can stage conflict versions and make an evicted file
  arrive without iCloud. On iOS the explicit start must come before the wait,
  because a coordinated read of an evicted item doesn't reliably trigger the
  download.
- Its revision is a quoted content digest, so its revisions meet the
  strong-ETag checks. Its `list` reports none: `LampSyncFilePlan.listing` fills
  them from the manifest, so an unchanged library is listed without reading a
  file.
- It ports `LampSyncFolderPublisher`'s iCloud handling: an evicted file is
  downloaded first and one that never arrives is an error, never absent;
  unresolved conflict versions stop a file; a placeholder appearing mid-write
  is a refusal; links are refused before and inside coordination; every write
  and delete checks its condition inside its coordinated block
  (`directoryWrite`, `directoryDelete`).

### Copies written at once (done)

iCloud has no server-side condition, so two devices can both write the bundle,
and iCloud keeps the loser's as a conflict version. The bundle is the one file
that merges them.

```swift
public protocol LampSyncVersionedStore: LampSyncRemoteStore {
    func readWithVersions(path:into:) async throws -> (current: LampSyncDownloadedFile?, versions: [LampSyncDownloadedFile])
    func resolveVersions(of:writing:ifRevision:resolving: Set<String>) async throws -> String
    func hasVersions(path:) async throws -> Bool
}
```

- `LampSyncSettingsStore.read` returns `Snapshot.versions`, each a decoded
  bundle and the revision of its bytes. A version that isn't a format-3 bundle
  throws `unreadableVersion`: merging it is impossible and dropping it loses a
  write (`versionMerges`).
- `update(in:attempts:mergingVersion:_:)` folds each version in, runs
  `change`, and writes through `resolveVersions`, which resolves exactly the
  versions it merged, named by their bytes. One that arrived after the read
  stays for the next. Merged versions are written even when nothing changed,
  or they would stay forever. With no `mergingVersion`, versions throw
  `versionsNeedAMerge` and nothing is touched (`settingsWrite`).
- `LampSyncSettingsBundle.merge(version:)`, in LampCore, joins the manifest,
  the shared preferences and both deletion ledgers, and keeps the current
  copy's `userSettings` and `macSettings`. The joined parts come out the same
  whichever copy iCloud kept as current (`versionMerge`). An unreadable
  ledger never stops it, as it never stops a pass: of two personal ledgers
  the readable one stands, and an unreadable deck ledger leaves this copy's.
- Each app merges its own settings from `Snapshot.versions` before the write,
  **without a base**: after a lost write, a device has recorded its own write
  as the base, which the current copy never saw, so a three-way merge undoes
  its edit. The phone does this already (union of readings, settings field by
  field). The Mac doesn't, by design: every synced `settings.plist` key is a
  preference with no join (a font size, a chosen module), and a union of
  `modules.hiddenIDs` would make un-hiding impossible. So the current copy's
  `macSettings` stands, and a setting changed on the losing Mac may need
  setting again. Don't add a plist union. An app whose participants are prepared before `update` must check,
  in `mergingVersion`, that each version is one it prepared with, and throw
  as for a moved bundle otherwise, or a version arriving in between is
  resolved without its settings merged.
- So the shared preferences can join without a base, each field now carries
  `modifiedAt`: the device's time, raised past the field it replaced
  (`preferenceStamp`). A field without one, from before, counts as earliest
  and encodes as it did.
- A wrapper around the store must adopt `LampSyncVersionedStore` and forward
  it. Without it, the plain `read` refuses the bundle at the first conflict:
  the pass stops visibly rather than writing over a version.

### A library nobody has migrated (done)

A folder the Mac keeps has no archive at the bundle path: the folder publisher
writes the portable backup's files loose, sealed by `lamp-sync-snapshot.json`.
So nothing at the path no longer means a new library. With nothing there,
`read` lists the root and answers `notMigrated(revision: nil)` if it finds
`lamp-sync-snapshot.json`, the portable `manifest.json`, the phone's `UserData`
folder, or any file in a kind folder (`emptyBundlePath`). `update` never
creates a bundle over an earlier library; only the migration does. The same
rule holds on WebDAV, where it costs one listing and only when there is no
bundle.

So a pass starts with `readOrClaim(from:knownArchiveRevision:)`, not `read`.
In a new library it writes an empty bundle `.ifAbsent` before any file. A
pass that wrote its files first would find them at its closing `update` and
be told `notMigrated`, on every pass. A device that loses the claim reads the
winner's bundle (`bundleRead`).

### A library only the phone kept (done)

Decided by the user on 20 October: the phone may migrate a library only it
kept. `earlierLibrary(in:)` says who kept one:
- `.mac` if the Mac's seal or portable manifest is at the root. Its files are a
  backup's layout, so only the Mac's migration moves it, and the phone keeps
  waiting.
- `.phone` otherwise, when the phone's `UserData` folder or any module file is
  there. The phone's files are already the per-file layout, named by their
  IDs.

`migratePhoneLibrary(in:)` claims a `.phone` library with an empty bundle,
`.ifAbsent` as `readOrClaim` does, and the next pass adopts its files and
downloads or merges them by value. Nothing else claims one: `readOrClaim`
still throws `notMigrated` there (`mayClaim`). The phone asks first, and asks
the person to update their other devices. Its iCloud sync before 1.2.0 never
reads `lamp-bible.lampsync`, so an un-updated device doesn't stop at format 3
the way it does on WebDAV. It keeps writing loose files and
`UserData/user-settings.db`, which the new sync ignores, and what it deletes
comes back. The same holds on a folder the Mac migrates.

The Mac never claims a `.phone` library during a pass. It reports it and offers
joining as an action the person takes once. The Mac publishes the whole
library, so a background join of the wrong folder would republish everything
into someone else's library.

On the folder, a revision is the quoted SHA-256 of a file's bytes. A phone
whose earlier records hold the digest of what it installed can seed
`lastRevision` from them and compare without downloading.

**On WebDAV** (decided by the user the same day, in the iOS session: both
providers). The shipped phone publishes a settings-only archive to an empty
server: its settings database, the legacy manifest, the shared preferences
and the empty portable manifest every new archive starts with. Its modules
are loose files. So a library only the phone kept has an archive at the
bundle path.
- `earlierLibrary(in:)` judges an archive by its entries
  (`earlierLibrary(ofArchive:)`): the phone's if it holds nothing but those
  four, the Mac's otherwise. Entries are sorted by path and nothing the phone
  writes sorts before `Settings/`, so an archive whose first entry does
  (`Modules/`, `Media/`, …) is the Mac's from its first kilobyte, never
  unpacked.
- It downloads the archive to judge it. A client that polls should judge the
  archive its old pass already read, or remember the answer by revision.
- `migratePhoneLibrary(in:)` replaces a phone's archive with a bundle carrying
  its settings and shared preferences, written `.ifRevision` of the archive it
  judged. If the Mac publishes in between, the write is refused, the phone
  judges again, and stops.

### The Mac's one-time migration (done)

```swift
public enum LampSyncLibraryMigration {                    // LampCore
    public enum Fate { carried, republished, inPlace, dropped, unknown }
    public static func fate(of path: String) -> Fate
    public static func firstBundle(from archive: LampSyncArchive) throws -> LampSyncSettingsBundle
    public static func migrate(in store:, imported archive: LampSyncArchive, revision: String?) async throws
        -> LampSyncSettingsStore.Snapshot
}
```

The earlier proposal wrote every library file `.ifAbsent` from the archive,
converted by the Mac, before the bundle. That's replaced by something
smaller. The migration writes only the first bundle, carrying what lives
nowhere else under B. The Mac's next pass publishes the library from the
library, as every pass does. Every byte the Mac would have converted, its
pass already produces: installed modules by `syncPath()`, personal modules in
the phone's format, media, decks and workspace files. Files already in the
per-file layout, the phone's and the compatibility publisher's, are adopted
by that pass.

The Mac's sequence:
1. Run the old pass's import to completion, and keep what it read: on
   WebDAV the archive and its revision, on a folder the captured tree
   (`LampSyncFolderPublisher.capture`) with `revision` nil.
2. Ask the person, saying to update their other devices first.
3. `migrate(in:imported:revision:)`.
4. Run the new pass, starting with `readOrClaim`, which now finds the bundle.

`importAgain` means the archive moved since step 1: import again and retry.

What each entry of the archive or tree becomes (`entryFate`):
- **Carried** into the first bundle: `settings.plist` → `macSettings`,
  `UserData/user-settings.db` → `userSettings`,
  `Settings/shared-preferences.json` → `preferences`, `Deletions/ledger.json`
  → `personalDeletions` (carried as it is; a pass that can't read it skips
  it), `Workspaces/Presentations/deleted-decks.json` → `deckDeletions`.
  Ledgers go into the bundle, never into files: a ledger written as a member
  file is won, not merged, so two Macs deleting different decks would lose
  one deletion. The deck ledger left in the deck folder is never adopted
  (`aLedgerInAListedFolderIsNeverAdopted`).
- **Republished** by the Mac's next pass: `Modules/`, `Study/`, `Media/`,
  `Compatibility/` modules, `Workspaces/`, and the portable writings
  `Devotionals/*.json`.
- **In place**: a file already in the per-file layout, such as
  `Translations/kjv.lamp` or `Devotionals/daily.lamp`, which the pass adopts.
- **Dropped**: the old layout's bookkeeping. That covers the legacy and
  compatibility manifests, the portable `manifest.json`, the folder seal, the
  archive index, any hidden file such as Finder's `Media/.DS_Store`, and the
  retired notes alias `Notes/bible-notes.lamp`.
- **Unknown**: anything else stops the move before it writes, naming the path.

When it writes (`macMigrationStep`):
- On WebDAV, over the archive `.ifRevision` of the revision imported, and
  only if the imported archive is the Mac's (`archiveKeeper`).
- On a folder, `.ifAbsent`, and only if the folder is the Mac's
  (`earlierLibrary`).
- A bundle already there is returned, so a second run, or a second Mac,
  writes nothing.

Before asking, the Mac can name everything that would stop the move with
`unplaceableEntries(in:)`, so a stray file is reported up front, not found by
a refusal. The fates are tested against a real `exportPortableBackup`, with
what the Mac and phone add beside it. The Mac's own workspace and
compatibility exports should be checked the same way in the Mac's tests.

The migration's `macSettings` is only a starting point. It's the same bytes as
`settings.plist`, a snapshot of `syncedKeys`, and every pass re-encodes it
from the live defaults.

`macSettings` carries only the synced `settings.plist` keys
(`LampPortableSettingsCodec.syncedKeys`). The Mac's highlight set to module
mapping is not among them: it lives in the Mac's defaults and is re-derived
from each remote highlight module's `highlight_meta.id`. Under B an unchanged
module isn't downloaded, so with no local record for a set the Mac must read
that set's remote module rather than mint an ID, or it publishes a duplicate.
That's the Mac's per-path record store, not the migration's.

Nothing old is deleted. The archive is replaced; a folder's old tree stays.
Its `Devotionals/*.json` are not `.lamp`, so the listing skips them, and its
`Workspaces/` already is B's workspace layout. The Mac's folder sync before
B, still running on another Mac, stops at the new files: its seal no longer
matches what it captures. It never deletes, so it can't wipe the new layout.

Devices still on format 1 or 2 stop receiving deletions once the bundle is
written. Today the deletion ledger travels inside the archive, which they
read; in format 3 it's in the bundle, which they refuse. Nothing is
corrupted, since the Mac's ledger suppresses those items on import, but
deleted items linger on the old device until it's updated. So the Mac asks
the person to update their other devices first, and confirms before it runs.

## Step 1, streaming (done)

- `LampSyncRemoteStore.read(path:into:)` and `write(fileAt:to:condition:)`
  stream bodies to and from disk.
- `writeAndConfirm(fileAt:…)` confirms by a digest of a read-back streamed to
  disk.
- `LampSyncArchive.writeCompressed(to:)` and `decode(compressedFileAt:)` pack
  and unpack one entry at a time.
- With 200 MB of module bodies, peak memory fell:
  - packing, from 1,244 MB to 305 MB;
  - reading, from 797 MB to 321 MB.

## Decisions the user made (20 October)

- B covers the folder (iCloud Drive) provider too. Both providers run one
  per-file pass, and `LampSyncArchive` and `LampSyncFolderPublisher` retire.
- A deletion is remembered for 180 days. A device offline for longer brings
  deleted files back once.
- Old app versions stop syncing at the switch. They refuse format 3 rather than
  misread it. There is no compatibility layer.
- A library only the phone kept is migrated by the phone, once the person
  agrees; one the Mac kept waits for the Mac.
- Relayed through the iOS session: no dry run, so the migration runs on the
  original library folder, which the user has backed up; and the phone's
  design B build is version 1.2.0.

## What the model has

These are in `Verification/SyncMerge.lean`, with conformance tables against the
Swift.

- **The manifest merge**, a join of stamps: `mergeManifestEntry`, `laterStamp`.
- **Membership.** Equal times delete. A write after a deletion is a member.
  Adoption never undoes a deletion, and a copy put back is adopted.
- **Successor writes** are stamped later.
- **The plan:** `filePlanAction`. No local deletion happens without a
  tombstone. An unknown file is adopted. A file with no record is never
  written over.
- **Listing:** a recorded member is never read.
- **The bundle's update:** retries are bounded.
- **The bundle path:** an archive is never read as a bundle, and old readers
  refuse format 3.
- **Pruning:** a tombstone waits for its file to be reaped. The 180-day cost is
  proved as a counterexample.
- **The folder store:** its coordinated check is the folder publisher's, and
  versions stop any file but the bundle.
- **Versions of the bundle:** merged and resolved, or the update stops; never
  dropped. The joined parts ignore which copy is current, and a later
  preference edit survives either way.
- **An empty bundle path:** a new library only when nothing earlier is there.
- **The Mac's migration:** every setting and ledger is carried, only
  bookkeeping is dropped, and it writes over an archive only at the revision
  it imported.

## Unreadable ledgers (20 October)

Both apps skip a personal deletion ledger they can't read rather than stop
syncing, and contribute their own records in its place. Core's version merge
and the migration follow. One consequence to keep in mind: `decode` ignores
`formatVersion`, and a ledger an old client can't read is replaced by that
client's own records. So a future ledger format must not be written while
older clients still sync, or they will overwrite it and its deletions with
them. Change the format only together with a bundle format that old clients
refuse.

## A server that lags after a write (20 October)

The first real move on the user's Synology failed with `tooManyAttempts`
though its bundle had landed. The Synology names no revision on PUT, and
answers the next reads with what it held before. `writeAndConfirm`'s two
read-backs both showed the old archive, so it threw `conflict`. `migrate`
took that for a refusal and retried at once, still read the archive at the
imported revision, wrote `.ifRevision` of it, and was refused for real by its
own bundle, three times over.

`LampSyncConditionalWrite.write(_:to:in:condition:patience:)` now says what
became of a write:
- `written(revision)`: read back as the bytes sent;
- `writtenUnconfirmed`: taken, not shown back within the patience allowed;
- `refused`: the write's own refusal.

While the server still names the revision being replaced, it asks by HEAD,
so a library-sized archive is never downloaded just to see it is still
there. `update`, `readOrClaim`, `migratePhoneLibrary` and
`LampSyncLibraryMigration.migrate` use it. A write the server took is never
retried. Unconfirmed, they throw `LampSyncConditionalWrite.Unconfirmed`: the
bundle is there, and the next pass reads it. A refused write is retried after
a wait. `Patience.standard` allows about seven and a half seconds to show a
write back, and waits 0.5 s, then 2 s, before retries. `StoreError` now
describes itself.

