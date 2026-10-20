# Sync verification

`SyncMerge.lean` is a Lean 4 model of the decisions Lamp's sync makes, with
proofs of the properties those decisions are meant to have. It models the
decisions — not the Swift runtime, the databases, the filesystem or the
network. Each area's boundary is described below and recorded in
`coverage.json`.

## Running it

`swift test` in this repository checks the proofs as part of the core suite
(`SyncModelConformanceTests`). Lean comes from elan, pinned by
`lean-toolchain`:

```sh
brew install elan-init                       # once
elan run leanprover/lean4:v4.34.0 lean Verification/SyncMerge.lean
```

A clean run prints only the conformance tables (lines starting
`CONFORMANCE`). Anything else — an error, or a warning such as a `sorry` —
fails the suite. On a machine without elan, `LAMP_SKIP_LEAN=1 swift test`
skips the Lean-backed tests by name rather than letting them pass.

## Keeping the model and the code together

Three checks run with the core suite, so the model cannot quietly fall behind
the code it describes:

- **The proofs check.** `theModelChecks` runs Lean on the model and fails on
  any error or warning.
- **The model and Swift answer alike.** The model's last section prints a table
  for each decision that has a Swift counterpart: its inputs and the model's
  answer, 3,778 cases across 73 decisions. `SyncModelConformanceTests` asks the
  shipped Swift decision every one of those questions. A decision changed on one
  side and not the other fails the suite and names the case that differs. So
  does a table with no Swift check, or a check with no table.
- **Every sync source is accounted for.** `coverage.json` names each shared
  sync source (by the patterns it lists), the Lean rules that model it, the
  conformance tables that hold it, and what is deliberately not modelled.
  `SyncVerificationCoverageTests` fails on a new sync source with no entry, an
  entry for a file that is gone, or a rule the model does not define. The Mac
  and iOS repositories are held the same way, by their own patterns
  (`platformPatterns`): wherever they are checked out beside this one, a sync
  file in either app with no entry fails too, so sync logic written into an
  app cannot arrive unaccounted for.

When you change a sync decision, change the model in the same commit, update
its conformance table if it has one, and give any new sync source a
`coverage.json` entry. A decision that lives only in an app cannot be held to
the model from here. Move its pure decision into core, as
`LampSyncPassRetry`, `LampSyncSettingsBootstrap.uploadsBeforeMerge` and
`LampSyncArchiveIndex.mayAdvanceWithoutFetch` were.

## What the review on 19 October 2026 found

The model was last written on 24 September, and about forty sync changes landed
after it. Comparing the two found the following.

**Drift — the model described behaviour the code no longer had:**

- Equal-time disagreements over a note or a writing no longer stop a sync run.
  They are set aside for the person to choose (`portableImportOutcome`), but the
  model and this README still said they stopped publication.
- A settings merge with no baseline no longer refuses different reading rows.
  It keeps every row and takes the newer copy (`baselessReading`). The old
  `differentReadingsWithoutBaseReject` is gone. Its cost — a deletion this
  device never saw comes back once — is now a proved counterexample,
  `baselessMergeRevivesAnUnseenDeletion`.
- Shared preferences no longer stop the sync over a disputed field, and a
  client with no baseline meets the server rather than refusing
  (`preferenceMerge`).
- A guarded first settings upload whose token has moved merges instead of
  refusing (`uploadsBeforeMerge`).
- Module revisions now compare as tokens. The weak-ETag rule still holds, but
  only because the WebDAV adapters drop weak tags before `needsImport` sees
  them. The model now says so (`needsImportByToken`, `webDAVAdapterRevision`).
- After a 409 from MKCOL, the model accepted only a 207 PROPFIND as proof that
  the collection already exists. The adapter accepts any success, since some
  servers answer 200, and treats a failed PROPFIND as an error. Found when
  `webDAVDirectoryReady` got a conformance table; the model now says what the
  adapter does (`collectionConfirmed`, `plainSuccessListingAlsoConfirmsTheCollection`).

**A bug the model exposed:**

- `LampSyncConditionalWrite.landing` judged a write conditioned on revision
  *e* to have landed whenever the server no longer held *e*. But a conditional
  write is refused precisely when another device wrote first, and that also
  leaves the server off *e* (`refusedWriteCanLookWritten`). The Mac then told
  the user a refused file was published. Such a write is now undecidable and
  settled by its bytes (`landingIsSound`, `settleByBytes`).

**Behaviour that was never modelled, now covered:**

- deletion ledgers for personal content, decks and workspace files, and the
  deck pull plan;
- files refused within a batch;
- confirming a write by reading it back twice;
- revision tokens and stored-JSON sameness;
- the archive index, and skipping a fetch by it;
- reusing an archive already read;
- starting a pass again after losing a race.

See "Coverage added in October" below.

## Model notes by area

`SyncMerge.lean` models the shared record merge decision, the fixed
millisecond file ordering in `Sources/LampModuleKit/LampSyncMerge.swift`,
the shared preference ledger's per-field choice, and the
pull/publish/complete sequence in `Sources/LampModuleKit/LampSyncEngine.swift`.
It proves that newer record revisions win, equal revisions with different
content report a conflict, and file merge is commutative, idempotent, and
associative. It proves that a failed pull cannot publish, and a failed publish
cannot record completion. `LampSyncEngine.run` now checks cancellation before
each phase; `cancellableRunTrace` proves that cancellation after pull blocks
publication and cancellation after publish blocks completion. Swift tests
cancel the running task at both boundaries. A callback already running must
handle its own cancellation. The model also gives a concrete three-file cycle
for the former sliding timestamp tolerance. The Swift tests exercise the implementation
with the same cases and an import round trip.
`LampSyncOnce` now coalesces concurrent initial-sync calls and closes only
after success. Mac automatic sync and iOS's first devotional pull and default
module creation use it, so a failed attempt can retry. `failedInitialSyncCanRetry` and
`successfulInitialSyncClosesGate` model that state change; the core Swift test
checks failure, retry, and later no-op behavior. A canceled caller stops at the
gate even if another caller finishes the shared attempt;
`cancelledInitialSyncWaiterCannotContinue` models that boundary.
iOS default notes and devotionals now skip the remote pull in local-only mode,
while a configured but unavailable provider still fails before creating a
potentially conflicting local default. `localOnlyDefaultModuleSkipsRemote`
and `configuredUnavailableDefaultModuleDoesNotCreateLocalCopy` model this
choice; the iOS regression opens both default modules without remote storage.

The shared record-set merge is called by iOS note and devotional imports;
`LampCore` portable note and devotional imports used by macOS use its record
decision. macOS workspace file sync uses the shared file order. Each platform
also calls `LampSyncEngine.run` for the pull, publish, and completion sequence.
iOS backend migration uses the same runner so a failed file copy or settings
publish cannot record a new backend choice. The runner does not roll back files
written before a later failure. `LampSyncBackendTransition` persists the
selected backend after target publication, wipes local modules only after
that persistence succeeds, and activates the new backend after the wipe.
If the wipe fails, it tries to restore the previous provider configuration.
`failedBackendPublishCannotWipe`, `failedBackendPersistenceCannotWipe`,
`failedWipeRequestsBackendRollback`, and `earlyWipeLosesDataOnFailedPublish`
model the ordering and the former data-loss path. iOS writes the previous
provider choice to its local module database before changing the provider
database. The content wipe removes that recovery record in the same SQLite
transaction. On launch or the next sync attempt, a remaining record restores
the previous choice; sync remains disabled if that restoration fails.
`committedBackendWipeClearsMarker`, `failedBackendWipeRetainsMarker`, and
`pendingMarkerSuspendsNewBackend` model this recovery gate. The two databases
still do not form one atomic transaction, so the proof relies on SQLite's
transactional write and durable read behavior. It does not prove crash behavior
of the OS or database library.

The iOS full module pass now pulls every type under one runner before publishing
any pending module. A failed settings/archive pull or any module-type pull
blocks that publication; `failedArchivePullStopsAllModulePublication` and
`failedModuleTypePullStopsBatchPublication` model the gate. An iOS test keeps
a note publication pending after both an earlier pull failure and a later
module-type listing failure. The foreground coordinator now pulls all editable
types during legacy reconciliation, then exports in its publish phase; a later
editable pull failure cannot trigger an earlier upload. Swift tests check the
pull-only path, and `failedEditablePullCannotStartForegroundPublication`
models the gate. One foreground pass passes the same selected provider to
settings and modules through `SyncCoordinator.SyncSession`; the iOS regression
observes both operations on the supplied storage. The iOS full pass now
imports the archive and pulls every module type before publishing settings,
shared preferences, or pending modules. `failedModulePullPreventsSettingsPublication`
and `failedArchivePullPreventsAllIOSPublication` model this gate; the iOS
regression checks that a late module listing failure leaves settings unwritten.
The foreground coordinator and module manager now use one top-level shared
engine run.
Its pull phase includes the optional legacy reconciliation, archive import,
and every module type. Its publish phase includes settings, preferences,
modules, optional legacy export, and final settings reconciliation. The
completion callback records the sync date only after those steps succeed.
The Settings screen's manual sync uses this same coordinator pass and reports
any thrown error.
`failedModulePullPreventsLegacyExport`,
`failedForegroundModulePullStopsBeforePublish`, and
`failedForegroundLegacyExportCannotComplete` model these gates. An iOS test
checks that a late module pull failure skips the export and completion hooks.
Settings reconciliation has its own inner runner because the poller also uses
it independently. Its database baseline may commit before a later preference
or module write fails; `settingsCanCommitBeforeLaterModuleFailure` makes that
partial state explicit. The coordinator now saves a new endpoint or completion
marker before exposing it in memory; `failedIOSSettingsPersistKeepsVisibleChoice`
models a failed save.
After settings sync, iOS rereads the archive and verifies all non-settings
entry bytes before merging shared preferences against that new revision.
The uploads themselves remain separate conditional writes. The portable archive
inspects all uncached modules before installing any;
`invalidLaterArchiveModuleCannotInstallPrefix` models
the rejection of a malformed later module, and an iOS test checks it. The
shared inspector's archive-import mode checks the required columns each iOS
SQLite copy or editable record decode uses before the first install;
identity-only callers keep their
older-file behavior. `missingLaterBookSectionsCannotInstallPrefix` and
`missingLaterImportColumnCannotInstallPrefix` model this gate. Shared inspector
tests cover all nine module kinds and an iOS archive regression checks a later
book or dictionary with missing copied columns. iOS now stages every SQLite
source before opening one local write transaction. A single attached staging
database exposes each source in turn, so an archive with more than SQLite's
usual attachment limit can still install. Note and devotional records are
decoded before the transaction, then reconciled inside it. A later module SQL error
rolls back earlier read-only and editable module changes; the archive cache is
recorded only after the commit. `failedIOSArchivePreparationKeepsInstalled`,
`lateIOSArchiveSQLFailureKeepsInstalled`, and
`successfulIOSArchiveCommitInstallsWholeCandidate` model this boundary;
`sequentialIOSArchiveFailureCanLeaveLocalPrefix` shows the former order's loss.
iOS tests force a late SQL error after a dictionary copy or notes merge, retry
after removing the error, and install twelve dictionary modules in one pass.
The staged highlight branch preserves a newer local set;
`newerLocalHighlightsSurviveArchive` models that decision and an iOS archive
test checks both the first import and a later local edit.
This still relies on SQLite transaction behavior and does not prove crash
durability of the database engine or consistency with separate settings/media
writes.
The shared compiler's nine output kinds now pass archive-import preflight in
its own tests. Compiled plans omit app-local file columns; iOS fills those from
the observed archive entry during installation. `compiledPlanWithoutLocalColumnsCanImport`
models that schema decision, and an iOS archive test checks the installed plan,
day, path, and digest.
`LampSyncArchiveRemote.readIfChanged` now owns the archive cache HEAD/GET
decision. It fetches the body when the local cache is invalid, the known
revision is weak, or the provider reports a change; the four
`archiveGetRequired` theorems and a shared Swift test cover these branches.

The wipe also clears editable module hashes with their rows, so an unchanged
remote file or cached archive revision cannot skip their next import.
`wipedEditableHashForcesArchiveImport` models the archive skip condition; an
iOS integration test removes a note's rows and hash, then reimports the same
archive revision.
During backend migration, `LampSyncMigrationCopy` now defers editable modules
to the merged local export. A raw read-only module is created only when absent,
skipped when identical, and reported as a conflict when the destination has
different bytes. WebDAV uses a create-only conditional PUT; iCloud checks
locally visible absence again before creating its ubiquitous file. Lean's
`editableMigrationNeverRawCopies`, `divergentReadOnlyDestinationIsConflict`,
and `divergentReadOnlyMigrationStopsBeforeBackendPublish` model the decision
and its effect on backend activation. A remote device can still upload after
the iCloud check.
The shared `LampWebDAVStorage` owns WebDAV requests, status handling, and
directory parsing for both apps. `LampSyncRemoteStore` gives both WebDAV
adapters the same list, read, revision, and conditional-write operations.
Each platform maps the results into its own database and file layout. The Swift
record-set test covers key union and duplicate input handling; the Lean proof
covers the per-key choice. WebDAV
transport behavior is covered by Swift tests, not by this Lean model.

A full sync is lossless only within the system model below ("What the system
model proves"), and only for content whose merge is a join; the two
exceptions are named there. `uploadFirstLosesRemoteOnlyEdit` demonstrates why a whole-file upload before
reading the remote snapshot can discard an independent edit. iOS settings now
read first and use `LampSyncThreeWaySet` with a locally stored baseline for
completed readings. `mergeMembership` proves the per-ID add and delete rule;
`chooseWholeValue` proves that different concurrent settings-row edits produce
a conflict. The shared Swift planner chooses the later completion time for a
reading retained by both sides and reports a conflict on tied times with
different row data; `chooseReading` models those decisions in Lean. The
uploaded SQLite copy omits device-local sync provider configuration. An older
installation without a baseline uses a guarded first
upload only when the remote token still matches its last observation.
`staleSnapshotCannotUpload` and `uploadsBeforeMerge` model that check; when the
token has moved, or either token is unknown, the merge runs on its own instead
of refusing (`movedRevisionMergesInsteadOfRefusing`). `chooseWithoutBase`
models the timestamp choice for settings, which still refuses an equal-time
disagreement. Reading rows without a baseline are merged rather than refused:
every row either side holds is kept, and a row both hold takes the newer copy,
the remote's on a tie (`baselessReading`, `baselessMergeKeepsEveryRow`). A row
only one side holds may be an addition here or a deletion there, so a deletion
this device never saw comes back once (`baselessMergeRevivesAnUnseenDeletion`);
from the next merge on there is a baseline. WebDAV sends an atomic HTTP precondition on
the write; `staleConditionalWriteRejected`, `createOnlyWriteCannotOverwrite`,
and `observedRemoteDeletionCannotRecreate` model the server-side revision rule.
The shared WebDAV adapter validates one complete strong entity-tag before
using it as an `If-Match` condition. RFC 9110 allows a comma inside the quoted
tag but not an embedded quote that could turn the header into a list. Lean's
`combinedETagsCannotAuthorizeWrite`, `commaInsideStrongETagIsValid`, and
`weakETagCannotAuthorizeWrite` model that grammar gate; Swift tests exercise
the adapter and conditional-write helper.
The shared existence check treats only HTTP 404 as missing, falls back to GET
for a server that rejects HEAD with 405, and propagates other errors. Lean's
`forbiddenWebDAVHeadIsNotAbsence` and `unsupportedHeadFallsBackToGET` model
that distinction; the WebDAV adapter test exercises the actual responses.
Both WebDAV publishers now use `LampSyncRemoteDirectories` to prepare parent
paths in root-to-leaf order. The shared adapter accepts a 409 from MKCOL only
when a PROPFIND confirms the same path is an existing collection. Lean's
`existingWebDAVCollectionAcceptsConflict`,
`missingWebDAVCollectionKeepsConflict`, and
`nonCollectionCannotSatisfyMKCOLConflict` model that decision; Swift tests
check the requests and reject unsafe paths before publishing.
`LampSyncConditionalWrite` implements the
shared revision check used by the app adapters, and `LampSyncArchiveRemote`
keeps the archive and revision from one GET together for both apps. Swift tests
exercise their missing-ETag and changed-revision paths. The Lean model assumes
the WebDAV server honors these headers. When PUT omits an ETag, either app
accepts a revision only after a GET returns the uploaded bytes with that
revision. `separateSettingsTokenCanAuthorizeStaleBody` shows why iOS settings
now read database bytes and ETag from one GET; the paired revision is rejected
if the server changes before PUT. `macPublishRetainsObservedSettings` and
`staleMacArchiveCannotReplaceSettings` model Mac's archive rebuild retaining
the iOS settings entry read with the archive revision. `macDoesNotInventSettingsFromOutgoing`
models removal of a stray local settings copy when the observed archive has none. The Swift archive tests
cover entry preservation and revision-conditioned publication. iOS now writes
settings into the archive and conditionally mirrors the standalone file.
`classifyLegacySettings` models the compatibility manifest: exact mirrors and
unchanged old copies are safe to ignore, while different legacy bytes or a
removed observed file report a conflict. Swift tests cover archive creation,
preservation of Mac entries, detection of an older-client edit, and retrying a
failed mirror. `resolveSettingsSource` models the shared archive-first read,
which falls back to the standalone file before migration and stops on a later
legacy edit. `mayAdoptLegacyBase` models the source and revision check used
to carry a standalone-file baseline into an archive merge.
`failedInitialLegacyMirrorCanRetry` models the missing mirror state after an
archive commit when the first compatibility write failed.
`maySkipArchivePoll` models the shared paired HEAD check: iOS skips downloading
settings only when the applied archive baseline and the legacy mirror both
still have matching strong revisions and no local change is pending.
`observedModuleWrite`
models the legacy module rule: a different remote body cannot be replaced using an old revision, old
digest, or unknown
base. It assumes digest equality means equal bytes; the Swift tests exercise
actual SHA-256 comparison. `observedCompatibilityWrite` models the archive
manifest exception: its payload may replace the folder revision it superseded,
while a later folder edit is rejected. `changedTokenDuringReadIsRejected`
models the shared `LampSyncStableRead` check used for iCloud's before-and-after
content digests. `equalModificationDateCanHideChangedBody` shows why the iCloud
adapter no longer uses a modification date as its token. SHA-256 collision
resistance is assumed rather than proved. The iCloud read also compares the
returned body's digest with both probes; `equalOuterTokensCanHideDifferentBody`
models an A→B→A read that this extra check rejects.
An iOS test confirms that a saved modification-date token still identifies its
existing three-way settings baseline during the first digest-based read.
`missingTokenCannotAuthorizeExistingBody` rejects
an existing file when both token reads are unavailable.
The iCloud adapter also rejects unresolved `NSFileVersion` conflicts before
coordinated reads and writes; `reportedICloudVersionConflictStopsRead` models
that gate, assuming the OS reports the conflict. It includes hidden iCloud
module placeholders in listings and propagates listing errors.
For generic media files, iOS now uses the shared no-base content decision:
an absent file may be created and identical bytes may be retried, while a
different remote body stops the upload. iCloud rechecks the body and rejects
a visible placeholder inside the coordinated write. Lean's
`unbasedContentWriteAllowed`, `differentMediaCannotBeReplacedWithoutBase`,
and `hiddenRemotePlaceholderStopsCreate` model those gates. The WebDAV media
adapter uses the same content decision and a server-side conditional PUT.
For iOS module-folder pulls, `LampSyncReferencedMedia` in core transfers
referenced book and devotional files and reports the first failure after trying
the rest. The files belong to pull completion: a file
read or local write failure stops the sync, and an unchanged module retries
missing media on the next pass. Malformed devotional media references and
missing local upload files also prevent publication. The iOS regression reads
an unchanged devotional twice, failing its first media read and recovering on
the second. `unchangedModuleRetriesMissingMedia` and
`failedMediaTransferBlocksCompletion` model the retry and completion gate.
Editable module publication writes its durable retry marker before the module
body; the marker survives a later media upload failure and clears after the
files succeed. A pending local media upload avoids a pull from an incomplete
remote copy. `failedMediaUploadRetainsPublication` and
`pendingLocalMediaUploadWaitsForPublish` model these transitions.
`swallowedListingErrorCouldReachCompletion` shows why a listing failure must
fail the pull stage instead of being interpreted as an empty provider.
`stableICloudReadDoesNotProtectLaterWrite` gives a
counterexample when another device writes after that check. iOS now compares
the observed body again inside the coordinated module and settings write
callbacks; `changedBodyInsideCoordinationIsRejected` models the local guard.
Archive checksums, compatibility manifests, observed WebDAV writes, and iOS
module hashes now share `LampSyncContentRevision.digest`.
`LampSyncArchive.create` includes hidden attachments under `Media/` and rejects
source media symlinks instead of silently omitting them. Hidden non-media files
remain excluded. `hiddenMediaAttachmentIsIncluded` and
`mediaSymlinkStopsArchiveCapture` model that capture decision. Library import
also includes hidden media and rejects media symlinks;
`hiddenMediaAttachmentSurvivesPortableRoundTrip` and
`mediaSymlinkStopsPortableImport` model that path. Core tests exercise both
capture and import.
The portable devotional media bridge shares iOS's full media reference schema
with Mac. Mac's compatibility export unwraps only its exact plain paragraph
Markdown shape, retains rich blocks and existing media fields, and adds legacy
`lamp-media://` references. iOS checks the matching archive attachment before
installing rows, copies it into `DevotionalMedia`, and rereads an unchanged
archive when a local attachment is missing. Mac retains raw `media_json`,
resolves both `media/id` and legacy URLs, and pulls missing iOS attachments
through `LampSyncReferencedMedia`. Mac also stores the original structured
`content_json` and exports it through JSON, `.lamp`, and portable backups when
the body is unchanged; metadata edits retain those blocks. The shared
`LampPortableDevotionalContent` projects iOS headings, annotated text, lists,
media, tables, and section trees for Mac's reader and editor. Mac body edits
convert the projection back to iOS blocks. Identical blocks keep their full
source JSON, including blocks an older renderer cannot display. Outline edits
retain the structured root and matched section metadata, including IDs when
sections move or change depth.
The Mac reader now lays out tables rather than showing their Markdown pipes.
Both editors now parse Markdown through the shared core block parser and use
the same projection for flat and structured content. iOS keeps authored
Markdown for plain drafts and stores revised rich blocks for rich sources,
retaining section IDs when their outline is edited. Its frontmatter and
footnote export remain in iOS. iOS distinguishes rich JSON by its block schema
so an authored Markdown body beginning with `[` or `{` still loads as Markdown.
Mac now authors new devotional attachments with the shared rich reference
schema. Its WebDAV compatibility publisher uploads both legacy and rich media
to `DevotionalMedia/devotionals/<entry>/<file>` before the `.lamp` module,
preparing nested directories and stopping on a missing or conflicting file.
`richDevotionalBlocksKeepTheirContent`,
`unchangedRichDevotionalBlockIsExact`,
`editedRichDevotionalBlockKeepsOpaqueFields`,
`editedRichDevotionalBlockUsesNewBody`,
`movedRichSectionKeepsIdentity`, `movedRichSectionKeepsOpaqueFields`,
`changedRichOutlineKeepsRootFields`,
`iosRichEditStoresRevisedBlocks`, `iosPlainEditKeepsAuthoredMarkdown`,
`bracketedMarkdownWithoutBlockSchemaKeepsMarkdown`,
`existingMediaMetadataIsPreserved`, `missingPortableAttachmentStopsCommit`,
`missingPortableMediaForcesArchiveRead`, `macImportEnrichesMissingMetadata`,
`macMetadataEditKeepsStructuredBlocks`, `failedDevotionalMediaStopsModuleMirror`,
`identicalDevotionalMediaNeedsNoWrite`, `conflictingDevotionalMediaCannotPublish`,
and `missingIOSMediaStopsMacPull` model
these boundaries. Core and iOS tests
exercise the file and metadata round trips.
iCloud still has no equivalent server-side condition in this implementation,
so a later device upload can supersede the locally checked write. Mac's archive
and iOS-compatible files are still separate writes,
so a failed later write can leave a partial publish. The compatibility manifest
lets both clients ignore a folder revision superseded by the archive;
`observedCompatibilityWrite` models that revision rule.
`LampSyncCompatibilityPublisher` owns the ordered compatibility writes used
by macOS and the standalone settings mirror used by iOS. `mirrorAttempts`
and `failedMirrorPreventsCompletion` show that a failed mirror stops later
writes and prevents completion; earlier successful writes remain committed.
Mac's highlight preparation uses `LampSyncPersonalExport`: an empty set may be
skipped, while a database or serialization error stops publication before the
archive PUT. `emptyMacHighlightSetMayBeSkipped` and
`failedMacHighlightExportStopsArchivePublish` model the decision; a shared
Swift test checks the expected skip and propagation of other errors.
Mac folder sync now uses `LampSyncFolderPublisher` in core. It captures the
folder once for pull, checks the full snapshot before publish, and checks each
file's observed bytes inside a coordinated write. Hidden iCloud placeholders
are downloaded before the snapshot, and a missing or unreadable folder fails
the pull. `changedFolderStopsBeforeFirstWrite` and
`changedFolderFileCannotBeReplaced` prove the modeled guards. The real folder
still has no cross-device atomic multi-file commit; a failed later file write
can leave earlier files published, as `folderBatchCanCommitPrefixBeforeFailure`
shows. The publisher now writes `lamp-sync-snapshot.json` with the complete
old and intended new file digests before changing payloads, then records only
the new snapshot after the batch. It stages the intended payload archive in
the folder before writing the marker. Capture accepts either complete set and
rejects a mixed set before import. macOS asks the shared publisher to finish
an interrupted batch before importing it. Recovery verifies the staged
archive's digest and rechecks that each visible file is still either the old
or intended body before replacing it. An unrelated edit blocks recovery.
`pendingFolderSealAcceptsOld`,
`pendingFolderSealAcceptsCompleteNew`, `mixedFolderSnapshotIsRejected`, and
`committedFolderSealRejectsLaterEdit` model the reader gate.
`missingFolderStageCannotRecover`, `oldFolderFileCanResume`,
`completedFolderFileCanResume`, and `unrelatedFolderEditCannotBeOverwritten`
model recovery's per-file decision. Swift tests cover a stopped batch, safe
replay, an unrelated edit, a fully written batch whose final marker was not
updated, stale edits, per-file rechecks, placeholders, and missing folders.
Legacy folders without a snapshot marker remain readable. A stopped batch
with a missing stage or unrelated edits needs repair before sync can resume.
The marker does not
make writes atomic for older clients that do not check it or prove provider
propagation order.
The shared preference ledger's per-field choice is modeled in Lean
(`choosePreference`) and tested in Swift. A field both devices changed
differently is set aside rather than stopping the sync: the server keeps its
value, so the other device's edit survives; this device keeps what its user
set; and the baseline keeps what the two last agreed, so the dispute shows
again until they hold one value (`preferenceMerge`,
`disputedPreferenceKeepsTheServersValue`, `disputePersistsWhileTheValuesDiffer`).
A client with no baseline meets the server: the server's value stands, and a
value only this client holds is contributed (`firstMeetingKeepsTheServersValue`,
`firstMeetingContributesALocalOnlyValue`). Mac staging reads only explicitly stored settings from the app's
persistent domain; registered UI defaults do not become local sync edits.
`registeredDefaultWithoutStoredPreferenceIsNotAnEdit` models that extraction,
and a Mac Swift test covers a fresh domain. The proof
does not cover archive JSON, local database mapping, or UserDefaults. Both apps
now use `LampSyncPreferenceState` to validate, encode, and retain a base per
sync source. The shared Swift tests check source isolation and invalid cached
data; `failedPreferencePublishKeepsEveryBase`,
`publishedPreferenceUpdatesItsSource`, and
`publishedPreferenceKeepsAnotherSource` model the base transition. Likewise,
local and remote record edits with different timestamps are resolved by
last-writer-wins; the
proof does not claim to preserve both edits. OS file-coordination semantics and
the runtime durability of crash recovery are outside this model.

iOS now persists unresolved note and devotional conflicts in its module
database and restores them after restart. Exports remain blocked until every
conflict for that module is resolved, even when the stored remote hash matches.
`pendingModuleConflictBlocksExport` and
`changedModuleRevisionBlocksResolvedExport` model those gates. A Swift test
round trips the conflict payload through the database and checks the export
gate. `resolvedRecordRevisionExceedsBoth` models the timestamp assigned to
the chosen value, so another device can prefer it over either conflicting
copy. The database operations and conflict-resolution UI are not proved by Lean.
The local publication marker now survives a failed module upload and is
retried after the next pull. `locallyKeptRowRequiresPublication`,
`failedModuleWriteRetainsPublication`, and
`successfulModuleWriteClearsPublication` model its transitions. When a JSON
module and its .lamp successor coexist, `LampSyncModuleFiles` selects one
current representation for the pass, preferring .lamp even if JSON was
installed. Archive-superseded files are removed before ranking, so a stale
.lamp cannot hide a later JSON edit. `supersededCanonicalCannotHideActiveLegacy`
and `whollySupersededIdentityUsesArchive` model those cases. Both apps now use
`preferredCandidateIndices` to select one active occurrence per identity while
keeping its payload paired with the selected listing; the Swift regression
checks duplicate paths, and `duplicateSupersededPathChoosesActiveOccurrence`
models that case. `LampSyncModuleFolder.list` supplies both WebDAV adapters with
the same supported-file filter and preserves listing errors. The Swift folder
test checks directory, extension, duplicate, missing-folder, and error cases;
`moduleFolderListing` models the missing-versus-failed distinction and filter.
The other format-choice theorems cover the canonical and legacy ranking;
an iOS module-sync test reads the active JSON path when the .lamp revision is
superseded, and a Mac support test covers the same choice after JSON expansion.
`changedModulePathRequiresImport` shows that matching hashes on different
filenames cannot skip the import. Swift tests exercise retry and the full
format ranking. Mac's WebDAV importer now reads module identities from each
portable SQLite body and each normalized JSON document, then uses the same
per-identity choice. Legacy notes JSON can expand into per-book documents;
each keeps the original source module identity for this choice. A JSON envelope
with several modules keeps the documents whose identities have no canonical
successor; `aggregateJSONKeepsUnshadowedModule` models that case. Both clients
also use the shared case-insensitive portable filename check, so unrelated
files cannot enter the module import loop.
The iOS WebDAV module adapter now exposes only strong ETags as module
revisions and reads a fresh body with its GET revision for single-module sync
instead of reusing an earlier listing cache. `LampSyncModuleFiles.needsImport` forces a
download whenever the remote revision is missing, even if the stored revision
is also missing. Revisions compare as tokens, so a quoted listing tag matches
the bare revision recorded after this device's own upload
(`quotedListingOfOwnUploadMaySkip`). A weak tag still cannot skip an import,
because the WebDAV adapters pass on only strong revisions
(`weakListingCannotSkipThroughTheAdapter`); iCloud passes a content digest.
`missingRemoteRevisionRequiresImport` and
`weakETagCannotSkipModuleImport` model the import gate; a Swift integration
test imports a changed module when both revision fields are nil. Weak or
combined ETags also cannot become stored settings change tokens.
Module imports now use `readModuleSnapshot`: the WebDAV adapter returns bytes
and strong ETag from one GET, while iCloud derives a digest from its coordinated
read body. The listing revision only decides whether to fetch; it is not saved
as the imported body's revision. `changedModuleBetweenListAndGetUsesGetRevision`
and `iCloudModuleRevisionDescribesReadBody` model that pairing. A Swift iOS
test gives the listing and read different revisions and checks which one is
saved. After an iCloud module export, iOS saves the digest of the bytes it
wrote, so a later remote upload cannot make its baseline describe another
body. `laterRemoteUploadDoesNotChangeExportRevision` models that rule. The
`ModuleStorage` protocol requires each adapter to implement
`readModuleSnapshot`; it has no separate-read fallback.
For iOS read-only JSON modules, decoding now precedes replacement, and
dictionary and commentary row replacement runs in one SQLite transaction.
Dictionary, note, and devotional JSON imports also reject an embedded module
ID that differs from the listed ID. `invalidRemoteJSONKeepsInstalledRows` and
`mismatchedModuleIdentityKeepsInstalledRows` model the preflight gate; the
transactional result still relies on SQLite. Dictionary and commentary JSON
child inserts now fail on a foreign primary-key collision and roll back the
whole replacement. Legacy commentary JSON has no
embedded module ID, so its filename remains the identity source.
The iOS and Mac remote SQLite paths use `LampPortableModuleInspector.inspectRemote`
to check the downloaded body and its kind before local replacement. iOS also
checks its embedded ID against the selected file.
Canonical .lamp files require an embedded identity, except older compact
highlight files whose `highlight_meta.id` names the set rather than the module.
New compact highlight exports write `module_format.module_id`; iOS accepts the
older form using its listed filename. Older .db and .db.zlib files without an
identity also use their filenames for compatibility; the inspector
rejects a damaged SQLite body and checks any identity it can find. The Mac
importer uses the same inspector to select candidates by embedded identity.
`canonicalModuleRequiresEmbeddedIdentity`,
`legacyModuleWithoutIdentityCanUseFilename`, and
`damagedOrMismatchedSQLiteCannotReplace` model the acceptance boundary.
`legacyCompactHighlightMayUseListedID` models the one canonical exception;
`unrelatedSchemaCannotUseLegacyFallback` and
`wrongKindOrDamagedRemoteCannotFallBack` keep unrelated or malformed bodies out.
`compactHighlightSetIDCannotSupplyModuleID` and
`canonicalHighlightUsesHeaderID` keep the two highlight IDs separate. A full
headerless highlight archive can use `module_meta.id`. Mac personal study
import also uses that stored ID for headerless notes, even when the download
has a temporary filename; `legacyPersonalStudyUsesMetadata` models the choice.
Mac's direct installer likewise uses the file identity for old compact
highlights and keeps `highlight_meta.id` as the set ID; a core round-trip test
checks both IDs.
For read-only SQLite imports, iOS now retires old rows and copies replacement
rows inside the same ATTACH write transaction. A failed copy rolls back those
rows and their metadata; `failedSQLiteCopyKeepsInstalledRows` models the
result, while `earlySQLiteDeleteLosesRows` shows the former order. Dictionary
and book registry metadata now saves inside that same transaction.
`failedMetadataSaveKeepsInstalledRows` models a late metadata error, and an
iOS trigger regression checks that the copied rows roll back. This still
relies on SQLite's actual transaction behavior. Editable note and
devotional merges use their separate reconciliation path.
The portable inspector also checks every present owner column against the
selected module ID before iOS import, including a legacy SQLite file whose
header is absent. It rejects a matching header with foreign dictionary,
commentary, translation, plan, book, quiz, note, devotional, or highlight rows.
Full highlight child rows must refer to a source set. The same inspector runs
for Mac portable archive candidates. `foreignSQLiteOwnerKeepsInstalled` models
the preflight gate; it does not prove SQLite schema parsing or file integrity.
Mac's direct `.lamp` installer, including folder backup imports, now checks
those same owner columns before replacing an installed module. A core Swift
test confirms a mixed-owner archive leaves the installed file intact.
Mac personal note and highlight `.lamp` imports check the same ownership rule
before merging rows. `foreignPersonalStudyRowCannotMerge` models that gate;
a core test corrupts each export and confirms the target stays empty, then
imports a headerless notes archive through a temporary filename.
Portable backup import now applies modules and personal documents to a sibling
copy of the Mac library and replaces the local root only after every item
succeeds. Mac folder and WebDAV pulls use the same stage for backup content,
workspaces, and canonical iOS WebDAV items. A later import failure discards the
stage and leaves the local library unchanged; core Swift tests cover a good
module followed by a damaged one and a workspace failure after backup import.
A Mac support integration test covers a workspace document followed by a
malformed skill selection, then a successful retry.
Legacy workspace skill migration now runs inside the staged pull; publishing
the portable workspace export reads the prepared library without migrating it.
`failedStagedBackupImportKeepsLibrary` models the local pull result, while
`laterBackupFailureCouldLeavePartialLocalLibrary` shows the old behavior.
The live library's file digests are checked before replacing the root, so an
edit made while staged import is suspended aborts the commit;
`changedLocalLibraryRejectsStagedCommit` models that guard. Mac settings and
the iOS highlight ID mapping are also prepared before the stage commits. A
failed pull leaves both unchanged; `failedMacPullKeepsEveryLocalPart` models
the combined logical result. The Swift path checks for live settings edits
before commit. The proof relies on filesystem replacement and digest
calculation at runtime. The staged library root now carries a settings
journal. Mac startup and each sync replay it after a crash before publishing
again. A distinct settings edit blocks replay, leaving the journal for repair.
`swappedMacLibraryRetainsRecoveryJournal`,
`pendingMacSettingsReplayCompletesPull`, and `distinctMacSettingsEditBlocksReplay`
model those transitions; Mac Swift tests cover partial replay and a conflicting
edit. `mixedMacSettingsReplayToWholePlan` and
`unrelatedMacSettingBlocksWholeReplay` model the per-key check used when a
crash leaves some UserDefaults keys updated and others untouched. The runtime
guarantee depends on the root swap, property-list write,
UserDefaults flush, and journal removal surviving OS interruption in that order.
Bulk copied child rows use plain `INSERT` in SQLite and JSON import paths, so a
source primary key that belongs to another installed module fails and rolls
back the replacement. Commentary
series metadata updates in place to retain references from other books.
`foreignImportKeyCollisionKeepsInstalled` models the collision rollback.
Editable note and devotional SQLite and JSON reconciliation now reads local rows,
merges them, and saves metadata, replacement rows, conflicts, and publication
markers in one SQLite transaction. A failure in any insert rolls back the
whole state; `failedEditableMergePreservesWholeState` models that
transaction outcome. The model still depends on SQLite for runtime atomicity.
The separate iOS translation-schema JSON importer now retires metadata and
content inside its batch insert transaction. It uses plain inserts for child
rows so duplicate or foreign keys fail and restore the installed translation.
`failedTranslationSchemaReplacementKeepsInstalled` models the transaction
result; an iOS test exercises duplicate incoming books and a successful retry.
The importer also checks the schema type and ID before writing. Local
translation-file revisions use the shared content digest.
`wrongTranslationSchemaTypeCannotImport` and
`invalidTranslationSchemaIDCannotImport` model the preflight checks.
Portable note and devotional import compares payloads before treating an
equal-time import as an unchanged duplicate, with JSON columns compared by
meaning (`sameColumn`). A disagreement that remains is set aside on a sync run:
this device's copy stays, the other is stashed for the person to choose, and
the import carries on (`portableImportOutcome`, `syncImportNeverStops`). An
import someone asked for still stops with an error
(`requestedImportStopsOnDisagreement`). The Lean `decide` rule models the
conflict decision; Swift tests cover the payload comparison.
`LampSyncSettingsBootstrap` now selects the five iOS settings entry cases in
core. The ordinary merge uses `LampSyncEngine` for pull, publish, and
completion. The `settingsBootstrap` theorems prove that a required missing
remote cannot be created, fresh adoption precedes local upload, and a dirty
no-base state uses the guarded path. Provider writes, SQLite import, and
compatibility mirror recovery remain Swift and provider boundaries.

## Coverage added in October

**Disagreements set aside.** `LampSyncMerge.importOutcome` turns a record
decision into keep, take, set aside or stop; both personal import paths in
`LampLibrary` use it. Choosing a version later stamps it past both copies, so
the device that chose prefers it, and so does the other
(`resolvedChoiceWinsWhereItWasMade`, `resolvedChoiceWinsOnTheOtherDevice`).
Neither raises the same disagreement again.

**Deletion ledgers.** Personal content, decks and workspace files keep one
ledger shape: per item, the latest save and the latest deletion, merged by
keeping the later of each. `later` and `mergeTombstone` are commutative,
associative and idempotent, so two devices reach one verdict whatever order
they exchange ledgers in (`exchangedLedgersAgree`). A deletion no earlier than
the last save deletes, and an equal time favours the deletion
(`equalTimeFavoursDeletion`). An edit or save after a deletion survives it
(`editAfterDeletionSurvives`, `saveAfterDeletionSurvives`). A workspace
document's deletion is stamped with the version this Mac last had, so an edit
made elsewhere after that survives (`documentDeletionSparesALaterEdit`). The
deck pull keeps the greatest undeleted copy in the shared file order and never
keeps a deleted deck (`deckPullNeverKeepsADeletedDeck`), whatever order copies
arrive in (`deckPullIgnoresArrivalOrder`).

**Refused files.** `publishReportingRefusals` attempts every file and collects
the refused ones (`refusalsDoNotStopTheBatch`, `everyFileIsAccountedFor`). Any
other failure stops the batch at that file (`aFailureStopsTheBatch`).

**Did a refused write land?** `landing` now claims "not written" only while the
server still satisfies the write's condition, and "written" only for a write
that asserted nothing (`landingIsSound`). Everything else is undecidable, and
the Mac settles it by comparing bytes (`settleByBytes`). `writeAndConfirm` names
a revision only from a read returning this write's bytes, asking twice
(`settlingServerConfirmsOnTheSecondRead`,
`anotherDevicesBytesNeverConfirm`, `aThirdReadIsNeverMade`). The read-back is
streamed to disk and compared by SHA-256 digest, so a library-sized body is
never held twice; equal digests standing for equal bytes is the assumption
`contentRevision` already makes. This compares this client's own upload with
the server's copy of it. Imports compare values, never bytes, since two clients
encode one value differently.

**Revisions and JSON.** `namesSameRevision` treats quoted, bare and weak
spellings of one tag as one revision, and absent and present as different
(`spellingsOfOneTagNameOneRevision`, `namesSameRevision_symm`).
`LampSyncJSONComparison` compares stored JSON by meaning; `sameColumn` is an
equivalence, and text that is not JSON never matches JSON or an absence
(`sameColumn_trans`, `textIsNeverTheSameAsJSONOrNothing`). Classifying a string
is left to Swift.

**Archive index.** A reader trusts the index only when it names the server's
current strong revision (`trustedIndexDescribesTheServersRevision`). An index
a slow publisher left for an older revision is never trusted
(`lateIndexForAnOlderRevisionIsNotTrusted`), and neither is any index under a
weak or unknown revision. Advancing past a moved archive without fetching
requires the trusted index's importable entries to be exactly those last
installed (`advancingWithoutFetchMissesNothingInstallable`). The fingerprint is
a SHA-256 of the sorted entries, and its collision resistance is assumed.
Settings resolution reuses an archive already read only while the server still
holds that strong revision (`reusedArchiveIsTheServersCurrentRevision`).

**Starting a pass again.** `LampSyncPassRetry` runs one more pass after an
archive write loses to another device's publish, and never more than two in
all (`aSyncRunsAtMostTwoPasses`). A succeeded pass is not repeated, and neither
is a failure that left the revision where it was
(`anUnmovedRevisionIsNotRepeated`). An archive that appeared since the read
counts as a lost race (`anArchiveThatAppearedIsALostRace`).

**The per-file library (design B).** Each module is its own file, and a
manifest in the settings bundle says which belong to the library. Per path it
keeps two stamps, the latest write and the latest deletion, each a time and
the revision it concerned. Stamps order by time and then by revision, and the
manifest merges by keeping the later of each, a join
(`laterStamp_comm`, `_assoc`, `_idem`; `mergeManifestEntry_comm`, `_assoc`,
`_idem`), so devices agree on membership whatever order they merge in
(`membershipIgnoresMergeOrder`). Equal times are a deletion
(`equalTimeDeletesAFile`). A write recorded over the revision the manifest
holds is stamped after it, so a slow clock cannot make the later write lose
(`successorWriteIsStampedLater`), and any write made after a deletion comes out
a member (`writeAfterDeletionIsMember`). Adoption never undoes a deletion
(`adoptionNeverUndoesADeletion`), and a copy put back by hand after one is
adopted (`aCopyPutBackIsAdopted`). A tombstone is never pruned from a member
(`pruneNeverDropsAMember`), nor from a listed file still waiting to be reaped
(`pruneWaitsForTheReap`). The 180-day lifetime has a cost, proved as a
counterexample: a device offline for longer brings the file back
(`tombstoneLifetimeCost`).

`filePlanAction` is the decision for one path. Nothing is deleted locally
without a tombstone, so absence from a listing never deletes
(`deletingNeedsATombstone`). A file nobody tombstoned is adopted, never dropped
(`anUnknownFileIsAdopted`). That is what lets a pass write its files first and
record them all in one bundle update at the end. A client with no record of a
file never writes over the server's copy, but downloads or merges it
(`noRecordNeverOverwrites`). Records are kept per provider, so a provider
switch costs one comparison by value, not a re-upload. On the folder provider a
member's revision comes from the manifest, so an evicted iCloud file is never
read just to be compared (`aRecordedMemberIsNeverRead`). The bundle's update
retries a refused write, never more than its attempts
(`settingsUpdateIsBounded`). Format 3 is refused by archive readers, which
accept 1 and 2 (`oldReadersRefuseTheBundle`), and an archive at the bundle path
is never read as a bundle (`anArchiveIsNeverReadAsTheBundle`). That is judged
from the unpacked header alone. Nothing at the bundle path is a new library
only when no earlier sync's marker or module file is there either
(`onlyAnEmptyLibraryIsNew`): a folder the Mac keeps holds its files loose,
with no archive, and only the migration may create a bundle over them. So a
new library's first pass claims the path with an empty bundle before writing
any file. Writing files first, its own files would make the closing update
call the library an earlier one, and it could never finish
(`uploadingFirstLocksAFreshLibraryOut`, `claimingFirstNeverMeetsItsOwnFiles`).
An earlier library is the Mac's if its marks are there, and otherwise the
phone's, whose files are already the per-file layout (`earlierLibrary`). An
ordinary pass claims only a new library (`anOrdinaryPassClaimsOnlyANewLibrary`);
the phone's migration may also claim the phone's, and nothing claims the
Mac's (`thePhoneNeverClaimsAMacLibrary`). On WebDAV the phone left a
settings-only archive. An archive is the phone's only if it holds nothing but
settings; a module or the Mac's own settings make it the Mac's
(`archiveKeeper`, `anArchiveWithAModuleIsTheMacs`,
`theMacsSettingsMarkItsArchive`). Entries are sorted, and nothing the phone
writes sorts before `Settings/`, so judging by a first entry before it never
misjudges a phone's archive and spares unpacking a library
(`thePeekNeverMisjudgesAPhoneArchive`).

The Mac moves a library it kept by writing the first bundle, carrying only
what lives nowhere else under the per-file layout: every setting and ledger
is carried (`everySettingAndLedgerIsCarried`), only the old layout's
bookkeeping and the copy a retired alias left are dropped
(`onlyBookkeepingIsDropped`), and anything it cannot
place stops it. The content the Mac publishes from its library on its next
pass. It writes over an archive only at the revision it imported
(`theMigrationWritesOnlyOverTheArchiveItImported`), moves only a library the
Mac kept (`theMigrationMovesOnlyTheMacsLibrary`), and run again writes nothing
(`aMigratedLibraryIsLeftAlone`).

A server can take a write and still answer the next reads with what it held
before, as the user's Synology does after a PUT that names no revision; the
first real move failed on exactly that. `writeOutcome` keeps "taken but not
yet shown back" apart from "refused": a write the server took is never a
refusal (`anAcceptedWriteIsNeverRefused`), and only a read-back of the bytes
sent names its revision (`aWriteIsNamedOnlyByItsOwnBytes`). So the bundle's
update, the claim and the move wait for the server instead of retrying into a
refusal of their own write.

Both apps run one pass engine, `LampSyncBundlePass`, whose substance is an
order. A pass takes a subset of eleven steps, always in one order
(`aPassKeepsTheOrder`):
- it claims the bundle first (`aPassStartsByClaimingTheBundle`);
- it applies what the bundle carries before gathering the library;
- it takes what came down before anything goes up;
- media goes before the modules that name it;
- the bundle is written once, after every upload and local deletion
  (`oneBundleWriteAtMost`);
- bytes are reaped only with the bundle write that records their deletion
  (`aReapComesWithItsBundleWrite`).

The `passTrace` table runs the engine itself for every combination of work and
compares the steps it took, in order.

On the folder provider, `directoryWrite` and `directoryDelete` decide a
conditional write or delete inside the coordinated block, and a write goes
ahead exactly when the folder publisher's coordinated check allowed it
(`directoryWriteIsTheCoordinatedCheck`). Unresolved iCloud versions stop a
file (`unresolvedVersionsStopTheFile`), and a reap never removes a copy other
than the one named (`aDeleteNeverRemovesAnotherCopy`). The settings bundle is
the one file whose versions are merged. Only a format-3 bundle is merged
(`anArchiveVersionIsNeverMerged`). A version is merged and resolved by the
write, or it stops the update; it is never dropped unmerged, and merged
versions are written even when nothing changed (`aVersionIsMergedOrStops`,
`mergedVersionsAreAlwaysResolved`). Core's merge of a version joins what it
can and keeps the apps' own settings for them to merge. The joined parts come
out the same whichever copy iCloud kept as current, and fold in any order
(`versionMergeIgnoresWhichCopyIsCurrent`, `versionsFoldInAnyOrder`). That
needs no base, which matters: a device that lost a write has recorded its own
write as its base. So the shared preferences carry a time per field, raised
past the field it replaced, and the later edit survives the join either way
(`aLaterEditSurvivesEitherWay`, `aSetFieldBeatsWhatItReplaced`).

## What the system model proves

The section "Devices interleaving whole passes" runs the decisions together:
two devices editing, pulling and publishing in any interleaving, against one
server whose writes are conditional on the revision a device read. Content is,
per item, a version in a total order, merged by taking the later — which is
what `mergeFile`, a record's time and a deletion ledger each provide.

- **Nothing the server holds is ever lost, under any interleaving**
  (`serverNeverLosesAlongRun`), starting from any state in which each device's
  last read is in it — which any library whose devices have not yet synced
  satisfies (`unsyncedDevicesAgree`, `agreesAlongRun`).
- **What an accepted publish put there stays** (`publishedContentIsNeverLost`),
  and **a refused publish changes nothing** (`refusedPublishChangesNothing`).
- **Retrying works:** reading and then publishing with nobody else publishing
  in between is always accepted (`pullThenPublishIsAccepted`), which is what
  `LampSyncPassRetry`'s one extra pass relies on.
- **Devices converge:** once editing stops, one quiet round — A reads and
  publishes, B reads and publishes, A reads — leaves both devices and the
  server holding everything any of them held (`aQuietRoundConverges`), from
  any prior state.
- **Why the condition matters:** on one schedule a conditional write keeps
  another device's edit (`conditionalPublishKeepsTheOtherEdit`), and an
  unconditional one — iCloud's situation — loses it
  (`unconditionalPublishLosesTheOtherEdit`).

Assumed: the server honours the condition and gives each accepted write a new
revision; steps are atomic; storage is durable. Device clocks decide which of
two edits to one item wins; skew changes the winner, never these results. Not
a join, and so outside this model: an equal-time disagreement over a record,
which each device keeps its own copy of until someone chooses, and a settings
merge with no baseline, which may bring back an unseen deletion once.

**Still outside the model.**

- 73 tables ask 83 of the model's 221 definitions directly, and reach 114
  counting the rules those call. Of the rest:
  - Counterexamples of former behaviour (`oldReplace`, `uploadBeforeRead`,
    `earlyBackendWipe` and the like) have no Swift counterpart by design.
  - The system model's own parts (`step`, `run`, `Agrees`) describe devices,
    not code.
  - Decisions made in the apps are held by the apps' own tests. These are
    iOS's import checks and pass traces (`iosFullPassTrace`,
    `sqliteImportAllowed`, `importSchemaAllows` and their kin) and the Mac's
    pull and settings recovery (`guardedMacPull`, `recoverMacSettings`). A
    table needs the decision moved into core first.
  - Core decisions still held only by Swift unit tests:
    - folder publishing's whole-tree preflight and per-file check
      (`folderPreflight`, `folderFileWrite`);
    - settings and preferences without a shared base (`chooseWithoutBase`,
      `choosePreference`, `explicitPreferenceValue`, `preservedSettings`,
      `mayAdoptLegacyBase`, `preferenceBasesAfterPublish`);
    - revising rich writing blocks (`reviseRichDevotionalBlock` and its kin,
      `devotionalStoredBody`);
    - portable media import (`mediaImportChoice`, `portableMediaMayCommit`,
      `mediaMetadataAfterBridge`) and whether to fetch referenced media
      (`shouldFetchReferencedMedia`);
    - the provider-switch marker (`pendingBackendMarker`,
      `newBackendAvailable`).

    For module reads (`pairedModuleImport`, `contentModuleImport`), pairing a
    body with its own revision is fixed by the function's signature, so there
    is nothing for a table to ask.

- iOS serialises settings syncs — one in flight, later requests wait. That is
  Swift concurrency, not a decision.
- iOS's settings first upload and its archive skip now call
  `uploadsBeforeMerge` and `mayAdvanceWithoutFetch`, which the conformance
  tables hold. When those call sites are reached is covered by iOS's own
  tests, not by Lean; `testAGuardedFirstUploadWritesFirstWhileTheServerIsUnchanged`,
  `testAGuardedFirstUploadMergesWhenTheServerHasMoved` and
  `testAGuardedFirstUploadMergesWhenNeitherRevisionIsKnown` drive the first
  upload end to end.
- Presentation assets carry no deletion ledger. An image is kept while any deck
  names it, by design.

## Implementation map

For every path that uses `LampSyncEngine`, `cancellableRunTrace` models its
phase-boundary cancellation checks alongside `runTrace`.

| Path | Shared implementation | Lean rules | Remaining verification boundary |
| --- | --- | --- | --- |
| iOS and macOS shared preferences | `LampSharedPreferenceLedger`, `LampSyncPreferenceState` for archive encoding and source-keyed saved bases | `choosePreference`, `preferenceMerge` (conformance), `disputedPreferenceKeepsTheServersValue`, `firstMeetingKeepsTheServersValue`, `failedPreferencePublishKeepsEveryBase`, `publishedPreferenceUpdatesItsSource`, `publishedPreferenceKeepsAnotherSource` | UserDefaults persistence and each app's local preference mapping |
| iOS WebDAV modules | `LampSyncEngine`, `LampSyncArchiveRemote`, `LampSyncMerge`, `LampSyncObservedWrite`, `LampSyncModuleFolder`, `LampSyncModuleFiles`, `LampSyncModuleRead`, `LampPortableModuleInspector`, `LampWebDAVStorage`, durable conflict and publication ledgers | `runTrace`, `failedEditablePullCannotStartForegroundPublication`, `failedArchivePullStopsAllModulePublication`, `failedModuleTypePullStopsBatchPublication`, `failedModulePullPreventsSettingsPublication`, `moduleFolderListing`, `duplicateSupersededPathChoosesActiveOccurrence`, `webDAVPresence`, `decide`, `mergeFile`, `observedModuleWrite`, `pendingModuleConflictBlocksExport`, `failedModuleWriteRetainsPublication`, `canonicalFileWinsOverInstalledLegacy`, `supersededCanonicalCannotHideActiveLegacy`, `missingRemoteRevisionRequiresImport`, `needsImportByToken` (conformance), `weakListingCannotSkipThroughTheAdapter`, `mayAdvanceWithoutFetch` (conformance), `indexTrusted` (conformance), `pairedModuleImport`, `replaceReadOnlyRows`, `sqliteImportAllowed`, `sqliteReplacementResult`, `missingLaterImportColumnCannotInstallPrefix`, `lateIOSArchiveSQLFailureKeepsInstalled` | Archive module changes share one local SQLite transaction; settings, preferences, media, and module uploads remain separate writes; filesystem and live server behavior |
| iOS local translation JSON | `LampSyncContentRevision` for the file revision; one GRDB transaction for metadata, books, verses, and headings | `translationSchemaAllowed`, `failedTranslationSchemaReplacementKeepsInstalled`, `foreignImportKeyCollisionKeepsInstalled` | JSON decoding and SQLite execution |
| iOS iCloud modules | `LampSyncEngine`, `LampSyncMerge`, `LampSyncModuleFiles`, `LampSyncModuleRead`, `LampSyncContentRevision`, durable conflict and publication ledgers | `runTrace`, `failedEditablePullCannotStartForegroundPublication`, `failedModuleTypePullStopsBatchPublication`, `failedModulePullPreventsSettingsPublication`, `decide`, `pendingModuleConflictBlocksExport`, `failedModuleWriteRetainsPublication`, `changedBodyInsideCoordinationIsRejected`, `contentModuleImport`, `laterRemoteUploadDoesNotChangeExportRevision`, `sqliteImportAllowed`, `sqliteReplacementResult` | Settings and module uploads are separate writes; a coordinated hash check cannot stop a later remote upload |
| iOS WebDAV media | `LampSyncReferencedMedia`, `LampSyncObservedWrite`, `LampSyncContentRevision`, `LampSyncConditionalWrite`, durable publication gate | `observedModuleWrite`, `unbasedContentWriteAllowed`, `conditionalWrite`, `unchangedModuleRetriesMissingMedia`, `failedMediaTransferBlocksCompletion`, `failedMediaUploadRetainsPublication`, `pendingLocalMediaUploadWaitsForPublish` | Server must honor strong ETag preconditions; media has no merge base |
| iOS iCloud media | `LampSyncReferencedMedia`, `LampSyncContentRevision`, guarded coordinated file write, durable publication gate | `unbasedContentWriteAllowed`, `coordinatedGenericFileWriteAllowed`, `unchangedModuleRetriesMissingMedia`, `failedMediaTransferBlocksCompletion`, `failedMediaUploadRetainsPublication`, `pendingLocalMediaUploadWaitsForPublish` | A later remote upload can supersede the locally checked write; media has no merge base |
| iOS WebDAV settings | `LampSyncEngine`, `LampSyncSettingsBootstrap`, `LampSyncSettingsArchive`, `LampSyncSettingsPlanner`, `LampSyncConditionalWrite`, `LampSyncCompatibilityPublisher` | `settingsBootstrap`, `uploadsBeforeMerge` (conformance), `baselessReading` (conformance), `reuseArchive` (conformance), `runTrace`, `mergeMembership`, `chooseWholeValue`, `resolveSettingsSource`, `classifyLegacySettings`, `maySkipArchivePoll`, `conditionalWrite` | SQLite serialization and the separate compatibility mirror |
| iOS iCloud settings | `LampSyncEngine`, `LampSyncSettingsBootstrap`, `LampSyncContentRevision`, `LampSyncStableRead`, `LampSyncSettingsPlanner` | `settingsBootstrap`, `uploadsBeforeMerge`, `baselessReading`, `contentRevision`, `stableRead`, `chooseWholeValue`, `runTrace`, `changedBodyInsideCoordinationIsRejected`, the post-read race counterexample | No server-side precondition against a later remote upload |
| macOS WebDAV library | `LampSyncEngine`, `LampSyncArchiveRemote`, `LampSyncArchiveIndex`, `LampSyncCompatibilityPublisher`, `LampSyncConditionalWrite`, `LampSyncPassRetry`, `LampSyncPersonalExport`, `LampSyncModuleFolder`, `LampSyncModuleFiles`, `LampSharedPreferenceLedger`, shared record conflict decision | `runTrace`, `shouldRunAgain` and `lostRace` (conformance), `aSyncRunsAtMostTwoPasses`, `publishReportingRefusals`, `landing` (conformance), `landingIsSound`, `settleByBytes`, `confirmWrite`, `portableImportOutcome` (conformance), `preferenceMerge`, `moduleFolderListing`, `duplicateSupersededPathChoosesActiveOccurrence`, `decide`, `macArchivePublish`, `mirrorAttempts`, `choosePreference`, `aggregateJSONKeepsUnshadowedModule`, `supersededCanonicalCannotHideActiveLegacy`, `failedMacHighlightExportStopsArchivePublish` | Local library export and separate compatibility writes |
| Cross-platform devotional media | `LampDevotionalMediaReference`, `LampPortableDevotionalMedia`, `LampPortableDevotionalContent`, `LampSyncReferencedMedia`, `LampSyncDevotionalMedia`, staged `LampLibrary.importPortableBackup`, iOS archive import | `hiddenMediaAttachmentSurvivesPortableRoundTrip`, `richDevotionalBlocksKeepTheirContent`, `unchangedRichDevotionalBlockIsExact`, `editedRichDevotionalBlockKeepsOpaqueFields`, `movedRichSectionKeepsIdentity`, `movedRichSectionKeepsOpaqueFields`, `changedRichOutlineKeepsRootFields`, `iosRichEditStoresRevisedBlocks`, `iosPlainEditKeepsAuthoredMarkdown`, `bracketedMarkdownWithoutBlockSchemaKeepsMarkdown`, `existingMediaMetadataIsPreserved`, `missingPortableAttachmentStopsCommit`, `missingPortableMediaForcesArchiveRead`, `macImportEnrichesMissingMetadata`, `macMetadataEditKeepsStructuredBlocks`, `failedDevotionalMediaStopsModuleMirror`, `identicalDevotionalMediaNeedsNoWrite`, `conflictingDevotionalMediaCannotPublish`, `missingIOSMediaStopsMacPull` | Old archives without a compatible devotional module still leave personal JSON outside iOS import; deleted sections are removed; local media files and SQLite rows are separate writes |
| macOS folder library | `LampSyncEngine`, `LampSyncFolderPublisher`, `LampPortableModuleInspector`, staged local library import and settings recovery, shared record and file ordering | `runTrace`, `folderPreflight`, `folderFileWrite`, `folderSealAccepts`, `folderRecoveryStep`, `mergeFile`, `ownedSQLiteRows`, `stagedBackupImport`, `guardedStagedBackupCommit`, `commitMacPull`, `recoverMacSettings` | Cross-device and multi-file atomicity, OS durability of library and UserDefaults writes, repair when the stage is missing or another writer changed a file |
| iOS backend switching | `LampSyncBackendTransition`, `LampSyncMigrationCopy`, local recovery record | `deferredBackendWipe`, `backendActivationOccurs`, `pendingBackendMarker`, `migrationCopyAction` | Two local databases remain separate; sync is suspended until a failed rollback can be recovered; iCloud remote uploads can race the local create check |
| Per-file library and settings bundle (design B) | `LampSyncFolderLayout`, `LampSyncLibraryManifest`, `LampSyncFilePlan`, `LampSyncSettingsBundle`, `LampSyncSettingsStore`, conditional `delete(path:condition:)` | `mergeManifestEntry`, `recordWrite`, `adoptFile`, `pruneTombstone`, `filePlanAction`, `listedRevision`, `settingsUpdate` and `bundlePathHolds` (conformance), `deletingNeedsATombstone`, `anUnknownFileIsAdopted`, `noRecordNeverOverwrites`, `aRecordedMemberIsNeverRead`, `tombstoneLifetimeCost` | Revisions are compared within one provider; a value-equal import must not mark content changed, which each app's importer keeps; executing the plan and the folder provider's store are the apps' and batch 2's |
| Personal deletions (notes, writing, highlights, themes, sets) | `LampPersonalDeletionLedger`, `LampLibrary` ledger merge and apply | `tombstoneDeletes` and `mergeTombstone` (conformance), `mergeTombstone_comm`, `mergeTombstone_assoc`, `mergeTombstone_idem`, `exchangedLedgersAgree`, `editAfterDeletionSurvives`, `equalTimeFavoursDeletion` | Device clocks are assumed comparable; the SQL upsert is the Swift `merged(with:)` rule |
| Slide decks | `LampPresentationDeckDeletionLedger`, `LampPresentationDeckPortablePull`, macOS `PresentationDeckSyncSupport` | `tombstoneDeletes` (conformance), `deckPull`, `deckPullNeverKeepsADeletedDeck`, `deckPullIgnoresArrivalOrder` | Assets have no ledger and are kept while any deck names them |
| Workspace files (macOS) | `WorkspaceSyncLedger` in `SyncSupport.swift`, shared file order | `tombstoneDeletes`, `workspaceDeletionTime`, `documentDeletionSparesALaterEdit`, `mergeFile` | Context files' deletions use the time they were noticed, not a comparable modification time |
| Conflicts set aside and resolved | `LampSyncMerge.importOutcome`, `LampSyncConflict`, `LampLibrary.resolveSyncConflict` | `portableImportOutcome` (conformance), `syncImportNeverStops`, `resolvedChoiceWinsWhereItWasMade`, `resolvedChoiceWinsOnTheOtherDevice`, `sameColumn` | Choosing in the UI and the stored payload are Swift; JSON classification is JSONSerialization's |
| Two devices running whole passes (system model) | `LampSyncEngine`, `LampSyncConditionalWrite`, `LampSyncPassRetry`, and the per-item orders of `LampSyncMerge` and the deletion ledgers | `serverNeverLosesAlongRun`, `agreesAlongRun`, `publishedContentIsNeverLost`, `refusedPublishChangesNothing`, `pullThenPublishIsAccepted`, `aQuietRoundConverges`, `conditionalPublishKeepsTheOtherEdit`, `unconditionalPublishLosesTheOtherEdit` | The server honours conditions and issues new revisions; steps are atomic; storage is durable; equal-time record disagreements and baseless settings merges are not joins |

The listed Lean rules prove properties of models that correspond to shared
Swift decisions. Swift tests exercise each shared implementation with the
same edge cases. This is not a machine-checked proof of the Swift runtime,
database engines, filesystem, or network provider.
