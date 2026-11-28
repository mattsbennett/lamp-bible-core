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
