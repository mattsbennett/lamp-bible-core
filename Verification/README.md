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
`CONFORMANCE`) and the system checks (`SYSTEMCHECK`). Anything else — an error, or a warning such as a `sorry` —
fails the suite. On a machine without elan, `LAMP_SKIP_LEAN=1 swift test`
skips the Lean-backed tests by name rather than letting them pass.

## Keeping the model and the code together

Four checks run with the core suite, so the model cannot quietly fall behind
the code it describes:

- **The proofs check.** `theModelChecks` runs Lean on the model and fails on
  any error or warning.
- **The model and Swift answer alike.** The model's last section prints a table
  for each decision that has a Swift counterpart: its inputs and the model's
  answer, 4,146 cases across 54 decisions. `SyncModelConformanceTests` asks the
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
- **Every definition is held to something.** `everyDefinitionIsHeldToSomething`
  fails on a definition in the model that nothing reaches: not a coverage
  entry's rules, a conformance table, a system model, or a counterexample, nor
  anything those use. Code that is removed takes its entry with it, and its
  rules then fail here until they leave the model too. The system models and
  the counterexamples are listed in `coverage.json` under `modelOnly`, each
  with the reason it is there.

`filePassesHold` reads the system checks: each must have made runs, and none
may have failed.

When you change a sync decision, change the model in the same commit, update
its conformance table if it has one, and give any new sync source a
`coverage.json` entry. A decision that lives only in an app cannot be held to
the model from here. Move its pure decision into core, as the deletion rules
(`LampSyncBundleLedgers`) and the pass engine (`LampSyncBundlePass`) were.

## Model notes by area

### The per-file library and settings bundle

Each module is its own file, and a manifest in the settings bundle says which
belong to the library. Per path it keeps two stamps, the latest write and the
latest deletion, each a time and the revision it concerned. Stamps order by
time and then by revision, and the manifest merges by keeping the later of
each, a join (`laterStamp_comm`, `_assoc`, `_idem`; `mergeManifestEntry_comm`,
`_assoc`, `_idem`), so devices agree on membership whatever order they merge
in (`membershipIgnoresMergeOrder`). Equal times are a deletion
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
(`settingsUpdateIsBounded`).

The bundle is format 3. Readers that accept only formats 1 and 2 refuse it
(`oldReadersRefuseTheBundle`), and anything else at the bundle path is never
read as a bundle (`anArchiveIsNeverReadAsTheBundle`), judged from the unpacked
header alone.

### Claiming a library, and moving an earlier one

Nothing at the bundle path is a new library only when no earlier library's
marker or module file is there either (`onlyAnEmptyLibraryIsNew`). So a new
library's first pass claims the path with an empty bundle before writing any
file. Writing files first, its own files would make the closing update call
the library an earlier one, and it could never finish
(`uploadingFirstLocksAFreshLibraryOut`, `claimingFirstNeverMeetsItsOwnFiles`).
An ordinary pass claims only a new library
(`anOrdinaryPassClaimsOnlyANewLibrary`).

An earlier library is the Mac's if its marks are there, and otherwise the
phone's, whose files are already in the per-file layout (`earlierLibrary`).
The phone's move may claim the phone's library, and nothing claims the Mac's
(`thePhoneNeverClaimsAMacLibrary`). On WebDAV the phone's library has a
settings-only file at the bundle path: one holding nothing but settings is the
phone's, and a module or the Mac's own settings make it the Mac's
(`archiveKeeper`, `anArchiveWithAModuleIsTheMacs`,
`theMacsSettingsMarkItsArchive`). Any entry the phone never writes settles it,
however few entries were read (`anEntryThePhoneNeverWritesSettlesIt`). So a
library-sized file is judged from the paths its first 256 KB reach, found
wherever they stand, since the encoder fixes no order for an entry's fields.

The Mac moves a library it kept by writing the first bundle, carrying only
what lives nowhere else under the per-file layout: every setting and ledger
is carried (`everySettingAndLedgerIsCarried`), only the old layout's
bookkeeping and the copy a retired alias left are dropped
(`onlyBookkeepingIsDropped`), and anything it cannot place stops it. The Mac
publishes the content from its library on its next pass. The move writes over
the old file only at the revision it imported
(`theMigrationWritesOnlyOverTheArchiveItImported`), moves only a library the
Mac kept (`theMigrationMovesOnlyTheMacsLibrary`), and run again writes nothing
(`aMigratedLibraryIsLeftAlone`).

### The pass engine

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

### When nothing has changed

A pass over a file nobody has touched since the last does nothing: a member
held unchanged at the revision listed, or a deletion every device has carried
out (`aSettledFileNeedsNothing`, `aSettledDeletionNeedsNothing`). The engine
records a client's own digest of a copy it takes, not the downloaded bytes', so
two devices that encode alike content differently settle rather than trade
it for ever (`recordingTheDownloadedBytesNeverSettles`).

### Save times

A tombstone is settled against a copy by the copy's last save: saved after
the deletion, the copy survives and goes back up; otherwise it goes
(`aSaveAfterTheDeletionSurvives`). A copy with no save time always goes,
since nothing says the edit came after (`anUnreportedSaveLosesToADeletion`).
So each client must report a save time for every copy that holds a person's
own writing — notes, writing, highlights and decks — and each app's coverage
entry for its gather says which kinds it reports. Modules and media may go
without, since the server can always supply them again.

### Deleting a copy here

`LampSyncLocalDeletion.target` decides what deleting a path removes, and both
sides call it: whether a removal here may be recorded as a deletion, and
whether one recorded elsewhere is carried out, so no client records a
tombstone another refuses (`mayRecordRemoval`,
`everyRecordedRemovalIsCarriedOut`). `Notes/notes.lamp` and
`Devotionals/devotionals.lamp` are each one file holding every note or every
writing, so they are never deleted as files; their items are deleted through
the ledger (`aCollectionIsNeverDeletedWhole`). Any other notes or writing
module is a module, and so is a highlight set: deleting a set on one device
deletes it on the others. A module removal names the ID its path carries
(`aModuleRemovalNamesItsPathsID`).

The plan agrees with it. A path no library deletes is never tombstoned,
asked to be deleted here, or reaped (`thePlanNeverAsksForARefusedDeletion`).
Under a tombstone some older client recorded, it is planned as a member: a
device holding none takes the server's copy, one the server has lost is sent
back (`aRefusedTombstoneHidesNothing`), changes go up or are merged as their
revisions say, and the next write supersedes the tombstone
(`aRefusedDeletionGoesBackUp`).

**A tombstone from a fast clock.** A tombstone carries its deleting device's
time. A write that survives one — saved after it, or on a path no library
deletes — is recorded after it, whatever this device's clock says, so it
supersedes the tombstone; recorded at the pass's own time, a write under a
tombstone dated ahead would leave it in place, and a surviving copy would go
up again on every pass until the clocks met
(`aWriteSupersedesATombstoneFromAFastClock`).

### Writes and revisions

WebDAV sends an atomic HTTP precondition on each conditional write;
`staleConditionalWriteRejected`, `createOnlyWriteCannotOverwrite` and
`observedRemoteDeletionCannotRecreate` model the server-side revision rule. The
shared adapter, `LampWebDAVStorage`, validates one complete strong entity-tag
before using it as an `If-Match` condition. RFC 9110 allows a comma inside the
quoted tag but not an embedded quote that could turn the header into a list
(`combinedETagsCannotAuthorizeWrite`, `commaInsideStrongETagIsValid`,
`weakETagCannotAuthorizeWrite`). The existence check treats only HTTP 404 as
missing, falls back to GET for a server that rejects HEAD with 405, and
propagates other errors (`forbiddenWebDAVHeadIsNotAbsence`,
`unsupportedHeadFallsBackToGET`). `LampSyncRemoteDirectories` prepares parent
paths in root-to-leaf order. After a 409 from MKCOL, the adapter takes any
successful PROPFIND of a collection as proof that it exists, since some servers
answer 200, and treats a failed PROPFIND as an error (`collectionConfirmed`,
`plainSuccessListingAlsoConfirmsTheCollection`); a path that is not a
collection keeps the conflict (`nonCollectionCannotSatisfyMKCOLConflict`).

**Did a refused write land?** `landing` claims "not written" only while the
server still satisfies the write's condition, and "written" only for a write
that asserted nothing (`landingIsSound`). Everything else is undecidable, and
is settled by comparing bytes (`settleByBytes`). `writeAndConfirm` names a
revision only from a read returning this write's bytes, asking twice
(`settlingServerConfirmsOnTheSecondRead`, `anotherDevicesBytesNeverConfirm`,
`aThirdReadIsNeverMade`). The read-back is streamed to disk and compared by
SHA-256 digest, so a library-sized body is never held twice; equal digests
standing for equal bytes is the assumption `contentRevision` already makes.
This compares this client's own upload with the server's copy of it. Imports
compare values, never bytes, since two clients encode one value differently.

**A write the server took but has not shown back.** A server can take a write
and still answer the next reads with what it held before, as the user's
Synology does after a PUT that names no revision. `writeOutcome` keeps "taken
but not yet shown back" apart from "refused": a write the server took is never
a refusal (`anAcceptedWriteIsNeverRefused`), and only a read-back of the bytes
sent names its revision (`aWriteIsNamedOnlyByItsOwnBytes`). So the bundle's
update, the claim and the move wait for the server instead of retrying into a
refusal of their own write.

`namesSameRevision` treats quoted, bare and weak spellings of one tag as one
revision, and absent and present as different
(`spellingsOfOneTagNameOneRevision`, `namesSameRevision_symm`). Content
revisions share `LampSyncContentRevision.digest`; SHA-256 collision resistance
is assumed rather than proved.

### The folder provider

On the folder provider, `directoryWrite` and `directoryDelete` decide a
conditional write or delete inside the coordinated block, and a write goes
ahead exactly when the coordinated check allowed it
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

iCloud offers no server-side precondition, so a later device upload can
supersede a locally checked write (`stableICloudReadDoesNotProtectLaterWrite`).
Every iCloud write goes through `LampSyncDirectoryStore`'s coordinated check;
the phone's reads stop on a conflict the OS reports
(`reportedICloudVersionConflictStopsRead`).

### Records, conflicts and deletions

`LampSyncMerge` holds the record decision and the fixed millisecond file
order. Newer record revisions win, equal revisions with different content
report a conflict, and file merge is commutative, idempotent and associative.
Portable note and writing import compares payloads before treating an
equal-time import as an unchanged duplicate, with JSON columns compared by
meaning (`sameColumn`, an equivalence; text that is not JSON never matches JSON
or an absence: `sameColumn_trans`, `textIsNeverTheSameAsJSONOrNothing`). A
disagreement that remains is set aside on a sync run: this device's copy stays,
the other is stashed for the person to choose, and the import carries on
(`portableImportOutcome`, `syncImportNeverStops`). An import someone asked for
still stops with an error (`requestedImportStopsOnDisagreement`). Choosing a
version later stamps it past both copies, so the device that chose prefers it,
and so does the other (`resolvedChoiceWinsWhereItWasMade`,
`resolvedChoiceWinsOnTheOtherDevice`). Neither raises the same disagreement
again.

The phone keeps unresolved note and writing conflicts in its module database
across restarts. A module with an unsettled conflict is held back by the pass,
neither published nor fetched as missing (`pendingModuleConflictBlocksExport`,
`changedModuleRevisionBlocksResolvedExport`). Its publication marker is
cleared only once the records show the module's export uploaded; a failed or
unconfirmed write leaves it marked (`locallyKeptRowRequiresPublication`,
`failedModuleWriteRetainsPublication`, `successfulModuleWriteClearsPublication`).

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
arrive in (`deckPullIgnoresArrivalOrder`). The ledgers travel in the settings
bundle and are joined, never replaced (`LampSyncBundleLedgers`).

### Shared preferences

The shared preference ledger's per-field choice is modelled
(`choosePreference`) and tested in Swift. A field both devices changed
differently is set aside rather than stopping the sync: the server keeps its
value, so the other device's edit survives; this device keeps what its user
set; and the baseline keeps what the two last agreed, so the dispute shows
again until they hold one value (`preferenceMerge`,
`disputedPreferenceKeepsTheServersValue`, `disputePersistsWhileTheValuesDiffer`).
A client with no baseline meets the server: the server's value stands, and a
value only this client holds is contributed (`firstMeetingKeepsTheServersValue`,
`firstMeetingContributesALocalOnlyValue`). The Mac reads only explicitly stored
settings from the app's persistent domain, so registered UI defaults do not
become local edits (`registeredDefaultWithoutStoredPreferenceIsNotAnEdit`).
Both apps use `LampSyncPreferenceState` to validate, encode and keep a base per
sync source (`failedPreferencePublishKeepsEveryBase`,
`publishedPreferenceUpdatesItsSource`, `publishedPreferenceKeepsAnotherSource`).

The phone merges its settings database with `LampSyncSettingsPlanner`, against
a locally stored baseline. `mergeMembership` proves the per-ID add and delete
rule for completed readings; `chooseWholeValue` proves that different
concurrent edits to a settings row are a conflict. A reading both sides kept
takes the later completion time, and tied times with different row data are a
conflict (`chooseReading`). `chooseWithoutBase` models the timestamp choice
for settings with no baseline, which still refuses an equal-time disagreement.
Reading rows without a baseline are merged rather than refused: every row
either side holds is kept, and a row both hold takes the newer copy, the
remote's on a tie (`baselessReading`, `baselessMergeKeepsEveryRow`). A row only
one side holds may be an addition here or a deletion there, so a deletion this
device never saw comes back once (`baselessMergeRevivesAnUnseenDeletion`);
from the next merge on there is a baseline. The uploaded database omits
device-local provider configuration.

The Mac writes the settings a pass brings down through a journal kept with the
library: staged, applied to UserDefaults, cleared, and replayed at startup and
before each sync after a crash. Staging refuses when the live settings moved
after the plan was made, so a preference changed during a pass is never
reverted by a plan made before it (`aSettingChangedDuringThePassIsNeverReverted`).
A distinct settings edit after staging blocks the replay and leaves the
journal for repair (`pendingMacSettingsReplayCompletesPull`,
`distinctMacSettingsEditBlocksReplay`);
when a crash leaves some keys written and others not, the check is per key
(`mixedMacSettingsReplayToWholePlan`, `unrelatedMacSettingBlocksWholeReplay`).
The runtime guarantee depends on the property-list write, the UserDefaults
flush and the journal's removal surviving interruption in that order.

### Module files and import

When a JSON module and its .lamp successor coexist, `LampSyncModuleFiles`
selects one current representation, preferring .lamp even if JSON was
installed. Superseded files are removed before ranking, so a stale .lamp cannot
hide a later JSON edit (`supersededCanonicalCannotHideActiveLegacy`).
`preferredCandidateIndices` picks one active occurrence per identity and keeps
its payload paired with the chosen listing
(`duplicateSupersededPathChoosesActiveOccurrence`). `LampSyncModuleFolder.list`
keeps a missing folder apart from a failed listing and filters to supported
files (`moduleFolderListing`). Matching hashes on different filenames cannot
skip an import (`changedModulePathRequiresImport`). `needsImport` downloads
whenever the remote revision is missing, even if the stored one is missing
too (`missingRemoteRevisionRequiresImport`). Revisions compare as tokens, so a
quoted listing tag matches the bare revision recorded after this device's own
upload (`quotedListingOfOwnUploadMaySkip`); a weak tag cannot skip an import,
because the WebDAV adapters pass on only strong revisions
(`weakListingCannotSkipThroughTheAdapter`, `needsImportByToken`), and iCloud
passes a content digest.

The phone reads a module's body and its revision together: WebDAV returns
bytes and strong ETag from one GET, and iCloud derives a digest from its
coordinated read. The listing revision only decides whether to fetch
(`changedModuleBetweenListAndGetUsesGetRevision`,
`iCloudModuleRevisionDescribesReadBody`).

`LampPortableModuleInspector.inspectRemote` checks a downloaded body and its
kind before local replacement. Canonical .lamp files need an embedded identity,
except older compact highlight files whose `highlight_meta.id` names the set
rather than the module; older .db and .db.zlib files without one use their
filenames (`canonicalModuleRequiresEmbeddedIdentity`,
`legacyModuleWithoutIdentityCanUseFilename`,
`damagedOrMismatchedSQLiteCannotReplace`,
`legacyCompactHighlightMayUseListedID`,
`unrelatedSchemaCannotUseLegacyFallback`,
`wrongKindOrDamagedRemoteCannotFallBack`). The two highlight IDs stay separate
(`compactHighlightSetIDCannotSupplyModuleID`, `canonicalHighlightUsesHeaderID`).
The inspector also checks every present owner column against the module ID,
so a matching header over foreign rows is refused
(`foreignSQLiteOwnerKeepsInstalled`, `foreignPersonalStudyRowCannotMerge`).

The phone replaces a read-only SQLite module by retiring old rows and copying
new ones inside one write transaction, with its registry metadata; a failed
copy or metadata save keeps what was installed
(`failedSQLiteCopyKeepsInstalledRows`, `failedMetadataSaveKeepsInstalledRows`).
Copied child rows use plain `INSERT`, so a key belonging to another module
fails and rolls back (`foreignImportKeyCollisionKeepsInstalled`). Editable note
and writing reconciliation reads, merges and saves rows, conflicts and
publication markers in one transaction
(`failedEditableMergePreservesWholeState`). The phone imports SQLite modules
only. The importer for a translation the person opens themselves
checks the schema type and ID first and replaces in one transaction
(`wrongTranslationSchemaTypeCannotImport`,
`invalidTranslationSchemaIDCannotImport`,
`failedTranslationSchemaReplacementKeepsInstalled`). All of this relies on
SQLite's transactions.

### Writing content and media

`LampPortableDevotionalContent` projects the phone's rich blocks — headings,
annotated text, lists, media, tables and section trees — for the Mac's reader
and editor, and converts an edit back. Identical blocks keep their full source
JSON, including blocks an older renderer cannot display; outline edits keep the
root and matched section metadata, IDs included, when sections move or change
depth (`richDevotionalBlocksKeepTheirContent`,
`unchangedRichDevotionalBlockIsExact`,
`editedRichDevotionalBlockKeepsOpaqueFields`,
`editedRichDevotionalBlockUsesNewBody`, `movedRichSectionKeepsIdentity`,
`movedRichSectionKeepsOpaqueFields`, `changedRichOutlineKeepsRootFields`). The
phone keeps authored Markdown for plain drafts and stores revised blocks for
rich sources, and tells rich JSON by its block schema, so a Markdown body
beginning with `[` or `{` still loads as Markdown
(`iosRichEditStoresRevisedBlocks`, `iosPlainEditKeepsAuthoredMarkdown`,
`bracketedMarkdownWithoutBlockSchemaKeepsMarkdown`). Media metadata is kept and
enriched, never dropped (`existingMediaMetadataIsPreserved`,
`macImportEnrichesMissingMetadata`, `macMetadataEditKeepsStructuredBlocks`).

`LampSyncReferencedMedia` transfers the files a module names and reports the
first failure after trying the rest; a batch completes only if every file did
(`mediaBatchComplete`, `failedMediaTransferBlocksCompletion`). In the pass, a
media file is a library member like any other: one with no local copy is
downloaded, and an upload is decided by digest against the records. The Mac's
highlight export skips only the one expected empty set, and the pass carries
on; any other failure reaches the pass, so the set is never recorded as
published (`emptyMacHighlightSetMayBeSkipped`,
`failedMacHighlightExportStopsPublish`).

### Switching provider on the phone

`LampSyncBackendTransition` runs a switch through `LampSyncEngine`. It
persists the new provider only after publishing to it, wipes local modules only
after that persistence succeeds, and activates the new provider after the
wipe; a failed wipe tries to restore the previous provider
(`failedBackendPublishCannotWipe`, `failedBackendPersistenceCannotWipe`,
`failedWipeRequestsBackendRollback`). The phone writes the previous provider to
its module database before changing the provider database, and the wipe removes
that record in the same SQLite transaction; a record left behind restores the
previous choice on launch or the next sync, and sync stays off if that fails
(`committedBackendWipeClearsMarker`, `failedBackendWipeRetainsMarker`,
`pendingMarkerSuspendsNewBackend`). The two databases are not one transaction,
so this relies on SQLite's transactional writes. `LampSyncEngine.run` checks
cancellation before each phase: cancelled after its pull it publishes nothing,
and cancelled after publishing it records no completion
(`cancellableRunTrace`).

`LampSyncOnce` coalesces concurrent first-sync calls and closes only after a
success, so a failed attempt can retry (`failedInitialSyncCanRetry`,
`successfulInitialSyncClosesGate`); a cancelled caller stops at the gate even if
another caller finishes the attempt (`cancelledInitialSyncWaiterCannotContinue`).

## What the system models prove

### Whole content

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
  the bundle's update relies on when it reads again after a refused write.
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

### The per-file pass

The section "Devices running the per-file pass" runs the plan and the bundle
update across two devices over one path — the plan and the manifest both
decide path by path, so paths do not interact. A pass reads, then acts:
downloads and merges, uploads conditioned on the revision it planned against,
deletes locally, makes one bundle update stamping each write and adoption at
the pass's time and each tombstone at its deletion's, and reaps conditioned on
the revision listed. Reading and acting are separate steps, so the other device
can act in between and a write it beats is refused. Each device encodes
content its own way.

This is checked, not proved: every sequence of up to five edits, deletions,
reads and acts — from an empty library, from one both devices hold, and from
one a device with a fast clock has tombstoned — for a
path libraries delete and one they never do, is run, followed by any pass
still under way and two rounds of passes — 55,986 runs. Every run:

- **converges:** both devices and the server hold the same copy, or none;
- **is quiet afterwards:** another round changes nothing;
- **loses no edit** except to a deletion made after it;
- **keeps a deletion** made by a device that had every edit, when nothing was
  edited after it;
- **never deletes** a path no library deletes.

Assumed: an edit made while a deletion waits to be recorded cancels it;
tombstones outlive the run; the bundle update is one step, as its
read-merge-retry makes it.

**An edit made during a pass.** The pass acts on a local copy — installs the
other device's over it, or deletes it — only while it is still the one the
plan saw, as a write to the server is conditioned on the revision it read. An
edit made in between is left for the next pass, which merges it or keeps it
(`anEditDuringAPassSurvives`; the engine lists such paths as
`changedDuringPass`, not as failures). A copy made at a path the pass planned
to take while holding none has nothing to compare with, and is installed over
(`aCopyMadeDuringAPassCanBeOverwritten`): a file made at the very path another
device's copy is arriving at, within one pass. The loss-of-edits check leaves
those copies out, and names them.

**Still outside the model.**

- 54 tables ask 70 of the model's 198 definitions directly, and reach 112
  counting the rules those call. Of the rest:
  - Counterexamples (`uploadBeforeRead`, `earlyBackendWipe` and the like,
    listed under `modelOnly`) show what a rule prevents, and have no Swift
    counterpart by design.
  - The system models' own parts (`step`, `run`, `Agrees`, `settle`) describe
    devices, not code.
  - Decisions made in the apps are held by the apps' own tests: the phone's
    import checks (`sqliteImportAllowed`, `importSchemaAllows` and their kin)
    and the Mac's settings recovery (`recoverMacSettings`). A table needs the
    decision moved into core first.
  - Core decisions still held only by Swift unit tests:
    - settings and preferences without a shared base (`chooseWithoutBase`,
      `choosePreference`, `explicitPreferenceValue`,
      `preferenceBasesAfterPublish`);
    - revising rich writing blocks (`reviseRichDevotionalBlock` and its kin,
      `devotionalStoredBody`);
    - which kinds each app reports a save time for: the obligation is
      modelled, the reporting is each app's.
    - portable media import (`mediaImportChoice`, `portableMediaMayCommit`,
      `mediaMetadataAfterBridge`);
    - the provider-switch marker (`pendingBackendMarker`,
      `newBackendAvailable`).

    For module reads (`pairedModuleImport`, `contentModuleImport`), pairing a
    body with its own revision is fixed by the function's signature, so there
    is nothing for a table to ask.

- The phone serialises settings syncs — one in flight, later requests wait.
  That is Swift concurrency, not a decision.
- Presentation assets carry no deletion ledger. An image is kept while any deck
  names it, by design.

## Implementation map

| Path | Shared implementation | Lean rules | Remaining verification boundary |
| --- | --- | --- | --- |
| Per-file library and settings bundle | `LampSyncFolderLayout`, `LampSyncLibraryManifest`, `LampSyncFilePlan`, `LampSyncSettingsBundle`, `LampSyncSettingsStore`, conditional `delete(path:condition:)` | `mergeManifestEntry`, `recordWrite`, `adoptFile`, `pruneTombstone`, `filePlanAction`, `listedRevision`, `settingsUpdate` and `bundlePathHolds` (conformance), `bundleRead`, `mayClaim` and `settingsWrite` (conformance), `deletingNeedsATombstone`, `anUnknownFileIsAdopted`, `noRecordNeverOverwrites`, `aRecordedMemberIsNeverRead`, `tombstoneLifetimeCost` | Revisions are compared within one provider; a value-equal import must not mark content changed, which each app's importer keeps |
| Pass engine | `LampSyncBundlePass`, `LampSyncFileRecords`, `LampSyncLocalFile`, `LampSyncLibraryLayout`, `LampSyncBundleLedgers` | `passTrace` (conformance), `aPassKeepsTheOrder`, `aPassStartsByClaimingTheBundle`, `oneBundleWriteAtMost`, `aReapComesWithItsBundleWrite` | What each app gathers, imports and applies is the app's |
| Deleting a copy here | `LampSyncLocalDeletion`, the plan's `deletable` | `deleteTarget` (conformance), `mayRecordRemoval`, `everyRecordedRemovalIsCarriedOut`, `aCollectionIsNeverDeletedWhole`, `aModuleRemovalNamesItsPathsID`, `thePlanNeverAsksForARefusedDeletion`, `aRefusedDeletionGoesBackUp`, `aRefusedTombstoneHidesNothing`, `aWriteSupersedesATombstoneFromAFastClock` | Each app must call it on both sides; its library carries the deletion out |
| Save times and quiet passes | `LampSyncFilePlan`, `LampSyncFileRecords`, each app's gather | `aSaveAfterTheDeletionSurvives`, `anUnreportedSaveLosesToADeletion`, `aSettledFileNeedsNothing`, `aSettledDeletionNeedsNothing` | Which kinds report a save time is each app's, held by its own tests |
| Moving an earlier library | `LampSyncSettingsStore.earlierLibrary`, `migratePhoneLibrary`, `LampSyncLibraryMigration`, `LampSyncArchiveRemote.read`, `LampSyncFolderPublisher.capture` | `earlierLibrary`, `archiveKeeper`, `entryFate` and `macMigrationStep` (conformance), `onlyAnEmptyLibraryIsNew`, `anEntryThePhoneNeverWritesSettlesIt`, `everySettingAndLedgerIsCarried`, `onlyBookkeepingIsDropped`, `theMigrationWritesOnlyOverTheArchiveItImported`, `aMigratedLibraryIsLeftAlone` | Reading the old files is format conversion, tested against captured fixtures |
| Writes and revisions | `LampSyncConditionalWrite`, `LampWebDAVStorage`, `LampSyncRemoteDirectories`, `LampSyncContentRevision` | `conditionalWrite`, `landing` (conformance), `landingIsSound`, `settleByBytes`, `confirmWrite`, `writeOutcome` (conformance), `namesSameRevision` (conformance), `collectionConfirmed`, `combinedETagsCannotAuthorizeWrite`, `forbiddenWebDAVHeadIsNotAbsence` | The server must honour strong ETag preconditions; transport behaviour is Swift-tested |
| Folder provider | `LampSyncDirectoryStore`, `LampSyncSettingsBundle.merge(version:)`, `LampSharedPreferenceLedger` | `directoryWrite`, `directoryDelete`, `versionMerges` and `versionMerge` (conformance), `directoryWriteIsTheCoordinatedCheck`, `unresolvedVersionsStopTheFile`, `aVersionIsMergedOrStops`, `versionMergeIgnoresWhichCopyIsCurrent`, `aLaterEditSurvivesEitherWay` | No server-side precondition against a later remote upload; file coordination and `NSFileVersion` are the OS's |
| Shared preferences | `LampSharedPreferenceLedger`, `LampSyncPreferenceState` | `choosePreference`, `preferenceMerge` (conformance), `disputedPreferenceKeepsTheServersValue`, `firstMeetingKeepsTheServersValue`, `failedPreferencePublishKeepsEveryBase`, `publishedPreferenceUpdatesItsSource`, `publishedPreferenceKeepsAnotherSource` | UserDefaults persistence and each app's local preference mapping |
| Phone settings merge | `LampSyncSettingsPlanner`, `LampSyncThreeWaySet`, `LampSyncThreeWayValue` | `mergeMembership`, `chooseWholeValue`, `chooseReading`, `baselessReading` (conformance), `chooseWithoutBase` | SQLite serialisation of the settings database |
| Mac settings journal | macOS `LampSyncSettingsCommit`, `LampSyncBundleSettings` | `stageMacSettings`, `aSettingChangedDuringThePassIsNeverReverted`, `recoverMacSettings`, `pendingMacSettingsReplayCompletesPull`, `distinctMacSettingsEditBlocksReplay`, `mixedMacSettingsReplayToWholePlan` | Property-list write, UserDefaults flush and journal removal surviving interruption |
| Module files and import | `LampSyncModuleFiles`, `LampSyncModuleFolder`, `LampPortableModuleInspector` | `selectedCandidateIndex`, `needsImportByToken`, `moduleFolderListing` (conformance), `supersededCanonicalCannotHideActiveLegacy`, `missingRemoteRevisionRequiresImport`, `canonicalModuleRequiresEmbeddedIdentity`, `foreignSQLiteOwnerKeepsInstalled`, `sqliteImportAllowed`, `sqliteReplacementResult`, `failedEditableMergePreservesWholeState` | SQLite execution and JSON decoding |
| Phone translation JSON | `LampSyncContentRevision` for the file revision; one GRDB transaction for metadata, books, verses and headings | `translationSchemaAllowed`, `failedTranslationSchemaReplacementKeepsInstalled`, `foreignImportKeyCollisionKeepsInstalled` | JSON decoding and SQLite execution |
| Writing content and media | `LampPortableDevotionalContent`, `LampDevotionalMediaReference`, `LampPortableDevotionalMedia`, `LampSyncReferencedMedia`, `LampSyncDevotionalMedia`, `LampSyncPersonalExport` | `richDevotionalBlocksKeepTheirContent`, `unchangedRichDevotionalBlockIsExact`, `movedRichSectionKeepsIdentity`, `iosRichEditStoresRevisedBlocks`, `bracketedMarkdownWithoutBlockSchemaKeepsMarkdown`, `existingMediaMetadataIsPreserved`, `mediaBatchComplete` (conformance), `failedMediaTransferBlocksCompletion`, `macHighlightAllowsPublish` (conformance), `emptyMacHighlightSetMayBeSkipped` | Media has no merge base; local media files and SQLite rows are separate writes |
| Phone provider switching | `LampSyncBackendTransition`, `LampSyncEngine`, local recovery record | `deferredBackendWipe`, `backendActivationOccurs`, `backendTransition` and `cancellableRunTrace` (conformance), `pendingBackendMarker` | Two local databases remain separate; sync is suspended until a failed rollback can be recovered |
| Personal deletions (notes, writing, highlights, themes, sets) | `LampPersonalDeletionLedger`, `LampLibrary` ledger merge and apply, `LampSyncBundleLedgers` | `tombstoneDeletes` and `mergeTombstone` (conformance: `tombstone`, `tombstoneMerge`), `mergeTombstone_comm`, `mergeTombstone_assoc`, `mergeTombstone_idem`, `exchangedLedgersAgree`, `editAfterDeletionSurvives`, `equalTimeFavoursDeletion` | Device clocks are assumed comparable; the SQL upsert is the Swift `merged(with:)` rule |
| Slide decks | `LampPresentationDeckDeletionLedger`, `LampPresentationDeckPortablePull`, macOS `LampPresentationDeckSync` | `tombstoneDeletes` (conformance: `tombstone`), `deckPull`, `deckPullNeverKeepsADeletedDeck`, `deckPullIgnoresArrivalOrder` | Assets have no ledger and are kept while any deck names them |
| Workspace files (macOS) | `LampWorkspaceSync` and its `WorkspaceFileLedger`, shared file order | `tombstoneDeletes`, `workspaceDeletionTime`, `documentDeletionSparesALaterEdit`, `mergeFile` | Context files' deletions use the time they were noticed, not a comparable modification time |
| Conflicts set aside and resolved | `LampSyncMerge.importOutcome`, `LampSyncConflict`, `LampLibrary.resolveSyncConflict` | `portableImportOutcome` (conformance: `importOutcome`), `syncImportNeverStops`, `resolvedChoiceWinsWhereItWasMade`, `resolvedChoiceWinsOnTheOtherDevice`, `sameColumn` | Choosing in the UI and the stored payload are Swift; JSON classification is JSONSerialization's |
| Two devices exchanging whole content (system model) | the per-item orders of `LampSyncMerge` and the deletion ledgers, over `LampSyncConditionalWrite` | `serverNeverLosesAlongRun`, `agreesAlongRun`, `publishedContentIsNeverLost`, `refusedPublishChangesNothing`, `pullThenPublishIsAccepted`, `aQuietRoundConverges`, `conditionalPublishKeepsTheOtherEdit`, `unconditionalPublishLosesTheOtherEdit` | The server honours conditions and issues new revisions; steps are atomic; storage is durable; equal-time record disagreements and baseless settings merges are not joins |
| Two devices running the per-file pass (system model, checked to a bound) | `filePlanAction`, `recordWrite`, `adoptFile` and `removeFile` as `LampSyncFilePlan`, `LampSyncLibraryManifest` and `LampSyncBundlePass` run them | `converges`, `quiet`, `noLostEdit`, `deletionSticks`, `neverDeleted` (system checks), `anEditDuringAPassSurvives`, `aCopyMadeDuringAPassCanBeOverwritten`, `recordingTheDownloadedBytesNeverSettles`, `anUnreportedSaveLosesAnEditMadeAfterTheDeletion` | One path; up to five steps from three starts; a copy made during a pass at a path it planned to take while holding none is installed over |

The listed Lean rules prove properties of models that correspond to shared
Swift decisions. Swift tests exercise each shared implementation with the
same edge cases. This is not a machine-checked proof of the Swift runtime,
database engines, filesystem, or network provider.
