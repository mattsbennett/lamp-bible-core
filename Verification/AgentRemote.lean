import Init

/-!
A model of the decisions behind following a Mac's chats from a phone
(`LampAgentRemote*` in LampCore): the pairing window, the order a secure
channel opens frames in, which proofs a host lets in, and the contract
between what a host sends as a chat changes and how a device puts it back
together. It models the decisions — not CryptoKit, the network or the apps.
-/

namespace LampAgentRemoteVerification

/-! ## The pairing window

A QR's code pairs one device, and closes after a number of proofs that fit
no key. -/

structure Window where
  failuresLeft : Nat
  closed : Bool
  deriving DecidableEq, Repr

def Window.open (allowance : Nat) : Window := ⟨allowance, allowance == 0⟩

/-- A device paired under the code. -/
def Window.paired (w : Window) : Window := { w with closed := true }

/-- A proof that fit no key while the window was open. -/
def Window.failed (w : Window) : Window :=
  if w.closed then w
  else
    let left := w.failuresLeft - 1
    ⟨left, left == 0⟩

/-- An attempt: the right code, or a wrong one. A right one pairs only while
the window is open; a wrong one counts against it. -/
inductive Attempt where
  | right | wrong
  deriving DecidableEq, Repr

def attempt (s : Window × Nat) : Attempt → Window × Nat
  | .right => if s.1.closed then s else (s.1.paired, s.2 + 1)
  | .wrong => (s.1.failed, s.2)

def run (allowance : Nat) (attempts : List Attempt) : Window × Nat :=
  attempts.foldl attempt (Window.open allowance, 0)

theorem closedStaysClosed (s : Window × Nat) (a : Attempt) (h : s.1.closed = true) :
    (attempt s a).1.closed = true := by
  cases a <;> simp [attempt, h, Window.failed]

theorem closedPairsNoMore (s : Window × Nat) (a : Attempt) (h : s.1.closed = true) :
    (attempt s a).2 = s.2 := by
  cases a <;> simp [attempt, h, Window.failed]

theorem foldClosed (s : Window × Nat) (as : List Attempt) (h : s.1.closed = true) :
    (as.foldl attempt s).1.closed = true ∧ (as.foldl attempt s).2 = s.2 := by
  induction as generalizing s with
  | nil => simp [h]
  | cons a rest ih =>
    simp only [List.foldl]
    have h1 := closedStaysClosed s a h
    have h2 := closedPairsNoMore s a h
    have := ih (attempt s a) h1
    exact ⟨this.1, this.2.trans h2⟩

/-- However many attempts, a code pairs at most one device. -/
theorem pairsAtMostOnce (s : Window × Nat) (as : List Attempt) (h : s.2 ≤ 1)
    (hc : s.2 = 1 → s.1.closed = true) :
    (as.foldl attempt s).2 ≤ 1 := by
  induction as generalizing s with
  | nil => simpa using h
  | cons a rest ih =>
    simp only [List.foldl]
    cases a with
    | right =>
      by_cases hcl : s.1.closed = true
      · simp only [attempt, hcl, ↓reduceIte]; exact ih s h hc
      · have h0 : s.2 = 0 := by
          rcases Nat.lt_or_ge s.2 1 with hl | hg
          · omega
          · exact absurd (hc (by omega)) hcl
        simp only [attempt, hcl]
        have hclosed : (s.1.paired, s.2 + 1).1.closed = true := by simp [Window.paired]
        have := (foldClosed (s.1.paired, s.2 + 1) rest hclosed).2
        simp at this ⊢; omega
    | wrong =>
      apply ih
      · simpa [attempt] using h
      · intro h1
        have : s.1.closed = true := hc (by simpa [attempt] using h1)
        simp [attempt, Window.failed, this]

theorem aCodePairsAtMostOnce (allowance : Nat) (as : List Attempt) : (run allowance as).2 ≤ 1 :=
  pairsAtMostOnce _ as (by simp) (by simp)

/-- A window opened with an allowance is closed by that many wrong codes. -/
theorem wrongCodesClose (n : Nat) (s : Window × Nat) (h : s.1.failuresLeft = n) :
    ((List.replicate n Attempt.wrong).foldl attempt s).1.closed = true ∨ n = 0 := by
  induction n generalizing s with
  | zero => exact Or.inr rfl
  | succ k ih =>
    left
    simp only [List.replicate, List.foldl]
    by_cases hc : s.1.closed = true
    · exact (foldClosed (attempt s .wrong) _ (closedStaysClosed s .wrong hc)).1
    · cases k with
      | zero =>
        have : (attempt s .wrong).1.closed = true := by
          simp [attempt, Window.failed, hc, h]
        simpa using this
      | succ j =>
        have hl : (attempt s .wrong).1.failuresLeft = j + 1 := by
          simp [attempt, Window.failed, hc, h]
        rcases ih (attempt s .wrong) hl with hd | hd
        · exact hd
        · omega

/-! ## A channel's frames

Each side numbers what it seals, and the other opens only the next number:
a frame replayed, dropped or out of order does not open, and the connection
ends there. -/

/-- How many of the frames, numbered as they arrive, open before one does not. -/
def opened (expected : Nat) : List Nat → Nat
  | [] => 0
  | c :: rest => if c == expected then 1 + opened (expected + 1) rest else 0

/-- What opens is exactly the frames in the order they were sealed. -/
theorem openedIsTheSealedOrder (expected : Nat) (cs : List Nat) :
    ∀ i, i < opened expected cs → cs[i]? = some (expected + i) := by
  induction cs generalizing expected with
  | nil => intro i hi; simp [opened] at hi
  | cons c rest ih =>
    intro i hi
    unfold opened at hi
    split at hi
    · rename_i hc
      have hc : c = expected := by simpa using hc
      cases i with
      | zero => simp [hc]
      | succ j =>
        have := ih (expected + 1) j (by omega)
        simp only [List.getElem?_cons_succ, this]
        congr 1; omega
    · simp at hi

/-- No frame opens twice. -/
theorem aReplayDoesNotOpen (expected : Nat) (cs : List Nat) (i j : Nat)
    (hi : i < opened expected cs) (hj : j < opened expected cs) (h : cs[i]? = cs[j]?) : i = j := by
  have a := openedIsTheSealedOrder expected cs i hi
  have b := openedIsTheSealedOrder expected cs j hj
  rw [a, b] at h
  simp at h; omega

/-! ## Which proofs a host lets in

A paired device's key, unless the device was forgotten since the keys were
read; the open pairing code, while its window is open; nothing else. -/

inductive Proof where
  | device | pairingCode | unknown
  deriving DecidableEq, Repr

inductive Admission where
  | acceptedDevice | pairedByCode | close
  deriving DecidableEq, Repr

def admit (proof : Proof) (revoked windowOpen : Bool) : Admission :=
  match proof with
  | .device => if revoked then .close else .acceptedDevice
  | .pairingCode => if windowOpen then .pairedByCode else .close
  | .unknown => .close

theorem aForgottenDeviceIsNotLetIn (w : Bool) : admit .device true w = .close := by
  simp [admit]

theorem aSpentCodeIsNotLetIn (r : Bool) : admit .pairingCode r false = .close := by
  simp [admit]

/-! ## A chat's updates

A host sends a device a snapshot of a chat, then events as it changes. The
model's messages carry an id, whether they are the person's, and words named
by a number; the reply so far, the run's activity and a failure are numbers
too, 0 meaning none. -/

structure Msg where
  id : Nat
  user : Bool
  deriving DecidableEq, Repr

structure State where
  msgs : List Msg
  arriving : Nat
  activity : Nat
  running : Bool
  failure : Nat
  deriving DecidableEq, Repr

structure View where
  msgs : List Msg
  soFar : Nat
  activity : Nat
  notice : Nat
  running : Bool
  deriving DecidableEq, Repr

def snapshot (s : State) : View :=
  ⟨s.msgs, if s.running then s.arriving else 0, if s.running then s.activity else 0, s.failure, s.running⟩

inductive Event where
  | turnStarted (turn : Option Nat) (msg : Option Msg)
  | fragment (turn : Option Nat) (text : Nat)
  | activity (turn : Option Nat) (a : Nat)
  | reply (turn : Option Nat) (msg : Msg)
  | failed (turn : Option Nat) (text : Nat)
  | turnEnded (turn : Option Nat)
  deriving DecidableEq, Repr

def upsert (ms : List Msg) (m : Msg) : List Msg :=
  if ms.any (·.id == m.id) then ms.map (fun x => if x.id == m.id then m else x) else ms ++ [m]

def apply (v : View) : Event → View
  | .turnStarted _ m => let v := { v with running := true, soFar := 0, activity := 0, notice := 0 }
                        match m with | some m => { v with msgs := upsert v.msgs m } | none => v
  | .fragment _ t => { v with running := true, soFar := t }
  | .activity _ a => { v with running := true, activity := a }
  | .reply _ m => { v with msgs := upsert v.msgs m }
  | .failed _ t => { v with notice := t }
  | .turnEnded _ => { v with running := false, soFar := 0, activity := 0 }

def applyAll (v : View) (es : List Event) : View := es.foldl apply v

def lastQuestion (ms : List Msg) : Option Nat := (ms.filter (·.user)).getLast?.map (·.id)

/-- The question before a message: the last of the person's before it. -/
def questionBefore (ms : List Msg) (id : Nat) : Option Nat :=
  lastQuestion (ms.takeWhile (·.id != id))

/-- The plan's state as it goes: the events so far, the device's copy, and the
turn open. -/
structure Plan where
  events : List Event
  copy : View
  open_ : Option Nat

def Plan.send (p : Plan) (e : Event) : Plan := { p with events := p.events ++ [e], copy := apply p.copy e }

/-- The messages added, one at a time: a question ends the turn before it,
then begins a turn of its own if it is running now or answered in the same
step, or is just a message; an answer is filed under its question. -/
def messagePhase (new : State) (lastAdded : Option Nat) : Plan → List Msg → Plan
  | p, [] => p
  | p, m :: rest =>
    if m.user then
      let p := if p.copy.running then { (p.send (.turnEnded p.open_)) with open_ := none } else p
      let answered := rest.any (fun x => !x.user)
      if answered || (some m.id == lastAdded && new.running) then
        messagePhase new lastAdded { (p.send (.turnStarted (some m.id) (some m))) with open_ := some m.id } rest
      else
        messagePhase new lastAdded (p.send (.reply (some m.id) m)) rest
    else
      messagePhase new lastAdded (p.send (.reply (questionBefore new.msgs m.id) m)) rest

/-- What settles the copy's running state, reply so far, activity and notice
on the new state's. -/
def settle (new : State) (p : Plan) : Plan :=
  let target := snapshot new
  let p :=
    if target.running then
      let p := if !p.copy.running then
          let o := p.open_.orElse (fun _ => lastQuestion new.msgs)
          { (p.send (.turnStarted o none)) with open_ := o }
        else p
      let p := if p.copy.soFar != target.soFar then p.send (.fragment p.open_ target.soFar) else p
      if p.copy.activity != target.activity then p.send (.activity p.open_ target.activity) else p
    else p
  let p := if target.notice != 0 && p.copy.notice != target.notice then
      p.send (.failed (p.open_.orElse (fun _ => lastQuestion new.msgs)) target.notice) else p
  if !target.running && p.copy.running then p.send (.turnEnded p.open_) else p

/-- The events chosen from one state to the next. -/
def planEvents (old new : State) : List Event :=
  let added := new.msgs.drop old.msgs.length
  let start : Plan := ⟨[], snapshot old, if old.running then lastQuestion old.msgs else none⟩
  (settle new (messagePhase new (lastQuestion added) start added)).events

/-- The events from one state to the next, or none where only a snapshot can
say the change: checked, before anything is sent, by playing them on the
device's copy. -/
def plan (old new : State) : Option (List Event) :=
  if old.msgs.isPrefixOf new.msgs && applyAll (snapshot old) (planEvents old new) == snapshot new
  then some (planEvents old new) else none

/-- The contract: what a host sends, applied to the snapshot a device holds,
gives the snapshot of the new state. The plan checks exactly this before it
sends anything, so no choice it makes along the way can break it. -/
theorem eventsArriveAtTheNextSnapshot (old new : State) (es : List Event)
    (h : plan old new = some es) : applyAll (snapshot old) es = snapshot new := by
  unfold plan at h
  by_cases hc : (old.msgs.isPrefixOf new.msgs && applyAll (snapshot old) (planEvents old new) == snapshot new) = true
  · simp only [hc, ↓reduceIte, Option.some.injEq] at h
    subst h
    simp only [Bool.and_eq_true, beq_iff_eq] at hc
    exact hc.2
  · simp [hc] at h

/-- A failure cleared with no turn begun is a change no event can say, so
the host sends a snapshot rather than leave the device showing it. -/
theorem aClearedFailureNeedsASnapshot (msgs : List Msg) (a1 a2 c1 c2 f : Nat) (hf : f ≠ 0) :
    plan ⟨msgs, a1, c1, false, f⟩ ⟨msgs, a2, c2, false, 0⟩ = none := by
  simp [plan, planEvents, messagePhase, settle, snapshot, applyAll, hf]

/-- Messages taken away cannot be said by events either. -/
theorem aMessageTakenAwayNeedsASnapshot (m : Msg) (rest : List Msg) (o n : State)
    (ho : o.msgs = m :: rest) (hn : n.msgs = []) : plan o n = none := by
  simp [plan, ho, hn]

/-- An ordinary turn, as a host sees it a few changes at a time: every step
is told by events, and the device ends where the host does. -/
def q : Msg := ⟨1, true⟩
def r : Msg := ⟨2, false⟩
def turn : List State :=
  [ ⟨[], 0, 0, false, 0⟩,
    ⟨[q], 0, 0, true, 0⟩,
    ⟨[q], 0, 1, true, 0⟩,
    ⟨[q], 3, 2, true, 0⟩,
    ⟨[q], 4, 2, true, 0⟩,
    ⟨[q, r], 0, 0, false, 0⟩ ]

theorem anOrdinaryTurnIsToldByEvents :
    (List.zip turn turn.tail).all (fun (a, b) => (plan a b).isSome) = true := by decide

theorem anOrdinaryTurnIsToldInOrder :
    ((List.zip turn turn.tail).map (fun (a, b) => (plan a b).getD [])).flatten =
      [.turnStarted (some 1) (some q), .activity (some 1) 1, .fragment (some 1) 3, .activity (some 1) 2,
       .fragment (some 1) 4, .reply (some 1) r, .turnEnded (some 1)] := by decide

/-! ## Conformance tables

Each line names a decision, its inputs and the model's answer. Swift's
`AgentRemoteModelConformanceTests` runs this file, reads every `CONFORMANCE`
line, and asks the shipped Swift the same question; a `SYSTEMCHECK` line is a
count the Swift test expects. -/

def conformanceLine (rule : String) (fields : List String) : String :=
  "CONFORMANCE " ++ rule ++ " " ++ " ".intercalate fields

def attemptsName (as : List Attempt) : String :=
  if as.isEmpty then "-" else String.join (as.map fun | .right => "r" | .wrong => "w")

def allAttempts : Nat → List (List Attempt)
  | 0 => [[]]
  | n + 1 => [[]] ++ (allAttempts n).flatMap (fun as => [.right :: as, .wrong :: as])

#eval show IO Unit from do
  for a in [0, 1, 2, 3] do
    for as in (allAttempts 4).eraseDups do
      let (w, pairings) := run a as
      IO.println <| conformanceLine "pairingWindow" [toString a, attemptsName as, toString w.closed, toString pairings]

def countersName (cs : List Nat) : String :=
  if cs.isEmpty then "-" else ".".intercalate (cs.map toString)

def allCounters : Nat → List (List Nat)
  | 0 => [[]]
  | n + 1 => [[]] ++ (allCounters n).flatMap (fun cs => [0 :: cs, 1 :: cs, 2 :: cs])

#eval show IO Unit from do
  for cs in (allCounters 3).eraseDups do
    IO.println <| conformanceLine "channelOpens" [countersName cs, toString (opened 0 cs)]

#eval show IO Unit from do
  for (proof, name) in [(Proof.device, "device"), (.pairingCode, "pairingCode"), (.unknown, "unknown")] do
    for revoked in [false, true] do
      for windowOpen in [false, true] do
        let answer := match admit proof revoked windowOpen with
          | .acceptedDevice => "acceptedDevice" | .pairedByCode => "pairedByCode" | .close => "close"
        IO.println <| conformanceLine "admit" [name, toString revoked, toString windowOpen, answer]

def msgName (m : Msg) : String := (if m.user then "u" else "a") ++ toString m.id
def msgsName (ms : List Msg) : String := if ms.isEmpty then "-" else ".".intercalate (ms.map msgName)
def stateName (st : State) : String :=
  "/".intercalate [msgsName st.msgs, if st.running then "r" else "i", toString st.arriving, toString st.activity, toString st.failure]
def turnName : Option Nat → String | none => "-" | some n => toString n
def eventName : Event → String
  | .turnStarted t m => "S" ++ turnName t ++ ":" ++ (m.map msgName).getD "-"
  | .fragment t x => "F" ++ turnName t ++ ":" ++ toString x
  | .activity t a => "A" ++ turnName t ++ ":" ++ toString a
  | .reply t m => "R" ++ turnName t ++ ":" ++ msgName m
  | .failed t x => "X" ++ turnName t ++ ":" ++ toString x
  | .turnEnded t => "E" ++ turnName t

def lists : List (List Msg) :=
  [[], [⟨1, true⟩], [⟨1, true⟩, ⟨2, false⟩], [⟨1, true⟩, ⟨2, false⟩, ⟨3, true⟩],
   [⟨1, true⟩, ⟨2, false⟩, ⟨3, true⟩, ⟨4, false⟩], [⟨1, true⟩, ⟨3, true⟩], [⟨2, false⟩]]

def states (msgLists : List (List Msg)) : List State := Id.run do
  let mut out := []
  for ms in msgLists do
    for running in [false, true] do
      for arriving in [0, 1] do
        for activity in [0, 1] do
          for failure in [0, 1, 2] do
            out := out ++ [⟨ms, arriving, activity, running, failure⟩]
  return out

#eval show IO Unit from do
  let mut ordinaryRefused := 0
  for old in states (lists.take 3) do
    for new in states lists do
      let answer := match plan old new with
        | none => "snapshot"
        | some [] => "none"
        | some es => ",".intercalate (es.map eventName)
      IO.println <| conformanceLine "chatPlan" [stateName old, stateName new, answer]
      -- An ordinary change: messages only added, and no failure cleared.
      if old.msgs.isPrefixOf new.msgs && (old.failure == 0 || new.failure != 0) && (plan old new).isNone then
        ordinaryRefused := ordinaryRefused + 1
  IO.println s!"SYSTEMCHECK chatPlanOrdinaryNeedsNoSnapshot {ordinaryRefused}"

end LampAgentRemoteVerification
