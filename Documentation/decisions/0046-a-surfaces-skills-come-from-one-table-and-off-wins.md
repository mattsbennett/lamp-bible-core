# 0046. A surface's skills come from one table, and off wins

Status: Accepted, 2026-11-28. `WorkspaceSkillStore.bundledSkillNames(for:)`
on the Mac, held by `BundledSkillInstallTests`,
`theDeckLineFollowsTheDeckSkill` and `everyPromptIsABundledSkill`. Step 1 of
`../SkillsManagementPlan.md`.

## Context

The owner asked to turn Lamp's bundled skills off: in Settings, and for one
writing. Before anything could be turned off, the Mac had to say in one
place which skills a surface is given. It said so in four:

- the `bundledSkills` table's derived sets, for a writing and a reader chat;
- `LampBundledSkills.studySkillNames`, a second hand-written list, which
  set what an app outside Lamp could read;
- the MCP prompt catalog's own list of prompts;
- a writing's AGENTS.md, which named `build-lamp-deck` whatever the
  workspace held.

A skill turned off in only some of these would still be named or served by
the rest.

## Decision

- **One table.** `WorkspaceSkillStore.bundledSkills` holds each bundled
  skill with:
  - its title;
  - whether it writes files;
  - whether it belongs in a writing;
  - whether an outside app may read it;
  - whether it can be turned off.
- **One function.** `bundledSkillNames(for:offEverywhere:offOnSurface:)`
  answers for a writing, a reader chat and a connected app. Every consumer
  asks it, and nothing else decides:
  - writing install and sync;
  - reader-chat prepare and its instructions, including OpenCode's prompt;
  - `externalSkillNames`;
  - the AGENTS.md deck line.
- **Off wins.** A skill off in Settings or on the surface is not given.
- **`import-lamp-writing` cannot be turned off.** Add to Library's import
  is built to its format.
- **A reader chat's skills are worked out once in `prepare`.** The folder,
  AGENTS.md, CLAUDE.md and OpenCode's prompt are written from that one set,
  so they cannot disagree.
- **Prompts stay listed by hand.** Their titles and arguments are their
  own, but each must be a bundled skill's name, so turning the skill off
  can take its prompt away.

Nothing is off yet: every caller passes empty sets, so behaviour is as
before.

## Rejected

- **A per-surface inherit, on or off.** It needs a three-state control, and
  lets a writing silently contradict Settings.
- **Deriving the prompt list from the table.** A prompt carries its own
  title, arguments and adapted text, which the table has no reason to hold.
