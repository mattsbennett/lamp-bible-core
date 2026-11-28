# 0051. A skill has its own window, and is not a writing

Status: Accepted, 2026-11-28. The Mac's `SkillEditorWindow`, opened from
Settings ▸ Your Skills and from a writing's Skills. Step 7 of
`../SkillsManagementPlan.md`.

## Context

The owner considered treating skills as writings, opened in a writing
workspace, or giving the workspace a mode for editing them. They also asked
whether a file tree sidebar would help, and where. Until now a skill was
edited in a 650 × 480 sheet holding only SKILL.md.

## Decision

- **A window of its own**, one per skill, like Module Info.
  - It holds the name, fixed once saved, then "When to use it" (the
    description), then the instructions in the plain-source Markdown editor.
  - Saving is a button, never automatic, because a save rewrites every
    writing that uses the skill.
  - Lamp's own skills open read-only, with every reference they ship.
  - A new skill made from a writing is ticked in that writing once saved.
    An existing one edited from a writing is not ticked by the edit.
- **A file list only inside that window.** It shows SKILL.md and
  `references/*.md`, once a skill has more than one file. New Reference…
  and Remove sit beneath it.
- **No file tree in a writing's workspace.**

## Consequences

Codex's last review, which found nothing at P1, left these, each rare:

- **Checks and writes are separate calls to the files' owner.** A sync
  landing between the window's check that SKILL.md is unchanged and its
  write can be written over. A reference a sync adds at a path the window
  is about to create is refused only after SKILL.md is written. The post-save
  read can take up a synced copy the window never showed.
- **A save whose catalog write succeeded but whose update of the writings
  failed** is reported as failed. A retry of a new reference is then
  refused as already on disk; reopening the window shows it saved.
- **A skill over 64 references**, from an older import or additions synced
  together, can't be saved in the window until some are removed, since the
  limit is checked against the whole skill.
- **Making a skill under a removed one's name** takes in its leftover files,
  and an undecodable SKILL.md left there is written over.
- **A reader-chat opt-in made on one Mac while another removed the skill**
  can come back with the settings, and a skill made later under that name
  is then in reader chats. Removing a skill writes the list only when the
  skill was in it, so an unrelated choice is never published over.

## Rejected

- **Skills as writings.** A skill has no category, review marks, deck or
  read-aloud. Making it a writing would cost:
  - syncing to the phone as writings it cannot use;
  - a "not for skills" exception on every writing feature;
  - the writing editor normalising Markdown whose bytes are the
    instructions.
- **A skill mode in the writing workspace.** It puts a library-wide object
  in one writing's pane, as if the skill were that writing's: the mistake
  `import-lamp-writing` was moved out of workspaces to fix.
- **A file tree in every writing.** It would show `.lamp`, `.agents`,
  `.claude` and the providers' settings, which the workspace hides on
  purpose. An edit to an installed copy would also be replaced, unsaid, the
  next time the skills were brought up to date.
- **Keeping the sheet.** It has no room for real instructions, and none at
  all for references.
