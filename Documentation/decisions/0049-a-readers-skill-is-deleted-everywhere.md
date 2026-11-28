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
  no longer a skill, so the writings lose their copies straight away.
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

## Rejected

- **Deleting the folder and letting absence speak.** That is the inference
  0018 removed for sources: an agent tidying a folder, or a Finder slip,
  would delete the skill on every Mac.
- **One entry for the folder.** The receiving side checks each file by its
  own path, as it does for sources, so one entry for the folder would leave
  every file inside it.
