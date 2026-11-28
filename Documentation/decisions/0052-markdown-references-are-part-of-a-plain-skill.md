# 0052. Markdown references are part of a plain skill

Status: Accepted, 2026-11-28. The Mac's `WorkspaceSkillStore.isPlainSkill`
and `plainReferences`, and the editor's `saveReference` and
`removeReference`. Held by `aPlainSkillMayHaveMarkdownReferences`. Step 7
of `../SkillsManagementPlan.md`.

## Context

A writing's Terminal asks the reader about anything in the workspace's
settings that Lamp cannot vouch for. A skill of the reader's own was "plain",
and so never asked about, only while it was SKILL.md alone. Lamp's study
skills keep their depth in reference files, and the new editor writes them
too, so every such skill of the reader's would have been asked about on
every launch.

## Decision

- **A skill is still plain with a `references` folder** that holds Markdown
  and nothing else:
  - regular `.md` files, and folders of them up to three deep;
  - none hidden, none a link, no second SKILL.md;
  - at most 256 KB each, and 64 in all.
- **Anything else is still asked about.** A script, a link, or a skill inside
  a skill is not prose for an agent to read.
- **The editor writes only such paths.** `references/…/name.md`, every part
  a plain name, through real folders inside the skill.
- **Removing a reference queues its deletion** by its published path before
  it goes, as removing the whole skill does (0049).
- **SKILL.md itself must still be exactly what Lamp writes**: a name, a
  description, and the instructions.

## Rejected

- **Accepting any file under `references`.** A script there could be run by
  an agent the Terminal launched, unasked.
- **Leaving references as findings.** That would ask about every skill
  modelled on Lamp's own, on every launch.
