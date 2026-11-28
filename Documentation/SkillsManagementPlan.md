# Skills management plan

Planned by Fable on 2026-11-28, against Mac `e26683e` and core `90bc79e`.
The coordinator checked the load-bearing claims against the code the same
day. Not yet approved by the owner.

## What was asked

- Add and remove the owner's own skills in Settings.
- Turn off bundled skills in Settings, and in a writing's workspace or a
  reader chat.
- Three open questions:
  - open skills as writings, or give them a mode for editing;
  - whether a file tree sidebar earns its place;
  - if so, where it goes.

## What is there today

- `WorkspaceSkillStore` (`WorkspaceSkillSupport.swift`) keeps the custom
  catalog under the library's `AgentSkills`. Each writing ticks skills in
  `.lamp/enabled-skills.json`, and the store copies them into
  `.agents/skills` and `.claude/skills`.
- A workspace's "Remove" only unticks a skill. Nothing deletes one from the
  library. Core's model forbids deleting a skill file
  (`anyOtherWorkspaceFileIsNotDeletedAsAFile`), so a local delete would come
  back from the server.
- Built-ins can be viewed in a workspace, but not removed. The viewer shows
  only SKILL.md, though sola-scriptura ships ten reference files.
- `import-lamp-writing` is installed on no surface. It is read from the
  bundle.
- A custom skill with any second file is not "plain", so each extra file
  raises a Terminal launch-check finding.
- The bundled names are written out three times:
  - the `bundledSkills` table;
  - `LampBundledSkills.studySkillNames`;
  - the MCP prompt catalog.
- The AGENTS.md template names `build-lamp-deck` whether or not it is
  installed.
- iOS has no skills. Phone turns run on the Mac.
- Ticking a skill does not start a sync pass: `LampSyncLocalWork` does not
  walk the selection file.

## UX

**Skills are not writings.** A skill has no category, review marks, deck or
read-aloud. Making it a writing would cost:
- syncing to the phone as writings it cannot use;
- a "not for skills" exception on every writing feature;
- a storage migration;
- TipTap normalising Markdown whose bytes are the instructions.

**No skill mode in the writing workspace.** It would put a library-wide
object in one writing's pane, the mistake `import-lamp-writing` was moved
out of workspaces to fix.

**A skill editor window of its own**, a `WindowGroup(for:)` scene as Module
Info has. It opens from Settings and from a workspace's Edit.
- Fields: Name (fixed after creation), "When to use it" (the description),
  and Instructions in the plain-source `MarkdownTextEditor`.
- Saving is explicit, because a save rewrites every workspace that uses the
  skill.
- **A file list, only in this editor**: SKILL.md and `references/*.md`,
  shown once a skill has a second file.
- **No file tree in writing workspaces.** It would expose `.lamp`,
  `.agents`, `.claude` and provider configs that `WorkspaceTextFileStore`
  hides. Edits to an installed copy would also be silently replaced by
  `synchronizeWorkspace`.

**Where each control lives**

| Place | What it shows | Default |
|---|---|---|
| Settings ▸ AI & Agents ▸ **Skills** (only with AI on) | Built-in skills: a toggle and View each. "Off takes a skill away from every writing, reader chat and connected app. Lamp's own copy is never changed." | On |
| Same section | Your skills: Edit…, Remove…, New Skill… Remove confirms that the skill leaves every writing on every Mac. | — |
| Writing workspace, "Skills" | One list of toggles: built-ins and your skills. A built-in that is off in Settings is greyed: "Off in Settings". The menu has New Skill… and Manage Skills…. | Built-ins on, yours off |
| Reader chat setup | A Skills menu with the two study skills, for this chat. | On |

- `import-lamp-writing` is never listed. Turning it off would break Add to
  Library's import.
- There is no "duplicate a built-in": that would make the divergent copy
  the `bundledSkills` comment forbids.

## Data model

**Off wins.** A surface gets its bundled set, less what is off in Settings,
less what is off on that surface. A per-surface "inherit, on, off" control
was rejected: it needs three states, and lets a writing silently contradict
Settings.

**In Settings**, `agent.skills.off.<name>` booleans, where absent means on.
- They sync through `LampPortableSettingsCodec.syncedKeys`, whose merge is
  already per key. No Lean change.
- The MCP helper learns the set through its descriptor.

**For a writing**, a sibling file, `.lamp/disabled-builtin-skills.json`,
published as `DisabledBuiltInSkills.json`.
- A key in `enabled-skills.json` was rejected: an older Mac re-encodes only
  `formatVersion` and `names`, so it would strip the key.
- A `formatVersion` bump was rejected: older builds would throw.

**For a reader chat**, the same file in the chat's folder. It stays local.

**Removing a custom skill is a synced deletion**, following 0019: a
deletable kind for skill files, queued on the act and never inferred from
absence.

## Order

1. **One function says which bundled skills a surface gets.**
   `WorkspaceSkillStore.bundledSkills(for:libraryOff:surfaceOff:)`. The
   table gains `title` and `canBeTurnedOff`. Every consumer goes through it
   with nothing off, and behaves exactly as before:
   - writing install and sync;
   - reader-chat prepare and instructions;
   - the AGENTS.md deck line;
   - `studySkillNames`;
   - the MCP prompts.
2. **Off in Settings.** The keys, the Settings section's toggles and the
   descriptor field. MCP filters on it, and open panes re-prepare when it
   changes. In core, three `syncedKeys`.
3. **Your skills in Settings.** The editor sheet moves to its own file; New
   and Edit appear in Settings.
4. **Remove everywhere.**
   - Core: `LampSyncLocalDeletion.skillFile`, the layout classifier,
     `LocalKind.skillFile` in the Lean model with a theorem and conformance
     rows, and `coverage.json`.
   - Mac: `deleteSkill` and the pass's dispatch.
   - iOS: a core bump and one test row.
5. **Per-writing toggles.** The sibling file, with its export and import,
   and both selection files added to the local-work fingerprint. Before it
   ships, test what an older exporter does with an unknown
   `DisabledBuiltInSkills.json`. If it re-fetches every pass, keep the
   choice local.
6. **The reader-chat menu.**
7. **The editor window with reference files.** `isPlainSkill` accepts
   regular `.md` files under `references/`. It still refuses:
   - links;
   - hidden files;
   - a second SKILL.md;
   - extra front matter.

## Decision records

- 0046: off wins, by selection.
- 0047: the Settings choice travels in the Mac's settings.
- 0048: a writing's off-list is a sibling file.
- 0049: a custom skill is deleted everywhere.
- 0050: a skill has its own editor and is not a writing; no workspace file
  tree.
- 0051: Markdown references are part of a plain skill.

## Tests that must bite

- **Off in Settings.** With sola-scriptura off, none of these hold it or
  name it:
  - a writing's provider folders;
  - its chat instructions and AGENTS.md;
  - a reader chat's AGENTS.md, CLAUDE.md and OpenCode prompt;
  - the MCP prompt list and `read_skill`.
- **The deck line.** With build-lamp-deck off, the deck line is gone.
- **On again.** Turning a skill back on installs a copy whose `treeDigest`
  equals the bundle's. The catalog and the export never hold a bundled
  name.
- **Older Macs.**
  - Re-encoding `enabled-skills.json` as today's selection leaves the
    off-list intact.
  - An import without `DisabledBuiltInSkills.json` turns nothing back on.
- **Two Macs.** An off set on one reaches the other's installed folders.
- **Deletion.**
  - Each file is queued by its published path.
  - A Finder delete does not delete everywhere.
  - A bundled name is refused.
  - A context file is not taken for a skill file.
  - The receiving Mac loses the installed copies.
- **Launch check.** `references/a.md` raises no finding. A script, a link,
  or a nested SKILL.md does.
- **Ownership.** `WorkspaceFileOwnershipTests` covers the new writers.
- **The AI switch.** With AI off, there is no Skills section and nothing is
  published.

## Risks

- **An older Mac puts a removed skill back.** It refuses the tombstone and
  re-uploads, until every Mac is updated.
- **Two Macs toggling offline.** Per-writing choices merge whole-file, so
  one Mac's toggles are lost, as with `EnabledSkills.json` today.
- **The per-chat reader control is the weakest piece.** Chats are short,
  and a choice made once per chat has to be made again in every new one.
