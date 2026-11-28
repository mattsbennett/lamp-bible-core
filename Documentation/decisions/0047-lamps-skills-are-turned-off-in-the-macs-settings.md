# 0047. Lamp's skills are turned off in the Mac's settings

Status: Accepted, 2026-11-28. The Mac's `LampSkillChoices` and Settings ▸
AI & Agents ▸ Skills, held by `SkillChoicesTests` and
`SkillsTurnedOffTests`. Step 2 of `../SkillsManagementPlan.md`.

## Context

The owner wanted to turn Lamp's bundled skills off. Some they want in
writing chats but not in reader chats. 0046 made one function say which
skills a surface is given; this is where the choice it reads is kept.

## Decision

- **Each bundled skill that can be turned off gets a "Use in" menu in
  Settings:**
  - "Writings and reader chats", "Writings only" or "Off" for the two study
    skills;
  - "Writings" or "Off" for `build-lamp-deck`, which no reader chat has.

  "Off" takes a skill from every writing, reader chat and outside app.
  "Writings only" takes it from reader chats alone.
- **Two booleans per skill** in the Mac's settings:
  `agent.skills.off.<name>` and `agent.skills.readerOff.<name>`.
  - Five keys in all, added to core's `LampPortableSettingsCodec.syncedKeys`.
  - A Mac test holds that list to the Mac's `LampSkillChoices.keys`.
- **Absent means on.** A Mac on an older build publishes none of the keys,
  and the merge already reads a missing key as no news.
- **Back on is written as `false`.** Removing the key would never reach the
  other Macs, for the same reason.
- **The helper learns what is off from the agent descriptor**
  (`skillsTurnedOff`), read at each call as the descriptor's switches are.
  - It refuses a skill that is off from every root, not only Lamp's
    catalog, because a workspace prepared earlier may still hold a copy.
  - It also drops the skill's prompt from the list and refuses fetching it.
- **Open writings and reader chats react straight away.**
  - `LibraryModel` reads the choice again whenever the settings change,
    whether from Settings or from a sync.
  - It republishes the descriptor.
  - An open writing reinstalls or removes its copies and rewrites its
    instructions; an open reader chat prepares its folder again.
- **No per-chat control.** The owner's case is a skill kept out of reader
  chats, which "Writings only" says once. A menu in each reader chat would
  have to be set again in every new chat.

## Consequences

- The Mac's settings are not the phone's shared-preference ledger, so the
  phone neither sees nor needs these keys. Its turns run on the Mac.
- A choice made while a turn runs reaches that turn's folder at once. The
  provider has already read its instructions.

## Rejected

- **One three-valued key per skill.** Each surface would decode a value
  instead of reading one boolean.
- **The shared-preference ledger.** It would need iOS work, since
  `UserSettingsSyncManager` builds its values key by key, for settings only
  a Mac uses.
- **The helper reading the app's settings itself.** An outside app starts
  the helper with another settings domain; the descriptor is the one file
  both already agree on.
