# Skills management plan

Planned by Fable on 2026-11-28, against Mac `e26683e` and core `90bc79e`.
The coordinator checked the load-bearing claims against the code the same
day. The owner approved the shape on 2026-11-28 and replaced the per-chat
reader control with a "writings only" choice in Settings. All seven steps
were built the same day, Mac f79bae7 and core e868dda, recorded in
0046–0052.

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
| Settings ▸ AI & Agents ▸ **Skills** (only with AI on) | Built-in skills: a "Use in" menu and View each. The menu reads "Writings and reader chats", "Writings only" or "Off" for a study skill, and "Writings" or "Off" for build-lamp-deck, which reader chats never get. "Off takes a skill away from every writing, reader chat and connected app. Lamp's own copy is never changed." | Writings and reader chats |
| Same section | Your skills: a "Use in" menu, Edit…, Remove…, New Skill… The menu reads "Writings only" or "Writings and reader chats". A row set to reader chats is captioned: "Reader chats can't write files. When this skill would save something, the chat offers to start a writing instead." Remove confirms that the skill leaves every writing on every Mac. | Writings only |
| Writing workspace, "Skills" | One list of toggles: built-ins and your skills. A built-in that is off in Settings is greyed: "Off in Settings". The menu has New Skill… and Manage Skills…. | Built-ins on, yours off |

- `import-lamp-writing` is never listed. Turning it off would break Add to
  Library's import.
- There is no "duplicate a built-in": that would make the divergent copy
  the `bundledSkills` comment forbids.
- **No per-chat control for reader chats.** The owner wants some skills in
  writing chats but not reader chats. "Writings only" in Settings says that
  once. A menu in each reader chat would have to be set again in every new
  chat. Fable's plan had one; the owner's case replaced it on 2026-11-28.
- **Your skills can reach reader chats** (owner, 2026-11-28), chosen in
  Settings and off by default. Lamp cannot tell whether a skill writes
  files, so it does not guess. The choice is not in the editor window,
  which saves the skill's content, not where it is used.
- A writing still gets one of your skills only when ticked there, and
  outside apps get none.

**When a reader chat is asked for something to keep.** A reader chat
cannot write files. When the reader, or a skill's step, asks for a file or
a finished piece, the chat says it cannot save it here and offers to start
a writing with `start_writing`, which copies the conversation into a new
writing whose chat can carry the work on. It calls `start_writing` only
once the reader says yes, as its instructions already require. If that
tool is turned off, the chat gives the result in the conversation and says
where in Settings a writing can be started from a chat. This instruction
is in every reader chat, not only those with one of your skills, because
the reader can ask for output without any skill.

## Data model

**Off wins.** A surface gets its bundled set, less what is off in Settings,
less what is off on that surface. A per-surface "inherit, on, off" control
was rejected: it needs three states, and lets a writing silently contradict
Settings.

**In Settings**, two booleans per built-in, where absent means on:
`agent.skills.off.<name>` (everywhere) and `agent.skills.readerOff.<name>`
(reader chats). "Writings only" sets the second; "Off" sets the first.
- They sync through `LampPortableSettingsCodec.syncedKeys`, whose merge is
  already per key. No Lean change.
- Two keys rather than one three-valued key, so each surface reads one
  boolean, and an older Mac without the reader key still syncs the other.
- The MCP helper learns the set through its descriptor.

**Your skills in reader chats**: one list-valued key in `syncedKeys`,
`agent.skills.readerNames`, a sorted array as `modules.hiddenIDs` is.
- Absent means none, so an older Mac's settings are no news. No Lean
  change.
- A name with no skill in the catalog is ignored. Remove strips the name,
  so a skill re-created under it does not return to reader chats.
- Cost: two Macs marking different skills offline keep one Mac's whole
  list.
- Rejected: a field in front matter. An older Mac's `saveSkill` writes name
  and description only, so one edit there strips it. It would also make
  the skill not plain, and other agents' loaders read front matter.
- Rejected: a sidecar file. At the catalog root it needs new export and
  import code for the same whole-file merge. Inside each skill's folder an
  older Mac copies it into writings, where the plain-skill check flags it.

**Getting one into a chat.** `read_skill` in a reader chat serves only the
chat folder's `.claude/skills` and `.agents/skills`
(`LampMCPToolHandler.readSkill`), so prepare copies each marked skill
there.
- Markdown only: SKILL.md and its `.md` reference files.
- Prepare sweeps any folder not in the chat's set; today it removes only
  bundled names.
- The catalog read runs on `WritingWorkspaceFiles`, so it cannot copy a
  skill mid-save. Reader prepare's two callers become async.
- A chat already open re-prepares between turns when the setting or the
  catalog changes. A turn in flight keeps what it started with.

**For a writing**, `off:<name>` entries among the names in its existing
selection (0050). An older Mac reads only valid skill names, so it ignores
them.
- A sibling file was planned and dropped. A writing's portable folder has no
  catch-all, so an older Mac would fetch it every pass and never place it.
- Keeping the choice on one Mac was rejected: it would never reach the
  others.

**Removing a custom skill is a synced deletion**, following 0019: a
deletable kind for skill files, queued on the act and never inferred from
absence.

## Order

1. **One function says which skills a surface gets**, bundled and yours.
   `WorkspaceSkillStore.skills(for:libraryOff:surfaceOff:)`. The
   table gains `title` and `canBeTurnedOff`. Every consumer goes through it
   with nothing off, and behaves exactly as before:
   - writing install and sync;
   - reader-chat prepare and instructions;
   - the AGENTS.md deck line;
   - `studySkillNames`;
   - the MCP prompts.
2. **Off in Settings.** The keys, the Settings section's "Use in" menus
   and the descriptor field. MCP filters on the everywhere key, reader-chat
   prepare on both, and open panes re-prepare when either changes. In core,
   five `syncedKeys`.
3. **Your skills in Settings.** The editor sheet moves to its own file; New
   and Edit appear in Settings.
4. **Your skills in reader chats.** The menu, the key (a sixth in core),
   the copy and sweep, the re-prepare trigger, and the reader instruction
   that offers a writing for output. Mac plus one core key.
5. **Remove everywhere.** It also strips the name from the reader list.
   - Core: `LampSyncLocalDeletion.skillFile`, the layout classifier,
     `LocalKind.skillFile` in the Lean model with a theorem and conformance
     rows, and `coverage.json`.
   - Mac: `deleteSkill` and the pass's dispatch.
   - iOS: a core bump and one test row.
6. **Per-writing toggles.** `off:` entries in the selection, kept by every
   writer, and the selection file added to the local-work fingerprint.
7. **The editor window with reference files.** `isPlainSkill` accepts
   regular `.md` files under `references/`. It still refuses:
   - links;
   - hidden files;
   - a second SKILL.md;
   - extra front matter.

## Decision records

Numbered as they landed:

- 0046: a surface's skills come from one table, and off wins.
- 0047: Lamp's skills are turned off in the Mac's settings; no per-chat
  control.
- 0048: your skills reach reader chats by a Settings list, off by default,
  Markdown only; a reader chat asked for output offers a writing.
- 0049: a reader's skill is deleted everywhere.
- 0050: a writing's off-list rides in its selection.
- 0051: a skill has its own window and is not a writing; no workspace file
  tree.
- 0052: Markdown references are part of a plain skill.

## Tests that must bite

- **Your skills, default.** An unmarked skill is in no reader chat's
  folders, instructions or `read_skill` listing.
- **Your skills, marked.** Both folders hold SKILL.md and
  `references/a.md`, and not a script. AGENTS.md, CLAUDE.md and the
  OpenCode prompt name it. `read_skill` returns both files through the
  chat's real configuration.
- **Unmarked or removed.** The next prepare sweeps it and stops naming it.
  A link in the folder is not followed.
- **Edited.** A same-length edit replaces the copy.
- **Reader list.** An older Mac's settings leave it alone, a name with no
  skill is ignored, and Remove strips the name. Marking ticks no writing.
- **Output.** Every reader chat's instructions offer a writing for output,
  and say to call `start_writing` only after the reader agrees.

- **Writings only.** With sola-scriptura set to writings only, a reader
  chat's files and instructions do not name it, and a writing still holds
  it.
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
- **Older Macs.** Today's reading of a selection with `off:` entries is
  the reader's skills alone. Today's encoder drops them: the built-ins come
  back on, nothing throws, and nothing loops.
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
- **An older Mac's skill edit in a writing** turns that writing's built-ins
  back on everywhere.
