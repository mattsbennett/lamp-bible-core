# 0049. A reader's skill is deleted everywhere

Status: Accepted, 2026-11-28. `LampSyncLocalDeletion.skillFile`,
`LampWritingWorkspaceLayout.skillFile(ofPath:)`, the Mac's
`WorkspaceSkillStore.deleteSkill` and `removeDeletedSkillFile`. Held by
`areadersSkillIsDeletedEverywhere` and the `deleteTarget` table,
`LampSkillFileLayoutTests`, and the Mac's `WorkspaceSkillStoreTests`. Step 5
of `../SkillsManagementPlan.md`.

## Context

The owner asked to remove their own skills from Settings. Nothing could:

- a writing's "Remove" only unticked a skill;
- a skill's files are published one at a time under
  `Workspaces/Skills/<name>`, as workspace files that were never deleted as
  files (`anyOtherWorkspaceFileIsNotDeletedAsAFile`).

So a skill deleted on one Mac came back from the server on the next pass.

## Decision

- **A new deletable kind, as a writing's sources became one in 0019.** A
  path under `Workspaces/Skills/<name>/…` names one file of one skill.
  - The name must be one the Mac makes: lowercase letters and digits, joined
    by single hyphens.
  - The path stays inside the skill and is compared in NFC.
  - It is deleted everywhere, and the Lean model's `deleteTarget` holds it.
- **Recorded on the act, never inferred from absence.**
  - Settings' Remove queues each file the export would publish, by its
    published path, before anything is removed.
  - Then the folder goes, the name leaves every writing's selection, and
    the writings lose their copies.
  - The name also leaves the reader-chat list (0048), so a skill made later
    under the name is not given to reader chats unasked.
  - A skill deleted in the Finder is not queued, and comes back.
- **The receiving Mac removes one file at a time**, on the workspace files'
  owner. Folders left empty go with it. Once SKILL.md is gone the folder is
  no longer a skill, so the writings that held it lose their copies straight
  away.
- **A deletion never takes a save it did not see.** As with a writing's
  documents (`documentDeletionKeeps`):
  - a file edited here since it was last agreed with the server is kept, as
    checked against the live file on the owner;
  - a file changed here since it was last agreed is saved "now" for the plan,
    raised past the deletion, so an edit the removal never saw outlives it
    whatever the clocks say; the agreed copy has no save time and goes;
  - a queued removal is forgotten once a file is held there again, so a
    skill removed and made again under its name before the next pass is the
    new skill.
- **Lamp's own skills are refused.** They are turned off in Settings (0047),
  never removed.

## Consequences

- A Mac on an older build refuses the tombstone and uploads the skill
  again, until every Mac is updated.
- A file another Mac added to the skill after this Mac's last pass is not
  queued, and comes back on its own. Without a SKILL.md it is not a skill:
  it shows nowhere and is given to nothing.
- The iPhone has no skills, and no switch over these cases, so it is
  unchanged.
- **A removal made while a pass uploads the skill can come back once.** The
  pass records its upload after the removal, and the next pass reads that
  as a newer save. Core's `queuedDeletionTime` dates past such an upload for
  documents only, and a writing's sources have the same gap. Left as it is
  for both: the skill shows again, and removing it again sticks. Codex's
  review of step 5 raised it, at P2.
- A skill file whose name sync cannot publish, with a backslash in it, is
  not queued, and does not stop the skill being removed here.

- **A published write loses to a later removal; an unsent one does not.**
  If another Mac uploaded an edit and this one then removes the skill
  without having seen it, the skill goes on both. That is the rule for every
  deletable kind (`filePlanAction`), and the Remove dialog says "on all your
  Macs".

## Rejected

- **A file's modification time as its save time.** Tried first. A download
  dates a file when it arrives, so a Mac that had only fetched the old copy
  outranked a removal made before the fetch, and published the removed
  skill again. Codex's second review of step 5 found it.
- **A record of when the editor saved each file.** It misses every edit made
  outside Lamp's editor, in the Finder or another editor, and adds state to
  keep out of the export.
- **Keeping an edited file as a renamed copy, as documents are.** A skill
  file's name is load-bearing: a renamed SKILL.md stops the folder being a
  skill. The edit is kept in place and goes back up on the next pass.

- **Deleting the folder and letting absence speak.** That is the inference
  0018 removed for sources: an agent tidying a folder, or a Finder slip,
  would delete the skill on every Mac.
- **One entry for the folder.** The receiving side checks each file by its
  own path, as it does for sources, so one entry for the folder would leave
  every file inside it.
