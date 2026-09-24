# Sync verification

Run the proof checker from this repository:

```sh
elan run leanprover/lean4:v4.34.0 lean Verification/SyncMerge.lean
```

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

The proof does not establish that a full sync is lossless.
`uploadFirstLosesRemoteOnlyEdit` demonstrates why a whole-file upload before
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
`staleSnapshotCannotUpload` models that check, and `chooseWithoutBase`
models its timestamp choice for settings. If reading rows still differ without
a baseline, `differentReadingsWithoutBaseReject` shows the plan stops rather
than guessing whether a row was added or deleted. WebDAV sends an atomic HTTP precondition on
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
The shared preference ledger's per-field choice is modeled in Lean and tested
in Swift. Mac staging reads only explicitly stored settings from the app's
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
is also missing. `missingRemoteRevisionRequiresImport` and
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
Mac's portable note and devotional import now propagates the shared
equal-time conflict decision as an import error, which stops archive or folder
publication. It compares note payloads and devotional content before treating
an equal-time import as an unchanged duplicate. The Lean `decide` rule models
the conflict decision; Swift tests cover the payload comparison and stop.
`LampSyncSettingsBootstrap` now selects the five iOS settings entry cases in
core. The ordinary merge uses `LampSyncEngine` for pull, publish, and
completion. The `settingsBootstrap` theorems prove that a required missing
remote cannot be created, fresh adoption precedes local upload, and a dirty
no-base state uses the guarded path. Provider writes, SQLite import, and
compatibility mirror recovery remain Swift and provider boundaries.

## Implementation map

For every path that uses `LampSyncEngine`, `cancellableRunTrace` models its
phase-boundary cancellation checks alongside `runTrace`.

| Path | Shared implementation | Lean rules | Remaining verification boundary |
| --- | --- | --- | --- |
| iOS and macOS shared preferences | `LampSharedPreferenceLedger`, `LampSyncPreferenceState` for archive encoding and source-keyed saved bases | `choosePreference`, `failedPreferencePublishKeepsEveryBase`, `publishedPreferenceUpdatesItsSource`, `publishedPreferenceKeepsAnotherSource` | UserDefaults persistence and each app's local preference mapping |
| iOS WebDAV modules | `LampSyncEngine`, `LampSyncArchiveRemote`, `LampSyncMerge`, `LampSyncObservedWrite`, `LampSyncModuleFolder`, `LampSyncModuleFiles`, `LampSyncModuleRead`, `LampPortableModuleInspector`, `LampWebDAVStorage`, durable conflict and publication ledgers | `runTrace`, `failedEditablePullCannotStartForegroundPublication`, `failedArchivePullStopsAllModulePublication`, `failedModuleTypePullStopsBatchPublication`, `failedModulePullPreventsSettingsPublication`, `moduleFolderListing`, `duplicateSupersededPathChoosesActiveOccurrence`, `webDAVPresence`, `decide`, `mergeFile`, `observedModuleWrite`, `pendingModuleConflictBlocksExport`, `failedModuleWriteRetainsPublication`, `canonicalFileWinsOverInstalledLegacy`, `supersededCanonicalCannotHideActiveLegacy`, `missingRemoteRevisionRequiresImport`, `pairedModuleImport`, `replaceReadOnlyRows`, `sqliteImportAllowed`, `sqliteReplacementResult`, `missingLaterImportColumnCannotInstallPrefix`, `lateIOSArchiveSQLFailureKeepsInstalled` | Archive module changes share one local SQLite transaction; settings, preferences, media, and module uploads remain separate writes; filesystem and live server behavior |
| iOS local translation JSON | `LampSyncContentRevision` for the file revision; one GRDB transaction for metadata, books, verses, and headings | `translationSchemaAllowed`, `failedTranslationSchemaReplacementKeepsInstalled`, `foreignImportKeyCollisionKeepsInstalled` | JSON decoding and SQLite execution |
| iOS iCloud modules | `LampSyncEngine`, `LampSyncMerge`, `LampSyncModuleFiles`, `LampSyncModuleRead`, `LampSyncContentRevision`, durable conflict and publication ledgers | `runTrace`, `failedEditablePullCannotStartForegroundPublication`, `failedModuleTypePullStopsBatchPublication`, `failedModulePullPreventsSettingsPublication`, `decide`, `pendingModuleConflictBlocksExport`, `failedModuleWriteRetainsPublication`, `changedBodyInsideCoordinationIsRejected`, `contentModuleImport`, `laterRemoteUploadDoesNotChangeExportRevision`, `sqliteImportAllowed`, `sqliteReplacementResult` | Settings and module uploads are separate writes; a coordinated hash check cannot stop a later remote upload |
| iOS WebDAV media | `LampSyncReferencedMedia`, `LampSyncObservedWrite`, `LampSyncContentRevision`, `LampSyncConditionalWrite`, durable publication gate | `observedModuleWrite`, `unbasedContentWriteAllowed`, `conditionalWrite`, `unchangedModuleRetriesMissingMedia`, `failedMediaTransferBlocksCompletion`, `failedMediaUploadRetainsPublication`, `pendingLocalMediaUploadWaitsForPublish` | Server must honor strong ETag preconditions; media has no merge base |
| iOS iCloud media | `LampSyncReferencedMedia`, `LampSyncContentRevision`, guarded coordinated file write, durable publication gate | `unbasedContentWriteAllowed`, `coordinatedGenericFileWriteAllowed`, `unchangedModuleRetriesMissingMedia`, `failedMediaTransferBlocksCompletion`, `failedMediaUploadRetainsPublication`, `pendingLocalMediaUploadWaitsForPublish` | A later remote upload can supersede the locally checked write; media has no merge base |
| iOS WebDAV settings | `LampSyncEngine`, `LampSyncSettingsBootstrap`, `LampSyncSettingsArchive`, `LampSyncSettingsPlanner`, `LampSyncConditionalWrite`, `LampSyncCompatibilityPublisher` | `settingsBootstrap`, `runTrace`, `mergeMembership`, `chooseWholeValue`, `resolveSettingsSource`, `classifyLegacySettings`, `maySkipArchivePoll`, `conditionalWrite` | SQLite serialization and the separate compatibility mirror |
| iOS iCloud settings | `LampSyncEngine`, `LampSyncSettingsBootstrap`, `LampSyncContentRevision`, `LampSyncStableRead`, `LampSyncSettingsPlanner` | `settingsBootstrap`, `contentRevision`, `stableRead`, `chooseWholeValue`, `runTrace`, `changedBodyInsideCoordinationIsRejected`, the post-read race counterexample | No server-side precondition against a later remote upload |
| macOS WebDAV library | `LampSyncEngine`, `LampSyncArchiveRemote`, `LampSyncCompatibilityPublisher`, `LampSyncPersonalExport`, `LampSyncModuleFolder`, `LampSyncModuleFiles`, `LampSharedPreferenceLedger`, shared record conflict decision | `runTrace`, `moduleFolderListing`, `duplicateSupersededPathChoosesActiveOccurrence`, `decide`, `macArchivePublish`, `mirrorAttempts`, `choosePreference`, `aggregateJSONKeepsUnshadowedModule`, `supersededCanonicalCannotHideActiveLegacy`, `failedMacHighlightExportStopsArchivePublish` | Local library export and separate compatibility writes |
| Cross-platform devotional media | `LampDevotionalMediaReference`, `LampPortableDevotionalMedia`, `LampPortableDevotionalContent`, `LampSyncReferencedMedia`, `LampSyncDevotionalMedia`, staged `LampLibrary.importPortableBackup`, iOS archive import | `hiddenMediaAttachmentSurvivesPortableRoundTrip`, `richDevotionalBlocksKeepTheirContent`, `unchangedRichDevotionalBlockIsExact`, `editedRichDevotionalBlockKeepsOpaqueFields`, `movedRichSectionKeepsIdentity`, `movedRichSectionKeepsOpaqueFields`, `changedRichOutlineKeepsRootFields`, `iosRichEditStoresRevisedBlocks`, `iosPlainEditKeepsAuthoredMarkdown`, `bracketedMarkdownWithoutBlockSchemaKeepsMarkdown`, `existingMediaMetadataIsPreserved`, `missingPortableAttachmentStopsCommit`, `missingPortableMediaForcesArchiveRead`, `macImportEnrichesMissingMetadata`, `macMetadataEditKeepsStructuredBlocks`, `failedDevotionalMediaStopsModuleMirror`, `identicalDevotionalMediaNeedsNoWrite`, `conflictingDevotionalMediaCannotPublish`, `missingIOSMediaStopsMacPull` | Old archives without a compatible devotional module still leave personal JSON outside iOS import; deleted sections are removed; local media files and SQLite rows are separate writes |
| macOS folder library | `LampSyncEngine`, `LampSyncFolderPublisher`, `LampPortableModuleInspector`, staged local library import and settings recovery, shared record and file ordering | `runTrace`, `folderPreflight`, `folderFileWrite`, `folderSealAccepts`, `folderRecoveryStep`, `mergeFile`, `ownedSQLiteRows`, `stagedBackupImport`, `guardedStagedBackupCommit`, `commitMacPull`, `recoverMacSettings` | Cross-device and multi-file atomicity, OS durability of library and UserDefaults writes, repair when the stage is missing or another writer changed a file |
| iOS backend switching | `LampSyncBackendTransition`, `LampSyncMigrationCopy`, local recovery record | `deferredBackendWipe`, `backendActivationOccurs`, `pendingBackendMarker`, `migrationCopyAction` | Two local databases remain separate; sync is suspended until a failed rollback can be recovered; iCloud remote uploads can race the local create check |

The listed Lean rules prove properties of models that correspond to shared
Swift decisions. Swift tests exercise each shared implementation with the
same edge cases. This is not a machine-checked proof of the Swift runtime,
database engines, filesystem, or network provider.
