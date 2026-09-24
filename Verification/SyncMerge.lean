import Init

/-!
An executable model of LampSyncMerge's two decisions. `revision` models the
stored integer modification time (nil maps to zero). `FileVersion.tick` models
the fixed millisecond bucket; `bytes` is an ordered stand-in for file bytes.
This proves the decision rules, not the Swift runtime or transport adapters.
-/

namespace LampSyncVerification

inductive Decision where
  | local | incoming | conflict
  deriving DecidableEq, Repr

def decide (current incoming : Int) (sameContent : Bool) : Decision :=
  if current < incoming then .incoming
  else if incoming < current then .local
  else if sameContent then .local else .conflict

theorem newerIncomingWins (l r : Int) (same : Bool) (h : l < r) :
    decide l r same = .incoming := by
  simp [decide, h]

theorem newerLocalWins (l r : Int) (same : Bool) (h : r < l) :
    decide l r same = .local := by
  have hnot : ¬ l < r := by omega
  simp [decide, hnot, h]

theorem equalContentKeepsLocal (t : Int) : decide t t true = .local := by
  simp [decide]

theorem equalTimeDifferentContentConflicts (t : Int) :
    decide t t false = .conflict := by
  simp [decide]

structure FileVersion where
  tick : Int
  bytes : Nat
  deriving DecidableEq, Repr

def fileLE (a b : FileVersion) : Prop :=
  a.tick < b.tick ∨ (a.tick = b.tick ∧ a.bytes ≤ b.bytes)

instance (a b : FileVersion) : Decidable (fileLE a b) := by
  unfold fileLE
  infer_instance

theorem fileLE_refl (a : FileVersion) : fileLE a a := by
  simp [fileLE]

theorem fileLE_antisymm (a b : FileVersion)
    (hab : fileLE a b) (hba : fileLE b a) : a = b := by
  cases a with
  | mk ta ba =>
    cases b with
    | mk tb bb =>
      simp only [fileLE] at hab hba
      have ht : ta = tb := by omega
      have hb : ba = bb := by omega
      simp [ht, hb]

theorem fileLE_trans (a b c : FileVersion)
    (hab : fileLE a b) (hbc : fileLE b c) : fileLE a c := by
  simp only [fileLE] at *
  omega

theorem fileLE_total (a b : FileVersion) : fileLE a b ∨ fileLE b a := by
  simp only [fileLE]
  omega

def mergeFile (a b : FileVersion) : FileVersion :=
  if fileLE a b then b else a

theorem mergeFile_comm (a b : FileVersion) : mergeFile a b = mergeFile b a := by
  by_cases hab : fileLE a b
  · by_cases hba : fileLE b a
    · have heq := fileLE_antisymm a b hab hba
      simp [mergeFile, heq]
    · simp [mergeFile, hab, hba]
  · have hba : fileLE b a := (fileLE_total a b).resolve_left hab
    simp [mergeFile, hab, hba]

theorem mergeFile_idempotent (a : FileVersion) : mergeFile a a = a := by
  simp [mergeFile, fileLE_refl]

theorem mergeFile_upper_left (a b : FileVersion) : fileLE a (mergeFile a b) := by
  by_cases hab : fileLE a b
  · simp [mergeFile, hab]
  · simp [mergeFile, hab, fileLE_refl]

theorem mergeFile_upper_right (a b : FileVersion) : fileLE b (mergeFile a b) := by
  by_cases hab : fileLE a b
  · simp [mergeFile, hab, fileLE_refl]
  · have hba : fileLE b a := (fileLE_total a b).resolve_left hab
    simpa [mergeFile, hab] using hba

theorem mergeFile_least_upper (a b c : FileVersion)
    (hac : fileLE a c) (hbc : fileLE b c) : fileLE (mergeFile a b) c := by
  by_cases hab : fileLE a b
  · simpa [mergeFile, hab] using hbc
  · simpa [mergeFile, hab] using hac

theorem mergeFile_assoc (a b c : FileVersion) :
    mergeFile (mergeFile a b) c = mergeFile a (mergeFile b c) := by
  apply fileLE_antisymm
  · apply mergeFile_least_upper
    · apply mergeFile_least_upper
      · exact mergeFile_upper_left a (mergeFile b c)
      · exact fileLE_trans b (mergeFile b c) (mergeFile a (mergeFile b c))
          (mergeFile_upper_left b c) (mergeFile_upper_right a (mergeFile b c))
    · exact fileLE_trans c (mergeFile b c) (mergeFile a (mergeFile b c))
        (mergeFile_upper_right b c) (mergeFile_upper_right a (mergeFile b c))
  · apply mergeFile_least_upper
    · exact fileLE_trans a (mergeFile a b) (mergeFile (mergeFile a b) c)
        (mergeFile_upper_left a b) (mergeFile_upper_left (mergeFile a b) c)
    · apply mergeFile_least_upper
      · exact fileLE_trans b (mergeFile a b) (mergeFile (mergeFile a b) c)
          (mergeFile_upper_right a b) (mergeFile_upper_left (mergeFile a b) c)
      · exact mergeFile_upper_right (mergeFile a b) c

-- The former sliding 1 ms tolerance was not transitive. These three files
-- formed a cycle: A beats B by bytes, B beats C by bytes, C beats A by time.
def oldReplace (currentTime incomingTime : Int)
    (currentBytes incomingBytes : Nat) : Bool :=
  if (incomingTime - currentTime).natAbs > 1000 then
    currentTime < incomingTime
  else currentBytes < incomingBytes

theorem oldWindowHasCycle :
    oldReplace 600 0 2 3 = true ∧
    oldReplace 1200 600 1 2 = true ∧
    oldReplace 0 1200 3 1 = true := by
  decide

-- A shared WebDAV existence check distinguishes a missing resource from a
-- failed request and uses GET when a server does not support HEAD.
def webDAVPresence (head get : Nat) : Option Bool :=
  if head == 404 then some false
  else if head == 405 then
    if get == 404 then some false
    else if 200 ≤ get ∧ get < 300 then some true else none
  else if 200 ≤ head ∧ head < 300 then some true else none

theorem forbiddenWebDAVHeadIsNotAbsence :
    webDAVPresence 403 200 = none := by decide

theorem unsupportedHeadFallsBackToGET :
    webDAVPresence 405 204 = some true ∧
    webDAVPresence 405 404 = some false := by decide

theorem missingWebDAVHeadIsAbsence :
    webDAVPresence 404 200 = some false := by decide

-- A 409 from MKCOL is accepted only after a separate PROPFIND confirms that
-- the requested path is already a collection. The Swift adapter checks the
-- returned href as well; this abstracts that path comparison as `samePath`.
def webDAVDirectoryReady
    (mkcolStatus propfindStatus : Nat)
    (samePath isCollection : Bool) : Bool :=
  [200, 201, 204, 405].contains mkcolStatus ||
    (mkcolStatus == 409 && propfindStatus == 207 && samePath && isCollection)

theorem existingWebDAVCollectionAcceptsConflict :
    webDAVDirectoryReady 409 207 true true = true := by decide

theorem missingWebDAVCollectionKeepsConflict :
    webDAVDirectoryReady 409 404 true true = false := by decide

theorem nonCollectionCannotSatisfyMKCOLConflict :
    webDAVDirectoryReady 409 207 true false = false := by decide

theorem differentWebDAVPathCannotSatisfyMKCOLConflict :
    webDAVDirectoryReady 409 207 false true = false := by decide

-- A whole-file upload before reading the remote file cannot preserve a
-- remote-only edit. iOS now reads first and uses a three-way base. Its one-time
-- upgrade path without a base still requires an unchanged remote token, and
-- WebDAV enforces the same revision atomically during the write.

def uploadBeforeRead (current _remote : Nat) : Nat × Nat := (current, current)

theorem uploadFirstLosesRemoteOnlyEdit :
    (uploadBeforeRead 1 2).2 ≠ 2 := by
  decide

def guardedUpload (baseToken remoteToken current : Nat) : Option Nat :=
  if baseToken == remoteToken then some current else none

theorem staleSnapshotCannotUpload (baseToken remoteToken current : Nat)
    (h : baseToken ≠ remoteToken) :
    guardedUpload baseToken remoteToken current = none := by
  simp [guardedUpload, h]

-- WebDAV If-Match and If-None-Match evaluate the revision at the write.
-- `none` as an expected revision means the client requires an absent file.
def conditionalWrite (expected : Option Nat) (remote : Option (Nat × Nat))
    (content : Nat) : Option (Nat × Nat) :=
  match expected, remote with
  | none, none => some (1, content)
  | some revision, some (currentRevision, _) =>
      if revision == currentRevision then some (currentRevision + 1, content) else none
  | _, _ => none

theorem staleConditionalWriteRejected (expected actual oldContent newContent : Nat)
    (h : expected ≠ actual) :
    conditionalWrite (some expected) (some (actual, oldContent)) newContent = none := by
  simp [conditionalWrite, h]

theorem createOnlyWriteCannotOverwrite (revision oldContent newContent : Nat) :
    conditionalWrite none (some (revision, oldContent)) newContent = none := by
  simp [conditionalWrite]

theorem observedRemoteDeletionCannotRecreate (revision newContent : Nat) :
    conditionalWrite (some revision) none newContent = none := by
  simp [conditionalWrite]

-- RFC 9110's opaque-tag admits visible bytes except an inner quote, plus
-- obs-text. The HTTP adapter must accept one strong entity-tag, since a
-- combined header value could otherwise become an If-Match validator list.
def validETagByte (byte : Nat) : Bool :=
  byte == 33 || (if 35 ≤ byte ∧ byte ≤ 126 then true else false) ||
    (if 128 ≤ byte ∧ byte ≤ 255 then true else false)

def strongETagBytes : List Nat → Bool
  | 34 :: rest =>
      match rest.reverse with
      | 34 :: interior => interior.all validETagByte
      | _ => false
  | _ => false

def guardedETagCondition (bytes : List Nat) : Option (List Nat) :=
  if strongETagBytes bytes then some bytes else none

theorem emptyStrongETagIsValid :
    guardedETagCondition [34, 34] = some [34, 34] := by
  decide

theorem commaInsideStrongETagIsValid :
    guardedETagCondition [34, 97, 44, 98, 34] = some [34, 97, 44, 98, 34] := by
  decide

theorem combinedETagsCannotAuthorizeWrite :
    guardedETagCondition [34, 97, 34, 44, 34, 98, 34] = none := by
  decide

theorem weakETagCannotAuthorizeWrite :
    guardedETagCondition [87, 47, 34, 97, 34] = none := by
  decide

theorem newlineInsideETagCannotAuthorizeWrite :
    guardedETagCondition [34, 97, 10, 34] = none := by
  decide

-- `LampSyncThreeWaySet` applies this decision independently to each reading
-- ID. An observed member is removed if either side removed it; a new member
-- is retained if either side added it.
def mergeMembership (base device remote : Bool) : Bool :=
  if base then device && remote else device || remote

theorem mergeMembership_comm (base device remote : Bool) :
    mergeMembership base device remote = mergeMembership base remote device := by
  cases base <;> cases device <;> cases remote <;> decide

theorem independentAdditionSurvives (remote : Bool) :
    mergeMembership false true remote = true := by
  cases remote <;> decide

theorem observedDeletionSurvives (remote : Bool) :
    mergeMembership true false remote = false := by
  cases remote <;> decide

theorem unchangedMemberFollowsRemote (remote : Bool) :
    mergeMembership true true remote = remote := by
  cases remote <;> decide

theorem mergedMembershipHasSource (base device remote : Bool)
    (h : mergeMembership base device remote = true) :
    device = true ∨ remote = true := by
  cases base <;> cases device <;> cases remote <;> simp_all [mergeMembership]

inductive ThreeWayChoice where
  | local | remote | conflict
  deriving DecidableEq, Repr

def chooseWholeValue (base device remote : Nat) : ThreeWayChoice :=
  if device = remote || remote = base then .local
  else if device = base then .remote
  else .conflict

theorem unchangedLocalTakesRemote (base remote : Nat)
    (h : remote ≠ base) :
    chooseWholeValue base base remote = .remote := by
  simp [chooseWholeValue, h, Ne.symm h]

theorem unchangedRemoteKeepsLocal (base device : Nat) :
    chooseWholeValue base device base = .local := by
  simp [chooseWholeValue]

theorem divergentWholeValuesConflict (base device remote : Nat)
    (hLocal : device ≠ base)
    (hRemote : remote ≠ base)
    (hDifferent : device ≠ remote) :
    chooseWholeValue base device remote = .conflict := by
  simp [chooseWholeValue, hLocal, hRemote, hDifferent]

-- `LampSyncSettingsPlanner` compares the completion time of records retained
-- by both sides. If times tie but the rows differ, it reports a conflict so
-- two devices cannot each keep their own metadata indefinitely.
def chooseReading (deviceTime remoteTime deviceRow remoteRow : Nat) : ThreeWayChoice :=
  if deviceTime > remoteTime then .local
  else if remoteTime > deviceTime then .remote
  else if deviceRow = remoteRow then .local
  else .conflict

theorem laterDeviceCompletionWins (deviceTime remoteTime deviceRow remoteRow : Nat)
    (h : deviceTime > remoteTime) :
    chooseReading deviceTime remoteTime deviceRow remoteRow = .local := by
  simp [chooseReading, h]

theorem laterRemoteCompletionWins (deviceTime remoteTime deviceRow remoteRow : Nat)
    (h : remoteTime > deviceTime) :
    chooseReading deviceTime remoteTime deviceRow remoteRow = .remote := by
  have hnot : ¬ deviceTime > remoteTime := by omega
  simp [chooseReading, hnot, h]

theorem equalCompletionDifferentRowsConflict (time deviceRow remoteRow : Nat)
    (h : deviceRow ≠ remoteRow) :
    chooseReading time time deviceRow remoteRow = .conflict := by
  simp [chooseReading, h]

-- The upgrade path has no membership base. Its caller guards a pending upload
-- with the last observed remote token and then takes the remote reading set.
-- Settings use the old timestamp rule, refusing an equal-time disagreement.
def chooseWithoutBase (deviceTime remoteTime : Nat) (sameSettings : Bool) : ThreeWayChoice :=
  if deviceTime = remoteTime && !sameSettings then .conflict
  else if remoteTime > deviceTime then .remote
  else .local

def planWithoutBase (sameReadings : Bool) (deviceTime remoteTime : Nat)
    (sameSettings : Bool) : Option ThreeWayChoice :=
  if sameReadings then some (chooseWithoutBase deviceTime remoteTime sameSettings)
  else none

theorem differentReadingsWithoutBaseReject (deviceTime remoteTime : Nat)
    (sameSettings : Bool) :
    planWithoutBase false deviceTime remoteTime sameSettings = none := by
  simp [planWithoutBase]

theorem equalTimeDifferentSettingsConflict (time : Nat) :
    chooseWithoutBase time time false = .conflict := by
  simp [chooseWithoutBase]

theorem newerRemoteSettingsWinWithoutBase (deviceTime remoteTime : Nat)
    (sameSettings : Bool) (h : remoteTime > deviceTime) :
    chooseWithoutBase deviceTime remoteTime sameSettings = .remote := by
  have hne : deviceTime ≠ remoteTime := by omega
  simp [chooseWithoutBase, hne, h]

theorem newerDeviceSettingsWinWithoutBase (deviceTime remoteTime : Nat)
    (sameSettings : Bool) (h : deviceTime > remoteTime) :
    chooseWithoutBase deviceTime remoteTime sameSettings = .local := by
  have hne : deviceTime ≠ remoteTime := by omega
  have hnot : ¬ remoteTime > deviceTime := by omega
  simp [chooseWithoutBase, hne, hnot]

-- A body from one GET paired with a later HEAD revision can overwrite the
-- intervening edit. iOS WebDAV settings now carry body and ETag from one GET.
theorem separateSettingsTokenCanAuthorizeStaleBody :
    conditionalWrite (some 2) (some (2, 99)) 1 = some (3, 1) := by
  decide

theorem pairedSettingsSnapshotRejectsLaterRevision
    (readRevision laterRevision laterBody mergedBody : Nat)
    (h : readRevision ≠ laterRevision) :
    conditionalWrite (some readRevision)
      (some (laterRevision, laterBody)) mergedBody = none := by
  exact staleConditionalWriteRejected readRevision laterRevision laterBody mergedBody h

-- Mac may rebuild all archive entries it owns, but its archive PUT retains the
-- iOS settings entry from the same revision that authorized that PUT.
def preservedSettings (observed _outgoing : Option Nat) : Option Nat := observed

def macArchivePublish (observedRevision currentRevision : Nat)
    (observedSettings outgoingSettings : Option Nat) : Option (Nat × Option Nat) :=
  if observedRevision == currentRevision then
    some (currentRevision + 1, preservedSettings observedSettings outgoingSettings)
  else none

theorem macPublishRetainsObservedSettings
    (revision settings : Nat) (outgoing : Option Nat) :
    macArchivePublish revision revision (some settings) outgoing =
      some (revision + 1, some settings) := by
  simp [macArchivePublish, preservedSettings]

theorem macDoesNotInventSettingsFromOutgoing
    (revision : Nat) (outgoing : Option Nat) :
    macArchivePublish revision revision none outgoing =
      some (revision + 1, none) := by
  simp [macArchivePublish, preservedSettings]

theorem staleMacArchiveCannotReplaceSettings
    (observedRevision currentRevision : Nat)
    (observedSettings outgoingSettings : Option Nat)
    (h : observedRevision ≠ currentRevision) :
    macArchivePublish observedRevision currentRevision observedSettings outgoingSettings = none := by
  simp [macArchivePublish, h]

-- Mac's iOS-compatible highlight export may skip an empty set. Any other
-- export error must stop the publish callback before its archive PUT.
inductive MacHighlightExport where
  | ready | empty | failed
  deriving DecidableEq, Repr

def macHighlightAllowsArchivePublish : MacHighlightExport → Bool
  | .ready | .empty => true
  | .failed => false

theorem emptyMacHighlightSetMayBeSkipped :
    macHighlightAllowsArchivePublish .empty = true := by
  rfl

theorem failedMacHighlightExportStopsArchivePublish :
    macHighlightAllowsArchivePublish .failed = false := by
  rfl

def oldMacHighlightAllowsArchivePublish (_ : MacHighlightExport) : Bool := true

theorem swallowedMacHighlightFailureCouldPublish :
    oldMacHighlightAllowsArchivePublish .failed = true := by
  rfl

-- The archive's legacy-settings manifest records the standalone file observed
-- before commit. Matching archive bytes are a completed mirror; unchanged
-- older bytes are superseded. Any other bytes may be an older client edit.
inductive LegacySettingsState where
  | absent | mirrored | superseded | changed
  deriving DecidableEq, Repr

def classifyLegacySettings (archiveDigest : Nat)
    (baseRevision baseDigest : Option Nat)
    (legacy : Option (Nat × Nat)) : LegacySettingsState :=
  match legacy with
  | none => if baseRevision = none then .absent else .changed
  | some (revision, digest) =>
      if digest = archiveDigest then .mirrored
      else if some revision = baseRevision && some digest = baseDigest then .superseded
      else .changed

theorem mirroredLegacyIsCurrent (archiveDigest revision : Nat)
    (baseRevision baseDigest : Option Nat) :
    classifyLegacySettings archiveDigest baseRevision baseDigest
      (some (revision, archiveDigest)) = .mirrored := by
  simp [classifyLegacySettings]

theorem unchangedLegacyIsSuperseded (archiveDigest revision digest : Nat)
    (h : digest ≠ archiveDigest) :
    classifyLegacySettings archiveDigest (some revision) (some digest)
      (some (revision, digest)) = .superseded := by
  simp [classifyLegacySettings, h]

theorem changedLegacyCannotBeIgnored (archiveDigest baseRevision baseDigest
    revision digest : Nat)
    (hArchive : digest ≠ archiveDigest)
    (hBase : revision ≠ baseRevision ∨ digest ≠ baseDigest) :
    classifyLegacySettings archiveDigest (some baseRevision) (some baseDigest)
      (some (revision, digest)) = .changed := by
  rcases hBase with hRevision | hDigest
  · simp [classifyLegacySettings, hArchive, hRevision]
  · simp [classifyLegacySettings, hArchive, hDigest]

theorem removedObservedLegacyIsConflict (archiveDigest revision digest : Nat) :
    classifyLegacySettings archiveDigest (some revision) (some digest) none = .changed := by
  simp [classifyLegacySettings]

theorem failedInitialLegacyMirrorCanRetry (archiveDigest : Nat) :
    classifyLegacySettings archiveDigest none none none = .absent := by
  simp [classifyLegacySettings]

-- `LampSyncSettingsArchive.readWithLegacy` selects the archive only after
-- checking whether an older client changed the standalone settings file.
inductive SettingsReadSource where
  | absent | legacy | archive | conflict
  deriving DecidableEq, Repr

def resolveSettingsSource (archiveDigest : Option Nat)
    (baseRevision baseDigest : Option Nat)
    (legacy : Option (Nat × Nat)) : SettingsReadSource :=
  match archiveDigest with
  | none => if legacy.isSome then .legacy else .absent
  | some digest =>
      if classifyLegacySettings digest baseRevision baseDigest legacy = .changed
      then .conflict else .archive

theorem legacySettingsUsedBeforeMigration (revision digest : Nat) :
    resolveSettingsSource none none none (some (revision, digest)) = .legacy := by
  simp [resolveSettingsSource]

theorem supersededLegacyDoesNotReplaceArchive
    (archiveDigest revision legacyDigest : Nat)
    (h : legacyDigest ≠ archiveDigest) :
    resolveSettingsSource (some archiveDigest)
      (some revision) (some legacyDigest) (some (revision, legacyDigest)) = .archive := by
  simp [resolveSettingsSource, unchangedLegacyIsSuperseded, h]

theorem changedLegacyStopsArchiveRead (archiveDigest baseRevision baseDigest
    revision digest : Nat)
    (hArchive : digest ≠ archiveDigest)
    (hBase : revision ≠ baseRevision ∨ digest ≠ baseDigest) :
    resolveSettingsSource (some archiveDigest)
      (some baseRevision) (some baseDigest) (some (revision, digest)) = .conflict := by
  simp [resolveSettingsSource,
    changedLegacyCannotBeIgnored archiveDigest baseRevision baseDigest
      revision digest hArchive hBase]

-- A client's old reading/settings baseline can seed the archive merge only
-- when it names the same provider and the exact legacy revision superseded by
-- the archive. Otherwise a no-base conflict is required.
def mayAdoptLegacyBase (savedSource currentSource savedRevision manifestRevision : Nat) : Bool :=
  savedSource == currentSource && savedRevision == manifestRevision

theorem matchingLegacyBaseMayBeAdopted (source revision : Nat) :
    mayAdoptLegacyBase source source revision revision = true := by
  simp [mayAdoptLegacyBase]

theorem differentLegacyRevisionCannotSeedArchive (source savedRevision manifestRevision : Nat)
    (h : savedRevision ≠ manifestRevision) :
    mayAdoptLegacyBase source source savedRevision manifestRevision = false := by
  simp [mayAdoptLegacyBase, h]

theorem differentLegacySourceCannotSeedArchive (savedSource currentSource revision : Nat)
    (h : savedSource ≠ currentSource) :
    mayAdoptLegacyBase savedSource currentSource revision revision = false := by
  simp [mayAdoptLegacyBase, h]

-- A settings poll may skip the GET only after both archive and compatibility
-- file HEADs return the strong revisions saved with the applied baseline.
def maySkipArchivePoll (localPending sourceMatches archiveStrong legacyStrong : Bool)
    (savedArchive currentArchive savedLegacy currentLegacy : Option Nat) : Bool :=
  !localPending && sourceMatches && archiveStrong && legacyStrong &&
    savedArchive.isSome && savedLegacy.isSome &&
    savedArchive == currentArchive && savedLegacy == currentLegacy

theorem unchangedStrongRevisionsMaySkipPoll (archive legacy : Nat) :
    maySkipArchivePoll false true true true
      (some archive) (some archive) (some legacy) (some legacy) = true := by
  simp [maySkipArchivePoll]

theorem changedArchiveForcesRead (saved current legacy : Nat)
    (h : saved ≠ current) :
    maySkipArchivePoll false true true true
      (some saved) (some current) (some legacy) (some legacy) = false := by
  simp [maySkipArchivePoll, h]

theorem changedLegacyForcesRead (archive saved current : Nat)
    (h : saved ≠ current) :
    maySkipArchivePoll false true true true
      (some archive) (some archive) (some saved) (some current) = false := by
  simp [maySkipArchivePoll, h]

theorem pendingLocalChangeForcesRead (archive legacy : Nat) :
    maySkipArchivePoll true true true true
      (some archive) (some archive) (some legacy) (some legacy) = false := by
  simp [maySkipArchivePoll]

theorem weakLegacyRevisionForcesRead (archive legacy : Nat) :
    maySkipArchivePoll false true true false
      (some archive) (some archive) (some legacy) (some legacy) = false := by
  simp [maySkipArchivePoll]

-- iCloud offers no atomic conditional write. Bracketing its coordinated read
-- with content digests rejects changed bytes during the read, assuming the
-- SHA-256 digest distinguishes the particular bodies. A modification date
-- alone could remain equal across different writes.
def modificationDateToken (_body date : Nat) : Nat := date

theorem equalModificationDateCanHideChangedBody :
    modificationDateToken 1 10 = modificationDateToken 2 10 ∧ 1 ≠ 2 := by
  decide

-- Identity stands for a collision-free content digest in this finite model;
-- the Swift implementation computes SHA-256 and tests equal-date files.
def contentRevision (body : Nat) : Nat := body

theorem differentBodiesHaveDifferentContentRevisions (first second : Nat)
    (h : first ≠ second) : contentRevision first ≠ contentRevision second := by
  simpa [contentRevision] using h

def stableRead (before after : Option Nat) : Option Nat :=
  if before = after then after else none

theorem changedTokenDuringReadIsRejected (before after : Option Nat)
    (h : before ≠ after) : stableRead before after = none := by
  simp [stableRead, h]

theorem missingTokenCannotAuthorizeExistingBody :
    stableRead none none = none := by
  rfl

-- A body digest is checked as well as the two probes. This catches A→B→A
-- around the body read, which comparing the probes alone would miss.
def checkedContentRead
    (before body after : Option Nat) : Option Nat :=
  if before = after ∧ body = after then after else none

theorem equalOuterTokensCanHideDifferentBody :
    stableRead (some 1) (some 1) = some 1 ∧
    checkedContentRead (some 1) (some 2) (some 1) = none := by
  decide

theorem matchingContentReadIsAccepted (revision : Nat) :
    checkedContentRead (some revision) (some revision) (some revision) =
      some revision := by
  simp [checkedContentRead]

def iCloudReadReady (unresolvedVersions : Bool)
    (before body after : Option Nat) : Option Nat :=
  if unresolvedVersions then none else checkedContentRead before body after

theorem reportedICloudVersionConflictStopsRead
    (before body after : Option Nat) :
    iCloudReadReady true before body after = none := by
  simp [iCloudReadReady]

-- A coordinated iCloud read can be stable and still be followed by another
-- device's write before this client's unconditional upload. The later upload
-- then replaces that remote-only content. This is a verified limitation of
-- the provider path, not a guarantee supplied by the read check.
def unconditionedSettingsWrite (_observedToken : Option Nat)
    (currentRemote : Nat × Nat) (localContent : Nat) : Nat × Nat :=
  (currentRemote.1 + 1, localContent)

theorem stableICloudReadDoesNotProtectLaterWrite :
    stableRead (some 1) (some 1) = some 1 ∧
    unconditionedSettingsWrite (some 1) (2, 99) 7 = (3, 7) := by
  decide

-- `LampSyncObservedWrite` compares a legacy module with the version imported
-- by the client before using the remote revision as its PUT precondition.
-- Digest equality here stands for a collision-free SHA-256 comparison; the
-- actual digest and ETag validation are exercised by Swift tests.
inductive ObservedBase where
  | absent | revision (value : Nat) | digest (content : Nat)
  deriving DecidableEq, Repr

def observedModuleWrite (base : ObservedBase)
    (remote : Option (Nat × Nat)) (content : Nat) : Option (Nat × Nat) :=
  match remote with
  | none =>
      match base with
      | .revision _ => none
      | _ => conditionalWrite none none content
  | some (revision, remoteContent) =>
      if content = remoteContent || base = .revision revision ||
          base = .digest remoteContent then
        conditionalWrite (some revision) remote content
      else none

theorem staleModuleRevisionCannotOverwrite (baseRevision remoteRevision oldContent newContent : Nat)
    (hRevision : baseRevision ≠ remoteRevision)
    (hContent : oldContent ≠ newContent) :
    observedModuleWrite (.revision baseRevision)
      (some (remoteRevision, oldContent)) newContent = none := by
  simp [observedModuleWrite, hRevision, Ne.symm hContent]

theorem staleModuleDigestCannotOverwrite (baseContent remoteContent newContent revision : Nat)
    (hBase : baseContent ≠ remoteContent)
    (hContent : newContent ≠ remoteContent) :
    observedModuleWrite (.digest baseContent)
      (some (revision, remoteContent)) newContent = none := by
  simp [observedModuleWrite, hBase, hContent]

theorem unknownModuleBaseCannotOverwrite (revision oldContent newContent : Nat)
    (hContent : newContent ≠ oldContent) :
    observedModuleWrite .absent (some (revision, oldContent)) newContent = none := by
  simp [observedModuleWrite, hContent]

theorem identicalLegacyUploadMayRepeat (revision content : Nat) :
    observedModuleWrite .absent (some (revision, content)) content =
      some (revision + 1, content) := by
  simp [observedModuleWrite, conditionalWrite]

theorem observedModuleWriteCreatesOnlyWhenAbsent (content : Nat) :
    observedModuleWrite .absent none content = some (1, content) := by
  simp [observedModuleWrite, conditionalWrite]

-- The compatibility manifest can authorize replacing the folder revision
-- superseded by an archived module, provided the imported digest identifies
-- that exact archive payload. A later folder edit remains protected.
def observedCompatibilityWrite (base : ObservedBase)
    (archive : Option (Nat × Nat)) (remote : Option (Nat × Nat))
    (content : Nat) : Option (Nat × Nat) :=
  match archive, remote with
  | some (archiveContent, oldRevision), some (revision, remoteContent) =>
      if base = .digest archiveContent && revision = oldRevision then
        conditionalWrite (some revision) (some (revision, remoteContent)) content
      else observedModuleWrite base remote content
  | _, _ => observedModuleWrite base remote content

theorem archivedModuleMayReplaceItsOldFolderRevision
    (archiveContent oldRevision oldFolderContent newContent : Nat) :
    observedCompatibilityWrite (.digest archiveContent)
      (some (archiveContent, oldRevision))
      (some (oldRevision, oldFolderContent)) newContent =
        some (oldRevision + 1, newContent) := by
  simp [observedCompatibilityWrite, conditionalWrite]

theorem changedFolderRejectsArchivedModule
    (archiveContent oldRevision laterRevision laterContent newContent : Nat)
    (hRevision : laterRevision ≠ oldRevision)
    (hBase : archiveContent ≠ laterContent)
    (hContent : newContent ≠ laterContent) :
    observedCompatibilityWrite (.digest archiveContent)
      (some (archiveContent, oldRevision))
      (some (laterRevision, laterContent)) newContent = none := by
  simp [observedCompatibilityWrite, observedModuleWrite,
    hRevision, hBase, hContent]

-- The shared preference ledger compares a field with the version this device
-- last applied. A local value change can be published when the remote revision
-- is unchanged; simultaneous different values require user resolution.
inductive PreferenceChoice where
  | local | remote | conflict
  deriving DecidableEq, Repr

-- Registered UserDefaults values are effective UI defaults, not explicit
-- local edits in the app's persistent domain.
def explicitPreferenceValue (stored _registered : Option Nat) : Option Nat :=
  stored

theorem registeredDefaultWithoutStoredPreferenceIsNotAnEdit
    (registered : Option Nat) :
    explicitPreferenceValue none registered = none := by
  rfl

def choosePreference (baseRevision remoteRevision : Option Nat)
    (baseValue localValue remoteValue : Option Nat) : PreferenceChoice :=
  if localValue != baseValue && remoteRevision != baseRevision &&
      localValue != remoteValue then .conflict
  else if localValue != baseValue && remoteRevision == baseRevision then .local
  else .remote

theorem independentLocalPreferenceWins (baseRevision : Option Nat)
    (baseValue localValue remoteValue : Option Nat)
    (h : localValue ≠ baseValue) :
    choosePreference baseRevision baseRevision baseValue localValue remoteValue = .local := by
  simp [choosePreference, h]

theorem independentRemotePreferenceWins (baseRevision remoteRevision : Option Nat)
    (baseValue remoteValue : Option Nat) :
    choosePreference baseRevision remoteRevision baseValue baseValue remoteValue = .remote := by
  simp [choosePreference]

theorem divergentPreferenceEditsConflict (baseRevision remoteRevision : Option Nat)
    (baseValue localValue remoteValue : Option Nat)
    (hLocal : localValue ≠ baseValue)
    (hRemote : remoteRevision ≠ baseRevision)
    (hDifferent : localValue ≠ remoteValue) :
    choosePreference baseRevision remoteRevision baseValue localValue remoteValue = .conflict := by
  simp [choosePreference, hLocal, hRemote, hDifferent]

theorem matchingPreferenceEditsConverge (baseRevision remoteRevision : Option Nat)
    (baseValue value : Option Nat)
    (hRemote : remoteRevision ≠ baseRevision) :
    choosePreference baseRevision remoteRevision baseValue value value = .remote := by
  simp [choosePreference, hRemote]

-- Both clients now use one source-keyed base store. When publication is
-- required, a failed write cannot advance the base for that source.
def preferenceBasesAfterPublish
    (bases : String → Option Nat) (source : String)
    (revision : Nat) (published : Bool) : String → Option Nat :=
  fun key => if published && key == source then some revision else bases key

theorem failedPreferencePublishKeepsEveryBase
    (bases : String → Option Nat) (source : String) (revision : Nat) :
    preferenceBasesAfterPublish bases source revision false = bases := by
  funext key
  simp [preferenceBasesAfterPublish]

theorem publishedPreferenceUpdatesItsSource
    (bases : String → Option Nat) (source : String) (revision : Nat) :
    preferenceBasesAfterPublish bases source revision true source = some revision := by
  simp [preferenceBasesAfterPublish]

theorem publishedPreferenceKeepsAnotherSource
    (bases : String → Option Nat) (source other : String) (revision : Nat)
    (different : other ≠ source) :
    preferenceBasesAfterPublish bases source revision true other = bases other := by
  simp [preferenceBasesAfterPublish, different]

def completed (settingsOK modulesOK uploadOK : Bool) : Bool :=
  settingsOK && modulesOK && uploadOK

theorem failedStageCannotComplete (s m u : Bool)
    (h : s = false ∨ m = false ∨ u = false) :
    completed s m u = false := by
  cases s <;> cases m <;> cases u <;> simp_all [completed]

-- The shared runner executes these stages in this order and exits on throw.
def runTrace (pullOK publishOK : Bool) : List Nat :=
  if !pullOK then [0]
  else if !publishOK then [0, 1]
  else [0, 1, 2]

theorem failedPullStopsBeforePublish (publishOK : Bool) :
    runTrace false publishOK = [0] := by
  simp [runTrace]

-- The shared runner checks task cancellation before each phase. Cancellation
-- cannot interrupt work already underway inside a platform callback.
def cancellableRunTrace
    (cancelBeforePull cancelAfterPull cancelAfterPublish pullOK publishOK : Bool) :
    List Nat :=
  if cancelBeforePull then []
  else if !pullOK || cancelAfterPull then [0]
  else if !publishOK || cancelAfterPublish then [0, 1]
  else [0, 1, 2]

theorem cancelledPullCannotReachPublish
    (cancelAfterPublish pullOK publishOK : Bool) :
    cancellableRunTrace false true cancelAfterPublish pullOK publishOK = [0] := by
  simp [cancellableRunTrace]

theorem cancelledPublishCannotRecordCompletion (publishOK : Bool) :
    cancellableRunTrace false false true true publishOK = [0, 1] := by
  simp [cancellableRunTrace]

theorem alreadyCancelledRunDoesNothing (pullOK publishOK : Bool) :
    cancellableRunTrace true false false pullOK publishOK = [] := by
  simp [cancellableRunTrace]

-- Both apps use the shared once gate for their optional initial sync. A
-- failed attempt is retryable; successful completion closes the gate.
def initialSyncCompletedAfterAttempt (completed succeeded : Bool) : Bool :=
  completed || succeeded

theorem failedInitialSyncCanRetry :
    initialSyncCompletedAfterAttempt false false = false := by
  rfl

theorem successfulInitialSyncClosesGate :
    initialSyncCompletedAfterAttempt false true = true := by
  rfl

theorem completedInitialSyncStaysComplete (succeeded : Bool) :
    initialSyncCompletedAfterAttempt true succeeded = true := by
  cases succeeded <;> rfl

def initialSyncCallerMayContinue (completed cancelled : Bool) : Bool :=
  completed && !cancelled

theorem cancelledInitialSyncWaiterCannotContinue (completed : Bool) :
    initialSyncCallerMayContinue completed true = false := by
  cases completed <;> rfl

inductive DefaultModuleSyncAction where
  | localOnly | pullRemote | unavailable
  deriving DecidableEq

def defaultModuleSyncAction
    (backendConfigured storageAvailable : Bool) : DefaultModuleSyncAction :=
  if !backendConfigured then .localOnly
  else if storageAvailable then .pullRemote else .unavailable

theorem localOnlyDefaultModuleSkipsRemote (storageAvailable : Bool) :
    defaultModuleSyncAction false storageAvailable = .localOnly := by
  cases storageAvailable <;> rfl

theorem configuredUnavailableDefaultModuleDoesNotCreateLocalCopy :
    defaultModuleSyncAction true false = .unavailable := by
  rfl

-- iOS now treats the settings/archive pull and all module-type pulls as one
-- gate before any module publication. Individual local imports may still
-- have committed before the gate fails; the theorem concerns remote writes.
def moduleBatchTrace
    (earlierPullOK : Bool) (typePulls : List Bool) (publishOK : Bool) : List Nat :=
  runTrace (earlierPullOK && typePulls.all id) publishOK

theorem failedArchivePullStopsAllModulePublication
    (typePulls : List Bool) (publishOK : Bool) :
    moduleBatchTrace false typePulls publishOK = [0] := by
  simp [moduleBatchTrace, runTrace]

theorem failedModuleTypePullStopsBatchPublication
    (earlierPullOK publishOK : Bool) (typePulls : List Bool)
    (failed : typePulls.all id = false) :
    moduleBatchTrace earlierPullOK typePulls publishOK = [0] := by
  simp [moduleBatchTrace, failed, runTrace]

-- The foreground coordinator's legacy editable reconciliation only pulls.
-- The module pass runs afterward in the same shared engine pull phase.
def foregroundReconciliationTrace
    (editablePulls : List Bool) (laterPublishOK : Bool) : List Nat :=
  runTrace (editablePulls.all id) laterPublishOK

theorem failedEditablePullCannotStartForegroundPublication
    (editablePulls : List Bool) (laterPublishOK : Bool)
    (failed : editablePulls.all id = false) :
    foregroundReconciliationTrace editablePulls laterPublishOK = [0] := by
  simp [foregroundReconciliationTrace, failed, runTrace]

-- The iOS full pass imports the archive and pulls every module type before
-- publishing settings, shared preferences, or pending modules. The later
-- writes are still separate conditional operations.
def iosFullPassTrace
    (archivePullOK : Bool) (modulePulls : List Bool)
    (settingsPublishOK preferencesPublishOK modulesPublishOK : Bool) : List Nat :=
  if archivePullOK && modulePulls.all id then
    if settingsPublishOK then
      if preferencesPublishOK then
        if modulesPublishOK then [0, 1, 2, 3, 4] else [0, 1, 2, 3]
      else [0, 1, 2]
    else [0, 1]
  else [0]

theorem failedModulePullPreventsSettingsPublication
    (archivePullOK settingsPublishOK preferencesPublishOK modulesPublishOK : Bool)
    (modulePulls : List Bool) (failed : modulePulls.all id = false) :
    iosFullPassTrace archivePullOK modulePulls settingsPublishOK
      preferencesPublishOK modulesPublishOK = [0] := by
  simp [iosFullPassTrace, failed]

theorem failedArchivePullPreventsAllIOSPublication
    (modulePulls : List Bool)
    (settingsPublishOK preferencesPublishOK modulesPublishOK : Bool) :
    iosFullPassTrace false modulePulls settingsPublishOK
      preferencesPublishOK modulesPublishOK = [0] := by
  simp [iosFullPassTrace]

-- The foreground coordinator exports all editable legacy modules only after
-- archive and module pulls, settings, preferences, and module publication.
def foregroundLegacyExportAllowed
    (editablePulls modulePulls : List Bool)
    (archivePullOK settingsPublishOK preferencesPublishOK modulesPublishOK : Bool) : Bool :=
  editablePulls.all id && archivePullOK && modulePulls.all id &&
    settingsPublishOK && preferencesPublishOK && modulesPublishOK

theorem failedModulePullPreventsLegacyExport
    (editablePulls modulePulls : List Bool)
    (archivePullOK settingsPublishOK preferencesPublishOK modulesPublishOK : Bool)
    (failed : modulePulls.all id = false) :
    foregroundLegacyExportAllowed editablePulls modulePulls archivePullOK
      settingsPublishOK preferencesPublishOK modulesPublishOK = false := by
  simp [foregroundLegacyExportAllowed, failed]

-- The foreground coordinator and module manager share one top-level runner. Its pull
-- callback includes optional legacy reconciliation, archive import, and all
-- module types; its publish callback includes settings, preferences, modules,
-- optional legacy export, and a final settings reconciliation. The settings
-- operation has its own inner runner and can commit its baseline before a
-- later module write fails. Top-level completion is entered only after every
-- preceding callback succeeds.
def iosForegroundSinglePassTrace
    (editablePulls modulePulls : List Bool)
    (archivePullOK settingsPublishOK preferencesPublishOK modulesPublishOK
      legacyExportOK pendingSettingsOK : Bool) : List Nat :=
  runTrace
    (editablePulls.all id && archivePullOK && modulePulls.all id)
    (settingsPublishOK && preferencesPublishOK && modulesPublishOK &&
      legacyExportOK && pendingSettingsOK)

theorem failedForegroundModulePullStopsBeforePublish
    (editablePulls modulePulls : List Bool)
    (archivePullOK settingsPublishOK preferencesPublishOK modulesPublishOK
      legacyExportOK pendingSettingsOK : Bool)
    (failed : modulePulls.all id = false) :
    iosForegroundSinglePassTrace editablePulls modulePulls archivePullOK
      settingsPublishOK preferencesPublishOK modulesPublishOK legacyExportOK
      pendingSettingsOK = [0] := by
  simp [iosForegroundSinglePassTrace, runTrace, failed]

theorem failedForegroundLegacyExportCannotComplete
    (editablePulls modulePulls : List Bool)
    (settingsPublishOK preferencesPublishOK modulesPublishOK pendingSettingsOK : Bool)
    (editableOK : editablePulls.all id = true)
    (modulesOK : modulePulls.all id = true) :
    iosForegroundSinglePassTrace editablePulls modulePulls true
      settingsPublishOK preferencesPublishOK modulesPublishOK false
      pendingSettingsOK = [0, 1] := by
  simp [iosForegroundSinglePassTrace, runTrace, editableOK, modulesOK]

theorem settingsCanCommitBeforeLaterModuleFailure :
    iosFullPassTrace true [] true true false = [0, 1, 2, 3] := by
  decide

-- The coordinator exposes a new endpoint or completion marker in memory
-- only after UserDatabase has persisted the same settings value.
def iosVisibleSettingsAfterPersist
    (current selected : Nat) (persistSucceeded : Bool) : Nat :=
  if persistSucceeded then selected else current

theorem failedIOSSettingsPersistKeepsVisibleChoice
    (current selected : Nat) :
    iosVisibleSettingsAfterPersist current selected false = current := by
  rfl

theorem successfulIOSSettingsPersistExposesChoice
    (current selected : Nat) :
    iosVisibleSettingsAfterPersist current selected true = selected := by
  rfl

-- iOS inspects every portable archive module before installing the first.
-- A malformed later body therefore leaves the local library as it was.
def iosArchiveAfterInspection
    (installed candidate : List Nat) (valid : List Bool) : List Nat :=
  if valid.all id then candidate else installed

theorem invalidLaterArchiveModuleCannotInstallPrefix
    (installed candidate : List Nat) :
    iosArchiveAfterInspection installed candidate [true, false] = installed := by
  simp [iosArchiveAfterInspection]

-- A book identity row is insufficient for installation: the importer also
-- needs its parent columns and complete sections table.
def bookImportSchemaValid (parentColumns sectionsColumns : Bool) : Bool :=
  parentColumns && sectionsColumns

def bookInspectionAllows
    (requireImportSchema parentColumns sectionsColumns : Bool) : Bool :=
  !requireImportSchema || bookImportSchemaValid parentColumns sectionsColumns

theorem identityOnlyBookInspectionKeepsLegacySchema
    (parentColumns sectionsColumns : Bool) :
    bookInspectionAllows false parentColumns sectionsColumns = true := by
  simp [bookInspectionAllows]

theorem archiveBookInspectionRejectsMissingSections :
    bookInspectionAllows true true false = false := by
  rfl

theorem missingLaterBookSectionsCannotInstallPrefix
    (installed candidate : List Nat) :
    iosArchiveAfterInspection installed candidate
      [true, bookImportSchemaValid true false] = installed := by
  simp [iosArchiveAfterInspection, bookImportSchemaValid]

-- Every iOS archive candidate now checks the columns read by its selected
-- import schema before the first candidate installs. Identity-only inspection
-- used by other callers does not impose that stricter schema contract.
def importSchemaAllows (requireImportSchema : Bool) (requiredColumns : List Bool) : Bool :=
  !requireImportSchema || requiredColumns.all id

theorem identityOnlyModuleInspectionKeepsLegacySchema (columns : List Bool) :
    importSchemaAllows false columns = true := by
  simp [importSchemaAllows]

theorem missingLaterImportColumnCannotInstallPrefix
    (installed candidate : List Nat) (columns : List Bool)
    (h : columns.all id = false) :
    iosArchiveAfterInspection installed candidate
      [true, importSchemaAllows true columns] = installed := by
  simp [iosArchiveAfterInspection, importSchemaAllows, h]

-- Compiled plans carry content columns but omit local installation fields.
-- The iOS importer supplies path, revision, and timestamps from the observed
-- archive entry, so those source-only columns are not a preflight requirement.
def planSourceUsable (contentColumns _localInstallColumns : Bool) : Bool :=
  contentColumns

theorem compiledPlanWithoutLocalColumnsCanImport :
    planSourceUsable true false = true := by
  rfl

theorem planMissingContentColumnsCannotImport (localColumns : Bool) :
    planSourceUsable false localColumns = false := by
  rfl

-- iOS now prepares every source before opening one local transaction. A
-- preparation error or any SQL error in the batch leaves the installed state
-- unchanged; only a successful commit exposes the entire candidate state.
def iosArchiveBatchCommit
    (installed : List Nat) (prepared : Option (List Nat)) (sqlOK : Bool) : List Nat :=
  if sqlOK then prepared.getD installed else installed

theorem failedIOSArchivePreparationKeepsInstalled
    (installed : List Nat) (sqlOK : Bool) :
    iosArchiveBatchCommit installed none sqlOK = installed := by
  simp [iosArchiveBatchCommit]

theorem lateIOSArchiveSQLFailureKeepsInstalled
    (installed : List Nat) (prepared : Option (List Nat)) :
    iosArchiveBatchCommit installed prepared false = installed := by
  rfl

theorem successfulIOSArchiveCommitInstallsWholeCandidate
    (installed candidate : List Nat) :
    iosArchiveBatchCommit installed (some candidate) true = candidate := by
  rfl

-- The iOS archive importer leaves a newer local highlight set in place during
-- the transaction, including when its source is exposed through staging.
def iosArchiveHighlightRows
    (localTime remoteTime : Nat) (installed incoming : List Nat) : List Nat :=
  if localTime >= remoteTime then installed else incoming

theorem newerLocalHighlightsSurviveArchive
    (localTime remoteTime : Nat) (installed incoming : List Nat)
    (newer : localTime >= remoteTime) :
    iosArchiveHighlightRows localTime remoteTime installed incoming = installed := by
  simp [iosArchiveHighlightRows, newer]

-- The former per-module transaction could leave an installed prefix after a
-- later failure. This is a counterexample for that removed order.
def oldIOSArchiveLocalStateAfterLateFailure
    (_installed firstImported : List Nat) : List Nat :=
  firstImported

theorem sequentialIOSArchiveFailureCanLeaveLocalPrefix :
    oldIOSArchiveLocalStateAfterLateFailure [1] [1, 2] ≠ [1] := by
  decide

-- A cached local archive can replace a GET only when its installed modules
-- remain valid and the provider reports the same strong revision.
def archiveGetRequired
    (cacheValid strongRevision revisionMatches : Bool) : Bool :=
  !(cacheValid && strongRevision && revisionMatches)

theorem missingCacheRequiresArchiveGet (strongRevision revisionMatches : Bool) :
    archiveGetRequired false strongRevision revisionMatches = true := by
  simp [archiveGetRequired]

theorem weakRevisionRequiresArchiveGet (cacheValid revisionMatches : Bool) :
    archiveGetRequired cacheValid false revisionMatches = true := by
  simp [archiveGetRequired]

theorem changedRevisionRequiresArchiveGet (cacheValid strongRevision : Bool) :
    archiveGetRequired cacheValid strongRevision false = true := by
  simp [archiveGetRequired]

theorem matchingStrongCacheSkipsArchiveGet :
    archiveGetRequired true true true = false := by
  rfl

-- The shared module-folder listing removes directories and unsupported
-- filenames but keeps duplicate file observations. An absent folder is empty;
-- a listing failure remains an error that stops the pull.
structure ModuleFolderEntry where
  isDirectory : Bool
  supportedFilename : Bool
  deriving DecidableEq

def moduleFolderListing
    (response : Option (Option (List ModuleFolderEntry))) :
    Option (List ModuleFolderEntry) :=
  match response with
  | none => none
  | some none => some []
  | some (some entries) =>
      some (entries.filter fun entry => !entry.isDirectory && entry.supportedFilename)

theorem failedModuleFolderListingIsNotEmptySuccess :
    moduleFolderListing none = none := by rfl

theorem missingModuleFolderIsEmpty :
    moduleFolderListing (some none) = some [] := by rfl

theorem moduleFolderKeepsOnlySupportedFiles :
    moduleFolderListing (some (some [
      ⟨false, true⟩, ⟨true, true⟩, ⟨false, false⟩, ⟨false, true⟩
    ])) = some [⟨false, true⟩, ⟨false, true⟩] := by
  decide

-- Treating an unreadable iCloud directory as an empty successful listing
-- would allow publication. The adapter now throws so the pull stage fails.
theorem swallowedListingErrorCouldReachCompletion :
    runTrace true true = [0, 1, 2] ∧
    runTrace false true = [0] := by
  decide

theorem failedPublishStopsBeforeComplete :
    runTrace true false = [0, 1] := by
  simp [runTrace]

-- Mac folder publishing compares the whole observed tree before its first
-- write and then checks each file's observed bytes in its coordinated write.
-- The local file check is modeled as atomic with that one file write; this
-- does not give an atomic multi-file or cross-device transaction.
def folderPreflight (observed current : List (Nat × Nat)) : Bool :=
  observed == current

def folderFileWrite (observed current : Option Nat) (outgoing : Nat) : Option Nat :=
  if observed = current then some outgoing else none

theorem changedFolderStopsBeforeFirstWrite
    (observed current : List (Nat × Nat)) (h : observed ≠ current) :
    folderPreflight observed current = false := by
  simp [folderPreflight, h]

theorem changedFolderFileCannotBeReplaced
    (observed current : Option Nat) (outgoing : Nat)
    (h : observed ≠ current) :
    folderFileWrite observed current outgoing = none := by
  simp [folderFileWrite, h]

theorem newFolderFileCannotOverwriteConcurrentCreation
    (remote outgoing : Nat) :
    folderFileWrite none (some remote) outgoing = none := by
  simp [folderFileWrite]

theorem successfulRunReachesComplete :
    runTrace true true = [0, 1, 2] := by
  simp [runTrace]

-- Backend migration sends editable modules through the reconciled export.
-- Raw read-only files are created only when absent, and a different target
-- body is a conflict rather than permission to overwrite it.
inductive MigrationCopyAction where
  | publishMerged | create | alreadyPresent | conflict
  deriving DecidableEq

def migrationCopyAction
    (editable : Bool) (source : Nat) (destination : Option Nat) : MigrationCopyAction :=
  if editable then .publishMerged
  else match destination with
    | none => .create
    | some current => if current == source then .alreadyPresent else .conflict

def migrationRawWriteOccurs (action : MigrationCopyAction) : Bool :=
  action == .create

theorem editableMigrationNeverRawCopies (source : Nat) (destination : Option Nat) :
    migrationRawWriteOccurs (migrationCopyAction true source destination) = false := by
  simp [migrationRawWriteOccurs, migrationCopyAction]

theorem absentReadOnlyDestinationMayBeCreated (source : Nat) :
    migrationCopyAction false source none = .create := by
  rfl

theorem identicalReadOnlyDestinationNeedsNoWrite (source : Nat) :
    migrationCopyAction false source (some source) = .alreadyPresent := by
  simp [migrationCopyAction]

theorem divergentReadOnlyDestinationIsConflict
    (source destination : Nat) (different : source ≠ destination) :
    migrationCopyAction false source (some destination) = .conflict := by
  simp [migrationCopyAction, Ne.symm different]

theorem divergentReadOnlyMigrationStopsBeforeBackendPublish
    (source destination : Nat) (different : source ≠ destination) :
    runTrace (migrationCopyAction false source (some destination) != .conflict) true = [0] := by
  simp [divergentReadOnlyDestinationIsConflict source destination different,
    runTrace]

-- iOS's Switch Only operation persists the new provider configuration after
-- remote publication, then wipes local modules, then activates the provider.
-- Keeping the wipe in the pull stage would delete modules on publish failure.
def earlyBackendWipe (requested pullOK : Bool) : Bool := requested && pullOK

def deferredBackendWipe (requested pullOK publishOK persistOK : Bool) : Bool :=
  if 2 ∈ runTrace pullOK publishOK then requested && persistOK else false

theorem failedBackendPublishCannotWipe (requested persistOK : Bool) :
    deferredBackendWipe requested true false persistOK = false := by
  simp [deferredBackendWipe, runTrace]

theorem failedBackendPullCannotWipe (requested publishOK persistOK : Bool) :
    deferredBackendWipe requested false publishOK persistOK = false := by
  simp [deferredBackendWipe, runTrace]

theorem failedBackendPersistenceCannotWipe (requested pullOK publishOK : Bool) :
    deferredBackendWipe requested pullOK publishOK false = false := by
  cases pullOK <;> cases publishOK <;> simp [deferredBackendWipe, runTrace]

theorem successfulSwitchOnlyMayWipe :
    deferredBackendWipe true true true true = true := by
  simp [deferredBackendWipe, runTrace]

theorem earlyWipeLosesDataOnFailedPublish :
    earlyBackendWipe true true = true ∧
    deferredBackendWipe true true false true = false := by
  simp [earlyBackendWipe, deferredBackendWipe, runTrace]

def backendActivationOccurs (pullOK publishOK persistOK wipeRequested wipeOK : Bool) : Bool :=
  pullOK && publishOK && persistOK && (!wipeRequested || wipeOK)

theorem failedBackendWipeCannotActivate (pullOK publishOK persistOK : Bool) :
    backendActivationOccurs pullOK publishOK persistOK true false = false := by
  simp [backendActivationOccurs]

theorem successfulMigrationCanActivate (pullOK publishOK : Bool)
    (hPull : pullOK = true) (hPublish : publishOK = true) :
    backendActivationOccurs pullOK publishOK true false false = true := by
  simp [backendActivationOccurs, hPull, hPublish]

def localDataWiped (pullOK publishOK persistOK wipeOK : Bool) : Bool :=
  deferredBackendWipe true pullOK publishOK persistOK && wipeOK

theorem failedPersistenceLeavesLocalData (pullOK publishOK wipeOK : Bool) :
    localDataWiped pullOK publishOK false wipeOK = false := by
  simp [localDataWiped, failedBackendPersistenceCannotWipe]

def rollbackAttempted (pullOK publishOK persistOK wipeOK : Bool) : Bool :=
  deferredBackendWipe true pullOK publishOK persistOK && !wipeOK

theorem failedWipeRequestsBackendRollback :
    rollbackAttempted true true true false = true ∧
    backendActivationOccurs true true true true false = false := by
  simp [rollbackAttempted, deferredBackendWipe,
    backendActivationOccurs, runTrace]

-- The local module database holds the previous provider before the provider
-- database changes. Its wipe transaction deletes content and marker together.
-- A remaining marker suspends sync until restoring the previous provider.
def pendingBackendMarker (prepared wipeCommitted rollbackCleared : Bool) : Bool :=
  prepared && !wipeCommitted && !rollbackCleared

def newBackendAvailable (persisted wipeCommitted markerPresent : Bool) : Bool :=
  persisted && wipeCommitted && !markerPresent

theorem committedBackendWipeClearsMarker (rollbackCleared : Bool) :
    pendingBackendMarker true true rollbackCleared = false := by
  simp [pendingBackendMarker]

theorem failedBackendWipeRetainsMarker :
    pendingBackendMarker true false false = true := by
  simp [pendingBackendMarker]

theorem pendingMarkerSuspendsNewBackend (persisted wipeCommitted : Bool) :
    newBackendAvailable persisted wipeCommitted true = false := by
  simp [newBackendAvailable]

theorem failedWipeCannotExposeNewBackend (persisted rollbackCleared : Bool) :
    newBackendAvailable persisted false
      (pendingBackendMarker true false rollbackCleared) = false := by
  simp [newBackendAvailable]

-- A wiped editable module must not be treated as installed merely because
-- its registry row and the remote archive revision are unchanged. iOS clears
-- file_hash with the rows, then requires a hash to skip an archive import.
def maySkipEditableArchiveImport
    (sameArchiveRevision modulePresent localHashPresent : Bool) : Bool :=
  sameArchiveRevision && modulePresent && localHashPresent

theorem wipedEditableHashForcesArchiveImport
    (sameArchiveRevision modulePresent : Bool) :
    maySkipEditableArchiveImport sameArchiveRevision modulePresent false = false := by
  simp [maySkipEditableArchiveImport]

-- Compatibility files are a sequence of conditional writes after the archive
-- commit. A failed write leaves its successful prefix committed and prevents
-- all later writes and the runner's completion stage.
def mirrorAttempts : List Bool → List Bool
  | [] => []
  | success :: rest =>
      if success then true :: mirrorAttempts rest else [false]

theorem failedMirrorStopsLaterWrites (remaining : List Bool) :
    mirrorAttempts (false :: remaining) = [false] := by
  simp [mirrorAttempts]

-- Mac puts devotional attachment PUTs before the compatible devotional
-- module PUT, so a failed attachment cannot publish a dangling folder module.
theorem failedDevotionalMediaStopsModuleMirror (moduleWrite : Bool) :
    mirrorAttempts [false, moduleWrite] = [false] := by
  rfl

-- For an immutable attachment path, `some true` means a conditional create,
-- `some false` means the remote bytes already match, and `none` is a conflict.
def devotionalMediaUploadDecision (remote : Option Nat) (authored : Nat) : Option Bool :=
  match remote with
  | none => some true
  | some value => if value == authored then some false else none

theorem missingDevotionalMediaRequiresConditionalCreate (authored : Nat) :
    devotionalMediaUploadDecision none authored = some true := by
  rfl

theorem identicalDevotionalMediaNeedsNoWrite (authored : Nat) :
    devotionalMediaUploadDecision (some authored) authored = some false := by
  simp [devotionalMediaUploadDecision]

theorem conflictingDevotionalMediaCannotPublish (remote authored : Nat)
    (h : remote ≠ authored) :
    devotionalMediaUploadDecision (some remote) authored = none := by
  simp [devotionalMediaUploadDecision, h]

theorem folderBatchCanCommitPrefixBeforeFailure :
    mirrorAttempts [true, false, true] = [true, false] := by
  rfl

theorem successfulMirrorsBeforeFailureRemainAttempted
    (count : Nat) (remaining : List Bool) :
    mirrorAttempts (List.replicate count true ++ (false :: remaining)) =
      List.replicate count true ++ [false] := by
  induction count with
  | zero => simp [mirrorAttempts]
  | succ count ih => simpa [List.replicate_succ, mirrorAttempts] using congrArg (List.cons true) ih

def mirrorBatchSucceeds : List Bool → Bool
  | [] => true
  | success :: rest => success && mirrorBatchSucceeds rest

theorem failedMirrorPreventsCompletion (initial remaining : List Bool) :
    runTrace true (mirrorBatchSucceeds (initial ++ (false :: remaining))) = [0, 1] := by
  have failure : mirrorBatchSucceeds (initial ++ (false :: remaining)) = false := by
    induction initial with
    | nil => simp [mirrorBatchSucceeds]
    | cons success rest ih =>
        cases success <;> simp [mirrorBatchSucceeds, ih]
  simp [failure, runTrace]

-- iOS keeps unresolved module record conflicts in its local database. A
-- matching remote hash is not permission to publish while any row remains.
-- For iCloud, the hash comparison is a preflight and cannot make the later
-- provider write atomic.
def editableModuleExportAllowed
    (pendingConflicts : List Nat) (expected observed : Option Nat) : Bool :=
  pendingConflicts.isEmpty && expected == observed

theorem pendingModuleConflictBlocksExport
    (key : Nat) (rest : List Nat) (expected observed : Option Nat) :
    editableModuleExportAllowed (key :: rest) expected observed = false := by
  simp [editableModuleExportAllowed]

theorem matchedModuleRevisionAllowsResolvedExport (revision : Nat) :
    editableModuleExportAllowed [] (some revision) (some revision) = true := by
  simp [editableModuleExportAllowed]

theorem changedModuleRevisionBlocksResolvedExport
    (expected observed : Option Nat) (h : expected ≠ observed) :
    editableModuleExportAllowed [] expected observed = false := by
  simp [editableModuleExportAllowed, h]

theorem oneResolvedConflictCannotReleaseOther (expected observed : Option Nat) :
    editableModuleExportAllowed [2] expected observed = false := by
  simp [editableModuleExportAllowed]

def resolvedRecordRevision (device incoming now : Nat) : Nat :=
  max now (max device incoming) + 1

theorem resolvedRecordRevisionExceedsBoth (device incoming now : Nat) :
    device < resolvedRecordRevision device incoming now ∧
    incoming < resolvedRecordRevision device incoming now := by
  constructor
  · apply Nat.lt_succ_of_le
    exact Nat.le_trans (Nat.le_max_left device incoming)
      (Nat.le_max_right now (max device incoming))
  · apply Nat.lt_succ_of_le
    exact Nat.le_trans (Nat.le_max_right device incoming)
      (Nat.le_max_right now (max device incoming))

-- A resolved choice and any locally retained newer row need publication.
-- The local marker survives failed writes and disappears only after success.
def pendingPublicationAfterMerge (previous localKept : Bool) : Bool :=
  previous || localKept

def pendingPublicationAfterWrite (pending writeSucceeded : Bool) : Bool :=
  pending && !writeSucceeded

theorem locallyKeptRowRequiresPublication (previous : Bool) :
    pendingPublicationAfterMerge previous true = true := by
  simp [pendingPublicationAfterMerge]

theorem failedModuleWriteRetainsPublication (pending : Bool) :
    pendingPublicationAfterWrite pending false = pending := by
  simp [pendingPublicationAfterWrite]

theorem successfulModuleWriteClearsPublication (pending : Bool) :
    pendingPublicationAfterWrite pending true = false := by
  simp [pendingPublicationAfterWrite]

-- The format model covers the canonical .lamp and legacy .json case. Swift
-- also ranks .db.zlib and .db between them.
inductive ModuleFormat where
  | lamp | json
  deriving DecidableEq

def selectModuleFormat
    (_installed : Option ModuleFormat) (hasLamp hasJSON : Bool) : Option ModuleFormat :=
  if hasLamp then some .lamp else if hasJSON then some .json else none

theorem canonicalFileWinsOverInstalledLegacy :
    selectModuleFormat (some .json) true true = some .lamp := by
  rfl

theorem freshModulePrefersCanonicalFile :
    selectModuleFormat none true true = some .lamp := by
  rfl

theorem legacyUsedWhenCanonicalMissing :
    selectModuleFormat (some .lamp) false true = some .json := by
  rfl

-- A legacy JSON envelope may contain several module identities. Choosing a
-- canonical successor for one identity must not discard the others.
def selectModuleFormatForIdentity
    (identity : Nat) (files : List (Nat × ModuleFormat)) : Option ModuleFormat :=
  selectModuleFormat none
    (files.any fun file => if file.1 = identity ∧ file.2 = .lamp then true else false)
    (files.any fun file => if file.1 = identity ∧ file.2 = .json then true else false)

theorem aggregateJSONKeepsUnshadowedModule :
    selectModuleFormatForIdentity 1 [(1, .json), (2, .json), (1, .lamp)] = some .lamp ∧
    selectModuleFormatForIdentity 2 [(1, .json), (2, .json), (1, .lamp)] = some .json := by
  decide

structure ModuleCandidate where
  identity : Nat
  format : ModuleFormat
  superseded : Bool
  deriving DecidableEq

def selectCurrentModuleFormatForIdentity
    (identity : Nat) (files : List ModuleCandidate) : Option ModuleFormat :=
  selectModuleFormatForIdentity identity
    ((files.filter fun file => !file.superseded).map fun file =>
      (file.identity, file.format))

theorem supersededCanonicalCannotHideActiveLegacy :
    selectCurrentModuleFormatForIdentity 1 [
      ⟨1, .lamp, true⟩, ⟨1, .json, false⟩
    ] = some .json := by
  decide

theorem whollySupersededIdentityUsesArchive :
    selectCurrentModuleFormatForIdentity 1 [
      ⟨1, .lamp, true⟩, ⟨1, .json, true⟩
    ] = none := by
  decide

-- After format ranking, both apps now take the first active occurrence of
-- that identity and format. The Swift selector also compares full paths.
def firstActiveCandidateIndex (identity : Nat) (format : ModuleFormat) :
    List ModuleCandidate → Nat → Option Nat
  | [], _ => none
  | candidate :: rest, index =>
      if candidate.identity == identity && candidate.format == format
          && !candidate.superseded then
        some index
      else firstActiveCandidateIndex identity format rest (index + 1)

def selectedCandidateIndexForIdentity
    (identity : Nat) (files : List ModuleCandidate) : Option Nat :=
  match selectCurrentModuleFormatForIdentity identity files with
  | none => none
  | some format => firstActiveCandidateIndex identity format files 0

theorem duplicateSupersededPathChoosesActiveOccurrence :
    selectedCandidateIndexForIdentity 1 [
      ⟨1, .lamp, true⟩, ⟨1, .lamp, false⟩, ⟨1, .lamp, false⟩
    ] = some 1 := by
  decide

def moduleNeedsImport
    (isNew samePath hasRemoteRevision sameRevision : Bool) : Bool :=
  isNew || !samePath || !hasRemoteRevision || !sameRevision

theorem changedModulePathRequiresImport
    (isNew hasRemoteRevision sameRevision : Bool) :
    moduleNeedsImport isNew false hasRemoteRevision sameRevision = true := by
  simp [moduleNeedsImport]

theorem unchangedModulePathAndRevisionMaySkip :
    moduleNeedsImport false true true true = false := by
  rfl

theorem missingRemoteRevisionRequiresImport
    (isNew samePath sameRevision : Bool) :
    moduleNeedsImport isNew samePath false sameRevision = true := by
  simp [moduleNeedsImport]

theorem weakETagCannotSkipModuleImport :
    moduleNeedsImport false true
      (strongETagBytes [87, 47, 34, 97, 34]) true = true := by
  decide

-- The module listing chooses which path to import. The saved revision must
-- come from the same GET as the imported bytes, or from those exact bytes for
-- iCloud. A listing revision may describe an earlier body.
def pairedModuleImport (_listedRevision : Option Nat)
    (getRevision getBody : Nat) : Nat × Nat :=
  (getRevision, getBody)

theorem changedModuleBetweenListAndGetUsesGetRevision
    (listed getRevision getBody : Nat) (different : listed ≠ getRevision) :
    (pairedModuleImport (some listed) getRevision getBody).1 ≠ listed := by
  simp [pairedModuleImport, Ne.symm different]

def contentModuleImport (body : Nat) : Nat × Nat := (body, body)

theorem iCloudModuleRevisionDescribesReadBody (body : Nat) :
    (contentModuleImport body).1 = (contentModuleImport body).2 := by
  rfl

-- Read-only JSON replacement checks decode and payload identity before its
-- database transaction. Failure leaves the installed rows as the result.
def replaceReadOnlyRows
    (installed incoming : Nat) (decoded identityMatches : Bool) : Nat :=
  if decoded && identityMatches then incoming else installed

theorem invalidRemoteJSONKeepsInstalledRows (installed incoming : Nat) :
    replaceReadOnlyRows installed incoming false true = installed := by
  rfl

theorem mismatchedModuleIdentityKeepsInstalledRows (installed incoming : Nat) :
    replaceReadOnlyRows installed incoming true false = installed := by
  rfl

inductive ModuleInspection where
  | matched | mismatched | missingIdentity | damaged
  deriving DecidableEq

def sqliteImportAllowed (canonical : Bool) (inspection : ModuleInspection) : Bool :=
  match inspection with
  | .matched => true
  | .missingIdentity => !canonical
  | .mismatched | .damaged => false

theorem canonicalModuleRequiresEmbeddedIdentity :
    sqliteImportAllowed true .missingIdentity = false := by
  rfl

theorem legacyModuleWithoutIdentityCanUseFilename :
    sqliteImportAllowed false .missingIdentity = true := by
  rfl

theorem damagedOrMismatchedSQLiteCannotReplace (canonical : Bool) :
    sqliteImportAllowed canonical .damaged = false ∧
    sqliteImportAllowed canonical .mismatched = false := by
  constructor <;> rfl

-- Shared remote inspection grants one canonical exception to old compact
-- highlight archives. A wrong declared kind or damaged body never falls back.
def remoteSQLiteImportAllowed
    (canonical compactHighlight schemaMatches : Bool)
    (inspection : ModuleInspection) : Bool :=
  match inspection with
  | .matched => true
  | .missingIdentity => (!canonical || compactHighlight) && schemaMatches
  | .mismatched | .damaged => false

theorem legacyCompactHighlightMayUseListedID :
    remoteSQLiteImportAllowed true true true .missingIdentity = true := by
  rfl

theorem canonicalOtherModuleNeedsStoredID :
    remoteSQLiteImportAllowed true false true .missingIdentity = false := by
  rfl

theorem unrelatedSchemaCannotUseLegacyFallback
    (canonical compactHighlight : Bool) :
    remoteSQLiteImportAllowed canonical compactHighlight false .missingIdentity = false := by
  simp [remoteSQLiteImportAllowed]

theorem wrongKindOrDamagedRemoteCannotFallBack
    (canonical compactHighlight schemaMatches : Bool) :
    remoteSQLiteImportAllowed canonical compactHighlight schemaMatches .mismatched = false ∧
    remoteSQLiteImportAllowed canonical compactHighlight schemaMatches .damaged = false := by
  constructor <;> rfl

-- ATTACH happens outside the write transaction; retiring old rows and copying
-- replacements happen inside it. `none` represents a failed source copy.
def sqliteReplacementResult (installed : Nat) (replacement : Option Nat) : Nat :=
  replacement.getD installed

theorem failedSQLiteCopyKeepsInstalledRows (installed : Nat) :
    sqliteReplacementResult installed none = installed := by
  rfl

-- Read-only row copy and dictionary/book registry metadata now commit in the
-- same SQLite transaction. A metadata error rolls the copied rows back too.
def sqliteCopyWithMetadata
    (installed : Nat) (copied : Option Nat) (metadataOK : Bool) : Nat :=
  if metadataOK then copied.getD installed else installed

theorem failedMetadataSaveKeepsInstalledRows
    (installed copied : Nat) :
    sqliteCopyWithMetadata installed (some copied) false = installed := by
  rfl

def oldSQLiteReplacementResult (_installed : Nat) (replacement : Option Nat) : Nat :=
  replacement.getD 0

theorem earlySQLiteDeleteLosesRows :
    oldSQLiteReplacementResult 1 none ≠ 1 := by
  decide

-- A payload header alone cannot authorize copying rows with another owner.
-- The importer checks all present owner columns before any local replacement.
def ownedSQLiteRows (expected : Nat) (owners : List Nat) : Bool :=
  owners.all (· == expected)

def ownedSQLiteReplacement
    (expected : Nat) (owners : List Nat) (installed incoming : Nat) : Nat :=
  if ownedSQLiteRows expected owners then incoming else installed

theorem foreignSQLiteOwnerKeepsInstalled
    (expected foreign installed incoming : Nat) (different : foreign ≠ expected) :
    ownedSQLiteReplacement expected [expected, foreign] installed incoming = installed := by
  simp [ownedSQLiteReplacement, ownedSQLiteRows, different]

theorem ownedSQLiteRowsAllowReplacement (expected installed incoming : Nat) :
    ownedSQLiteReplacement expected [expected] installed incoming = incoming := by
  simp [ownedSQLiteReplacement, ownedSQLiteRows]

-- Compact highlight_meta.id names the set. New files carry their module ID in
-- module_format; legacy files use the known file path for that ID. The set ID
-- must not be promoted into a module identity during inspection.
def compactHighlightModuleID (header : Option Nat) (_setID : Nat) : Option Nat :=
  header

theorem compactHighlightSetIDCannotSupplyModuleID (setID : Nat) :
    compactHighlightModuleID none setID = none := by
  rfl

theorem canonicalHighlightUsesHeaderID (moduleID setID : Nat) :
    compactHighlightModuleID (some moduleID) setID = some moduleID := by
  rfl

-- Mac personal archive import and shared full-highlight inspection prefer a
-- stored module owner over the temporary download filename when no header is
-- present. Compact highlights have neither and keep the caller's path ID.
def personalStudyModuleID
    (header metadata : Option Nat) (filenameID : Nat) : Nat :=
  match header with
  | some moduleID => moduleID
  | none => metadata.getD filenameID

theorem legacyPersonalStudyUsesMetadata
    (moduleID filenameID : Nat) :
    personalStudyModuleID none (some moduleID) filenameID = moduleID := by
  rfl

theorem compactHighlightUsesKnownFilename (filenameID : Nat) :
    personalStudyModuleID none none filenameID = filenameID := by
  rfl

def personalStudyArchiveImport
    (expected : Nat) (owners : List Nat) (installed incoming : Nat) : Nat :=
  ownedSQLiteReplacement expected owners installed incoming

theorem foreignPersonalStudyRowCannotMerge
    (expected foreign installed incoming : Nat) (different : foreign ≠ expected) :
    personalStudyArchiveImport expected [expected, foreign] installed incoming = installed := by
  simp [personalStudyArchiveImport, ownedSQLiteReplacement, ownedSQLiteRows, different]

-- A plain INSERT fails on a foreign primary-key collision. SQLite and JSON
-- import paths both roll back the enclosing replacement transaction.
def collisionSafeReplacement
    (installed incoming : Nat) (foreignKeyCollision : Bool) : Nat :=
  sqliteReplacementResult installed (if foreignKeyCollision then none else some incoming)

theorem foreignImportKeyCollisionKeepsInstalled (installed incoming : Nat) :
    collisionSafeReplacement installed incoming true = installed := by
  rfl

-- Editable SQLite and JSON reconciliation now save metadata, merged entries,
-- conflict records, and the publication marker in one database transaction.
structure EditableSyncState where
  revision : Nat
  rows : Nat
  conflicts : Nat
  publicationPending : Bool
  deriving DecidableEq, Repr

def editableCommit
    (installed : EditableSyncState) (prepared : Option EditableSyncState) :
    EditableSyncState :=
  prepared.getD installed

theorem failedEditableMergePreservesWholeState
    (installed : EditableSyncState) :
    editableCommit installed none = installed := by
  rfl

-- Mac portable backups are imported into a sibling library first. A failed
-- item discards that stage; only a complete stage replaces the local root.
def stagedBackupImport (installed : List Nat) (prepared : Option (List Nat)) : List Nat :=
  prepared.getD installed

theorem failedStagedBackupImportKeepsLibrary (installed : List Nat) :
    stagedBackupImport installed none = installed := by
  rfl

theorem completedStagedBackupImportUsesWholeLibrary
    (installed incoming : List Nat) :
    stagedBackupImport installed (some incoming) = incoming := by
  rfl

def guardedStagedBackupCommit
    (base current incoming : List Nat) : Option (List Nat) :=
  if base == current then some incoming else none

theorem changedLocalLibraryRejectsStagedCommit
    (base current incoming : List Nat) (changed : base ≠ current) :
    guardedStagedBackupCommit base current incoming = none := by
  simp [guardedStagedBackupCommit, changed]

theorem unchangedLocalLibraryAcceptsStagedCommit
    (base incoming : List Nat) :
    guardedStagedBackupCommit base base incoming = some incoming := by
  simp [guardedStagedBackupCommit]

-- A Mac pull stages archive rows, canonical iOS rows, workspaces, and
-- settings before applying any of them to the live library/defaults. This
-- models the logical success or failure path, not a process crash between
-- the filesystem swap and the UserDefaults writes.
structure MacPullState where
  library : List Nat
  workspaces : List Nat
  settings : List Nat
  highlightMapping : List Nat
  deriving DecidableEq, Repr

def commitMacPull (installed : MacPullState) (prepared : Option MacPullState) :
    MacPullState :=
  prepared.getD installed

theorem failedMacPullKeepsEveryLocalPart (installed : MacPullState) :
    commitMacPull installed none = installed := by
  rfl

theorem completedMacPullUsesEveryPreparedPart
    (installed prepared : MacPullState) :
    commitMacPull installed (some prepared) = prepared := by
  rfl

def guardedMacPull
    (base current prepared : MacPullState) : Option MacPullState :=
  if base == current then some prepared else none

theorem changedMacLocalStateRejectsPreparedPull
    (base current prepared : MacPullState) (changed : base ≠ current) :
    guardedMacPull base current prepared = none := by
  simp [guardedMacPull, changed]

-- The library swap includes a durable settings journal. A crash can leave the
-- old defaults visible, but the next launch can replay the intended value.
-- A distinct edit after the swap blocks replay instead of being overwritten.
structure MacJournalState where
  library : Nat
  settings : Nat
  pending : Option (Nat × Nat)
  deriving DecidableEq, Repr

def swapMacLibraryWithJournal
    (installed : MacJournalState) (preparedLibrary preparedSettings : Nat) :
    MacJournalState :=
  { installed with
    library := preparedLibrary
    pending := some (installed.settings, preparedSettings) }

def recoverMacSettings (state : MacJournalState) : Option MacJournalState :=
  match state.pending with
  | none => some state
  | some (baseline, prepared) =>
      if state.settings == baseline || state.settings == prepared then
        some { state with settings := prepared, pending := none }
      else none

theorem swappedMacLibraryRetainsRecoveryJournal
    (installed : MacJournalState) (newLibrary newSettings : Nat) :
    (swapMacLibraryWithJournal installed newLibrary newSettings).settings =
      installed.settings ∧
    (swapMacLibraryWithJournal installed newLibrary newSettings).pending =
      some (installed.settings, newSettings) := by
  simp [swapMacLibraryWithJournal]

theorem pendingMacSettingsReplayCompletesPull
    (installed : MacJournalState) (newLibrary newSettings : Nat) :
    recoverMacSettings (swapMacLibraryWithJournal installed newLibrary newSettings) =
      some { library := newLibrary, settings := newSettings, pending := none } := by
  simp [recoverMacSettings, swapMacLibraryWithJournal]

theorem distinctMacSettingsEditBlocksReplay
    (baseline prepared changed library : Nat)
    (notBase : changed ≠ baseline) (notPrepared : changed ≠ prepared) :
    recoverMacSettings {
      library := library, settings := changed, pending := some (baseline, prepared)
    } = none := by
  simp [recoverMacSettings, notBase, notPrepared]

-- UserDefaults may contain a mixture of old and planned values after a crash
-- inside the per-key write loop. Each key, including an absent value, is
-- checked independently before any remaining writes are replayed.
structure MacSettingJournalKey where
  baseline : Option Nat
  planned : Option Nat
  current : Option Nat
  deriving DecidableEq

def macSettingKeysReplayable (keys : List MacSettingJournalKey) : Bool :=
  keys.all fun key => key.current == key.baseline || key.current == key.planned

def recoverMacSettingKeys (keys : List MacSettingJournalKey) :
    Option (List (Option Nat)) :=
  if macSettingKeysReplayable keys then some (keys.map (·.planned)) else none

theorem mixedMacSettingsReplayToWholePlan :
    recoverMacSettingKeys [
      ⟨some 16, some 19, some 19⟩,
      ⟨some 12, some 14, some 12⟩,
      ⟨some 1, none, some 1⟩
    ] = some [some 19, some 14, none] := by
  decide

theorem unrelatedMacSettingBlocksWholeReplay :
    recoverMacSettingKeys [
      ⟨some 16, some 19, some 19⟩,
      ⟨some 12, some 14, some 22⟩
    ] = none := by
  decide

theorem replayableMacSettingsReachPlannedValues
    (keys : List MacSettingJournalKey)
    (allowed : macSettingKeysReplayable keys = true) :
    recoverMacSettingKeys keys = some (keys.map (·.planned)) := by
  simp [recoverMacSettingKeys, allowed]

-- The former sequential loop could keep an earlier installed item after a
-- later item failed, even though publication was stopped.
def oldPartialBackupImport (_installed firstIncoming : List Nat) : List Nat :=
  firstIncoming

theorem laterBackupFailureCouldLeavePartialLocalLibrary :
    oldPartialBackupImport [1] [1, 2] ≠ [1] := by
  decide

-- Translation-schema replacement uses the same all-or-rollback result for
-- translation metadata, books, verses, and headings.
theorem failedTranslationSchemaReplacementKeepsInstalled
    (installed : EditableSyncState) :
    editableCommit installed none = installed := by
  rfl

def translationSchemaAllowed (validID translationType : Bool) : Bool :=
  validID && translationType

theorem wrongTranslationSchemaTypeCannotImport (validID : Bool) :
    translationSchemaAllowed validID false = false := by
  simp [translationSchemaAllowed]

theorem invalidTranslationSchemaIDCannotImport (translationType : Bool) :
    translationSchemaAllowed false translationType = false := by
  simp [translationSchemaAllowed]

-- After a coordinated upload, the saved baseline describes the body just
-- written. A later remote upload will then differ on the next observation;
-- rereading to choose the baseline could instead save that later body's hash.
def contentModuleExportRevision (writtenBody _laterRemoteBody : Nat) : Nat :=
  contentRevision writtenBody

theorem laterRemoteUploadDoesNotChangeExportRevision
    (writtenBody laterRemoteBody : Nat) :
    contentModuleExportRevision writtenBody laterRemoteBody =
      contentRevision writtenBody := by
  rfl

-- iOS settings bootstrap has one ordered decision before the ordinary
-- pull/merge/publish runner. A required missing file cannot be created, and
-- a fresh device adopts a remote file before considering local upload.
inductive SettingsBootstrapAction where
  | missing | create | adopt | guarded | merge
  deriving DecidableEq

def settingsBootstrap
    (remoteExists requireRemote hasBase hasToken fresh dirty : Bool) :
    SettingsBootstrapAction :=
  if !remoteExists then
    if requireRemote then .missing else .create
  else if !hasBase && !hasToken && fresh then .adopt
  else if !hasBase && dirty then .guarded
  else .merge

theorem requiredMissingSettingsCannotBeCreated
    (base token fresh dirty : Bool) :
    settingsBootstrap false true base token fresh dirty = .missing := by
  simp [settingsBootstrap]

theorem optionalMissingSettingsCreateRemote
    (base token fresh dirty : Bool) :
    settingsBootstrap false false base token fresh dirty = .create := by
  simp [settingsBootstrap]

theorem freshRemoteSettingsAdoptBeforeUpload (dirty : Bool) :
    settingsBootstrap true false false false true dirty = .adopt := by
  simp [settingsBootstrap]

theorem dirtySettingsWithoutBaseUseGuardedUpload (token : Bool) :
    settingsBootstrap true false false token false true = .guarded := by
  cases token <;> simp [settingsBootstrap]

theorem settingsWithBaseUseMerge (token fresh dirty : Bool) :
    settingsBootstrap true false true token fresh dirty = .merge := by
  simp [settingsBootstrap]

-- iCloud adapters now compare the observed body inside the coordinated
-- write callback. This guards local changes visible at that handoff; it
-- cannot guard a different device's later upload.
def coordinatedContentWriteAllowed
    (expected observed : Option Nat) : Bool :=
  expected == observed

theorem changedBodyInsideCoordinationIsRejected
    (expected observed : Option Nat) (h : expected ≠ observed) :
    coordinatedContentWriteAllowed expected observed = false := by
  simp [coordinatedContentWriteAllowed, h]

theorem absentExpectationCannotReplaceVisibleBody (observed : Nat) :
    coordinatedContentWriteAllowed none (some observed) = false := by
  simp [coordinatedContentWriteAllowed]

-- Media lacks a merge base. The shared content rule allows creation and an
-- identical retry, but cannot replace a different remote body. iCloud also
-- rechecks the body and placeholder inside its coordinated write callback.
def unbasedContentWriteAllowed (outgoing : Nat) (observed : Option Nat) : Bool :=
  observed == none || observed == some outgoing

theorem absentMediaMayBeCreated (outgoing : Nat) :
    unbasedContentWriteAllowed outgoing none = true := by
  simp [unbasedContentWriteAllowed]

theorem identicalMediaMayBeRetried (content : Nat) :
    unbasedContentWriteAllowed content (some content) = true := by
  simp [unbasedContentWriteAllowed]

theorem differentMediaCannotBeReplacedWithoutBase
    (outgoing remote : Nat) (different : outgoing ≠ remote) :
    unbasedContentWriteAllowed outgoing (some remote) = false := by
  simp [unbasedContentWriteAllowed, Ne.symm different]

-- Media is a dependency of the module pull. A saved module revision does not
-- certify its referenced files, so unchanged modules retry absent media.
def shouldFetchReferencedMedia (moduleChanged mediaPresent : Bool) : Bool :=
  moduleChanged || !mediaPresent

theorem unchangedModuleRetriesMissingMedia :
    shouldFetchReferencedMedia false false = true := by
  rfl

theorem unchangedModuleSkipsPresentMedia :
    shouldFetchReferencedMedia false true = false := by
  rfl

def shouldDownloadUnchangedMedia
    (pendingLocalUpload mediaPresent : Bool) : Bool :=
  !pendingLocalUpload && !mediaPresent

theorem pendingLocalMediaUploadWaitsForPublish (mediaPresent : Bool) :
    shouldDownloadUnchangedMedia true mediaPresent = false := by
  rfl

def mediaBatchComplete (referencesAndTransfers : List Bool) : Bool :=
  referencesAndTransfers.all id

theorem failedMediaTransferBlocksCompletion (before after : List Bool) :
    mediaBatchComplete (before ++ [false] ++ after) = false := by
  simp [mediaBatchComplete, List.all_append]

-- The publication marker is written before the module PUT and removed only
-- after its referenced media uploads. A successful module PUT alone is not a
-- complete publication and must remain retryable.
def mediaPublicationPendingAfterAttempt
    (moduleWritten mediaWritten : Bool) : Bool :=
  !(moduleWritten && mediaWritten)

theorem failedMediaUploadRetainsPublication :
    mediaPublicationPendingAfterAttempt true false = true := by
  rfl

theorem completedMediaUploadClearsPublication :
    mediaPublicationPendingAfterAttempt true true = false := by
  rfl

def coordinatedGenericFileWriteAllowed
    (expected observed : Option Nat) (placeholderVisible : Bool) : Bool :=
  !placeholderVisible && expected == observed

theorem hiddenRemotePlaceholderStopsCreate :
    coordinatedGenericFileWriteAllowed none none true = false := by
  simp [coordinatedGenericFileWriteAllowed]

theorem changedMediaBodyStopsCoordinatedWrite
    (expected observed : Option Nat) (different : expected ≠ observed) :
    coordinatedGenericFileWriteAllowed expected observed false = false := by
  simp [coordinatedGenericFileWriteAllowed, different]

-- Archive capture keeps hidden media attachments because published devotional
-- content may reference them. Hidden files elsewhere remain excluded. A
-- visible media symlink cannot be silently omitted from a complete snapshot.
inductive ArchiveCaptureChoice where
  | include | skip | reject
  deriving DecidableEq

def archiveCaptureChoice
    (isMedia hidden symlink : Bool) : ArchiveCaptureChoice :=
  if hidden && !isMedia then .skip
  else if symlink then .reject
  else .include

theorem hiddenMediaAttachmentIsIncluded :
    archiveCaptureChoice true true false = .include := by
  rfl

theorem hiddenNonMediaFileIsSkipped (symlink : Bool) :
    archiveCaptureChoice false true symlink = .skip := by
  cases symlink <;> rfl

theorem mediaSymlinkStopsArchiveCapture (hidden : Bool) :
    archiveCaptureChoice true hidden true = .reject := by
  cases hidden <;> rfl

def mediaImportChoice (symlink : Bool) : ArchiveCaptureChoice :=
  if symlink then .reject else .include

theorem hiddenMediaAttachmentSurvivesPortableRoundTrip :
    archiveCaptureChoice true true false = .include ∧
      mediaImportChoice false = .include := by
  exact ⟨rfl, rfl⟩

theorem mediaSymlinkStopsPortableImport :
    mediaImportChoice true = .reject := by
  rfl

inductive PortableDevotionalContentShape where
  | plainParagraph | richBlocks
  deriving DecidableEq

def compatibleDevotionalContent
    (shape : PortableDevotionalContentShape) (original markdown : Nat) : Nat :=
  if shape == .plainParagraph then markdown else original

theorem richDevotionalBlocksKeepTheirContent (original markdown : Nat) :
    compatibleDevotionalContent .richBlocks original markdown = original := by
  rfl

def mediaMetadataAfterBridge (existing generated : List Nat) : List Nat :=
  existing ++ generated.filter (fun id => !existing.contains id)

theorem existingMediaMetadataIsPreserved (existing generated : List Nat) :
    (mediaMetadataAfterBridge existing generated).take existing.length = existing := by
  simp [mediaMetadataAfterBridge]

def portableMediaMayCommit (allReferencedPresent copiesSucceeded : Bool) : Bool :=
  allReferencedPresent && copiesSucceeded

theorem missingPortableAttachmentStopsCommit (copiesSucceeded : Bool) :
    portableMediaMayCommit false copiesSucceeded = false := by
  rfl

theorem failedPortableMediaCopyStopsCommit (allReferencedPresent : Bool) :
    portableMediaMayCommit allReferencedPresent false = false := by
  cases allReferencedPresent <;> rfl

def mayReusePortableArchiveRevision
    (bridgeReady modulesInstalled mediaPresent : Bool) : Bool :=
  bridgeReady && modulesInstalled && mediaPresent

theorem missingPortableMediaForcesArchiveRead
    (bridgeReady modulesInstalled : Bool) :
    mayReusePortableArchiveRevision bridgeReady modulesInstalled false = false := by
  cases bridgeReady <;> cases modulesInstalled <;> rfl

def macMediaMetadataAfterImport
    (stored incoming : Option Nat) : Option Nat :=
  match stored, incoming with
  | none, some value => some value
  | some value, none => some value
  | _, _ => stored

theorem macImportEnrichesMissingMetadata (value : Nat) :
    macMediaMetadataAfterImport none (some value) = some value := by
  rfl

theorem macImportKeepsRicherMetadataWhenIncomingOmitsIt (value : Nat) :
    macMediaMetadataAfterImport (some value) none = some value := by
  rfl

def macStructuredContentAfterSave
    (stored incoming : Option Nat) (bodyUnchanged : Bool) : Option Nat :=
  match incoming with
  | some content => some content
  | none => if bodyUnchanged then stored else none

theorem macMetadataEditKeepsStructuredBlocks (blocks : Nat) :
    macStructuredContentAfterSave (some blocks) none true = some blocks := by
  rfl

theorem macChangedBodyDoesNotReuseOldBlocks (blocks : Nat) :
    macStructuredContentAfterSave (some blocks) none false = none := by
  rfl

-- The Mac editor now supplies revised rich JSON for a body edit. Its shared
-- block merger keeps the opaque fields of an unchanged block, and updates
-- only the rendered field of a same-shape changed block. This abstracts the
-- Swift JSON parser and block alignment, which are exercised in Swift tests.
structure RichDevotionalBlock where
  rendered : Nat
  unknown : Nat
  deriving DecidableEq

def reviseRichDevotionalBlock
    (original : RichDevotionalBlock) (edited : Nat) : RichDevotionalBlock :=
  if original.rendered == edited then original
  else { original with rendered := edited }

theorem unchangedRichDevotionalBlockIsExact (original : RichDevotionalBlock) :
    reviseRichDevotionalBlock original original.rendered = original := by
  simp [reviseRichDevotionalBlock]

theorem editedRichDevotionalBlockKeepsOpaqueFields
    (original : RichDevotionalBlock) (edited : Nat) :
    (reviseRichDevotionalBlock original edited).unknown = original.unknown := by
  by_cases h : original.rendered = edited
  · simp [reviseRichDevotionalBlock, h]
  · simp [reviseRichDevotionalBlock, h]

theorem editedRichDevotionalBlockUsesNewBody
    (original : RichDevotionalBlock) (edited : Nat) :
    (reviseRichDevotionalBlock original edited).rendered = edited := by
  by_cases h : original.rendered = edited
  · simp [reviseRichDevotionalBlock, h]
  · simp [reviseRichDevotionalBlock, h]

-- Outline reconstruction may change a matched section's title and depth.
-- Its identity and opaque fields belong to the section, not its old position.
-- Swift tests exercise the title/body matching and tree construction.
structure RichDevotionalSection where
  title : Nat
  level : Nat
  identity : Nat
  unknown : Nat
  deriving DecidableEq

def reviseRichDevotionalSection
    (original : RichDevotionalSection) (title level : Nat) : RichDevotionalSection :=
  { original with title := title, level := level }

theorem movedRichSectionKeepsIdentity
    (original : RichDevotionalSection) (title level : Nat) :
    (reviseRichDevotionalSection original title level).identity = original.identity := by
  rfl

theorem movedRichSectionKeepsOpaqueFields
    (original : RichDevotionalSection) (title level : Nat) :
    (reviseRichDevotionalSection original title level).unknown = original.unknown := by
  rfl

structure RichDevotionalOutline where
  rootUnknown : Nat
  sections : List RichDevotionalSection

def reviseRichDevotionalOutline
    (original : RichDevotionalOutline) (sections : List RichDevotionalSection) :
    RichDevotionalOutline :=
  { original with sections := sections }

theorem changedRichOutlineKeepsRootFields
    (original : RichDevotionalOutline) (sections : List RichDevotionalSection) :
    (reviseRichDevotionalOutline original sections).rootUnknown = original.rootUnknown := by
  rfl

-- Both editors use the shared block parser. iOS keeps authored Markdown for
-- plain drafts and saves revised JSON when its source was a rich block tree.
def devotionalStoredBody (richSource : Bool) (revisedBlocks markdown : Nat) : Nat :=
  if richSource then revisedBlocks else markdown

theorem iosRichEditStoresRevisedBlocks (revisedBlocks markdown : Nat) :
    devotionalStoredBody true revisedBlocks markdown = revisedBlocks := by
  rfl

theorem iosPlainEditKeepsAuthoredMarkdown (revisedBlocks markdown : Nat) :
    devotionalStoredBody false revisedBlocks markdown = markdown := by
  rfl

-- A body beginning with `[` or `{` is only rich JSON when it has the expected
-- content schema and decodes successfully. Its first character is irrelevant.
def decodedDevotionalBlocks (hasSchema decodeSucceeded : Bool) : Bool :=
  hasSchema && decodeSucceeded

theorem bracketedMarkdownWithoutBlockSchemaKeepsMarkdown (decodeSucceeded : Bool) :
    decodedDevotionalBlocks false decodeSucceeded = false := by
  cases decodeSucceeded <;> rfl

def referencedMediaPhaseComplete (allCopied : Bool) : Bool := allCopied

theorem missingIOSMediaStopsMacPull :
    referencedMediaPhaseComplete false = false := by
  rfl

-- The folder publisher writes a sidecar containing the complete old and
-- intended new content signatures before changing any payload file. Capture
-- accepts only one of those whole signatures, including the case where all
-- payloads were written but the final sidecar update did not finish.
def folderSealAccepts
    (committed : List Nat) (pending : Option (List Nat)) (observed : List Nat) : Bool :=
  observed == committed || pending == some observed

theorem pendingFolderSealAcceptsOld (old next : List Nat) :
    folderSealAccepts old (some next) old = true := by
  simp [folderSealAccepts]

theorem pendingFolderSealAcceptsCompleteNew (old next : List Nat) :
    folderSealAccepts old (some next) next = true := by
  simp [folderSealAccepts]

theorem mixedFolderSnapshotIsRejected
    (old next mixed : List Nat) (notOld : mixed ≠ old) (notNew : mixed ≠ next) :
    folderSealAccepts old (some next) mixed = false := by
  have nextNotMixed : next ≠ mixed := Ne.symm notNew
  simp [folderSealAccepts, notOld, nextNotMixed]

theorem committedFolderSealRejectsLaterEdit
    (committed changed : List Nat) (different : changed ≠ committed) :
    folderSealAccepts committed none changed = false := by
  simp [folderSealAccepts, different]

-- Recovery replays a staged payload only when its archive digest matches the
-- marker and the locally visible file is still old or already intended.
def folderRecoveryStep
    (stageValid : Bool) (old intended current : Option Nat) : Option (Option Nat) :=
  if stageValid && (current == old || current == intended)
  then some intended else none

theorem missingFolderStageCannotRecover
    (old intended current : Option Nat) :
    folderRecoveryStep false old intended current = none := by
  simp [folderRecoveryStep]

theorem oldFolderFileCanResume (old intended : Option Nat) :
    folderRecoveryStep true old intended old = some intended := by
  simp [folderRecoveryStep]

theorem completedFolderFileCanResume (old intended : Option Nat) :
    folderRecoveryStep true old intended intended = some intended := by
  simp [folderRecoveryStep]

theorem unrelatedFolderEditCannotBeOverwritten
    (old intended current : Option Nat)
    (notOld : current ≠ old) (notIntended : current ≠ intended) :
    folderRecoveryStep true old intended current = none := by
  simp [folderRecoveryStep, notOld, notIntended]

end LampSyncVerification
