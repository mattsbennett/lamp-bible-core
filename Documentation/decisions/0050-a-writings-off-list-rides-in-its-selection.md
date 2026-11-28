# 0050. A writing's off-list rides in its selection

Status: Accepted, 2026-11-28. The Mac's `WorkspaceSkillStore.builtInSkillsOff`
and `setBuiltInSkill`, held by `aWritingsOffListSurvivesEveryWriter`,
`anOffEntryIsANameNeverAPath`, `aWritingsOffListReachesItsFolders` and
`aTickStartsASync`. Step 6 of `../SkillsManagementPlan.md`.

## Context

The owner asked to turn Lamp's skills off for one writing as well as in
Settings. The plan put the writing's list in a new file beside its selection,
`DisabledBuiltInSkills.json`, and asked first what an older Mac would do with
it.

The code answers: a writing's portable folder carries its documents,
sources, selection, revisions and conversations, each placed by a step of
its own, with no catch-all. An older Mac would fetch the new file, place it
nowhere, never claim it, and fetch it again on every pass.

## Decision

- **An `off:<name>` entry among the names in the writing's existing
  `EnabledSkills.json`.**
  - Every build reads that file's names through `isValidSkillName`, and `:`
    is not in a skill's name, so an older Mac ignores the entries and serves
    nothing different.
  - `formatVersion` stays 1.
  - The file already syncs whole, by date.
- **Every writer here keeps the entries**, since all of them write through
  `writeSelection`:
  - enable and disable;
  - a removed skill's strip;
  - `applySelectionData`, and the legacy import that goes through it;
  - the toggle itself.

  A selection arriving with entries of its own replaces this writing's; one
  with none leaves them.
- **Matched against Lamp's table, never used as a path.**
  - Only a skill a writing has and may turn off is acted on.
  - An entry naming a skill this build does not ship is kept verbatim, for
    the build that does.
  - An entry that could not be a skill's name is dropped.
- **Off wins** (0046). A skill off in Settings is off in every writing,
  whatever the writing says, and shows as "Off in Settings".
- **A tick starts a sync.** The selection file joins `LampSyncLocalWork`'s
  marks, since ticking writes nothing else.
- **The workspace pane shows one list of checkboxes**, Lamp's skills then
  the reader's own. "Remove from this workspace?" goes: unticking is a
  choice, not a deletion.

## Consequences

- **An older Mac can turn a writing's built-ins back on.** It drops the
  entries when the reader ticks or creates a skill in that writing there.
  Every Mac then has the skill on again, visibly in that writing's list, and
  one click turns it off. This is not a precedent for fields whose loss is
  silent or does harm (`merged-record-new-fields-must-union`). Here the loss
  restores a skill to its default, and shows.
- No Lean change: the file merges whole by date as before.

## Rejected

- **A sibling file.** An older Mac never claims it, and fetches it on every
  pass.
- **Keeping the choice on one Mac.** It would never reach the owner's other
  Macs, and a turn asked from the phone would get whichever Mac answered.
- **A new key in the selection.** An older Mac re-encodes only
  `formatVersion` and `names`.
- **Raising `formatVersion`.** An older Mac would refuse to read the file
  and fail to prepare the writing.
