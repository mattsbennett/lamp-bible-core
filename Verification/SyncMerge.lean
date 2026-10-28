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
-- A PROPFIND's 404 is no collection, any success is whatever its listing
-- shows (207 usually, 200 from some servers), and anything else is an error.
-- Until 19 October this said 207 only, which the adapter never required.
def collectionConfirmed (propfindStatus : Nat) (listsCollection : Bool) : Option Bool :=
  if propfindStatus == 404 then some false
  else if 200 ≤ propfindStatus ∧ propfindStatus < 300 then some listsCollection
  else none

def webDAVDirectoryReady
    (mkcolStatus propfindStatus : Nat)
    (samePath isCollection : Bool) : Bool :=
  [200, 201, 204, 405].contains mkcolStatus ||
    (mkcolStatus == 409 && collectionConfirmed propfindStatus (samePath && isCollection) == some true)

theorem plainSuccessListingAlsoConfirmsTheCollection :
    webDAVDirectoryReady 409 200 true true = true := by decide

theorem failedPropfindConfirmsNothing :
    webDAVDirectoryReady 409 500 true true = false := by decide

theorem existingWebDAVCollectionAcceptsConflict :
    webDAVDirectoryReady 409 207 true true = true := by decide

theorem missingWebDAVCollectionKeepsConflict :
    webDAVDirectoryReady 409 404 true true = false := by decide

theorem nonCollectionCannotSatisfyMKCOLConflict :
    webDAVDirectoryReady 409 207 true false = false := by decide

theorem differentWebDAVPathCannotSatisfyMKCOLConflict :
    webDAVDirectoryReady 409 207 false true = false := by decide

-- A whole-file upload before reading the remote file cannot preserve a
-- remote-only edit, which is why every write is conditioned on the revision
-- it read.

def uploadBeforeRead (current _remote : Nat) : Nat × Nat := (current, current)

theorem uploadFirstLosesRemoteOnlyEdit :
    (uploadBeforeRead 1 2).2 ≠ 2 := by
  decide

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

-- Settings with no membership base use the timestamp rule, refusing an
-- equal-time disagreement.
def chooseWithoutBase (deviceTime remoteTime : Nat) (sameSettings : Bool) : ThreeWayChoice :=
  if deviceTime = remoteTime && !sameSettings then .conflict
  else if remoteTime > deviceTime then .remote
  else .local

-- Readings without a baseline: a row only one side holds is either an addition
-- here or a deletion there, and nothing says which. Refusing the merge then
-- changed nothing, so it refused forever and the device never earned the
-- baseline that would tell the two apart. `planWithoutBase` now keeps every
-- row, takes the newer copy of a row both sides hold, and keeps the remote's
-- on a tie because this device is the one joining. A row is (revision, body).
def baselessReading (device remote : Option (Nat × Nat)) : Option (Nat × Nat) :=
  match device, remote with
  | none, r => r
  | some d, none => some d
  | some d, some r => if d.1 > r.1 then some d else some r

theorem baselessMergeKeepsEveryRow (device remote : Option (Nat × Nat))
    (h : device.isSome = true ∨ remote.isSome = true) :
    (baselessReading device remote).isSome = true := by
  cases device with
  | none =>
    cases remote with
    | none => simp at h
    | some r => rfl
  | some d =>
    cases remote with
    | none => rfl
    | some r => simp only [baselessReading]; split <;> rfl

theorem baselessNewerDeviceRowWins (d r : Nat × Nat) (h : d.1 > r.1) :
    baselessReading (some d) (some r) = some d := by
  simp [baselessReading, h]

theorem baselessTiedOrNewerRemoteRowWins (d r : Nat × Nat) (h : ¬ d.1 > r.1) :
    baselessReading (some d) (some r) = some r := by
  simp [baselessReading, h]

theorem baselessMergeOfAgreeingSidesChangesNothing (row : Option (Nat × Nat)) :
    baselessReading row row = row := by
  cases row with
  | none => rfl
  | some r => simp [baselessReading]

-- The stated cost: a reading deleted elsewhere before this device held any
-- baseline comes back, once. From the next merge on there is a baseline.
theorem baselessMergeRevivesAnUnseenDeletion :
    baselessReading (some (1, 7)) none = some (1, 7) := rfl

-- The plan publishes when its rows differ from the remote's, or when this
-- device's settings win and differ.
def baselessNeedsPublish (rowsDiffer settingsLocal settingsDiffer : Bool) : Bool :=
  rowsDiffer || (settingsLocal && settingsDiffer)

theorem agreeingBaselessSidesNeedNoPublish (settingsLocal : Bool) :
    baselessNeedsPublish false settingsLocal false = false := by
  cases settingsLocal <;> rfl

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

-- The Mac's highlight export may skip an empty set, and the pass carries on.
-- Any other export error reaches the pass, so the set is never recorded as
-- published.
inductive MacHighlightExport where
  | ready | empty | failed
  deriving DecidableEq, Repr

def macHighlightAllowsPublish : MacHighlightExport → Bool
  | .ready | .empty => true
  | .failed => false

theorem emptyMacHighlightSetMayBeSkipped :
    macHighlightAllowsPublish .empty = true := by
  rfl

theorem failedMacHighlightExportStopsPublish :
    macHighlightAllowsPublish .failed = false := by
  rfl

def oldMacHighlightAllowsPublish (_ : MacHighlightExport) : Bool := true

theorem swallowedMacHighlightFailureCouldPublish :
    oldMacHighlightAllowsPublish .failed = true := by
  rfl

-- iCloud offers no atomic conditional write, so a revision on the folder
-- provider is a content digest, assuming SHA-256 distinguishes the particular
-- bodies. A modification date alone could remain equal across different
-- writes.
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

def iCloudReadReady (unresolvedVersions : Bool) (body : Option Nat) : Option Nat :=
  if unresolvedVersions then none else body

theorem reportedICloudVersionConflictStopsRead (body : Option Nat) :
    iCloudReadReady true body = none := by
  simp [iCloudReadReady]

-- A coordinated iCloud read of revision 1 can still be followed by another
-- device's write before this client's unconditional upload. The later upload
-- then replaces that remote-only content. This is a verified limitation of
-- the provider path, not a guarantee supplied by the read.
def unconditionedSettingsWrite (_observedToken : Option Nat)
    (currentRemote : Nat × Nat) (localContent : Nat) : Nat × Nat :=
  (currentRemote.1 + 1, localContent)

theorem stableICloudReadDoesNotProtectLaterWrite :
    unconditionedSettingsWrite (some 1) (2, 99) 7 = (3, 7) := by
  decide

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

-- A module read by its legacy layout must carry the columns its import reads
-- (the inspector's legacy fallback checks them). Identity-only inspection used
-- by other callers does not impose that stricter schema contract.
def importSchemaAllows (requireImportSchema : Bool) (requiredColumns : List Bool) : Bool :=
  !requireImportSchema || requiredColumns.all id

theorem identityOnlyModuleInspectionKeepsLegacySchema (columns : List Bool) :
    importSchemaAllows false columns = true := by
  simp [importSchemaAllows]

-- Compiled plans carry content columns but omit local installation fields.
-- The iOS importer supplies path, revision, and timestamps itself, so those
-- source-only columns are not a preflight requirement.
def planSourceUsable (contentColumns _localInstallColumns : Bool) : Bool :=
  contentColumns

theorem compiledPlanWithoutLocalColumnsCanImport :
    planSourceUsable true false = true := by
  rfl

theorem planMissingContentColumnsCannotImport (localColumns : Bool) :
    planSourceUsable false localColumns = false := by
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

theorem successfulRunReachesComplete :
    runTrace true true = [0, 1, 2] := by
  simp [runTrace]

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

-- The format choice for one identity among a listing's files. Choosing a
-- canonical successor for one identity must not discard another identity's.
def selectModuleFormatForIdentity
    (identity : Nat) (files : List (Nat × ModuleFormat)) : Option ModuleFormat :=
  selectModuleFormat none
    (files.any fun file => if file.1 = identity ∧ file.2 = .lamp then true else false)
    (files.any fun file => if file.1 = identity ∧ file.2 = .json then true else false)

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

-- Mac personal study import and shared full-highlight inspection prefer a
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

-- The Mac writes the settings a pass brings down through a journal kept with
-- the library: staged first, then applied to UserDefaults and cleared. A crash
-- between the two leaves the journal, and the next launch or pass replays it.
-- Staging refuses when the live settings moved after the plan was made, so a
-- preference changed during the pass is never reverted by a plan made before
-- it. A distinct edit after staging blocks replay instead of being overwritten.
structure MacJournalState where
  settings : Nat
  pending : Option (Nat × Nat)
  deriving DecidableEq, Repr

def stageMacSettings (state : MacJournalState) (baseline planned : Nat) :
    Option MacJournalState :=
  if state.settings == baseline then some { state with pending := some (baseline, planned) }
  else none

def recoverMacSettings (state : MacJournalState) : Option MacJournalState :=
  match state.pending with
  | none => some state
  | some (baseline, prepared) =>
      if state.settings == baseline || state.settings == prepared then
        some { state with settings := prepared, pending := none }
      else none

theorem aSettingChangedDuringThePassIsNeverReverted
    (state : MacJournalState) (baseline planned : Nat) (moved : state.settings ≠ baseline) :
    stageMacSettings state baseline planned = none := by
  simp [stageMacSettings, moved]

theorem stagedMacSettingsKeepTheJournal (state : MacJournalState) (planned : Nat) :
    stageMacSettings state state.settings planned =
      some { state with pending := some (state.settings, planned) } := by
  simp [stageMacSettings]

theorem pendingMacSettingsReplayCompletesPull (settings planned : Nat) :
    recoverMacSettings { settings := settings, pending := some (settings, planned) } =
      some { settings := planned, pending := none } := by
  simp [recoverMacSettings]

theorem distinctMacSettingsEditBlocksReplay
    (baseline prepared changed : Nat)
    (notBase : changed ≠ baseline) (notPrepared : changed ≠ prepared) :
    recoverMacSettings { settings := changed, pending := some (baseline, prepared) } = none := by
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

def mediaBatchComplete (referencesAndTransfers : List Bool) : Bool :=
  referencesAndTransfers.all id

theorem failedMediaTransferBlocksCompletion (before after : List Bool) :
    mediaBatchComplete (before ++ [false] ++ after) = false := by
  simp [mediaBatchComplete, List.all_append]

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

/-! ## Disagreements set aside

Since 15 October a sync run no longer stops on an equal-time disagreement over
a note or a writing. `LampLibrary`'s personal import keeps this device's copy,
stashes the other device's whole for the person to choose from, and carries on
with the rest; an import someone asked for still stops, because someone is
there to tell. Choosing later stamps the kept copy past both
(`resolvedRecordRevision`), so neither device raises the same disagreement
again. -/

inductive ImportOutcome where
  | keepLocal | takeIncoming | setAside | stop
  deriving DecidableEq, Repr

def portableImportOutcome (forSync : Bool) (current incoming : Int)
    (sameContent : Bool) : ImportOutcome :=
  match decide current incoming sameContent with
  | .incoming => .takeIncoming
  | .local => .keepLocal
  | .conflict => if forSync then .setAside else .stop

theorem syncImportNeverStops (current incoming : Int) (same : Bool) :
    portableImportOutcome true current incoming same ≠ .stop := by
  unfold portableImportOutcome
  split <;> simp

theorem syncSetsEqualTimeDisagreementAside (t : Int) :
    portableImportOutcome true t t false = .setAside := by
  simp [portableImportOutcome, decide]

theorem requestedImportStopsOnDisagreement (t : Int) :
    portableImportOutcome false t t false = .stop := by
  simp [portableImportOutcome, decide]

theorem setAsideNeverTakesTheIncomingCopy (current incoming : Int) (same : Bool) :
    portableImportOutcome true current incoming same = .setAside →
    decide current incoming same = .conflict := by
  unfold portableImportOutcome
  split <;> simp_all

theorem resolvedChoiceWinsWhereItWasMade (device incoming now : Nat) (same : Bool) :
    decide (resolvedRecordRevision device incoming now) incoming same = .local := by
  have h := (resolvedRecordRevisionExceedsBoth device incoming now).2
  apply newerLocalWins
  exact_mod_cast h

theorem resolvedChoiceWinsOnTheOtherDevice (device incoming now : Nat) (same : Bool) :
    decide incoming (resolvedRecordRevision device incoming now) same = .incoming := by
  have h := (resolvedRecordRevisionExceedsBoth device incoming now).2
  apply newerIncomingWins
  exact_mod_cast h

/-! ## Preferences: disputes set aside, first meetings

`LampSharedPreferenceLedger.merge` returns what to publish, what to apply and
what to remember as agreed. A field both devices changed differently is set
aside: the server keeps its value, so the other device's edit survives; this
device keeps what its user set; the baseline keeps what the two last agreed, so
the dispute shows again until they hold one value. With no baseline at all the
two have never met: the server's value stands, and a value only this device
holds is contributed. `choosePreference` above is the per-field classification
when a baseline exists. -/

structure PrefField where
  value : Option Nat
  revision : Nat
  deriving DecidableEq, Repr

structure PreferenceOutcome where
  published : Option PrefField
  applies : Bool
  baseline : Option PrefField
  disputed : Bool
  deriving DecidableEq, Repr

-- `fresh` is the new revision Swift mints for a value this device publishes.
def preferenceMerge (hasBase : Bool) (previous remote : Option PrefField)
    (localValue : Option Nat) (fresh : Nat) : PreferenceOutcome :=
  let incoming := remote <|> previous
  if !hasBase then
    let published := match incoming, localValue with
      | none, some v => some ⟨some v, fresh⟩
      | i, _ => i
    ⟨published, true, published, false⟩
  else
    let localChanged := localValue != previous.bind (·.value)
    let remoteChanged := incoming.map (·.revision) != previous.map (·.revision)
    if localChanged && remoteChanged && localValue != incoming.bind (·.value) then
      ⟨incoming, false, previous, true⟩
    else if localChanged && !remoteChanged then
      let mine := some ⟨localValue, fresh⟩
      ⟨mine, true, mine, false⟩
    else
      ⟨incoming, true, incoming, false⟩

theorem disputedPreferenceKeepsTheServersValue
    (previous remote : Option PrefField) (localValue : Option Nat) (fresh : Nat)
    (h : (preferenceMerge true previous remote localValue fresh).disputed = true) :
    (preferenceMerge true previous remote localValue fresh).published = (remote <|> previous) ∧
    (preferenceMerge true previous remote localValue fresh).applies = false ∧
    (preferenceMerge true previous remote localValue fresh).baseline = previous := by
  unfold preferenceMerge at *
  simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte] at *
  split at h
  · simp_all
  · split at h <;> simp at h

theorem agreeingPreferenceIsNeverDisputed
    (previous remote : Option PrefField) (fresh : Nat)
    (value : Option Nat) (h : value = (remote <|> previous).bind (·.value)) :
    (preferenceMerge true previous remote value fresh).disputed = false := by
  unfold preferenceMerge
  simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte]
  split
  · next hd => simp_all
  · split <;> rfl

theorem firstMeetingNeverDisputes
    (previous remote : Option PrefField) (localValue : Option Nat) (fresh : Nat) :
    (preferenceMerge false previous remote localValue fresh).disputed = false := by
  simp [preferenceMerge]

theorem firstMeetingKeepsTheServersValue
    (field : PrefField) (localValue : Option Nat) (fresh : Nat) :
    (preferenceMerge false none (some field) localValue fresh).published = some field := by
  cases localValue <;> rfl

theorem firstMeetingContributesALocalOnlyValue (value fresh : Nat) :
    (preferenceMerge false none none (some value) fresh).published =
      some ⟨some value, fresh⟩ := rfl

theorem disputePersistsWhileTheValuesDiffer :
    (preferenceMerge true (some ⟨some 1, 10⟩) (some ⟨some 2, 11⟩) (some 3) 12).disputed = true ∧
    (preferenceMerge true (some ⟨some 1, 10⟩) (some ⟨some 2, 11⟩) (some 3) 12).baseline =
      some ⟨some 1, 10⟩ := by
  decide

/-! ## Deletion ledgers

Personal content (`LampPersonalDeletionLedger`), slide decks
(`LampPresentationDeckDeletionLedger`) and workspace files (macOS
`WorkspaceSyncLedger`) keep ledgers of one shape: per item, the latest recorded
save and the latest recorded deletion. Two ledgers merge by keeping the later
of each, which is what the SQL upsert in `mergePersonalDeletionLedger` does.
An item is deleted when its deletion is no earlier than the later of its
recorded save and the copy in hand; an equal time favours the deletion.
Absent times read as zero, as Swift's `Int64.min` stand-in does. -/

def later : Option Nat → Option Nat → Option Nat
  | some a, some b => some (max a b)
  | some a, none => some a
  | none, b => b

theorem later_comm (a b : Option Nat) : later a b = later b a := by
  cases a <;> cases b <;> simp [later, Nat.max_comm]

theorem later_assoc (a b c : Option Nat) :
    later (later a b) c = later a (later b c) := by
  cases a <;> cases b <;> cases c <;> simp [later, Nat.max_assoc]

theorem later_idem (a : Option Nat) : later a a = a := by
  cases a <;> simp [later]

structure Tombstone where
  presentSince : Option Nat
  deletedAt : Option Nat
  deriving DecidableEq, Repr

def mergeTombstone (a b : Tombstone) : Tombstone :=
  ⟨later a.presentSince b.presentSince, later a.deletedAt b.deletedAt⟩

def tombstoneDeletes (t : Tombstone) (copyModified : Option Nat) : Bool :=
  match t.deletedAt with
  | none => false
  | some d => Decidable.decide ((later t.presentSince copyModified).getD 0 ≤ d)

theorem mergeTombstone_comm (a b : Tombstone) :
    mergeTombstone a b = mergeTombstone b a := by
  simp [mergeTombstone, later_comm]

theorem mergeTombstone_assoc (a b c : Tombstone) :
    mergeTombstone (mergeTombstone a b) c = mergeTombstone a (mergeTombstone b c) := by
  simp [mergeTombstone, later_assoc]

theorem mergeTombstone_idem (a : Tombstone) : mergeTombstone a a = a := by
  simp [mergeTombstone, later_idem]

-- Whatever order two devices exchange ledgers in, they reach one verdict.
theorem exchangedLedgersAgree (a b : Tombstone) (copy : Option Nat) :
    tombstoneDeletes (mergeTombstone a b) copy = tombstoneDeletes (mergeTombstone b a) copy := by
  rw [mergeTombstone_comm]

theorem noDeletionNeverDeletes (presentSince copy : Option Nat) :
    tombstoneDeletes ⟨presentSince, none⟩ copy = false := rfl

theorem deletionAfterLastSaveDeletes (saved deleted : Nat) (h : saved ≤ deleted) :
    tombstoneDeletes ⟨some saved, some deleted⟩ none = true := by
  simp [tombstoneDeletes, later, h]

theorem editAfterDeletionSurvives (presentSince : Option Nat) (deleted edited : Nat)
    (h : deleted < edited) :
    tombstoneDeletes ⟨presentSince, some deleted⟩ (some edited) = false := by
  show Decidable.decide ((later presentSince (some edited)).getD 0 ≤ deleted) = false
  apply decide_eq_false
  cases presentSince with
  | none => simp [later]; omega
  | some p => simp [later]; omega

theorem saveAfterDeletionSurvives (saved deleted : Nat) (h : deleted < saved) :
    tombstoneDeletes ⟨some saved, some deleted⟩ none = false := by
  show Decidable.decide ((later (some saved) none).getD 0 ≤ deleted) = false
  apply decide_eq_false
  simp [later]; omega

theorem equalTimeFavoursDeletion (t : Nat) :
    tombstoneDeletes ⟨some t, some t⟩ (some t) = true := by
  simp [tombstoneDeletes, later]

-- A workspace document's deletion is stamped with the last version this Mac
-- had, so an edit made elsewhere after that survives it. A context file's
-- times are not comparable across Macs, so its deletion is stamped when the
-- deletion was noticed.
def workspaceDeletionTime (isContext : Bool) (lastSeenModified noticed : Nat) : Nat :=
  if isContext then noticed else lastSeenModified

theorem documentDeletionRemovesTheVersionSeen (seen noticed : Nat) :
    tombstoneDeletes ⟨none, some (workspaceDeletionTime false seen noticed)⟩ (some seen) = true := by
  simp [tombstoneDeletes, workspaceDeletionTime, later]

theorem documentDeletionSparesALaterEdit (seen noticed edited : Nat) (h : seen < edited) :
    tombstoneDeletes ⟨none, some (workspaceDeletionTime false seen noticed)⟩ (some edited) = false := by
  show Decidable.decide
    ((later none (some edited)).getD 0 ≤ workspaceDeletionTime false seen noticed) = false
  apply decide_eq_false
  simp [later, workspaceDeletionTime]; omega

/-! ### Plan progress

`LampSyncPlanProgress` keeps, for each followed plan and each finished
reading, the deletion ledger's two times: when it was last set (chosen,
ticked) and last cleared, joined by `mergeTombstone`.

It is a join rather than the three-way merge the apps' own settings use. An
app from before it decodes the bundle, passes over the key it does not know,
and writes the bundle back without it. Merged three ways, that absence would
read as every reading unticked on another device. Joined, a missing part or
a missing mark says nothing, and the next client to contribute puts its marks
back.

A tie keeps the tick, the reverse of `tombstoneDeletes`: there a tie would
bring a deleted thing back, here it would lose someone's progress. -/

def planMarkIsSet (m : Tombstone) : Bool :=
  match m.presentSince, m.deletedAt with
  | none, _ => false
  | some _, none => true
  | some s, some c => Decidable.decide (c ≤ s)

-- A change is stamped now, but never at or before the time it overrides, so
-- a device's own change holds against its own clock, and against a clock
-- behind the device whose change it undoes.
def stampSet (now : Nat) (m : Tombstone) : Tombstone :=
  mergeTombstone m ⟨some (max now ((m.deletedAt.map (· + 1)).getD now)), none⟩

def stampCleared (now : Nat) (m : Tombstone) : Tombstone :=
  mergeTombstone m ⟨none, some (max now ((m.presentSince.map (· + 1)).getD now))⟩

theorem aTickHoldsWhereItWasMade (now : Nat) (m : Tombstone) :
    planMarkIsSet (stampSet now m) = true := by
  rcases m with ⟨p, d⟩
  cases p <;> cases d <;> simp [stampSet, mergeTombstone, later, planMarkIsSet] <;> omega

theorem anUntickHoldsWhereItWasMade (now : Nat) (m : Tombstone) :
    planMarkIsSet (stampCleared now m) = false := by
  rcases m with ⟨p, d⟩
  cases p <;> cases d <;> simp [stampCleared, mergeTombstone, later, planMarkIsSet] <;> omega

theorem aTieKeepsTheTick (t : Nat) : planMarkIsSet ⟨some t, some t⟩ = true := by
  simp [planMarkIsSet]

-- Whatever order two devices exchange their marks in, they agree.
theorem exchangedPlanMarksAgree (a b : Tombstone) :
    planMarkIsSet (mergeTombstone a b) = planMarkIsSet (mergeTombstone b a) := by
  rw [mergeTombstone_comm]

-- A device with no mark for something changes nothing by joining.
theorem aMissingMarkSaysNothing (m : Tombstone) : mergeTombstone m ⟨none, none⟩ = m := by
  rcases m with ⟨p, d⟩
  cases p <;> cases d <;> simp [mergeTombstone, later]

inductive PlanChange where
  | leave
  | hold (time : Nat)
  | drop
  deriving DecidableEq, Repr

-- `LampSyncPlanProgress.apply`: what a client changes to hold what a joined
-- ledger says. Its own copy counts as a mark set at its time, so a copy held
-- since after the clearing stays.
def planApply (m : Tombstone) (held : Option Nat) : PlanChange :=
  let joined := mergeTombstone m ⟨held, none⟩
  if planMarkIsSet joined then
    match joined.presentSince with
    | some s => if held = some s then .leave else .hold s
    | none => .leave
  else if held.isSome then .drop else .leave

-- Nothing is taken away without a mark clearing it: a part an older app
-- dropped, or a mark no device made, takes nothing away.
theorem noClearingNeverDrops (p held : Option Nat) : planApply ⟨p, none⟩ held ≠ .drop := by
  cases p <;> cases held <;> simp [planApply, mergeTombstone, later, planMarkIsSet] <;> split <;> simp

theorem later_none (a : Option Nat) : later a none = a := by cases a <;> rfl

-- The joined mark, spelled out.
theorem planApply_eq (p d held : Option Nat) :
    planApply ⟨p, d⟩ held =
      if planMarkIsSet ⟨later p held, d⟩ then
        (match later p held with
         | some s => if held = some s then .leave else .hold s
         | none => .leave)
      else if held.isSome then .drop else .leave := by
  simp [planApply, mergeTombstone, later_none]

-- A copy held since the clearing stays.
theorem aTickSinceTheUntickStays (p : Option Nat) (c t : Nat) (h : c ≤ t) :
    planApply ⟨p, some c⟩ (some t) ≠ .drop := by
  rw [planApply_eq]
  have hs : planMarkIsSet ⟨later p (some t), some c⟩ = true := by
    cases p <;> simp [later, planMarkIsSet] <;> omega
  simp only [hs, ↓reduceIte]
  cases hl : later p (some t) <;> simp
  split <;> simp

-- Applying settles: once a client holds what it was told to, applying the
-- same ledger again changes nothing.
theorem planApplySettlesAHold (p d held : Option Nat) (s : Nat)
    (h : planApply ⟨p, d⟩ held = .hold s) : planApply ⟨p, d⟩ (some s) = .leave := by
  rw [planApply_eq] at h ⊢
  by_cases hs : planMarkIsSet ⟨later p held, d⟩ = true
  · simp only [hs, ↓reduceIte] at h
    cases hl : later p held with
    | none => rw [hl] at h; simp at h
    | some s' =>
      rw [hl] at h
      by_cases he : held = some s'
      · simp [he] at h
      · simp [he] at h
        subst h
        have hl2 : later p (some s') = some s' := by
          cases p <;> cases held <;> simp_all [later] <;> omega
        rw [hl2]
        have hs2 : planMarkIsSet ⟨some s', d⟩ = true := by rw [← hl]; exact hs
        simp [hs2]
  · simp only [Bool.not_eq_true] at hs
    simp only [hs, Bool.false_eq_true, ↓reduceIte] at h
    split at h <;> simp at h

theorem planApplySettlesADrop (p d held : Option Nat)
    (h : planApply ⟨p, d⟩ held = .drop) : planApply ⟨p, d⟩ none = .leave := by
  rw [planApply_eq] at h ⊢
  by_cases hs : planMarkIsSet ⟨later p held, d⟩ = true
  · simp only [hs, ↓reduceIte] at h
    split at h <;> (try split at h) <;> simp at h
  · simp only [Bool.not_eq_true] at hs
    simp only [hs, Bool.false_eq_true, ↓reduceIte] at h
    rw [later_none]
    have hm : planMarkIsSet ⟨p, d⟩ = false := by
      cases p <;> cases d <;> cases held <;> simp_all [later, planMarkIsSet] <;> omega
    simp [hm]

-- The bundle's plan part: absent, or a ledger, here one mark of it.
def mergePlanPart : Option Tombstone → Option Tombstone → Option Tombstone
  | none, b => b
  | some a, none => some a
  | some a, some b => some (mergeTombstone a b)

theorem planPartsJoinInAnyOrder (a b : Option Tombstone) :
    mergePlanPart a b = mergePlanPart b a := by
  cases a <;> cases b <;> simp [mergePlanPart, mergeTombstone_comm]

-- `Contribution.apply`: this client's whole ledger joined in, every pass, and
-- nothing written by a client with nothing of its own.
def contributePlan (own : Tombstone) (part : Option Tombstone) : Option Tombstone :=
  if own = ⟨none, none⟩ then part else mergePlanPart (some own) part

-- A part an older app wrote the bundle without comes back with the next
-- contribution of a client that holds it.
theorem aDroppedPartIsRestored (own : Tombstone) (h : own ≠ ⟨none, none⟩) :
    contributePlan own none = some own := by
  simp [contributePlan, h, mergePlanPart]

-- A contribution with no unticks of its own never takes back a tick the
-- part held.
theorem aContributionWithoutUnticksKeepsTheTick (own m : Tombstone)
    (hset : planMarkIsSet m = true) (hown : own.deletedAt = none) :
    ∃ r, contributePlan own (some m) = some r ∧ planMarkIsSet r = true := by
  rcases own with ⟨op, od⟩
  rcases m with ⟨p, d⟩
  simp at hown
  subst hown
  cases op <;> cases p <;> cases d <;>
    simp_all [contributePlan, mergePlanPart, mergeTombstone, later, planMarkIsSet] <;> omega

/-! ### Deck pull

`LampPresentationDeckPortablePull.plan` keeps, per deck, the greatest copy in
the shared file order (`mergeFile`) among those the ledger does not delete,
then deletes the result if the ledger deletes it. -/

def deckKeep (deleted : FileVersion → Bool) (acc : Option FileVersion)
    (candidate : FileVersion) : Option FileVersion :=
  if deleted candidate then acc else
    match acc with
    | none => some candidate
    | some current => some (mergeFile current candidate)

def deckFinal (deleted : FileVersion → Bool) : Option FileVersion → Option FileVersion
  | some kept => if deleted kept then none else some kept
  | none => none

def deckPull (deleted : FileVersion → Bool) (installed : Option FileVersion)
    (incoming : List FileVersion) : Option FileVersion :=
  deckFinal deleted (incoming.foldl (deckKeep deleted) installed)

theorem deckPullNeverKeepsADeletedDeck (deleted : FileVersion → Bool)
    (installed : Option FileVersion) (incoming : List FileVersion) (k : FileVersion)
    (h : deckPull deleted installed incoming = some k) : deleted k = false := by
  unfold deckPull at h
  generalize incoming.foldl (deckKeep deleted) installed = kept at h
  cases kept with
  | none => simp [deckFinal] at h
  | some x =>
    simp only [deckFinal] at h
    cases hx : deleted x <;> simp_all

theorem mergeFile_right_comm (v a b : FileVersion) :
    mergeFile (mergeFile v a) b = mergeFile (mergeFile v b) a := by
  rw [mergeFile_assoc, mergeFile_comm a b, ← mergeFile_assoc]

theorem deckPullIgnoresArrivalOrder (deleted : FileVersion → Bool)
    (installed : Option FileVersion) (a b : FileVersion) :
    deckPull deleted installed [a, b] = deckPull deleted installed [b, a] := by
  unfold deckPull
  cases ha : deleted a <;> cases hb : deleted b <;> cases installed <;>
    simp only [List.foldl, deckKeep, ha, hb, Bool.false_eq_true, ↓reduceIte] <;>
    first | rfl | rw [mergeFile_right_comm] | rw [mergeFile_comm]

/-! ## Did a refused write land?

`LampSyncConditionalWrite.landing` judges, after a write reported failure,
whether it landed. The server revision afterwards can show a write did not
land — the file is still where its condition left it — but not that it did: a
conditional write is refused precisely when another device wrote first, which
moves the file off the condition just as an accepted write would. The rule
before 19 October said such a file was written. -/

inductive WriteCondition where
  | unconditional | ifAbsent | ifRevision (expected : Nat)
  deriving DecidableEq, Repr

inductive Landing where
  | wrote | didNotWrite | undecidable
  deriving DecidableEq, Repr

def landingBefore : WriteCondition → Option Nat → Landing
  | .unconditional, _ => .wrote
  | .ifRevision e, s => if s == some e then .didNotWrite else .wrote
  | .ifAbsent, s => if s.isNone then .didNotWrite else .undecidable

def landing : WriteCondition → Option Nat → Landing
  | .unconditional, _ => .wrote
  | .ifRevision e, s => if s == some e then .didNotWrite else .undecidable
  | .ifAbsent, s => if s.isNone then .didNotWrite else .undecidable

-- Whether the server still satisfies the condition the write carried.
def stillSatisfies : WriteCondition → Option Nat → Bool
  | .unconditional, _ => true
  | .ifAbsent, s => s.isNone
  | .ifRevision e, s => s == some e

-- The old rule, wrong: this write was refused because another device wrote
-- revision 2 over the expected 1, and the rule called it written.
theorem refusedWriteCanLookWritten :
    landingBefore (.ifRevision 1) (some 2) = .wrote := rfl

-- The rule now claims "not written" only while the server still satisfies the
-- condition — which an accepted write always moves it off — and "written"
-- only for a write that asserted nothing and so could not be refused.
theorem landingIsSound (c : WriteCondition) (s : Option Nat) :
    (landing c s = .didNotWrite → stillSatisfies c s = true) ∧
    (landing c s = .wrote → c = .unconditional) := by
  cases c with
  | unconditional => simp [landing, stillSatisfies]
  | ifAbsent => cases s <;> simp [landing, stillSatisfies]
  | ifRevision e =>
    constructor
    · intro h
      simp only [landing] at h
      split at h
      · simp_all [stillSatisfies]
      · simp at h
    · intro h
      simp only [landing] at h
      split at h <;> simp at h

-- An undecidable case is settled by the bytes the server now holds.
def settleByBytes (serverBytes : Option Nat) (sent : Nat) : Landing :=
  if serverBytes == some sent then .wrote else .didNotWrite

theorem anotherDevicesBytesMeanNotWritten (theirs sent : Nat) (h : theirs ≠ sent) :
    settleByBytes (some theirs) sent = .didNotWrite := by
  simp [settleByBytes, h]

-- `writeAndConfirm` names the revision a write produced from a read that
-- returns this write's bytes with a strong revision, asking twice: a server
-- still settling a large body answers once with the version before it.
def confirmWrite (sent : Nat) (reads : List (Option (Nat × Option Nat))) : Option Nat :=
  (reads.take 2).findSome? fun r =>
    match r with
    | some (bytes, some revision) => if bytes == sent then some revision else none
    | _ => none

theorem settlingServerConfirmsOnTheSecondRead :
    confirmWrite 5 [some (4, some 1), some (5, some 2)] = some 2 := rfl

theorem oneReadWouldHaveCalledItLost :
    confirmWrite 5 [some (4, some 1)] = none := rfl

theorem anotherDevicesBytesNeverConfirm (theirs sent r1 r2 : Nat) (h : theirs ≠ sent) :
    confirmWrite sent [some (theirs, some r1), some (theirs, some r2)] = none := by
  simp [confirmWrite, List.findSome?, h]

theorem aThirdReadIsNeverMade :
    confirmWrite 5 [none, none, some (5, some 3)] = none := rfl

/-! ## Revision tokens

A server may spell one ETag differently between a PROPFIND and a GET: quoted,
bare or weak. `LampSyncConditionalWrite.token` keeps only the tag, and
`namesSameRevision` compares tokens; two absent revisions name the same
nothing, one absent and one present do not. -/

structure SpelledRevision where
  weak : Bool
  quoted : Bool
  tag : Nat
  deriving DecidableEq, Repr

def revisionToken (r : SpelledRevision) : Nat := r.tag

def namesSameRevision (a b : Option SpelledRevision) : Bool :=
  a.map revisionToken == b.map revisionToken

theorem spellingsOfOneTagNameOneRevision (tag : Nat) (w1 q1 w2 q2 : Bool) :
    namesSameRevision (some ⟨w1, q1, tag⟩) (some ⟨w2, q2, tag⟩) = true := by
  simp [namesSameRevision, revisionToken]

theorem absentAndPresentNameDifferentRevisions (r : SpelledRevision) :
    namesSameRevision none (some r) = false := by
  simp [namesSameRevision]

theorem namesSameRevision_symm (a b : Option SpelledRevision) :
    namesSameRevision a b = namesSameRevision b a := by
  apply Bool.eq_iff_iff.mpr
  simp only [namesSameRevision, beq_iff_eq]
  exact eq_comm

-- `LampSyncModuleFiles.needsImport` compares tokens. The WebDAV adapters pass
-- on only strong revisions, so a weak listing tag arrives as no revision at
-- all and forces the import; iCloud passes a content digest.
def webDAVAdapterRevision (r : SpelledRevision) : Option SpelledRevision :=
  if r.weak then none else some r

def needsImportByToken (isNew samePath : Bool) (installed : Option Nat)
    (remote : Option SpelledRevision) : Bool :=
  match remote with
  | none => true
  | some r => isNew || !samePath || installed != some (revisionToken r)

theorem quotedListingOfOwnUploadMaySkip (tag : Nat) :
    needsImportByToken false true (some tag) (some ⟨false, true, tag⟩) = false := by
  simp [needsImportByToken, revisionToken]

theorem weakListingCannotSkipThroughTheAdapter (tag : Nat) (quoted : Bool) :
    needsImportByToken false true (some tag) (webDAVAdapterRevision ⟨true, quoted, tag⟩) = true := by
  simp [needsImportByToken, webDAVAdapterRevision]

theorem changedTokenRequiresImport (installed tag : Nat) (w q : Bool) (h : installed ≠ tag) :
    needsImportByToken false true (some installed) (some ⟨w, q, tag⟩) = true := by
  simp [needsImportByToken, revisionToken, h]

/-! ## Stored JSON sameness

`LampSyncJSONComparison.sameValue` compares stored JSON columns by meaning:
nothing, `null` and an empty list or object are one absence; JSON compares by
its sorted-key encoding; anything that is not JSON compares exactly as
written, whitespace included, since leading spaces in Markdown are meaning.
Classifying a string is Swift's (tested there); the comparison is this. -/

inductive StoredColumn where
  | nothing | json (canonical : Nat) | text (raw : Nat)
  deriving DecidableEq, Repr

def sameColumn : StoredColumn → StoredColumn → Bool
  | .nothing, .nothing => true
  | .json a, .json b => a == b
  | .text a, .text b => a == b
  | _, _ => false

theorem sameColumn_refl (c : StoredColumn) : sameColumn c c = true := by
  cases c <;> simp [sameColumn]

theorem sameColumn_symm (a b : StoredColumn) : sameColumn a b = sameColumn b a := by
  cases a <;> cases b <;>
    (apply Bool.eq_iff_iff.mpr; simp only [sameColumn, beq_iff_eq]; try exact eq_comm)

theorem sameColumn_trans (a b c : StoredColumn)
    (hab : sameColumn a b = true) (hbc : sameColumn b c = true) : sameColumn a c = true := by
  cases a <;> cases b <;> cases c <;> simp_all [sameColumn]

theorem textIsNeverTheSameAsJSONOrNothing (raw canonical : Nat) :
    sameColumn (.text raw) (.json canonical) = false ∧ sameColumn (.text raw) .nothing = false := by
  simp [sameColumn]

/-! ## Devices interleaving whole passes

Everything above proves one decision at a time. This runs them together:
two devices editing, pulling and publishing in any interleaving, against one
server whose writes are conditional on the revision a device read — the
`LampSyncEngine` pull-then-publish pass over `LampSyncConditionalWrite`.

Content is, per item, a version in a total order, and merging takes the later
of each: `join`. That is what the per-item rules above provide —
`mergeFile` is the least upper bound in the shared file order
(`mergeFile_least_upper`, `mergeFile_comm`, `mergeFile_assoc`), a record's
last-writer-wins time is ordered, and a deletion ledger keeps the later of
each event (`mergeTombstone_comm`, `mergeTombstone_assoc`). Two exceptions
are not a join and are outside this model: an equal-time disagreement over a
record is set aside on each device, which keeps its own copy until someone
chooses (`syncSetsEqualTimeDisagreementAside`; the choice then wins on both,
`resolvedChoiceWinsOnTheOtherDevice`), and a settings merge with no baseline
may bring back a deletion once (`baselessMergeRevivesAnUnseenDeletion`).

Assumed, not proved: the server honours the write condition (WebDAV does;
iCloud cannot, as the last two theorems show); each accepted write gets a new
revision; device clocks give versions whose order decides who wins — skew
changes the winner, never the theorems; and storage is durable. Steps are
atomic: a device's pass is many steps here, and any interleaving of them is
covered. -/

namespace Interleaving

abbrev Content := Nat → Nat

def join (a b : Content) : Content := fun i => max (a i) (b i)

def Covers (big small : Content) : Prop := ∀ i, small i ≤ big i

theorem join_comm (a b : Content) : join a b = join b a := by
  funext i; simp only [join]; omega

theorem join_assoc (a b c : Content) : join (join a b) c = join a (join b c) := by
  funext i; simp only [join]; omega

theorem join_idem (a : Content) : join a a = a := by
  funext i; simp only [join]; omega

theorem join_covers_left (a b : Content) : Covers (join a b) a := by
  intro i; simp only [join]; omega

theorem join_covers_right (a b : Content) : Covers (join a b) b := by
  intro i; simp only [join]; omega

theorem covers_refl (a : Content) : Covers a a := fun _ => Nat.le_refl _

theorem covers_trans (a b c : Content) (hab : Covers a b) (hbc : Covers b c) : Covers a c :=
  fun i => Nat.le_trans (hbc i) (hab i)

structure Server where
  revision : Nat
  content : Content

structure Device where
  content : Content
  seen : Option (Nat × Content)

structure World where
  server : Server
  a : Device
  b : Device

inductive Who where | a | b
  deriving DecidableEq, Repr

inductive Step where
  | edit (who : Who) (item version : Nat)
  | pull (who : Who)
  | publish (who : Who)

def World.device (w : World) : Who → Device
  | .a => w.a
  | .b => w.b

def World.setDevice (w : World) : Who → Device → World
  | .a, d => { w with a := d }
  | .b, d => { w with b := d }

def edited (item version : Nat) : Content := fun j => if j = item then version else 0

-- A pull merges the server's content in and remembers the revision it read.
-- A publish is the conditional write: accepted only while the server still
-- holds that revision, and then it holds this device's content.
def step (w : World) : Step → World
  | .edit who item version =>
    let d := w.device who
    w.setDevice who { d with content := join d.content (edited item version) }
  | .pull who =>
    let d := w.device who
    w.setDevice who ⟨join d.content w.server.content, some (w.server.revision, w.server.content)⟩
  | .publish who =>
    let d := w.device who
    match d.seen with
    | some (r, _) =>
      if r = w.server.revision then
        { (w.setDevice who { d with seen := some (r + 1, d.content) }) with
            server := ⟨r + 1, d.content⟩ }
      else w
    | none => w

def run (w : World) : List Step → World
  | [] => w
  | s :: rest => run (step w s) rest

-- What a device last read is still in it, and if the server has not moved
-- since, it is what the server holds.
def DeviceAgrees (server : Server) (d : Device) : Prop :=
  match d.seen with
  | none => True
  | some (r, c) => Covers d.content c ∧ r ≤ server.revision ∧ (r = server.revision → c = server.content)

def Agrees (w : World) : Prop := DeviceAgrees w.server w.a ∧ DeviceAgrees w.server w.b

theorem device_setDevice_same (w : World) (who : Who) (d : Device) :
    (w.setDevice who d).device who = d := by cases who <;> rfl

theorem server_setDevice (w : World) (who : Who) (d : Device) :
    (w.setDevice who d).server = w.server := by cases who <;> rfl

-- The server never loses anything: every step leaves it covering what it held.
theorem serverNeverLoses (w : World) (s : Step) (h : Agrees w) :
    Covers (step w s).server.content w.server.content := by
  cases s with
  | edit who item version =>
    simp only [step, server_setDevice]; exact covers_refl _
  | pull who =>
    simp only [step, server_setDevice]; exact covers_refl _
  | publish who =>
    have hd : DeviceAgrees w.server (w.device who) := by cases who <;> simp [World.device, h.1, h.2]
    simp only [step]
    split
    · next r c hseen =>
      split
      · next hr =>
        simp only [DeviceAgrees, hseen] at hd
        have hc := hd.2.2 hr
        subst hc
        exact hd.1
      · exact covers_refl _
    · exact covers_refl _

theorem deviceAgrees_grow (s : Server) (d d' : Device) (h : DeviceAgrees s d)
    (grow : Covers d'.content d.content) (same : d'.seen = d.seen) : DeviceAgrees s d' := by
  unfold DeviceAgrees at *
  rw [same]
  cases hs : d.seen with
  | none => trivial
  | some p =>
    rw [hs] at h
    exact ⟨covers_trans _ _ _ grow h.1, h.2.1, h.2.2⟩

theorem deviceAgrees_pulled (s : Server) (content : Content) :
    DeviceAgrees s ⟨join content s.content, some (s.revision, s.content)⟩ := by
  unfold DeviceAgrees
  exact ⟨join_covers_right _ _, Nat.le_refl _, fun _ => rfl⟩

theorem deviceAgrees_published (d : Device) (r : Nat) :
    DeviceAgrees ⟨r + 1, d.content⟩ { d with seen := some (r + 1, d.content) } := by
  unfold DeviceAgrees
  exact ⟨covers_refl _, Nat.le_refl _, fun _ => rfl⟩

-- The other device's last read is now behind the server, so nothing more is
-- claimed about it than that it is behind.
theorem deviceAgrees_afterOtherPublishes (s : Server) (d : Device) (h : DeviceAgrees s d)
    (r : Nat) (hr : r = s.revision) (content : Content) :
    DeviceAgrees ⟨r + 1, content⟩ d := by
  unfold DeviceAgrees at *
  cases hs : d.seen with
  | none => trivial
  | some p =>
    rw [hs] at h
    obtain ⟨cov, le, _⟩ := h
    refine ⟨cov, ?_, fun e => ?_⟩
    · show p.1 ≤ r + 1
      omega
    · exfalso
      have : p.1 = r + 1 := e
      omega

theorem agreesAfterStep (w : World) (s : Step) (h : Agrees w) : Agrees (step w s) := by
  obtain ⟨ha, hb⟩ := h
  cases s with
  | edit who item version =>
    cases who
    · exact ⟨deviceAgrees_grow _ _ _ ha (join_covers_left _ _) rfl, hb⟩
    · exact ⟨ha, deviceAgrees_grow _ _ _ hb (join_covers_left _ _) rfl⟩
  | pull who =>
    cases who
    · exact ⟨deviceAgrees_pulled _ _, hb⟩
    · exact ⟨ha, deviceAgrees_pulled _ _⟩
  | publish who =>
    cases who
    · simp only [step, World.device]
      split
      · next r c hseen =>
        split
        · next hr =>
          exact ⟨deviceAgrees_published _ _, deviceAgrees_afterOtherPublishes _ _ hb _ hr _⟩
        · exact ⟨ha, hb⟩
      · exact ⟨ha, hb⟩
    · simp only [step, World.device]
      split
      · next r c hseen =>
        split
        · next hr =>
          exact ⟨deviceAgrees_afterOtherPublishes _ _ ha _ hr _, deviceAgrees_published _ _⟩
        · exact ⟨ha, hb⟩
      · exact ⟨ha, hb⟩

theorem agreesAlongRun (w : World) (steps : List Step) (h : Agrees w) : Agrees (run w steps) := by
  induction steps generalizing w with
  | nil => exact h
  | cons s rest ih => exact ih _ (agreesAfterStep w s h)

-- Whatever the devices do, in whatever order, the server never loses
-- anything it held.
theorem serverNeverLosesAlongRun (w : World) (steps : List Step) (h : Agrees w) :
    Covers (run w steps).server.content w.server.content := by
  induction steps generalizing w with
  | nil => exact covers_refl _
  | cons s rest ih =>
    exact covers_trans _ _ _ (ih _ (agreesAfterStep w s h)) (serverNeverLoses w s h)

-- Devices that have not synced yet claim nothing, so any library starts out
-- agreeing.
theorem unsyncedDevicesAgree (server : Server) (a b : Content) :
    Agrees ⟨server, ⟨a, none⟩, ⟨b, none⟩⟩ := ⟨trivial, trivial⟩

-- A publish the server refuses changes nothing anywhere.
theorem refusedPublishChangesNothing (w : World) (who : Who)
    (h : ∀ r c, (w.device who).seen = some (r, c) → r ≠ w.server.revision) :
    step w (.publish who) = w := by
  simp only [step]
  split
  · next r c hseen =>
    have := h r c hseen
    simp [this]
  · rfl

-- Reading and then publishing, with nobody else publishing in between, is
-- accepted: the bundle's update, reading again after a refused write,
-- succeeds unless another device publishes again inside it.
theorem pullThenPublishIsAccepted (w : World) (who : Who) :
    (run w [.pull who, .publish who]).server =
      ⟨w.server.revision + 1, join (w.device who).content w.server.content⟩ := by
  cases who <;> simp [run, step, World.device, World.setDevice]

-- What an accepted publish put on the server stays there, whatever happens
-- after.
theorem publishedContentIsNeverLost (w : World) (who : Who) (h : Agrees w)
    (steps : List Step) :
    Covers (run (run w [.pull who, .publish who]) steps).server.content
      (join (w.device who).content w.server.content) := by
  have hAgree : Agrees (run w [.pull who, .publish who]) := agreesAlongRun _ _ h
  have hLater := serverNeverLosesAlongRun _ steps hAgree
  rw [pullThenPublishIsAccepted] at hLater
  exact hLater

-- Once editing stops, one quiet round brings both devices and the server to
-- the same content: everything any of them held.
theorem aQuietRoundConverges (w : World) :
    let after := run w [.pull .a, .publish .a, .pull .b, .publish .b, .pull .a]
    after.a.content = after.b.content ∧
    after.b.content = after.server.content ∧
    after.server.content = join (join w.a.content w.b.content) w.server.content := by
  simp only [run, step, World.device, World.setDevice, ↓reduceIte]
  refine ⟨?_, ?_, ?_⟩
  all_goals first | trivial | (funext i; simp only [join]; omega)

/-! ### Without the condition

iCloud's provider path has no server-side precondition: a write replaces
whatever is there. On the same schedule as the theorem below, a conditional
write keeps the other device's edit, and an unconditional one loses it. -/

def publishUnconditionally (w : World) (who : Who) : World :=
  let d := w.device who
  { w with server := ⟨w.server.revision + 1, d.content⟩ }

def blank : World := ⟨⟨0, fun _ => 0⟩, ⟨fun _ => 0, none⟩, ⟨fun _ => 0, none⟩⟩

-- Both read; B edits item 1 and publishes; A, whose read is now stale,
-- publishes too.
theorem conditionalPublishKeepsTheOtherEdit :
    (run blank [.pull .a, .pull .b, .edit .b 1 5, .publish .b, .publish .a]).server.content 1 = 5 := by
  simp [run, step, blank, World.device, World.setDevice, join, edited]

theorem unconditionalPublishLosesTheOtherEdit :
    (publishUnconditionally
      (publishUnconditionally (run blank [.pull .a, .pull .b, .edit .b 1 5]) .b) .a).server.content 1 = 0 := by
  simp [run, step, blank, World.device, World.setDevice, join, publishUnconditionally]

end Interleaving

/-! ## Connecting rules for conformance

Two older rules are stated over shapes the Swift code does not use. These say
what the Swift decision computes and prove it agrees with the rule. -/

-- `LampSyncMerge.shouldReplaceFile` answers whether an incoming file replaces
-- the current one: whether `mergeFile` chooses it and it is not the same.
def replaceFile (current incoming : FileVersion) : Bool :=
  mergeFile current incoming == incoming && current != incoming

theorem replacedFileIsWhatMergeChooses (current incoming : FileVersion)
    (h : replaceFile current incoming = true) : mergeFile current incoming = incoming := by
  simp [replaceFile] at h
  exact h.1

theorem keptFileIsWhatMergeChooses (current incoming : FileVersion)
    (h : replaceFile current incoming = false) : mergeFile current incoming = current := by
  unfold replaceFile at h
  unfold mergeFile at *
  split at h <;> simp_all

/-! ## The per-file library (design B)

Each module is its own file, and the manifest in the settings bundle says
which files belong to the library (`LampSyncLibraryManifest`). Per path it
keeps two stamps: the latest write and the latest deletion, each a time and
the revision it concerned. Revisions are opaque, so numbers here. -/

abbrev Stamp := Option Nat × Option Nat

-- An absent time or revision orders before any present one.
def optKey : Option Nat → Nat
  | none => 0
  | some n => n + 1

theorem optKey_inj {a b : Option Nat} (h : optKey a = optKey b) : a = b := by
  cases a <;> cases b <;> simp_all [optKey]

-- Stamps order by time, then by revision, so equal times still pick one the
-- same way on every device.
def stampLE (a b : Stamp) : Prop :=
  optKey a.1 < optKey b.1 ∨ (optKey a.1 = optKey b.1 ∧ optKey a.2 ≤ optKey b.2)

instance (a b : Stamp) : Decidable (stampLE a b) := by
  unfold stampLE; infer_instance

theorem stampLE_refl (a : Stamp) : stampLE a a := by unfold stampLE; omega

theorem stampLE_total (a b : Stamp) : stampLE a b ∨ stampLE b a := by unfold stampLE; omega

theorem stampLE_trans {a b c : Stamp} (h1 : stampLE a b) (h2 : stampLE b c) : stampLE a c := by
  unfold stampLE at *; omega

theorem stampLE_antisymm {a b : Stamp} (h1 : stampLE a b) (h2 : stampLE b a) : a = b := by
  unfold stampLE at h1 h2
  exact Prod.ext (optKey_inj (by omega)) (optKey_inj (by omega))

def laterStamp (a b : Stamp) : Stamp := if stampLE a b then b else a

theorem laterStamp_left (a b : Stamp) : stampLE a (laterStamp a b) := by
  unfold laterStamp; split
  · assumption
  · exact stampLE_refl a

theorem laterStamp_right (a b : Stamp) : stampLE b (laterStamp a b) := by
  unfold laterStamp; split
  · exact stampLE_refl b
  · rename_i h; exact (stampLE_total a b).resolve_left h

theorem laterStamp_cases (a b : Stamp) : laterStamp a b = a ∨ laterStamp a b = b := by
  unfold laterStamp; split <;> simp

theorem laterStamp_comm (a b : Stamp) : laterStamp a b = laterStamp b a :=
  stampLE_antisymm
    (by rcases laterStamp_cases a b with h | h <;> rw [h]
        · exact laterStamp_right b a
        · exact laterStamp_left b a)
    (by rcases laterStamp_cases b a with h | h <;> rw [h]
        · exact laterStamp_right a b
        · exact laterStamp_left a b)

theorem laterStamp_idem (a : Stamp) : laterStamp a a = a := by
  rcases laterStamp_cases a a with h | h <;> exact h

theorem laterStamp_assoc (a b c : Stamp) :
    laterStamp (laterStamp a b) c = laterStamp a (laterStamp b c) := by
  have la := stampLE_trans (laterStamp_left a b) (laterStamp_left (laterStamp a b) c)
  have lb := stampLE_trans (laterStamp_right a b) (laterStamp_left (laterStamp a b) c)
  have lc := laterStamp_right (laterStamp a b) c
  have ra := laterStamp_left a (laterStamp b c)
  have rb := stampLE_trans (laterStamp_left b c) (laterStamp_right a (laterStamp b c))
  have rc := stampLE_trans (laterStamp_right b c) (laterStamp_right a (laterStamp b c))
  apply stampLE_antisymm
  · rcases laterStamp_cases (laterStamp a b) c with h | h <;> rw [h]
    · rcases laterStamp_cases a b with h' | h' <;> rw [h'] <;> assumption
    · assumption
  · rcases laterStamp_cases a (laterStamp b c) with h | h <;> rw [h]
    · assumption
    · rcases laterStamp_cases b c with h' | h' <;> rw [h'] <;> assumption

structure ManifestEntry where
  presentSince : Option Nat
  revision : Option Nat
  deletedAt : Option Nat
  deletedRevision : Option Nat
  deriving DecidableEq, Repr

def ManifestEntry.written (e : ManifestEntry) : Stamp := (e.presentSince, e.revision)
def ManifestEntry.deleted (e : ManifestEntry) : Stamp := (e.deletedAt, e.deletedRevision)

def ManifestEntry.withStamps (w d : Stamp) : ManifestEntry := ⟨w.1, w.2, d.1, d.2⟩

@[simp] theorem ManifestEntry.written_withStamps (w d : Stamp) :
    (ManifestEntry.withStamps w d).written = w := rfl

@[simp] theorem ManifestEntry.deleted_withStamps (w d : Stamp) :
    (ManifestEntry.withStamps w d).deleted = d := rfl

def emptyEntry : ManifestEntry := ⟨none, none, none, none⟩

-- Two manifests merge path by path, keeping the later of each stamp.
def mergeManifestEntry (a b : ManifestEntry) : ManifestEntry :=
  .withStamps (laterStamp a.written b.written) (laterStamp a.deleted b.deleted)

theorem mergeManifestEntry_comm (a b : ManifestEntry) :
    mergeManifestEntry a b = mergeManifestEntry b a := by
  simp [mergeManifestEntry, laterStamp_comm]

theorem mergeManifestEntry_assoc (a b c : ManifestEntry) :
    mergeManifestEntry (mergeManifestEntry a b) c = mergeManifestEntry a (mergeManifestEntry b c) := by
  simp only [mergeManifestEntry, ManifestEntry.written_withStamps,
    ManifestEntry.deleted_withStamps, laterStamp_assoc]

theorem mergeManifestEntry_idem (a : ManifestEntry) : mergeManifestEntry a a = a := by
  simp only [mergeManifestEntry, laterStamp_idem]; rfl

-- A file is a member while it was written after its latest deletion. Equal
-- times are a deletion, as the other ledgers rule.
def entryIsMember (e : ManifestEntry) : Bool :=
  match e.presentSince, e.deletedAt with
  | none, _ => false
  | some _, none => true
  | some p, some d => Decidable.decide (d < p)

theorem equalTimeDeletesAFile (t : Nat) (r d : Option Nat) :
    entryIsMember ⟨some t, r, some t, d⟩ = false := by
  simp [entryIsMember]

-- Devices that merged the same manifests, in any order, agree on membership.
theorem membershipIgnoresMergeOrder (a b : ManifestEntry) :
    entryIsMember (mergeManifestEntry a b) = entryIsMember (mergeManifestEntry b a) := by
  rw [mergeManifestEntry_comm]

-- A write recorded over the revision the manifest holds is that write's
-- successor, and is stamped after it, so a slow clock cannot make the later
-- write lose. Any other write takes the later stamp.
def recordWrite (e : ManifestEntry) (rev previous : Option Nat) (time : Nat) : ManifestEntry :=
  if e.revision = previous then
    { e with presentSince := some (max time ((e.presentSince.map (· + 1)).getD time)),
             revision := rev }
  else .withStamps (laterStamp e.written (some time, rev)) e.deleted

theorem successorWriteIsStampedLater (e : ManifestEntry) (rev : Option Nat) (time p : Nat)
    (h : e.presentSince = some p) :
    ∃ q, (recordWrite e rev e.revision time).presentSince = some q ∧ p < q := by
  simp [recordWrite, h]; omega

-- Whichever branch records it, a write is stamped no earlier than it was made.
theorem recordedWriteIsNoEarlier (e : ManifestEntry) (rev previous : Option Nat) (time : Nat) :
    ∃ q, (recordWrite e rev previous time).presentSince = some q ∧ time ≤ q := by
  unfold recordWrite
  split
  · exact ⟨_, rfl, Nat.le_max_left _ _⟩
  · have h := laterStamp_right e.written (some time, rev)
    unfold stampLE at h
    revert h
    generalize laterStamp e.written (some time, rev) = s
    obtain ⟨s1, s2⟩ := s
    cases s1 <;> simp [ManifestEntry.withStamps, optKey] <;> omega

-- So a copy written after a deletion comes out a member, on either branch.
theorem writeAfterDeletionIsMember (e : ManifestEntry) (rev previous : Option Nat)
    (time d : Nat) (hd : e.deletedAt = some d) (hlater : d < time) :
    entryIsMember (recordWrite e rev previous time) = true := by
  obtain ⟨q, hq, hle⟩ := recordedWriteIsNoEarlier e rev previous time
  have hdel : (recordWrite e rev previous time).deletedAt = some d := by
    unfold recordWrite; split <;> simp [ManifestEntry.withStamps, ManifestEntry.deleted, hd]
  simp [entryIsMember, hq, hdel]; omega

-- Whether a copy at `r` is the one a tombstone deleted, or the write it
-- recorded before that. A tombstone with neither recorded matches any copy.
def deletesRevision (e : ManifestEntry) (r : Nat) : Bool :=
  match e.revision, e.deletedRevision with
  | none, none => true
  | a, b => a == some r || b == some r

def removeFile (e : ManifestEntry) (time : Nat) (rev : Option Nat) : ManifestEntry :=
  .withStamps e.written (laterStamp e.deleted (some time, rev))

-- Adopting a file found on the server: one dropped in by hand, or one a pass
-- wrote and ended before recording. The deleted copy, waiting to be reaped,
-- is never adopted; anything else put back is, after the deletion.
def adoptFile (e : ManifestEntry) (rev time : Nat) : ManifestEntry :=
  if entryIsMember e then
    if e.revision.isNone then { e with revision := some rev } else e
  else if e.deletedAt.isSome && deletesRevision e rev then e
  else { e with presentSince := some (max time (((later e.presentSince e.deletedAt).map (· + 1)).getD time)),
                revision := some rev }

theorem adoptionNeverUndoesADeletion (e : ManifestEntry) (r t : Nat)
    (hm : entryIsMember e = false) (hd : e.deletedAt.isSome = true) (hr : deletesRevision e r = true) :
    adoptFile e r t = e := by
  simp [adoptFile, hm, hd, hr]

theorem aCopyPutBackIsAdopted (e : ManifestEntry) (r t d : Nat)
    (hm : entryIsMember e = false) (hd : e.deletedAt = some d) (hr : deletesRevision e r = false) :
    entryIsMember (adoptFile e r t) = true := by
  have bound : ∃ m, later e.presentSince (some d) = some m ∧ d ≤ m := by
    cases e.presentSince <;> simp [later] <;> omega
  obtain ⟨m, hl, hle⟩ := bound
  unfold adoptFile
  rw [hm]
  simp only [hd, hr, hl, Option.isSome_some, Bool.and_false, Bool.false_eq_true, ite_false,
    Option.map_some, Option.getD_some]
  simp [entryIsMember]; omega

-- A deletion is remembered for 180 days, in milliseconds.
def tombstoneLifetime : Nat := 180 * 24 * 60 * 60 * 1000

-- A tombstone goes once it is older than that, and, for a listed kind, once
-- its file is gone too: until then it is what tells devices to reap it.
def pruneTombstone (e : ManifestEntry) (now : Nat) (listed present : Bool) : Bool :=
  !entryIsMember e
    && (match e.deletedAt with | some d => Decidable.decide (d + tombstoneLifetime ≤ now) | none => false)
    && (!listed || !present)

theorem pruneNeverDropsAMember (e : ManifestEntry) (now : Nat) (listed present : Bool)
    (h : entryIsMember e = true) : pruneTombstone e now listed present = false := by
  simp [pruneTombstone, h]

theorem pruneWaitsForTheReap (e : ManifestEntry) (now : Nat) :
    pruneTombstone e now true true = false := by
  simp [pruneTombstone]

-- The cost accepted with the lifetime: once a tombstone is pruned, a device
-- offline for longer still holds the file and records it again, at the time
-- it last saved it, which predates the deletion. It comes back.
theorem tombstoneLifetimeCost :
    let deleted := ⟨some 1, some 1, some 5, some 1⟩
    pruneTombstone deleted (5 + tombstoneLifetime) false false = true
      ∧ entryIsMember (recordWrite emptyEntry (some 1) none 1) = true := by
  decide

/-! ### What a pass does with each file

`LampSyncFilePlan.plan` decides, per path, from the manifest entry, this
client's copy, a deletion made here and not yet in a written bundle, and the
revision a listing found on the server. One rule underlies the rest: a file
and the manifest disagreeing means the file changed, and is compared by
value. It is never a conflict or a loss. That is what lets a pass write its
files first and record them in one bundle update at the end. -/

-- Media never changes at a path. Listed kinds (modules, decks) are found by
-- listing their folders; workspace files are checked one at a time.
inductive FileClass where
  | media | listed | unlisted
  deriving DecidableEq, Repr

structure HeldFile where
  changed : Bool
  lastRevision : Option Nat
  savedAt : Option Nat
  deriving DecidableEq, Repr

structure PlanAction where
  download : Bool := false
  merge : Option Nat := none
  upload : Option WriteCondition := none
  deleteLocally : Bool := false
  adopt : Option Nat := none
  tombstone : Option Nat := none
  reap : Option Nat := none
  -- An upload that survives a tombstone, with its time: the write is recorded
  -- after it, so it supersedes the tombstone however fast the clock that
  -- dated it.
  supersede : Option Nat := none
  deriving DecidableEq, Repr

def uploadAction (c : WriteCondition) : PlanAction := { upload := some c }

-- A member, or a file being adopted: this client's copy against the server's.
def changeAction (cls : FileClass) (held : Option HeldFile) (listed : Option Nat) : PlanAction :=
  match cls, held, listed with
  | .media, none, _ => { download := true }
  | .media, some h, _ => if h.lastRevision.isNone then uploadAction .ifAbsent else {}
  | _, none, none => {}
  | _, none, some _ => { download := true }
  | _, some h, none => if h.changed || h.lastRevision.isNone then uploadAction .ifAbsent else {}
  | _, some h, some r =>
    match h.lastRevision != some r, h.changed with
    | false, false => {}
    | false, true => uploadAction (.ifRevision r)
    | true, false => { download := true }
    | true, true => { merge := some r }

-- A path no library deletes, under a tombstone some older client recorded:
-- planned as a member, a copy the server has lost sent back, and any write
-- recorded after the tombstone, which it then supersedes.
def refusedTombstoneAction (cls : FileClass) (held : Option HeldFile) (listed : Option Nat)
    (d : Nat) : PlanAction :=
  let a := match held, listed with
    | some _, none => uploadAction .ifAbsent
    | _, _ => changeAction cls held listed
  if a.upload.isSome || a.merge.isSome then { a with supersede := some d } else a

def savedAfter (h : HeldFile) (d : Nat) : Bool :=
  match h.savedAt with
  | some s => Decidable.decide (d < s)
  | none => false

-- `deletable` is whether a library carries out a deletion of the path
-- (`deleteTarget`). One it never does is never tombstoned, asked to be deleted
-- here, or reaped: a held copy survives a tombstone and goes back up.
def filePlanAction (cls : FileClass) (entry : Option ManifestEntry) (held : Option HeldFile)
    (deletedHere listed : Option Nat) (deletable : Bool := true) : PlanAction :=
  match if deletable then deletedHere else none with
  | some d =>
    let after := removeFile (entry.getD emptyEntry) d listed
    if entryIsMember after then
      -- Written elsewhere after it was deleted here: it comes back.
      { tombstone := some d, download := held.isNone && (listed.isSome || cls == .media) }
    else
      { tombstone := some d,
        reap := match listed with
          | some r => some r
          | none => if cls == .listed then none else (entry.bind (·.revision)) }
  | none =>
    match entry with
    | none =>
      match listed with
      | none => if held.isSome then uploadAction .ifAbsent else {}
      | some r => { changeAction cls held listed with adopt := some r }
    | some e =>
      if entryIsMember e then changeAction cls held listed
      else if !deletable && e.deletedAt.isSome then refusedTombstoneAction cls held listed (e.deletedAt.getD 0)
      else match e.deletedAt with
        | none =>
          match listed with
          | none => if held.isSome then uploadAction .ifAbsent else {}
          | some r => { changeAction cls held listed with adopt := some r }
        | some d =>
          match listed with
          | some r =>
            if !deletesRevision e r then { changeAction cls held listed with adopt := some r }
            else match held with
              | some h => if savedAfter h d then
                  { uploadAction (if cls == .media then .ifAbsent else .ifRevision r) with supersede := some d }
                else { deleteLocally := true, reap := some r }
              | none => { reap := some r }
          | none =>
            match held with
            | some h => if savedAfter h d then { uploadAction .ifAbsent with supersede := some d }
                else { deleteLocally := true }
            | none => {}

theorem changeActionNeverReaps (cls : FileClass) (held : Option HeldFile) (listed : Option Nat) :
    (changeAction cls held listed).reap = none ∧ (changeAction cls held listed).tombstone = none := by
  unfold changeAction
  split <;> (try split) <;> (try split) <;> exact ⟨rfl, rfl⟩

theorem changeActionNeverDeletes (cls : FileClass) (held : Option HeldFile) (listed : Option Nat) :
    (changeAction cls held listed).deleteLocally = false
      ∧ (changeAction cls held listed).adopt = none := by
  unfold changeAction
  split <;> (try split) <;> (try split) <;> exact ⟨rfl, rfl⟩

-- Absence from a listing never deletes: nothing is deleted here without a
-- tombstone in the manifest.
theorem deletingNeedsATombstone (cls : FileClass) (entry : Option ManifestEntry)
    (held : Option HeldFile) (listed : Option Nat)
    (h : (filePlanAction cls entry held none listed).deleteLocally = true) :
    ∃ e d, entry = some e ∧ e.deletedAt = some d ∧ entryIsMember e = false := by
  have keeps := (changeActionNeverDeletes cls held listed).1
  unfold filePlanAction at h
  cases entry with
  | none =>
    cases listed with
    | none => cases held <;> simp [uploadAction] at h
    | some r => simp [keeps] at h
  | some e =>
    by_cases hm : entryIsMember e = true
    · simp [hm, keeps] at h
    · cases hd : e.deletedAt with
      | none =>
        simp only [hm, hd] at h
        cases listed with
        | none => cases held <;> simp [uploadAction] at h
        | some r => simp [keeps] at h
      | some d => exact ⟨e, d, rfl, hd, by simpa using hm⟩

-- A file on the server that nobody tombstoned is adopted, never dropped.
theorem anUnknownFileIsAdopted (cls : FileClass) (held : Option HeldFile) (r : Nat) :
    (filePlanAction cls none held none (some r)).adopt = some r
      ∧ (filePlanAction cls none held none (some r)).deleteLocally = false := by
  simp [filePlanAction, (changeActionNeverDeletes cls held (some r)).1]

-- With no record of what it last installed, a client never writes over the
-- server's copy: it downloads it, or merges with it. Records are kept per
-- provider, so a provider switch starts here rather than re-uploading.
theorem noRecordNeverOverwrites (cls : FileClass) (e : ManifestEntry) (h : HeldFile) (r : Nat)
    (hc : cls ≠ .media) (hm : entryIsMember e = true) (hr : h.lastRevision = none) :
    (filePlanAction cls (some e) (some h) none (some r)).upload = none := by
  simp only [filePlanAction, hm, ite_true]
  cases cls with
  | media => exact absurd rfl hc
  | listed | unlisted =>
    have hne : ((none : Option Nat) != some r) = true := rfl
    cases hch : h.changed <;> simp [changeAction, hr, hch, hne]

/-! ### When nothing has changed

A pass over a file nobody has touched since the last one does nothing: a
member held unchanged at the revision listed, or a deletion every device has
carried out. Every loop the apps have hit — the same file installed on every
pass, two devices trading one encoding for another — broke this. -/

theorem aSettledFileNeedsNothing (cls : FileClass) (e : ManifestEntry) (r : Nat)
    (saved : Option Nat) (member : entryIsMember e = true) :
    filePlanAction cls (some e) (some ⟨false, some r, saved⟩) none (some r) = {} := by
  cases cls <;> simp [filePlanAction, member, changeAction]

theorem aSettledDeletionNeedsNothing (cls : FileClass) (e : ManifestEntry) (d : Nat)
    (gone : entryIsMember e = false) (deleted : e.deletedAt = some d) :
    filePlanAction cls (some e) none none none = {} := by
  simp [filePlanAction, gone, deleted]

/-! ### A tree taken in together

A workspace's files are staged as they arrive and taken in together once
every download is done (`isTakenInTogether`), and that import can stop
partway. A staged file is recorded as installed only once the tree is in. Then
nothing has to record how far the import got: a file it did not reach is
absent here, or still the copy this device last recorded, and either way the
next pass takes it again, since only the server moved. -/

theorem aPartialTreeImportIsCompletedByTheNextPass (cls : FileClass) (e : ManifestEntry)
    (old r : Nat) (saved : Option Nat) (member : entryIsMember e = true) (moved : old ≠ r)
    (notMedia : cls ≠ .media) :
    filePlanAction cls (some e) none none (some r) = { download := true } ∧
      filePlanAction cls (some e) (some ⟨false, some old, saved⟩) none (some r) = { download := true } := by
  have differs : (some old != some r) = true := by simp [moved]
  cases cls
  · exact absurd rfl notMedia
  all_goals
    refine ⟨by simp [filePlanAction, member, changeAction], ?_⟩
    simp only [filePlanAction, member, ↓reduceIte, changeAction]
    split <;> simp_all

-- Recorded when staged, a failed import leaves the record naming the new
-- revision over the old copy: it reads as an edit here, and goes up over the
-- other device's.
theorem recordingAStagedInstallSendsTheOldCopyBack (cls : FileClass) (e : ManifestEntry)
    (r : Nat) (saved : Option Nat) (member : entryIsMember e = true) (notMedia : cls ≠ .media) :
    filePlanAction cls (some e) (some ⟨true, some r, saved⟩) none (some r) =
      uploadAction (.ifRevision r) := by
  cases cls <;> simp_all [filePlanAction, changeAction]

/-! ### Which highlight set a module ID names

`LampSyncHighlightModules.setIDsByModule` (macOS): the set a highlight
module's ID stands for, when a pass acts on a path rather than on a set. The
recorded mapping outlives the sets in it — a set deleted here keeps its entry,
and the phone gives a new set on the same translation the same module ID — so
it is read only through the sets that exist, the first of them in the
library's order. -/

def setForModule (moduleOf : Nat → Option Nat) (existing : List Nat) (m : Nat) : Option Nat :=
  existing.find? fun s => moduleOf s == some m

theorem aModuleIDResolvesToASetThatExists (moduleOf : Nat → Option Nat) (existing : List Nat)
    (m s : Nat) (h : setForModule moduleOf existing m = some s) :
    s ∈ existing ∧ moduleOf s = some m := by
  unfold setForModule at h
  exact ⟨List.mem_of_find?_eq_some h, by simpa using List.find?_some h⟩

-- Inverting the whole mapping instead: a deleted set's entry left under the
-- same module ID can win, decided only by which entry the inversion meets
-- first — in Swift, a dictionary's order, seeded per process.
def setForModuleFromTheWholeMapping (entries : List (Nat × Nat)) (m : Nat) : Option Nat :=
  (entries.find? fun e => e.2 == m).map (·.1)

theorem invertingTheWholeMappingCanNameADeletedSet :
    setForModuleFromTheWholeMapping [(1, 7), (2, 7)] 7 = some 1 ∧
      setForModule (fun s => if s = 1 ∨ s = 2 then some 7 else none) [2] 7 = some 2 := by
  decide

/-! ### Save times

The plan settles a tombstone against a copy by the copy's last save: saved
after the deletion, it survives and goes back up; otherwise it goes. A copy
with no save time always goes, since nothing says the edit came after. So a
client must report a save time for every copy that holds a person's own
writing — notes, writing, highlights and decks. Modules and media may go
without: the server can always supply them again. Each app's gather is held to
this by its own tests. -/

theorem anUnreportedSaveLosesToADeletion (changed : Bool) (last : Option Nat) (r d : Nat) :
    (filePlanAction .listed (some ⟨some 0, some r, some d, some r⟩)
      (some ⟨changed, last, none⟩) none (some r)).deleteLocally = true := by
  simp [filePlanAction, entryIsMember, deletesRevision, savedAfter]

theorem aSaveAfterTheDeletionSurvives (changed : Bool) (last : Option Nat) (r d s : Nat)
    (after : d < s) :
    filePlanAction .listed (some ⟨some 0, some r, some d, some r⟩)
      (some ⟨changed, last, some s⟩) none (some r) =
        { uploadAction (.ifRevision r) with supersede := some d } := by
  simp [filePlanAction, entryIsMember, deletesRevision, savedAfter, after]

/-! ### Deleting a copy here

`LampSyncLocalDeletion.target`: what deleting a path from a device's library
removes, decided alike on both sides — whether a removal here may be recorded
as a deletion, and whether one recorded elsewhere is carried out. The notes
and writing collections are one file each holding every note or writing, so
deleting the file would delete them all; their items are deleted through the
ledger instead. Any other notes or writing module is a module, and so is a
highlight set: one file per set, so deleting a set deletes it everywhere. -/

inductive LocalKind where
  | module | collection | deck | deckAsset | media | workspaceFile | outside
  deriving DecidableEq, Repr

inductive LocalDeletion where
  | module (id : Nat) | deck | deckAsset | collection | unsupported
  deriving DecidableEq, Repr

def deleteTarget : LocalKind → Option Nat → LocalDeletion
  | .collection, _ => .collection
  | .module, some id => .module id
  | .module, none => .unsupported
  | .deck, _ => .deck
  | .deckAsset, _ => .deckAsset
  | .media, _ | .workspaceFile, _ | .outside, _ => .unsupported

def deleteAllowed : LocalDeletion → Bool
  | .module _ | .deck | .deckAsset => true
  | .collection | .unsupported => false

-- A removal here is recorded as a deletion only where the library would carry
-- one out: the same rule on both sides, so no client records a tombstone
-- another refuses.
def mayRecordRemoval (kind : LocalKind) (id : Option Nat) : Bool :=
  deleteAllowed (deleteTarget kind id)

theorem everyRecordedRemovalIsCarriedOut (kind : LocalKind) (id : Option Nat)
    (recorded : mayRecordRemoval kind id = true) :
    deleteAllowed (deleteTarget kind id) = true := recorded

theorem aCollectionIsNeverDeletedWhole (id : Option Nat) :
    deleteAllowed (deleteTarget .collection id) = false := rfl

theorem aModuleRemovalNamesItsPathsID (id : Nat) :
    deleteTarget .module (some id) = .module id := rfl

-- A copy no library deletes survives any tombstone and goes back up, which
-- supersedes the tombstone; the plan never asks for a deletion the library
-- refuses, which would be refused again on every pass.
theorem aRefusedDeletionGoesBackUp (r d : Nat) (saved : Option Nat) :
    filePlanAction .listed (some ⟨some 0, some r, some d, some r⟩)
      (some ⟨true, some r, saved⟩) none (some r) false =
        { uploadAction (.ifRevision r) with supersede := some d } := by
  simp [filePlanAction, entryIsMember, refusedTombstoneAction, changeAction, uploadAction]

-- A device holding none of it takes the server's copy, and one the server
-- has lost is sent back: the tombstone neither hides the path nor keeps it
-- off the server.
theorem aRefusedTombstoneHidesNothing (r d : Nat) (held : HeldFile) :
    filePlanAction .listed (some ⟨some 0, some r, some d, some r⟩) none none (some r) false =
        { download := true } ∧
      filePlanAction .listed (some ⟨some 0, some r, some d, some r⟩) (some held) none none false =
        { uploadAction .ifAbsent with supersede := some d } := by
  simp [filePlanAction, entryIsMember, refusedTombstoneAction, changeAction, uploadAction]

theorem refusedTombstoneActionNeverDeletes (cls : FileClass) (held : Option HeldFile)
    (listed : Option Nat) (d : Nat) :
    (refusedTombstoneAction cls held listed d).deleteLocally = false ∧
      (refusedTombstoneAction cls held listed d).reap = none ∧
      (refusedTombstoneAction cls held listed d).tombstone = none := by
  unfold refusedTombstoneAction
  rcases held with _ | h <;> rcases listed with _ | r <;>
    simp only [] <;> split <;>
    simp [changeActionNeverDeletes, changeActionNeverReaps, uploadAction]

-- One tactic covers every case, each needing a different one of its lemmas.
set_option linter.unusedSimpArgs false in
theorem thePlanNeverAsksForARefusedDeletion (cls : FileClass) (entry : Option ManifestEntry)
    (held : Option HeldFile) (deletedHere listed : Option Nat) :
    (filePlanAction cls entry held deletedHere listed false).deleteLocally = false ∧
      (filePlanAction cls entry held deletedHere listed false).reap = none ∧
      (filePlanAction cls entry held deletedHere listed false).tombstone = none := by
  unfold filePlanAction
  rcases entry with _ | e <;> simp only [Bool.false_eq_true, ↓reduceIte]
  · rcases listed with _ | r <;> rcases held with _ | h <;>
      simp [changeActionNeverDeletes, changeActionNeverReaps, uploadAction]
  · by_cases hm : entryIsMember e
    · simp [hm, changeActionNeverDeletes, changeActionNeverReaps]
    · simp only [hm, Bool.false_eq_true, ↓reduceIte]
      rcases e.deletedAt with _ | d <;> rcases listed with _ | r <;> rcases held with _ | h <;>
        simp [changeActionNeverDeletes, changeActionNeverReaps, uploadAction,
          refusedTombstoneActionNeverDeletes]
      all_goals (split <;> simp [changeActionNeverDeletes, changeActionNeverReaps, uploadAction,
        refusedTombstoneActionNeverDeletes])

/-! ### Listing revisions

`LampSyncFilePlan.listing` takes a listing's revision when it has one
(WebDAV's ETags), a member's recorded revision when it doesn't (the folder
provider), and asks the store only for a file the manifest doesn't record
as a member. -/

-- The revision used, and whether the store was asked.
def listedRevision (item recordedForMember stored : Option Nat) : Option Nat × Bool :=
  match item, recordedForMember with
  | some r, _ => (some r, false)
  | none, some r => (some r, false)
  | none, none => (stored, true)

-- So an evicted iCloud file the manifest records is never read just to be
-- compared.
theorem aRecordedMemberIsNeverRead (item stored : Option Nat) (r : Nat) :
    (listedRevision item (some r) stored).2 = false := by
  cases item <;> rfl

/-! ### The settings bundle

`LampSyncSettingsStore.update` reads the bundle, applies a change, and
writes it under the revision read; refused, it reads again, up to its
attempts. -/

-- `refusals` says, attempt by attempt, whether another device wrote first.
-- The answer is the attempt that wrote, counting from one.
def settingsUpdateFrom : Nat → List Bool → Nat → Option Nat
  | 0, _, _ => none
  | n + 1, true :: rest, made => settingsUpdateFrom n rest (made + 1)
  | _ + 1, _, made => some (made + 1)

def settingsUpdate (attempts : Nat) (refusals : List Bool) : Option Nat :=
  settingsUpdateFrom (max attempts 1) refusals 0

theorem settingsUpdateFromBounded (n : Nat) (refusals : List Bool) (made k : Nat)
    (h : settingsUpdateFrom n refusals made = some k) : k ≤ made + n := by
  induction n generalizing refusals made with
  | zero => simp [settingsUpdateFrom] at h
  | succ n ih =>
    cases refusals with
    | nil => simp [settingsUpdateFrom] at h; omega
    | cons b rest =>
      cases b with
      | true => have := ih rest (made + 1) (by simpa [settingsUpdateFrom] using h); omega
      | false => simp [settingsUpdateFrom] at h; omega

-- It never writes more times than it was given attempts.
theorem settingsUpdateIsBounded (attempts : Nat) (refusals : List Bool) (k : Nat)
    (h : settingsUpdate attempts refusals = some k) : k ≤ max attempts 1 := by
  have := settingsUpdateFromBounded _ _ _ _ h; omega

-- What the bundle path holds, from the first bytes of its body, so an
-- archive the size of the library is never unpacked to find out.
inductive BundleHeader where
  | version (n : Nat) | entriesFirst | garbage
  deriving DecidableEq, Repr

inductive BundleContents where
  | bundle | archive | newer (n : Nat) | damaged
  deriving DecidableEq, Repr

def bundlePathHolds : BundleHeader → BundleContents
  | .version n =>
    if n = 1 ∨ n = 2 then .archive
    else if n = 3 then .bundle
    else if 3 < n then .newer n
    else .damaged
  | .entriesFirst => .archive
  | .garbage => .damaged

-- Archive readers accept formats 1 and 2 only, so an old client refuses the
-- bundle rather than reading a library with no modules as an emptied one.
def archiveReaderAccepts (version : Nat) : Bool := version == 1 || version == 2

theorem oldReadersRefuseTheBundle : archiveReaderAccepts 3 = false := rfl

theorem anArchiveIsNeverReadAsTheBundle (n : Nat) (h : archiveReaderAccepts n = true) :
    bundlePathHolds (.version n) = .archive := by
  simp [archiveReaderAccepts] at h
  simp [bundlePathHolds, h]

/-! ### The folder as a store

`LampSyncDirectoryStore` runs the folder provider through the same pass. Its
revision is a file's content digest, and a conditional write or delete
compares it inside a coordinated block. Unresolved iCloud versions stop the
file, and a placeholder that appeared means iCloud is replacing it under us,
so that refuses too. This guards against writers on this device only:
`stableICloudReadDoesNotProtectLaterWrite` is the upload that can still land
afterwards. -/

inductive DirectoryOutcome where
  | proceed | refuse | unresolved | nothingThere
  deriving DecidableEq, Repr

def directoryWrite (c : WriteCondition) (current : Option Nat) (placeholder unresolved : Bool) :
    DirectoryOutcome :=
  if unresolved then .unresolved
  else if placeholder then .refuse
  else match c with
    | .unconditional => .proceed
    | .ifAbsent => if current.isNone then .proceed else .refuse
    | .ifRevision r => if current = some r then .proceed else .refuse

def directoryDelete (c : WriteCondition) (current : Option Nat) (placeholder unresolved : Bool) :
    DirectoryOutcome :=
  if unresolved then .unresolved
  else if placeholder then .refuse
  else match current, c with
    | none, _ => .nothingThere
    | some _, .unconditional => .proceed
    | some _, .ifAbsent => .refuse
    | some v, .ifRevision r => if v = r then .proceed else .refuse

-- A conditional write goes ahead exactly when the coordinated check the
-- folder publisher already made allows it.
theorem directoryWriteIsTheCoordinatedCheck (expected current : Option Nat) (placeholder : Bool) :
    (directoryWrite (match expected with | none => .ifAbsent | some r => .ifRevision r)
        current placeholder false = .proceed)
      = coordinatedGenericFileWriteAllowed expected current placeholder := by
  cases expected <;> cases current <;> cases placeholder <;>
    simp [directoryWrite, coordinatedGenericFileWriteAllowed] <;> omega

theorem unresolvedVersionsStopTheFile (c : WriteCondition) (current : Option Nat) (placeholder : Bool) :
    directoryWrite c current placeholder true = .unresolved
      ∧ directoryDelete c current placeholder true = .unresolved := by
  simp [directoryWrite, directoryDelete]

-- A reap never removes a copy other than the one it was asked to.
theorem aDeleteNeverRemovesAnotherCopy (r v : Nat) (placeholder unresolved : Bool) (h : v ≠ r) :
    directoryDelete (.ifRevision r) (some v) placeholder unresolved ≠ .proceed := by
  unfold directoryDelete
  split
  · simp
  · split
    · simp
    · simp [h]

/-! ### Copies written at once

iCloud keeps a losing write as a conflict version instead of refusing it, so
the settings bundle can come back as a current copy with others beside it.
`LampSyncSettingsStore.update` folds each version in, then writes over the
current copy and resolves exactly the versions it merged. -/

-- Nothing at the bundle path: a marker an earlier sync left, or any file in a
-- kind folder, means nobody has migrated this library yet. A folder the Mac
-- keeps holds its files loose with no archive, so absence alone says nothing.
def emptyBundlePath (marker content : Bool) : Bool := marker || content

theorem onlyAnEmptyLibraryIsNew (marker content : Bool) :
    emptyBundlePath marker content = false ↔ marker = false ∧ content = false := by
  cases marker <;> cases content <;> simp [emptyBundlePath]

inductive BundleRead where
  | bundle | fresh | notMigrated
  deriving DecidableEq, Repr

-- What `read` answers: the bundle where there is one, whatever else is there;
-- otherwise new, or an earlier library nobody has migrated.
def bundleRead (bundle marker content : Bool) : BundleRead :=
  if bundle then .bundle
  else if emptyBundlePath marker content then .notMigrated else .fresh

-- A fresh library's pass that wrote its files before the bundle would find
-- its own files at the next read, and call the library an earlier one: it
-- could never finish. So `readOrClaim` writes an empty bundle first.
theorem uploadingFirstLocksAFreshLibraryOut : bundleRead false false true = .notMigrated := rfl

-- Once the path is claimed, no file written after changes what a read finds.
theorem claimingFirstNeverMeetsItsOwnFiles (marker content : Bool) :
    bundleRead true marker content = .bundle := rfl

inductive EarlierLibrary where
  | mac | phone
  deriving DecidableEq, Repr

-- Who kept a library nobody has migrated. The Mac's marks win: its files are
-- a backup's layout, and only its migration can move them. The phone's
-- files are already the per-file layout.
def earlierLibrary (mac phone content : Bool) : Option EarlierLibrary :=
  if mac then some .mac else if phone || content then some .phone else none

-- The same libraries count as earlier as under the empty-path rule.
theorem earlierLibraryIsTheEmptyPathRule (mac phone content : Bool) :
    (earlierLibrary mac phone content).isSome = emptyBundlePath (mac || phone) content := by
  cases mac <;> cases phone <;> cases content <;> rfl

-- Whether a pass may write the first bundle: in a new library always; in one
-- only the phone kept, when migrating it; in one the Mac kept, never.
def mayClaim (migratingPhone : Bool) : Option EarlierLibrary → Bool
  | none => true
  | some .phone => migratingPhone
  | some .mac => false

theorem thePhoneNeverClaimsAMacLibrary (migrating phone content : Bool) :
    mayClaim migrating (earlierLibrary true phone content) = false := by
  simp [earlierLibrary, mayClaim]

-- What an archive's entries can be. The phone's archive holds only settings:
-- its settings database, the legacy manifest beside it, the shared
-- preferences, and the empty portable manifest every new archive starts with.
inductive ArchiveEntry where
  | phoneSettings | legacyManifest | preferences | portableManifest | macSettings | module
  deriving DecidableEq, Repr

def isPhoneEntry : ArchiveEntry → Bool
  | .phoneSettings | .legacyManifest | .preferences | .portableManifest => true
  | .macSettings | .module => false

-- Who wrote an archive: the phone, if it holds nothing but settings.
def archiveKeeper (entries : List ArchiveEntry) : EarlierLibrary :=
  if entries.all isPhoneEntry then .phone else .mac

theorem anArchiveWithAModuleIsTheMacs (entries : List ArchiveEntry) (h : .module ∈ entries) :
    archiveKeeper entries = .mac := by
  have : entries.all isPhoneEntry = false := by
    rw [List.all_eq_false]; exact ⟨.module, h, by simp [isPhoneEntry]⟩
  simp [archiveKeeper, this]

theorem theMacsSettingsMarkItsArchive (entries : List ArchiveEntry) (h : .macSettings ∈ entries) :
    archiveKeeper entries = .mac := by
  have : entries.all isPhoneEntry = false := by
    rw [List.all_eq_false]; exact ⟨.macSettings, h, by simp [isPhoneEntry]⟩
  simp [archiveKeeper, this]

-- Any entry a phone never writes settles an archive as the Mac's, however
-- few of its entries were read: so the start of a library-sized archive is
-- enough to judge it, whatever order its entries' fields came in.
theorem anEntryThePhoneNeverWritesSettlesIt (entries : List ArchiveEntry) (e : ArchiveEntry)
    (he : e ∈ entries) (h : isPhoneEntry e = false) : archiveKeeper entries = .mac := by
  have : entries.all isPhoneEntry = false := by
    rw [List.all_eq_false]; exact ⟨e, he, by simp [h]⟩
  simp [archiveKeeper, this]

-- An ordinary pass never claims an earlier library, so only a migration the
-- person agreed to moves one.
theorem anOrdinaryPassClaimsOnlyANewLibrary (mac phone content : Bool)
    (h : mayClaim false (earlierLibrary mac phone content) = true) :
    emptyBundlePath (mac || phone) content = false := by
  cases mac <;> cases phone <;> cases content <;> simp_all [earlierLibrary, mayClaim, emptyBundlePath]

-- Only a bundle this client reads is merged. Anything else stops the update:
-- merging it is impossible, and dropping it loses another device's write.
def versionMerges (c : BundleContents) : Bool := c == .bundle

theorem anArchiveVersionIsNeverMerged (n : Nat) (h : archiveReaderAccepts n = true) :
    versionMerges (bundlePathHolds (.version n)) = false := by
  rw [anArchiveIsNeverReadAsTheBundle n h]; rfl

inductive SettingsWrite where
  | needsMerge | resolve | create | replace | nothing
  deriving DecidableEq, Repr

-- What `update` writes once `change` has run.
def settingsWrite (current versions merges changed : Bool) : SettingsWrite :=
  if versions then (if merges then .resolve else .needsMerge)
  else if !current then .create
  else if changed then .replace else .nothing

-- A version is merged and resolved by the write, or it stops the update. It
-- is never dropped unmerged, and never left behind by a write.
theorem aVersionIsMergedOrStops (current merges changed : Bool) :
    settingsWrite current true merges changed = (if merges then .resolve else .needsMerge) := by
  simp [settingsWrite]

-- Merged versions are written even when the merge changed nothing, or they
-- would stay, and every check after would find them again.
theorem mergedVersionsAreAlwaysResolved (current changed : Bool) :
    settingsWrite current true true changed = .resolve := by
  simp [settingsWrite]

theorem nothingIsWrittenOnlyOverAnUnchangedCopy (current versions merges changed : Bool)
    (h : settingsWrite current versions merges changed = .nothing) :
    current = true ∧ versions = false ∧ changed = false := by
  cases current <;> cases versions <;> cases merges <;> cases changed <;> simp_all [settingsWrite]

/-! The shared preferences join field by field. Each field carries when it was
set, always later than the field it replaced, and its revision, and the
later stamp wins. Without the time, one device's edit and the other's
unchanged value look the same, since there is no base: the device that lost
the write has recorded its own write as one. -/

-- When a field is set: now, but never before the field it replaces.
def preferenceStamp (now : Nat) (replaced : Option Nat) : Nat :=
  match replaced with
  | none => now
  | some t => max now (t + 1)

def preferenceJoin (a b : Stamp) : Stamp := laterStamp a b

-- The later edit survives whichever copy the store kept as current.
theorem aLaterEditSurvivesEitherWay (edit other : Stamp) (h : stampLE other edit) :
    preferenceJoin edit other = edit ∧ preferenceJoin other edit = edit := by
  have h1 : laterStamp other edit = edit := by simp [laterStamp, h]
  exact ⟨by rw [preferenceJoin, laterStamp_comm]; exact h1, h1⟩

-- So a field set on another device's value beats it, even with a clock
-- behind that device's.
theorem aSetFieldBeatsWhatItReplaced (now t r r' : Nat) :
    preferenceJoin (some t, some r) (some (preferenceStamp now (some t)), some r')
      = (some (preferenceStamp now (some t)), some r') :=
  (aLaterEditSurvivesEitherWay _ _ (by unfold stampLE; simp [optKey, preferenceStamp]; omega)).2

-- One copy of the bundle, reduced to a path's manifest entry, a preference
-- field, and an app's own settings, which are opaque to core.
structure BundleCopy where
  entry : ManifestEntry
  preference : Stamp
  own : Nat
  deriving DecidableEq, Repr

-- `LampSyncSettingsBundle.merge(version:)`: joins what core can join, and
-- keeps the current copy's own settings for the app to merge.
def mergeVersion (current version : BundleCopy) : BundleCopy :=
  { entry := mergeManifestEntry current.entry version.entry,
    preference := preferenceJoin current.preference version.preference,
    own := current.own }

theorem versionMergeIgnoresWhichCopyIsCurrent (a b : BundleCopy) :
    (mergeVersion a b).entry = (mergeVersion b a).entry
      ∧ (mergeVersion a b).preference = (mergeVersion b a).preference
      ∧ (mergeVersion a b).own = a.own := by
  simp [mergeVersion, preferenceJoin, mergeManifestEntry_comm, laterStamp_comm]

-- Several versions fold to the same joined parts in any order.
theorem versionsFoldInAnyOrder (a b c : BundleCopy) :
    (mergeVersion (mergeVersion a b) c).entry = (mergeVersion (mergeVersion a c) b).entry
      ∧ (mergeVersion (mergeVersion a b) c).preference
          = (mergeVersion (mergeVersion a c) b).preference := by
  simp only [mergeVersion, preferenceJoin]
  constructor
  · rw [mergeManifestEntry_assoc, mergeManifestEntry_comm b.entry, ← mergeManifestEntry_assoc]
  · rw [laterStamp_assoc, laterStamp_comm b.preference, ← laterStamp_assoc]

/-! ### A write the server took

A server can take a write and still answer the next reads with what it held
before, as the user's Synology does after a PUT that names no revision.
`LampSyncConditionalWrite.write` keeps "taken but not yet shown back" apart
from "refused": a loop that retried on the first as on the second would
retry against a server still showing the old revision, and be refused for
real, though its write was there all along. -/

inductive WriteOutcome where
  | written (r : Nat) | writtenUnconfirmed | refused
  deriving DecidableEq, Repr

-- Each read-back is the digest and revision of the body the server showed,
-- or none for nothing there. Only the bytes sent confirm the write.
def confirmReadBacks (sent : Nat) : List (Option (Nat × Nat)) → WriteOutcome
  | [] => .writtenUnconfirmed
  | some (d, r) :: rest => if d = sent then .written r else confirmReadBacks sent rest
  | none :: rest => confirmReadBacks sent rest

def writeOutcome (accepted : Bool) (sent : Nat) (readBacks : List (Option (Nat × Nat))) : WriteOutcome :=
  if accepted then confirmReadBacks sent readBacks else .refused

theorem confirmReadBacksNeverRefuses (sent : Nat) (readBacks : List (Option (Nat × Nat))) :
    confirmReadBacks sent readBacks ≠ .refused := by
  induction readBacks with
  | nil => simp [confirmReadBacks]
  | cons b rest ih =>
    rcases b with _ | ⟨d, r⟩
    · simpa [confirmReadBacks] using ih
    · unfold confirmReadBacks; split
      · simp
      · exact ih

-- A write the server took is never a refusal, however long it lags.
theorem anAcceptedWriteIsNeverRefused (sent : Nat) (readBacks : List (Option (Nat × Nat))) :
    writeOutcome true sent readBacks ≠ .refused := by
  simpa [writeOutcome] using confirmReadBacksNeverRefuses sent readBacks

-- A revision is named only from a read-back of the bytes sent.
theorem aWriteIsNamedOnlyByItsOwnBytes (sent r : Nat) (readBacks : List (Option (Nat × Nat)))
    (h : confirmReadBacks sent readBacks = .written r) : some (sent, r) ∈ readBacks := by
  induction readBacks with
  | nil => simp [confirmReadBacks] at h
  | cons b rest ih =>
    rcases b with _ | ⟨d, r'⟩
    · simp [confirmReadBacks] at h; exact List.mem_cons_of_mem _ (ih h)
    · unfold confirmReadBacks at h; split at h
      · rename_i hd; cases h; subst hd; exact List.mem_cons_self
      · exact List.mem_cons_of_mem _ (ih h)

/-! ### The Mac's migration

The Mac moves a library it kept by writing the first bundle, carrying only
what lives nowhere else under the per-file layout: its settings, the phone's
settings, the shared preferences and both deletion ledgers. The library's
content it publishes from the library on its next pass, as every pass does;
files already in the per-file layout are adopted there. So it must have just
imported the library it moves, and it writes over that archive only. -/

-- What an entry of the archive or folder tree the Mac imported can be.
inductive ArchivePath where
  | macSettings | phoneSettings | preferences | personalLedger | deckLedger
  | legacyManifest | compatibilityManifest | portableManifest | seal | archiveIndex | hidden
  | retiredAlias | portableModule | study | writingDocument | media | workspaceFile | compatibleModule
  | perFile | unknown
  deriving DecidableEq, Repr

inductive EntryFate where
  | carried | republished | inPlace | dropped | unknown
  deriving DecidableEq, Repr

def entryFate : ArchivePath → EntryFate
  | .macSettings | .phoneSettings | .preferences | .personalLedger | .deckLedger => .carried
  | .legacyManifest | .compatibilityManifest | .portableManifest | .seal | .archiveIndex
  | .hidden | .retiredAlias => .dropped
  | .portableModule | .study | .writingDocument | .media | .workspaceFile
  | .compatibleModule => .republished
  | .perFile => .inPlace
  | .unknown => .unknown

-- Only the old layout's own bookkeeping is dropped, with the copy a retired
-- alias left (`Notes/bible-notes.lamp`, merged into `notes` long ago):
-- nothing a person made that lives nowhere else.
theorem onlyBookkeepingIsDropped (p : ArchivePath) (h : entryFate p = .dropped) :
    p = .legacyManifest ∨ p = .compatibilityManifest ∨ p = .portableManifest ∨ p = .seal
      ∨ p = .archiveIndex ∨ p = .hidden ∨ p = .retiredAlias := by
  cases p <;> simp_all [entryFate]

-- Every setting and ledger goes into the bundle: none is left to a pass that
-- would not know to carry it.
theorem everySettingAndLedgerIsCarried :
    [ArchivePath.macSettings, .phoneSettings, .preferences, .personalLedger, .deckLedger].all
      (entryFate · == .carried) = true := rfl

inductive MigrationStep where
  | alreadyMigrated | write (c : WriteCondition) | importAgain | notTheMacs
  deriving DecidableEq, Repr

-- One step of the migration, from whether a bundle is there, the archive
-- revision the Mac imported (none for a folder tree), the one there now,
-- and who kept the library.
def macMigrationStep (bundle : Bool) (imported current : Option Nat)
    (keeper : Option EarlierLibrary) : MigrationStep :=
  if bundle then .alreadyMigrated
  else match imported, current with
    | some i, some c =>
      if i = c then (if keeper = some .mac then .write (.ifRevision c) else .notTheMacs)
      else .importAgain
    | none, none => if keeper = some .mac then .write .ifAbsent else .notTheMacs
    | _, _ => .importAgain

-- It writes over an archive only at the revision the Mac imported.
theorem theMigrationWritesOnlyOverTheArchiveItImported
    (bundle : Bool) (imported current : Option Nat) (keeper : Option EarlierLibrary) (r : Nat)
    (h : macMigrationStep bundle imported current keeper = .write (.ifRevision r)) :
    imported = some r ∧ current = some r := by
  unfold macMigrationStep at h
  split at h
  · cases h
  · split at h
    · rename_i i c
      split at h
      · split at h
        · cases h; subst_vars; exact ⟨rfl, rfl⟩
        · cases h
      · cases h
    · split at h <;> cases h
    · cases h

-- It never moves a library the Mac did not keep.
theorem theMigrationMovesOnlyTheMacsLibrary
    (bundle : Bool) (imported current : Option Nat) (keeper : Option EarlierLibrary)
    (c : WriteCondition) (h : macMigrationStep bundle imported current keeper = .write c) :
    keeper = some .mac := by
  unfold macMigrationStep at h
  split at h
  · cases h
  · split at h
    · split at h
      · split at h
        · assumption
        · cases h
      · cases h
    · split at h
      · assumption
      · cases h
    · cases h

-- Run again once it has written, it writes nothing.
theorem aMigratedLibraryIsLeftAlone (imported current : Option Nat) (keeper : Option EarlierLibrary) :
    macMigrationStep true imported current keeper = .alreadyMigrated := rfl

/-! ### The pass engine's order

`LampSyncBundlePass` is one pass for both apps, and its substance is an
order: each step is decided elsewhere, but done in the wrong order each loses
data somewhere other than where the mistake is. A pass does a subset of the
steps below, always in this order. -/

inductive PassStep where
  | claim | receive | gather | download | merge | finishInstalling
  | uploadMedia | uploadModule | deleteLocally | writeBundle | reap
  deriving DecidableEq, Repr

def PassStep.rank : PassStep → Nat
  | .claim => 0 | .receive => 1 | .gather => 2 | .download => 3 | .merge => 4
  | .finishInstalling => 5 | .uploadMedia => 6 | .uploadModule => 7
  | .deleteLocally => 8 | .writeBundle => 9 | .reap => 10

def passOrder : List PassStep :=
  [.claim, .receive, .gather, .download, .merge, .finishInstalling,
   .uploadMedia, .uploadModule, .deleteLocally, .writeBundle, .reap]

theorem passOrderIsRanked : passOrder.Pairwise (fun a b => a.rank < b.rank) := by decide

-- The work a plan hands a pass, one flag per kind.
structure PassWork where
  download : Bool
  merge : Bool
  uploadMedia : Bool
  uploadModule : Bool
  deleteLocally : Bool
  reap : Bool
  deriving DecidableEq, Repr

-- Which steps a pass takes. A merge is published, so it uploads a module.
-- The bundle is written when something changes what it records: an upload
-- or a tombstone. A download or a local deletion records nothing new.
def PassWork.does (w : PassWork) : PassStep → Bool
  | .claim | .receive | .gather | .finishInstalling => true
  | .download => w.download
  | .merge => w.merge
  | .uploadMedia => w.uploadMedia
  | .uploadModule => w.uploadModule || w.merge
  | .deleteLocally => w.deleteLocally
  | .writeBundle => w.merge || w.uploadMedia || w.uploadModule || w.reap
  | .reap => w.reap

def passTrace (w : PassWork) : List PassStep := passOrder.filter w.does

-- Whatever the work, its steps keep the order: the bundle is claimed first;
-- what the bundle carries is applied before the library is gathered; what
-- came down is taken before anything goes up; media goes before the modules
-- that name it; the bundle is written after every upload and local deletion;
-- and bytes are reaped only after the bundle records their deletion.
theorem aPassKeepsTheOrder (w : PassWork) :
    (passTrace w).Pairwise (fun a b => a.rank < b.rank) :=
  passOrderIsRanked.filter _

theorem aPassStartsByClaimingTheBundle (w : PassWork) : (passTrace w).head? = some .claim := rfl

-- A reap never happens without the bundle write that records it.
theorem aReapComesWithItsBundleWrite (w : PassWork) (h : PassStep.reap ∈ passTrace w) :
    PassStep.writeBundle ∈ passTrace w := by
  cases w with
  | mk d m um u l x => cases d <;> cases m <;> cases um <;> cases u <;> cases l <;> cases x <;>
      simp_all [passTrace, passOrder, PassWork.does, List.filter]

-- Never more than one bundle write in a pass.
theorem oneBundleWriteAtMost (w : PassWork) : (passTrace w).count .writeBundle ≤ 1 := by
  cases w with
  | mk d m um u l x => cases d <;> cases m <;> cases um <;> cases u <;> cases l <;> cases x <;> decide

/-! ## Devices running the per-file pass

Two devices and the server, one path: the plan and the manifest both decide
path by path, so paths do not interact. A pass reads the bundle's entry and
the listing and plans with `filePlanAction`; it then acts — takes what came
down, merges, uploads conditioned on the revision it planned against,
deletes locally, makes one bundle update recording each write and adoption at
the pass's time and each tombstone at its deletion's time, and reaps
conditioned on the revision listed. Reading and acting are separate steps,
so the other device can act in between, and a write it beats is refused.

Content is a version: a later edit is a larger one, its save time, and a
merge keeps the later. Each device encodes content its own way, so the digest
a device records for a copy it took is its own export's, as the engine
records it: recording the downloaded bytes instead reads as a change on the
next pass, and two devices trade the file for ever
(`recordingTheDownloadedBytesNeverSettles`).

Assumed: an edit made while a deletion waits to be recorded cancels it, as
re-adding a removed module does; tombstones outlive the run, which is far
shorter than 180 days; the bundle update is one step, as its read-merge-retry
makes it.

Checked, not proved: every sequence of up to `bound` steps from an empty
library and from one both devices hold is run, followed by any pass still
under way and two rounds of passes, and each result is checked. Each check
prints a `SYSTEMCHECK` line with the runs made and the runs that failed; the
suite requires runs and no failures. -/

namespace FilePasses

inductive Who where | a | b
  deriving DecidableEq, Repr

def encode (who : Who) (content : Nat) : Nat :=
  2 * content + (if who = .a then 0 else 1)

-- `seen` is every edit the copy incorporates, for the checks only: the plan
-- never reads it.
structure Copy where
  content : Nat
  lastRevision : Option Nat
  recorded : Option Nat
  seen : List Nat
  deriving DecidableEq, Repr

structure Device where
  copy : Option Copy
  deletedHere : Option Nat
  -- A pass under way: what it planned, the revision listed, and the copy it saw.
  plan : Option (PlanAction × Option Nat × Option Copy)
  deriving DecidableEq, Repr

structure ServerFile where
  revision : Nat
  content : Nat
  writer : Who
  seen : List Nat
  deriving DecidableEq, Repr

-- `deletable`: whether a library deletes this path (`deleteTarget`). The
-- notes and writing collections are not, and a removal of one is never
-- recorded.
structure World where
  server : Option ServerFile
  entry : ManifestEntry
  a : Device
  b : Device
  clock : Nat
  deletable : Bool
  deriving DecidableEq, Repr

-- What a client reports and records, and whether a write that survives a
-- tombstone is stamped past it. The shipped behaviour is all three.
structure Policy where
  reportsSaves : Bool
  recordsOwnExport : Bool
  stampsPastTombstone : Bool
  deriving DecidableEq, Repr

def shipped : Policy := ⟨true, true, true⟩

def World.device (w : World) : Who → Device
  | .a => w.a
  | .b => w.b

def World.setDevice (w : World) : Who → Device → World
  | .a, d => { w with a := d }
  | .b, d => { w with b := d }

def held (p : Policy) (who : Who) (d : Device) : Option HeldFile :=
  d.copy.map fun c =>
    { changed := c.recorded != some (encode who c.content),
      lastRevision := c.lastRevision,
      savedAt := if p.reportsSaves then some c.content else none }

def entryOf (e : ManifestEntry) : Option ManifestEntry :=
  if e = emptyEntry then none else some e

def conditionHolds (server : Option ServerFile) : WriteCondition → Bool
  | .unconditional => true
  | .ifAbsent => server.isNone
  | .ifRevision r => server.map (·.revision) == some r

inductive Step where
  | edit (who : Who) | delete (who : Who) | read (who : Who) | act (who : Who)
  deriving DecidableEq, Repr

def edit (w : World) (who : Who) : World :=
  let d := w.device who
  let copy := match d.copy with
    | some c => { c with content := w.clock, seen := c.seen ++ [w.clock] }
    | none => ⟨w.clock, none, none, [w.clock]⟩
  let w' := w.setDevice who { d with copy := some copy, deletedHere := none }
  { w' with clock := w.clock + 1 }

def delete (w : World) (who : Who) : World :=
  let d := w.device who
  match d.copy with
  | none => w
  | some _ =>
    let w' := w.setDevice who
      { d with copy := none, deletedHere := if w.deletable then some w.clock else none }
    { w' with clock := w.clock + 1 }

def read (p : Policy) (w : World) (who : Who) : World :=
  let d := w.device who
  let listed := w.server.map (·.revision)
  w.setDevice who
    { d with plan := some (filePlanAction .listed (entryOf w.entry) (held p who d) d.deletedHere listed w.deletable,
        listed, d.copy) }

-- Sends `content` if the server still satisfies `c`: the new revision, and
-- the revision it replaced, for the bundle update.
def send (w : World) (who : Who) (content : Nat) (seen : List Nat) (c : WriteCondition) :
    World × Option (Nat × Option Nat) :=
  if conditionHolds w.server c then
    let previous := w.server.map (·.revision)
    let d := w.device who
    let w' := w.setDevice who { d with copy := some ⟨content, some w.clock, some (encode who content), seen⟩ }
    ({ w' with server := some ⟨w.clock, content, who, seen⟩, clock := w.clock + 1 }, some (w.clock, previous))
  else (w, none)

def act (p : Policy) (w : World) (who : Who) : World :=
  match (w.device who).plan with
  | none => w
  | some (action, listed, planned) =>
    -- A copy is acted on only while it is the one the plan saw. One that
    -- was not there when the pass planned has nothing to compare with, and
    -- one gone now cannot be read: both are acted on as before. Refusing on
    -- an unreadable copy would never install a collection whose exported
    -- snapshot is gone by then.
    let unchanged := planned.isNone || (w.device who).copy.isNone || (w.device who).copy == planned
    -- Take what came down.
    let w := if action.download && unchanged then
        match w.server with
        | some f =>
          let d := w.device who
          let recorded := if p.recordsOwnExport then encode who f.content else encode f.writer f.content
          w.setDevice who { d with copy := some ⟨f.content, some f.revision, some recorded, f.seen⟩ }
        | none => w
      else w
    -- Merge, then send the merge over the revision merged with.
    let (w, written) := match action.merge, (w.device who).copy, w.server with
      | some r, some c, some f =>
        if f.revision == r then send w who (max c.content f.content) (c.seen ++ f.seen) (.ifRevision r)
        else (w, none)
      | _, _, _ => (w, none)
    -- Upload.
    let (w, written) := match action.upload, (w.device who).copy, written with
      | some cond, some c, none => send w who c.content c.seen cond
      | _, _, _ => (w, written)
    -- Delete here.
    let w := if action.deleteLocally && unchanged then
        let d := w.device who
        w.setDevice who { d with copy := none }
      else w
    -- One bundle update. A write that survives a tombstone is recorded after it.
    let time := w.clock
    let stamp := match action.supersede with
      | some d => if p.stampsPastTombstone then max time (d + 1) else time
      | none => time
    let entry := match written with
      | some (rev, previous) => recordWrite w.entry (some rev) previous stamp
      | none => match action.adopt with
        | some r => adoptFile w.entry r time
        | none => w.entry
    let entry := match action.tombstone with
      | some d => removeFile entry d listed
      | none => entry
    let d := w.device who
    let kept := if action.tombstone.isSome then none else d.deletedHere
    let w' := w.setDevice who { d with plan := none, deletedHere := kept }
    let w := { w' with entry := entry, clock := w.clock + 1 }
    -- Reap.
    match action.reap with
    | some r => if conditionHolds w.server (.ifRevision r) then { w with server := none } else w
    | none => w

def step (p : Policy) (w : World) : Step → World
  | .edit who => edit w who
  | .delete who => delete w who
  | .read who => read p w who
  | .act who => act p w who

def pass (p : Policy) (w : World) (who : Who) : World := act p (read p w who) who

-- Finish any pass under way, then two rounds.
def settle (p : Policy) (w : World) : World :=
  let w := act p (act p w .a) .b
  let w := pass p (pass p w .a) .b
  pass p (pass p w .a) .b

def contentOf (c : Option Copy) : Option Nat := c.map (·.content)

def converged (w : World) : Bool :=
  contentOf w.a.copy == w.server.map (·.content)
    && contentOf w.b.copy == w.server.map (·.content)
    && w.a.deletedHere.isNone && w.b.deletedHere.isNone
    && (w.a.copy.map (·.lastRevision)).all (· == w.server.map (·.revision))
    && (w.b.copy.map (·.lastRevision)).all (· == w.server.map (·.revision))

def withoutClock (w : World) : World := { w with clock := 0 }

def quiet (p : Policy) (w : World) : Bool :=
  withoutClock (pass p (pass p w .a) .b) == withoutClock w

-- What happened, in time order: each edit's version, and each deletion with
-- whether the deleting device's copy incorporated every edit made so far.
-- `duringPass` is each edit that made a copy while its own device's pass,
-- planned when it held none, was under way.
structure History where
  edits : List Nat
  deletions : List (Nat × Bool)
  duringPass : List Nat
  deriving Repr

def record (h : History) (w : World) : Step → History
  | .edit who =>
    let created := match (w.device who).plan with
      | some (_, _, none) => true
      | _ => false
    let during := if created then h.duringPass ++ [w.clock] else h.duringPass
    { h with edits := h.edits ++ [w.clock], duringPass := during }
  | .delete who => match (w.device who).copy with
    | some c => { h with deletions := h.deletions ++ [(w.clock, h.edits.all c.seen.contains)] }
    | none => h
  | _ => h

-- An edit is lost only to a deletion made after it — on a path no library
-- deletes, only to the person removing their own copy. A copy made while its
-- own device's pass is under way, one the pass planned without, is not held
-- to this: there was nothing to compare it with
-- (`aCopyMadeDuringAPassCanBeOverwritten`).
def noLostEdit (final : World) (h : History) : Bool :=
  h.edits.all fun t =>
    h.duringPass.contains t || final.server.any (·.content ≥ t) || h.deletions.any (·.1 > t)

-- A deletion made by a device whose copy incorporated every edit, with no
-- edit after it, leaves the file gone everywhere.
def deletionSticks (final : World) (h : History) : Bool :=
  !final.deletable || match h.deletions.getLast? with
  | some (d, informed) =>
    if informed && h.edits.all (· < d) then final.server.isNone && final.a.copy.isNone && final.b.copy.isNone
    else true
  | none => true

-- A path a library never deletes is never deleted: whoever held it still does.
def neverDeleted (start final : World) : Bool :=
  final.deletable || start.server.isNone || (final.server.isSome && final.a.copy.isSome && final.b.copy.isSome)

def startEmpty (deletable : Bool) : World :=
  ⟨none, emptyEntry, ⟨none, none, none⟩, ⟨none, none, none⟩, 1, deletable⟩

def startHeld (deletable : Bool) : World :=
  ⟨some ⟨0, 0, .a, [0]⟩, ⟨some 0, some 0, none, none⟩,
   ⟨some ⟨0, some 0, some (encode .a 0), [0]⟩, none, none⟩,
   ⟨some ⟨0, some 0, some (encode .b 0), [0]⟩, none, none⟩, 1, deletable⟩

-- Both devices hold the file, and a device whose clock runs far ahead
-- tombstoned it at 100; the others' clocks start at 1.
def startAhead (deletable : Bool) : World :=
  { startHeld deletable with entry := ⟨some 0, some 0, some 100, some 0⟩ }

-- What a start already holds: a tombstone in it is a deletion made by nobody
-- who held every edit — and, on a path no library deletes, no deletion at all.
def startHistory (w : World) : History :=
  ⟨[], if w.deletable then (w.entry.deletedAt.map fun d => [(d, false)]).getD [] else [], []⟩

def steps : List Step :=
  [.edit .a, .edit .b, .delete .a, .delete .b, .read .a, .read .b, .act .a, .act .b]

-- A step that may be taken: a pass reads once, then acts once.
def allowed (w : World) : Step → Bool
  | .read who => (w.device who).plan.isNone
  | .act who => (w.device who).plan.isSome
  | _ => true

-- Every run of exactly `n` steps: the world it reaches and its history.
def runsOf (p : Policy) (start : World) : Nat → List (World × History)
  | 0 => [(start, startHistory start)]
  | n + 1 => (runsOf p start n).flatMap fun (w, h) =>
      (steps.filter (allowed w)).map fun s => (step p w s, record h w s)

-- Every run of up to `n` steps.
def runs (p : Policy) (start : World) (n : Nat) : List (World × History) :=
  (List.range (n + 1)).flatMap (runsOf p start)

-- One run of the given steps.
def runSteps (p : Policy) (start : World) (taken : List Step) : World × History :=
  taken.foldl (fun (w, h) s => (step p w s, record h w s)) (start, startHistory start)

-- B plans to take A's edit, and its person edits before the pass acts. The
-- pass leaves the copy, since it is no longer the one it planned against, and
-- the next pass merges the two.
theorem anEditDuringAPassSurvives :
    let (w, h) := runSteps shipped (startHeld true) [.edit .a, .read .a, .act .a, .read .b, .edit .b, .act .b]
    contentOf w.b.copy = some 4 ∧ noLostEdit (settle shipped w) h = true := by
  decide +kernel

-- B planned to take A's file while holding none, and its person makes one
-- before the pass acts: with no copy planned against there is nothing to
-- compare, and the pass installs over it. A file made at the very path
-- another device's copy is arriving at, during one pass.
theorem aCopyMadeDuringAPassCanBeOverwritten :
    let (w, _) := runSteps shipped (startEmpty true) [.edit .a, .read .a, .act .a, .read .b, .edit .b, .act .b]
    contentOf w.b.copy = some 1 := by
  decide +kernel

-- A deletes; B edits afterwards. Reporting B's save time keeps the edit;
-- without it the tombstone takes it.
theorem anUnreportedSaveLosesAnEditMadeAfterTheDeletion :
    let (w, h) := runSteps shipped (startHeld true) [.delete .a, .read .a, .act .a, .edit .b]
    let (w', h') := runSteps ⟨false, true, true⟩ (startHeld true) [.delete .a, .read .a, .act .a, .edit .b]
    noLostEdit (settle shipped w) h = true ∧ noLostEdit (settle ⟨false, true, true⟩ w') h' = false := by
  decide +kernel

-- Recording the bytes downloaded rather than this device's own export: the
-- next pass reads its own encoding as a change, and the devices never settle.
theorem recordingTheDownloadedBytesNeverSettles :
    let (w, _) := runSteps ⟨true, false, true⟩ (startHeld true) [.edit .a, .read .a, .act .a]
    let (w', _) := runSteps shipped (startHeld true) [.edit .a, .read .a, .act .a]
    quiet ⟨true, false, true⟩ (settle ⟨true, false, true⟩ w) = false ∧ quiet shipped (settle shipped w') = true := by
  decide +kernel

-- A collection edited under a tombstone from a clock far ahead: the edit goes
-- up, recorded after the tombstone, so it supersedes it and the path is a
-- member again. Recorded at the pass's own time, the write lands under the
-- tombstone and leaves it in place. A copy that survives a deletion by its
-- save time is recorded after it the same way, which matters where that save
-- time came from a faster clock than the pass's.
theorem aWriteSupersedesATombstoneFromAFastClock :
    let w := (runSteps shipped (startAhead false) [.edit .a]).1
    let w' := (runSteps ⟨true, true, false⟩ (startAhead false) [.edit .a]).1
    entryIsMember (settle shipped w).entry = true ∧ converged (settle shipped w) = true ∧
      quiet shipped (settle shipped w) = true ∧
      entryIsMember (settle ⟨true, true, false⟩ w').entry = false := by
  decide +kernel

def bound : Nat := 5

-- Every run from each start, for a path a library deletes and one it never
-- does, settled and checked.
#eval show IO Unit from do
  let checks : List (String × (World → World → History → Bool)) := [
    ("converges", fun _ w _ => converged w),
    ("quiet", fun _ w _ => quiet shipped w),
    ("noLostEdit", fun _ w h => noLostEdit w h),
    ("deletionSticks", fun _ w h => deletionSticks w h),
    ("neverDeleted", fun s w _ => neverDeleted s w)]
  let mut made := 0
  let mut failed : List Nat := checks.map fun _ => 0
  for deletable in [true, false] do
    for start in [startEmpty deletable, startHeld deletable, startAhead deletable] do
      for (w, h) in runs shipped start bound do
        made := made + 1
        let final := settle shipped w
        failed := (checks.zip failed).map fun ((_, check), n) => if check start final h then n else n + 1
  for ((name, _), n) in checks.zip failed do
    IO.println s!"SYSTEMCHECK {name} {made} {n}"

end FilePasses

/-! ## Conformance tables

Each line below names a model decision, its inputs and its answer. Swift's
`SyncModelConformanceTests` runs this file, reads every `CONFORMANCE` line, and
asks the shipped Swift decision the same question. A decision changed on one
side and not the other fails the suite, so the model cannot quietly drift from
the code it describes. The Swift tests read these inputs and print nothing
else: an unknown rule name, or a rule with no lines, fails too. -/

def conformanceLine (rule : String) (fields : List String) : String :=
  "CONFORMANCE " ++ rule ++ " " ++ " ".intercalate fields

def optNat : Option Nat → String
  | none => "-"
  | some n => toString n

def decisionName : Decision → String
  | .local => "local" | .incoming => "incoming" | .conflict => "conflict"

def importOutcomeName : ImportOutcome → String
  | .keepLocal => "keepLocal" | .takeIncoming => "takeIncoming"
  | .setAside => "setAside" | .stop => "stop"

def landingName : Landing → String
  | .wrote => "wrote" | .didNotWrite => "didNotWrite" | .undecidable => "undecidable"

def conditionName : WriteCondition → String
  | .unconditional => "unconditional" | .ifAbsent => "ifAbsent"
  | .ifRevision e => "ifRevision:" ++ toString e

def rowName : Option (Nat × Nat) → String
  | none => "-"
  | some (rev, body) => toString rev ++ ":" ++ toString body

def spelledName : Option SpelledRevision → String
  | none => "-"
  | some r => (if r.weak then "w" else if r.quoted then "q" else "b") ++ toString r.tag

def fieldName (fresh : Nat) : Option PrefField → String
  | none => "-"
  | some f => optNat f.value ++ "@" ++ (if f.revision == fresh then "fresh" else toString f.revision)

#eval show IO Unit from do
  for c in [0, 1, 2] do
    for i in [0, 1, 2] do
      for same in [true, false] do
        IO.println <| conformanceLine "decide"
          [toString c, toString i, toString same,
           decisionName (decide (Int.ofNat c) (Int.ofNat i) same)]
        for forSync in [true, false] do
          IO.println <| conformanceLine "importOutcome"
            [toString forSync, toString c, toString i, toString same,
             importOutcomeName (portableImportOutcome forSync (Int.ofNat c) (Int.ofNat i) same)]

#eval show IO Unit from do
  for c in [WriteCondition.unconditional, .ifAbsent, .ifRevision 1] do
    for s in [none, some 1, some 2] do
      IO.println <| conformanceLine "landing" [conditionName c, optNat s, landingName (landing c s)]

#eval show IO Unit from do
  let times := [none, some 0, some 1, some 2]
  for p in times do
    for d in times do
      for c in times do
        IO.println <| conformanceLine "tombstone"
          [optNat p, optNat d, optNat c, toString (tombstoneDeletes ⟨p, d⟩ c)]
  let few := [none, some 1, some 2]
  for ap in few do
    for ad in few do
      for bp in few do
        for bd in few do
          let m := mergeTombstone ⟨ap, ad⟩ ⟨bp, bd⟩
          IO.println <| conformanceLine "tombstoneMerge"
            [optNat ap, optNat ad, optNat bp, optNat bd, optNat m.presentSince, optNat m.deletedAt]

#eval show IO Unit from do
  for d in [none, some (1, 10), some (2, 20)] do
    for r in [none, some (1, 11), some (2, 21)] do
      IO.println <| conformanceLine "baselessReading"
        [rowName d, rowName r, rowName (baselessReading d r)]

#eval show IO Unit from do
  let spellings : List (Option SpelledRevision) :=
    [none, some ⟨false, true, 1⟩, some ⟨false, false, 1⟩, some ⟨true, true, 1⟩, some ⟨false, true, 2⟩]
  for a in spellings do
    for b in spellings do
      IO.println <| conformanceLine "namesSameRevision"
        [spelledName a, spelledName b, toString (namesSameRevision a b)]
  for isNew in [true, false] do
    for samePath in [true, false] do
      for installed in [none, some 1] do
        for remote in spellings do
          IO.println <| conformanceLine "needsImport"
            [toString isNew, toString samePath, optNat installed, spelledName remote,
             toString (needsImportByToken isNew samePath installed remote)]

#eval show IO Unit from do
  let fresh := 99
  let fields : List (Option PrefField) := [none, some ⟨some 1, 10⟩, some ⟨none, 10⟩]
  let remotes : List (Option PrefField) :=
    [none, some ⟨some 1, 10⟩, some ⟨some 2, 11⟩, some ⟨none, 11⟩]
  for hasBase in [true, false] do
    for previous in (if hasBase then fields else [none]) do
      for remote in remotes do
        for localValue in [none, some 1, some 2, some 3] do
          let o := preferenceMerge hasBase previous remote localValue fresh
          IO.println <| conformanceLine "preferenceMerge"
            [toString hasBase, fieldName fresh previous, fieldName fresh remote, optNat localValue,
             fieldName fresh o.published, toString o.applies, fieldName fresh o.baseline,
             toString o.disputed]

def fileName (v : FileVersion) : String := toString v.tick ++ ":" ++ toString v.bytes

def optFileName : Option FileVersion → String
  | none => "-"
  | some v => fileName v

def choiceName : ThreeWayChoice → String
  | .local => "local" | .remote => "remote" | .conflict => "conflict"

def optList : Option (List Nat) → String
  | none => "-"
  | some l => ",".intercalate (l.map toString)

def readName : Option (Nat × Option Nat) → String
  | none => "-"
  | some (bytes, revision) => toString bytes ++ ":" ++ optNat revision

#eval show IO Unit from do
  for ct in [0, 1, 2] do
    for cb in [0, 1, 2] do
      for it in [0, 1, 2] do
        for ib in [0, 1, 2] do
          let c : FileVersion := ⟨ct, cb⟩
          let i : FileVersion := ⟨it, ib⟩
          IO.println <| conformanceLine "replaceFile"
            [fileName c, fileName i, toString (replaceFile c i)]
  let incomings : List (List FileVersion) := [[], [⟨0, 2⟩], [⟨1, 0⟩], [⟨2, 1⟩], [⟨1, 2⟩, ⟨2, 0⟩]]
  for deletion in [none, some (0 : Int), some 1, some 2] do
    for installed in [none, some (⟨1, 1⟩ : FileVersion)] do
      for incoming in incomings do
        let deleted : FileVersion → Bool := fun v =>
          match deletion with | none => false | some d => Decidable.decide (v.tick ≤ d)
        IO.println <| conformanceLine "deckPull"
          [(match deletion with | none => "-" | some d => toString d), optFileName installed,
           (if incoming.isEmpty then "-" else ",".intercalate (incoming.map fileName)),
           optFileName (deckPull deleted installed incoming)]

#eval show IO Unit from do
  for base in [true, false] do
    for device in [true, false] do
      for remote in [true, false] do
        IO.println <| conformanceLine "mergeMembership"
          [toString base, toString device, toString remote, toString (mergeMembership base device remote)]
  for base in [0, 1, 2] do
    for device in [0, 1, 2] do
      for remote in [0, 1, 2] do
        IO.println <| conformanceLine "chooseWholeValue"
          [toString base, toString device, toString remote, choiceName (chooseWholeValue base device remote)]
  for dt in [0, 1, 2] do
    for rt in [0, 1, 2] do
      for dr in [0, 1] do
        for rr in [0, 1] do
          IO.println <| conformanceLine "chooseReading"
            [toString dt, toString rt, toString dr, toString rr, choiceName (chooseReading dt rt dr rr)]

#eval show IO Unit from do
  for committed in [[1], [2]] do
    for pending in [none, some [2], some [3]] do
      for observed in [[1], [2], [3]] do
        IO.println <| conformanceLine "folderSealAccepts"
          [optList (some committed), optList pending, optList (some observed),
           toString (folderSealAccepts committed pending observed)]

#eval show IO Unit from do
  let reads : List (Option (Nat × Option Nat)) := [none, some (5, some 1), some (4, some 2), some (5, none)]
  for first in reads do
    for second in reads do
      IO.println <| conformanceLine "confirmWrite"
        [readName first, readName second, optNat (confirmWrite 5 [first, second])]

def optBool : Option Bool → String
  | none => "-"
  | some b => toString b

def traceName (trace : List Nat) : String :=
  if trace.isEmpty then "-" else String.join (trace.map toString)

def formatName : ModuleFormat → String
  | .lamp => "lamp" | .json => "json"

def candidateName (c : ModuleCandidate) : String :=
  toString c.identity ++ ":" ++ formatName c.format ++ (if c.superseded then ":s" else "")

def hexBytes (bytes : List Nat) : String :=
  if bytes.isEmpty then "-" else ".".intercalate (bytes.map toString)

#eval show IO Unit from do
  for head in [200, 204, 403, 404, 405, 500] do
    for get in [200, 403, 404, 500] do
      IO.println <| conformanceLine "webDAVPresence"
        [toString head, toString get, optBool (webDAVPresence head get)]
  for mkcol in [201, 405, 409, 500] do
    for propfind in [200, 207, 404, 500] do
      for samePath in [true, false] do
        for isCollection in [true, false] do
          IO.println <| conformanceLine "webDAVDirectoryReady"
            [toString mkcol, toString propfind, toString samePath, toString isCollection,
             toString (webDAVDirectoryReady mkcol propfind samePath isCollection)]
  -- `"abc"`, `W/"abc"`, `"a,b"`, `"a"b"`, `""`, a newline inside, bare `abc`,
  -- two tags joined, and a lone quote.
  let tags : List (List Nat) := [[34, 97, 98, 99, 34], [87, 47, 34, 97, 98, 99, 34], [34, 97, 44, 98, 34],
    [34, 97, 34, 98, 34], [34, 34], [34, 97, 10, 98, 34], [97, 98, 99],
    [34, 97, 34, 44, 32, 34, 98, 34], [34]]
  for tag in tags do
    IO.println <| conformanceLine "guardedETagCondition"
      [hexBytes tag, toString (guardedETagCondition tag).isSome]

#eval show IO Unit from do
  for beforePull in [true, false] do
    for afterPull in [true, false] do
      for afterPublish in [true, false] do
        for pullOK in [true, false] do
          for publishOK in [true, false] do
            IO.println <| conformanceLine "cancellableRunTrace"
              [toString beforePull, toString afterPull, toString afterPublish, toString pullOK,
               toString publishOK,
               traceName (cancellableRunTrace beforePull afterPull afterPublish pullOK publishOK)]
  for pullOK in [true, false] do
    for publishOK in [true, false] do
      for persistOK in [true, false] do
        for wipeRequested in [true, false] do
          for wipeOK in [true, false] do
            IO.println <| conformanceLine "backendTransition"
              [toString pullOK, toString publishOK, toString persistOK, toString wipeRequested,
               toString wipeOK,
               toString (deferredBackendWipe wipeRequested pullOK publishOK persistOK),
               toString (wipeRequested && rollbackAttempted pullOK publishOK persistOK wipeOK),
               toString (backendActivationOccurs pullOK publishOK persistOK wipeRequested wipeOK)]

#eval show IO Unit from do
  let pool : List ModuleCandidate :=
    [⟨1, .lamp, false⟩, ⟨1, .json, false⟩, ⟨1, .lamp, true⟩, ⟨2, .json, false⟩]
  let mut lists : List (List ModuleCandidate) := []
  for a in pool do
    lists := lists ++ [[a]]
    for b in pool do
      lists := lists ++ [[a, b]]
      for c in pool do
        lists := lists ++ [[a, b, c]]
  for files in lists do
    for identity in [1, 2] do
      IO.println <| conformanceLine "selectedCandidateIndex"
        [toString identity, ",".intercalate (files.map candidateName),
         optNat (selectedCandidateIndexForIdentity identity files)]

def bools (values : List Bool) : String :=
  if values.isEmpty then "-" else String.join (values.map fun b => if b then "t" else "f")

def boolLists : Nat → List (List Bool)
  | 0 => [[]]
  | n + 1 => [[]] ++ (boolLists n).flatMap fun rest => [true :: rest, false :: rest]

def folderEntryCode (entry : ModuleFolderEntry) : String :=
  (if entry.isDirectory then "d" else "f") ++ (if entry.supportedFilename then "s" else "u")

def highlightName : MacHighlightExport → String
  | .ready => "ready" | .empty => "empty" | .failed => "failed"

#eval show IO Unit from do
  for device in [0, 1, 3] do
    for incoming in [0, 1, 3] do
      for now in [0, 2, 5] do
        IO.println <| conformanceLine "resolvedRecordRevision"
          [toString device, toString incoming, toString now,
           toString (resolvedRecordRevision device incoming now)]
  let kinds : List ModuleFolderEntry := [⟨false, true⟩, ⟨false, false⟩, ⟨true, true⟩, ⟨true, false⟩]
  let mut listings : List (Option (Option (List ModuleFolderEntry))) := [none, some none, some (some [])]
  for a in kinds do
    listings := listings ++ [some (some [a])]
    for b in kinds do
      listings := listings ++ [some (some [a, b])]
  for response in listings do
    let shown := match response with
      | none => "error" | some none => "missing"
      | some (some entries) => if entries.isEmpty then "-" else ",".intercalate (entries.map folderEntryCode)
    IO.println <| conformanceLine "moduleFolderListing"
      [shown, match moduleFolderListing response with
        | none => "error"
        | some kept => if kept.isEmpty then "-" else ",".intercalate (kept.map folderEntryCode)]

#eval show IO Unit from do
  -- Earlier attempts' outcomes, then one more attempt by a caller that may be
  -- cancelled while it waits.
  for earlier in boolLists 2 do
    let completed := earlier.foldl initialSyncCompletedAfterAttempt false
    for succeeded in [true, false] do
      for cancelled in [true, false] do
        let after := initialSyncCompletedAfterAttempt completed succeeded
        IO.println <| conformanceLine "initialSync"
          [bools earlier, toString succeeded, toString cancelled, toString after,
           toString (initialSyncCallerMayContinue after cancelled)]
  for outcomes in boolLists 3 do
    IO.println <| conformanceLine "mediaBatchComplete"
      [bools outcomes, toString (mediaBatchComplete outcomes)]
  for outcome in [MacHighlightExport.ready, .empty, .failed] do
    IO.println <| conformanceLine "macHighlightAllowsPublish"
      [highlightName outcome, toString (macHighlightAllowsPublish outcome)]

def captureName : ArchiveCaptureChoice → String
  | .include => "include" | .skip => "skip" | .reject => "reject"

def columnName : StoredColumn → String
  | .nothing => "nothing"
  | .json a => "json:" ++ toString a
  | .text a => "text:" ++ toString a

#eval show IO Unit from do
  for isMedia in [true, false] do
    for hidden in [true, false] do
      for symlink in [true, false] do
        IO.println <| conformanceLine "archiveCaptureChoice"
          [toString isMedia, toString hidden, toString symlink,
           captureName (archiveCaptureChoice isMedia hidden symlink)]
  let columns := [StoredColumn.nothing, .json 1, .json 2, .text 1, .text 2]
  for one in columns do
    for other in columns do
      IO.println <| conformanceLine "sameColumn"
        [columnName one, columnName other, toString (sameColumn one other)]

def entryCode (e : ManifestEntry) : String :=
  ":".intercalate [optNat e.presentSince, optNat e.revision, optNat e.deletedAt, optNat e.deletedRevision]

def optEntryCode : Option ManifestEntry → String
  | none => "-"
  | some e => entryCode e

def heldCode : Option HeldFile → String
  | none => "-"
  | some h => ":".intercalate [toString h.changed, optNat h.lastRevision, optNat h.savedAt]

def fileClassName : FileClass → String
  | .media => "media" | .listed => "listed" | .unlisted => "unlisted"

def actionCode (a : PlanAction) : String :=
  let tokens :=
    (if a.download then ["download"] else [])
    ++ (a.merge.map fun r => ["merge:" ++ toString r]).getD []
    ++ (a.upload.map fun c => ["upload:" ++ conditionName c]).getD []
    ++ (if a.deleteLocally then ["deleteLocally"] else [])
    ++ (a.adopt.map fun r => ["adopt:" ++ toString r]).getD []
    ++ (a.tombstone.map fun t => ["tombstone:" ++ toString t]).getD []
    ++ (a.reap.map fun r => ["reap:" ++ toString r]).getD []
    ++ (a.supersede.map fun t => ["supersede:" ++ toString t]).getD []
  if tokens.isEmpty then "-" else ",".intercalate tokens

def headerName : BundleHeader → String
  | .version n => "version:" ++ toString n
  | .entriesFirst => "entriesFirst"
  | .garbage => "garbage"

def contentsName : BundleContents → String
  | .bundle => "bundle" | .archive => "archive" | .newer n => "newer:" ++ toString n
  | .damaged => "damaged"

def manifestEntries : List ManifestEntry :=
  [emptyEntry, ⟨some 5, some 1, none, none⟩, ⟨some 5, some 2, none, none⟩,
   ⟨some 7, some 1, some 6, some 3⟩, ⟨none, none, some 5, some 1⟩, ⟨some 5, none, some 5, none⟩]

#eval show IO Unit from do
  for a in manifestEntries do
    for b in manifestEntries do
      let merged := mergeManifestEntry a b
      IO.println <| conformanceLine "manifestMerge"
        [entryCode a, entryCode b, entryCode merged, toString (entryIsMember merged)]
  for e in manifestEntries do
    for previous in [none, some 1, some 2] do
      for time in [3, 9] do
        IO.println <| conformanceLine "recordWrite"
          [entryCode e, optNat previous, toString time, entryCode (recordWrite e (some 4) previous time)]
    for rev in [1, 3, 4] do
      for time in [3, 9] do
        IO.println <| conformanceLine "adoptFile"
          [entryCode e, toString rev, toString time, entryCode (adoptFile e rev time)]
  let now := 10 + tombstoneLifetime
  for e in [⟨some 1, some 1, none, none⟩, ⟨some 1, some 1, some 5, some 1⟩,
            ⟨some 1, some 1, some 15, some 1⟩, emptyEntry] do
    for listed in [true, false] do
      for present in [true, false] do
        IO.println <| conformanceLine "pruneTombstone"
          [entryCode e, toString now, toString listed, toString present,
           toString (pruneTombstone e now listed present)]

#eval show IO Unit from do
  let entries : List (Option ManifestEntry) :=
    [none, some ⟨some 5, some 1, none, none⟩, some ⟨some 5, some 1, some 7, some 2⟩,
     some ⟨some 5, some 1, some 7, none⟩, some ⟨none, none, some 7, none⟩,
     some ⟨some 9, some 3, some 7, some 1⟩, some emptyEntry]
  let helds : List (Option HeldFile) :=
    [none, some ⟨false, some 1, some 6⟩, some ⟨true, some 1, some 8⟩, some ⟨false, some 2, some 6⟩,
     some ⟨true, none, some 8⟩, some ⟨false, none, none⟩]
  -- Unlisted paths are workspace files, which no library deletes.
  for (cls, deletable) in [(FileClass.media, true), (.media, false), (.listed, true), (.listed, false),
                           (.unlisted, false)] do
    for entry in entries do
      for held in helds do
        for deletedHere in [none, some 6, some 10] do
          for listed in [none, some 1, some 2, some 3] do
            IO.println <| conformanceLine "filePlanAction"
              [fileClassName cls, toString deletable, optEntryCode entry, heldCode held,
               optNat deletedHere, optNat listed,
               actionCode (filePlanAction cls entry held deletedHere listed deletable)]

def localKindName : LocalKind → String
  | .module => "module" | .collection => "collection" | .deck => "deck"
  | .deckAsset => "deckAsset" | .media => "media" | .workspaceFile => "workspaceFile"
  | .outside => "outside"

-- A module removal is checked to name the path's own ID, 7 here.
def localDeletionName : LocalDeletion → String
  | .module id => if id == 7 then "module:own" else "module:other"
  | .deck => "deck" | .deckAsset => "deckAsset" | .collection => "collection"
  | .unsupported => "unsupported"

#eval show IO Unit from do
  for kind in [LocalKind.module, .collection, .deck, .deckAsset, .media, .workspaceFile, .outside] do
    IO.println <| conformanceLine "deleteTarget"
      [localKindName kind, localDeletionName (deleteTarget kind (some 7)),
       toString (mayRecordRemoval kind (some 7))]

#eval show IO Unit from do
  -- The manifest's view of a listed file: unknown, a member with or without
  -- a recorded revision, or a tombstone.
  let states : List (String × Option Nat) :=
    [("unknown", none), ("member:2", some 2), ("member:-", none), ("tombstone:2", none)]
  for item in [none, some 1] do
    for (state, recorded) in states do
      for stored in [none, some 3] do
        let (revision, asked) := listedRevision item recorded stored
        IO.println <| conformanceLine "listedRevision"
          [optNat item, state, optNat stored, optNat revision, toString asked]
  for attempts in [0, 1, 2, 3] do
    for refusals in boolLists 3 do
      IO.println <| conformanceLine "settingsUpdate"
        [toString attempts, bools refusals, optNat (settingsUpdate attempts refusals)]
  for header in [BundleHeader.version 0, .version 1, .version 2, .version 3, .version 4,
                 .entriesFirst, .garbage] do
    IO.println <| conformanceLine "bundlePathHolds"
      [headerName header, contentsName (bundlePathHolds header)]

def directoryOutcomeName : DirectoryOutcome → String
  | .proceed => "proceed" | .refuse => "refuse" | .unresolved => "unresolved"
  | .nothingThere => "nothingThere"

#eval show IO Unit from do
  for c in [WriteCondition.unconditional, .ifAbsent, .ifRevision 1] do
    for current in [none, some 1, some 2] do
      for placeholder in [true, false] do
        for unresolved in [true, false] do
          IO.println <| conformanceLine "directoryWrite"
            [conditionName c, optNat current, toString placeholder, toString unresolved,
             directoryOutcomeName (directoryWrite c current placeholder unresolved)]
          IO.println <| conformanceLine "directoryDelete"
            [conditionName c, optNat current, toString placeholder, toString unresolved,
             directoryOutcomeName (directoryDelete c current placeholder unresolved)]

def settingsWriteName : SettingsWrite → String
  | .needsMerge => "needsMerge" | .resolve => "resolve" | .create => "create"
  | .replace => "replace" | .nothing => "nothing"

def stampCode (s : Stamp) : String := optNat s.1 ++ ":" ++ optNat s.2

def passStepName (s : PassStep) : String := ((reprStr s).splitOn ".").getLast!

def readBacksCode (rb : List (Option (Nat × Nat))) : String :=
  if rb.isEmpty then "empty"
  else ",".intercalate (rb.map fun | none => "-" | some (d, r) => toString d ++ ":" ++ toString r)

def writeOutcomeName : WriteOutcome → String
  | .written r => "written:" ++ toString r | .writtenUnconfirmed => "writtenUnconfirmed"
  | .refused => "refused"

def archivePathName (p : ArchivePath) : String := ((reprStr p).splitOn ".").getLast!

def entryFateName : EntryFate → String
  | .carried => "carried" | .republished => "republished" | .inPlace => "inPlace"
  | .dropped => "dropped" | .unknown => "unknown"

def migrationStepName : MigrationStep → String
  | .alreadyMigrated => "alreadyMigrated" | .write c => "write:" ++ conditionName c
  | .importAgain => "importAgain" | .notTheMacs => "notTheMacs"

def archiveEntryName : ArchiveEntry → String
  | .phoneSettings => "phoneSettings" | .legacyManifest => "legacyManifest"
  | .preferences => "preferences" | .portableManifest => "portableManifest"
  | .macSettings => "macSettings" | .module => "module"

def earlierLibraryName : Option EarlierLibrary → String
  | none => "-" | some .mac => "mac" | some .phone => "phone"

def bundleReadName : BundleRead → String
  | .bundle => "bundle" | .fresh => "fresh" | .notMigrated => "notMigrated"

def bundleCopies : List BundleCopy :=
  let stamps : List Stamp :=
    [(none, some 1), (none, some 2), (some 5, some 1), (some 5, some 2), (some 7, some 1), (some 3, some 9)]
  (stamps.zip manifestEntries).zipIdx.map fun ((p, e), i) => ⟨e, p, i⟩

#eval show IO Unit from do
  for marker in [true, false] do
    for content in [true, false] do
      IO.println <| conformanceLine "emptyBundlePath"
        [toString marker, toString content, toString (emptyBundlePath marker content)]
  for mac in [true, false] do
    for phone in [true, false] do
      for content in [true, false] do
        IO.println <| conformanceLine "earlierLibrary"
          [toString mac, toString phone, toString content,
           earlierLibraryName (earlierLibrary mac phone content)]
  for mask in List.range 64 do
    let bit := fun (i : Nat) => (mask >>> i) % 2 == 1
    let w : PassWork := ⟨bit 0, bit 1, bit 2, bit 3, bit 4, bit 5⟩
    IO.println <| conformanceLine "passTrace"
      [toString w.download, toString w.merge, toString w.uploadMedia, toString w.uploadModule,
       toString w.deleteLocally, toString w.reap, ",".intercalate ((passTrace w).map passStepName)]
  let readBacks : List (Option (Nat × Nat)) := [none, some (1, 7), some (2, 8)]
  let lists := [[]] ++ readBacks.map ([·]) ++ (readBacks.flatMap fun a => readBacks.map fun b => [a, b])
  for accepted in [true, false] do
    for rb in lists do
      IO.println <| conformanceLine "writeOutcome"
        [toString accepted, readBacksCode rb, writeOutcomeName (writeOutcome accepted 1 rb)]
  for p in [ArchivePath.macSettings, .phoneSettings, .preferences, .personalLedger, .deckLedger,
            .legacyManifest, .compatibilityManifest, .portableManifest, .seal, .archiveIndex, .hidden,
            .retiredAlias, .portableModule, .study, .writingDocument, .media, .workspaceFile, .compatibleModule,
            .perFile, .unknown] do
    IO.println <| conformanceLine "entryFate" [archivePathName p, entryFateName (entryFate p)]
  for bundle in [true, false] do
    for imported in [none, some 1] do
      for current in [none, some 1, some 2] do
        for keeper in [none, some EarlierLibrary.phone, some .mac] do
          IO.println <| conformanceLine "macMigrationStep"
            [toString bundle, optNat imported, optNat current, earlierLibraryName keeper,
             migrationStepName (macMigrationStep bundle imported current keeper)]
  let kinds := [ArchiveEntry.phoneSettings, .legacyManifest, .preferences, .portableManifest,
                .macSettings, .module]
  for mask in List.range 64 do
    let entries := (kinds.zipIdx.filter fun (_, i) => (mask >>> i) % 2 == 1).map (·.1)
    IO.println <| conformanceLine "archiveKeeper"
      [if entries.isEmpty then "-" else ",".intercalate (entries.map archiveEntryName),
       earlierLibraryName (some (archiveKeeper entries))]
  for migrating in [true, false] do
    for earlier in [none, some EarlierLibrary.phone, some .mac] do
      IO.println <| conformanceLine "mayClaim"
        [toString migrating, earlierLibraryName earlier, toString (mayClaim migrating earlier)]
  for bundle in [true, false] do
    for marker in [true, false] do
      for content in [true, false] do
        IO.println <| conformanceLine "bundleRead"
          [toString bundle, toString marker, toString content,
           bundleReadName (bundleRead bundle marker content)]
  for header in [BundleHeader.version 0, .version 1, .version 2, .version 3, .version 4,
                 .entriesFirst, .garbage] do
    IO.println <| conformanceLine "versionMerges"
      [headerName header, toString (versionMerges (bundlePathHolds header))]
  for current in [true, false] do
    for versions in [true, false] do
      for merges in [true, false] do
        for changed in [true, false] do
          IO.println <| conformanceLine "settingsWrite"
            [toString current, toString versions, toString merges, toString changed,
             settingsWriteName (settingsWrite current versions merges changed)]
  for now in [3, 9] do
    for replaced in [none, some 2, some 9] do
      IO.println <| conformanceLine "preferenceStamp"
        [toString now, optNat replaced, toString (preferenceStamp now replaced)]
  for a in bundleCopies do
    for b in bundleCopies do
      let m := mergeVersion a b
      IO.println <| conformanceLine "versionMerge"
        [stampCode a.preference, entryCode a.entry, toString a.own,
         stampCode b.preference, entryCode b.entry, toString b.own,
         stampCode m.preference, entryCode m.entry, toString m.own]


#eval show IO Unit from do
  let times := [none, some 0, some 1, some 2]
  for p in times do
    for d in times do
      IO.println <| conformanceLine "planMark" [optNat p, optNat d, toString (planMarkIsSet ⟨p, d⟩)]
  let few := [none, some 1, some 2]
  for now in [0, 1, 3] do
    for p in few do
      for d in few do
        let set := stampSet now ⟨p, d⟩
        let cleared := stampCleared now ⟨p, d⟩
        IO.println <| conformanceLine "planStamp"
          [toString now, optNat p, optNat d,
           optNat set.presentSince, optNat set.deletedAt,
           optNat cleared.presentSince, optNat cleared.deletedAt]
  for p in few do
    for d in few do
      for held in [none, some 0, some 1, some 2, some 3] do
        let change := match planApply ⟨p, d⟩ held with
          | .leave => "leave" | .hold s => "hold:" ++ toString s | .drop => "drop"
        IO.println <| conformanceLine "planApply" [optNat p, optNat d, optNat held, change]
  let marks : List (Option Tombstone) :=
    [none, some ⟨some 1, none⟩, some ⟨none, some 2⟩, some ⟨some 2, some 1⟩, some ⟨some 1, some 2⟩]
  let code : Option Tombstone → String
    | none => "absent"
    | some m => optNat m.presentSince ++ ":" ++ optNat m.deletedAt
  for a in marks do
    for b in marks do
      IO.println <| conformanceLine "planVersionMerge" [code a, code b, code (mergePlanPart a b)]
      let own := a.getD ⟨none, none⟩
      IO.println <| conformanceLine "planContribution" [code a, code b, code (contributePlan own b)]

end LampSyncVerification
