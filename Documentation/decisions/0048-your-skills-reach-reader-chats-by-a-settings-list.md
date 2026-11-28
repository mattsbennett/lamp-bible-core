# 0048. Your skills reach reader chats by a list in Settings

Status: Accepted, 2026-11-28. The Mac's `LampSkillChoices.yourSkillsInReaderChats`
and `WorkspaceSkillStore.installReaderSkills`, held by `SkillChoicesTests`
and `aReaderChatReadsYourSkillChosenForIt`. Step 4 of
`../SkillsManagementPlan.md`.

## Context

The owner asked for their own skills to be usable in reader chats. Until
now a reader chat had only Lamp's study skills: a reader chat cannot write
files, and Lamp cannot tell whether one of the reader's skills ends in one.

## Decision

- **Chosen per skill, in Settings ▸ Your Skills**: "Writings only" (the
  default) or "Writings and reader chats".
  - A row set to reader chats says that reader chats can't write files, and
    that the chat offers to start a writing instead.
  - The choice is not in the skill editor, which saves the skill's content,
    not where it is used.
  - A writing still gets one of the reader's skills only when it is ticked
    there, and an outside app gets none.
- **One list of names**, `agent.skills.readerNames`, in core's `syncedKeys`.
  The names are the reader's, so core cannot list a key per skill as it does
  for Lamp's own.
  - Absent means none, so an older Mac changes nothing.
  - An empty list is written as one, not removed.
  - A name with no skill in the catalog is ignored.
- **Copied into the chat, Markdown only.** In a reader chat, `read_skill`
  serves only the chat's own folders, so the skill must be there.
  - SKILL.md and its `.md` references are copied; scripts, hidden files and
    links are not.
  - The copy is made on `WritingWorkspaceFiles`, so it is never taken
    halfway through a save or a sync's take-in.
  - It is made before every turn, from a window or a phone, and when a pane
    opens. A skill edited, unchosen or gone from the catalog is followed on
    the next turn.
- **The chat's prepare takes out what is no longer chosen.** It needs no
  catalog to do it, and it names the skills from its own folders, so the
  instructions and the folder always agree.
- **Every reader chat offers a writing for what it can't save.** When the
  reader, or a skill's step, asks for a file or a finished piece, the chat
  says so and offers to start a writing with `start_writing`.
  - It calls `start_writing` only once the reader asks or agrees.
  - If that setting is off, it gives the result in the conversation and
    names the setting.
  - This is in every reader chat, since a reader can ask for output with no
    skill at all.

## Consequences

- If two Macs change the list while offline, one Mac's whole list wins.
  That is one visible choice to make again.
- A skill chosen for reader chats is copied into each reader chat a turn
  is sent from. The skills are Markdown, so this is small.

## Rejected

- **A field in the skill's front matter.** An older Mac's `saveSkill`
  writes the name and description only, so one edit there strips it. The
  skill would also no longer be plain, and other agents' loaders read front
  matter.
- **A sidecar file.**
  - At the catalog root, it needs new export and import code for the same
    whole-file merge.
  - Inside each skill's folder, an older Mac copies it into writings, where
    its launch check flags the skill.
- **Serving the catalog to reader chats through `read_skill`.** The catalog
  holds every skill, chosen or not, and the chat would be offered ones whose
  steps end in files.
- **Defaulting to on.** Lamp cannot tell whether a skill writes files.
