# 0038. A provider starts from Lamp's settings and the person's, never the workspace's

Status: Accepted, 2026-11-26. Built (`lamp-bible-macos`: `aClaudeWritingRunReadsNoneOfTheWorkspacesSettings`,
`aClaudeWritingRunIsToldLampsInstructionsNotTheFiles`,
`alwaysAllowRulesAreKeptByWritingOutsideTheWorkspace`,
`aWritingsAgentCannotEditWhatAProviderStartsFrom`, `AgentTerminalLaunchCheckTests`,
`retiredLaunchFilesAreRemovedOnlyInsideTheWorkspace`); OpenCode's chats are
open. Planned by Fable.

## Context

A writing workspace is where every provider's agent works, and every agent
can write in it. Lamp also started each provider from files in it:

- **Claude.** Under `-p`, a project's `.mcp.json` servers connect without
  asking, approved or not, and its settings files' hooks, `env` and
  `apiKeyHelper` are used (Claude Code's own table). Tried, 2026-11-26, on
  Claude Code 2.1.332: a server planted in `.mcp.json` and a `SessionStart`
  hook planted in `.claude/settings.json` both ran in an ordinary chat turn.
  Claude Code guards those paths from its own agent (they are prompted under
  `acceptEdits`), but not from another provider's agent in the same writing.
- **Codex** reads a project's settings only in a folder the person trusted,
  and since 0028 its chats are given Lamp's server on the command line.
- **Antigravity** documents per-workspace `.agents/` configuration, and Lamp's
  own answer to its permission requests let its agent edit anything in the
  workspace.
- **OpenCode** reads `opencode.json` from the workspace, and documents its
  shell as running with the person's full authority.
- **The Terminal** runs each provider's own CLI in the workspace, from those
  same files, with its launch script in the workspace's `.lamp/terminal/`.

## Decision

Built:

1. **A Claude writing chat runs with `--setting-sources user`**, so it reads
   the person's own settings and none of the workspace's, with Lamp's server
   given by `--mcp-config` (not `--strict-mcp-config`, so the person's own
   servers stay) and the instructions the workspace's `CLAUDE.md` held given
   by `--append-system-prompt`, made from the workspace as it is, never read
   from the file, through a file of Lamp's per run
   (`--append-system-prompt-file`), since a writing's list of sources can
   outgrow a command line, and with `--system-prompt-snapshot off`, since by
   default a resumed conversation resends its first prompt whatever a later
   launch says (only where the installed Claude Code has the flag, from
   2.1.257; before it there was no snapshot). Should the file not be
   written, the turn stops and says so rather than start Claude told nothing.
   A source's name is listed on one line and cannot end its code span. The writing's skills, which Claude no longer finds in
   `.claude/skills`, are named there for Lamp's `read_skill`, and by their
   files where Lamp's tools are off.
   Tried: with the flag, the planted server and hook did not run, the
   given server and a `--settings` hook did, and Lamp's `PermissionRequest`
   hook still asked.
2. **Always Allow is kept by Lamp**, in `AgentAllowRules.json` in Lamp's
   Application Support folder, by workspace, and given to each run as
   `permissions.allow` in the `--settings` Lamp passes; tried, a rule given
   so ran its command unasked. Claude Code no longer writes it into the
   workspace's `.claude/settings.local.json`, which the run no longer reads,
   and which an agent could write. Rules saved there before are not carried
   over, since that file can't be trusted as their source: the person is
   asked once more.
3. **An Antigravity writing agent cannot edit what a provider starts from:**
   anything under a hidden name at the top of the workspace (`.mcp.json`,
   `.claude/`, `.agents/`, `.codex/`, `.opencode/`, Lamp's `.lamp/`) or
   `opencode.json`, judged where the path lands, so a link to one counts.
   Only `.lamp-renders`, the agent's scratch folder, is free. The boundary:
   it does not follow links out of a guarded folder. Making one takes a
   command, which is never allowed by rule (a test holds that), and a writer
   able to make one could write the file itself; two review rounds that
   chased links were answered so, and the chasing taken out (Fable).
4. **What the Terminal runs is Lamp's.** Its launch script, Claude settings
   and recap are written to Lamp's own folder (`Terminal Launches`, by a
   digest of the workspace's path), no longer the workspace's
   `.lamp/terminal/`, and those left there are removed: Lamp ran a file an
   agent could have written. The capture files stay; they are data Lamp
   reads.
5. **The Terminal keeps reading the writing's settings, and is checked
   before it opens** (owner's choice: "I don't really want to degrade user
   experience"). In order: Lamp writes its own provider files again, whole
   and confined to the workspace (a folder on the way that is a link, or a
   file that isn't one, stops the launch, as any failure does); then, writing
   nothing more (its skills were brought up to date as the writing's pane
   opened), looks at everything under what any
   provider reads (`.mcp.json`, `.claude/`, `.codex/`, `.opencode/`,
   `.agents/`, `opencode.json`, `opencode.jsonc`, matched in any case) and
   counts every entry it can't vouch for. Vouched for: its own files as it
   writes them, its skills as it installs them (a built-in equal to the
   bundle's, a custom one as plain as Lamp writes one), and in
   `.claude/settings.local.json` the settings Claude writes there itself
   but for an allow rule or extra folder, which the person keeps by
   approving it, all saved since the last answer shown together as a
   confirmation ("Keep the permissions saved for Claude?"); a rule that
   only restricts passes, and one in place when the Terminal last opened
   and gone since, from either of Claude's project settings files, is asked
   about, since it can widen an approved grant. Everything else counts, a setting no one has seen yet included;
   a link is counted and never followed, and every file is opened through
   the walk, folder by folder, following no link. Each counted entry is shown, a
   small file whole, and fingerprinted by its bytes; the answer holds for
   exactly those, and the check runs again after it, so anything changed
   while the question was up is asked afresh. Claude's own "don't ask
   again" rules, output style and the rest are untouched. None of the
   owner's 14 writings raises anything once its skills are current.

   A first version listed the settings known to run something; Codex found
   one missed in each round (a key, an OpenCode folder, a YAML form) and an
   answer held to the warning's words rather than the bytes. Fable's
   allow-list replaced it.

   The Terminal doesn't open while a chat in the writing is busy, and the
   check is the last thing before it does: from the end of the check to the
   hand-over of its command nothing waits, and a turn begun meanwhile, from
   any pane or the phone (counted per writing), means checking again.

   A hold on the writing's chats until the CLI had read its settings was
   built and taken out: five review rounds found a fault in it each time
   (it expired during a slow scan, was released by capture data an agent
   could write, by time before a slow CLI had started, and closed an
   OpenCode Terminal set up the person's own way that never reported in).
   No provider gives a proof it has read its settings that an agent can't
   write and every setup sends, and a guard that can close the owner's
   working Terminal is worse than the second or two it covered (Fable).

   Rules were at first vouched for by when they appeared, as those present
   when the last Claude Terminal session ended. Five review rounds broke
   that guess five ways (a restart after exit, an exit with no status, a
   closed pane, a chat beside the Terminal), each time letting an agent's
   rule pass as Claude's; who wrote a rule can't be told from when. Fable:
   ask the person instead, once per rule.

Reviewed by Codex until a round found no P1: fourteen rounds, the later
ones each in a narrower corner of the check (a file or folder swapped for a
link between a look and its use, a file deleted between two reads), each
answered by opening through the walk rather than by path.

## What follows

- The check does not follow what an approved entry points at: an approved
  hook that runs `./x.sh` does not bind `x.sh`. Nor does it cover a change
  made from the hand-over until the CLI has read its settings, or for as long
  as it runs: Claude Code reloads its settings then, so a rule a chat's agent
  writes beside an open Claude Terminal applies there at once. Holding every
  chat while a Claude Terminal is open would close that, at the cost of not
  chatting meanwhile; left open, for the owner.

- A Claude writing chat no longer shows the workspace's skills in its own
  list; it reads them through `read_skill`.
- A `lamp` server in the person's own Claude settings would sit beside
  Lamp's; Claude Code documents no order between them. None on this Mac.
- Codex's agent can still write the workspace's hidden files (its sandbox
  allows the workspace); after this, only the Terminal and OpenCode read them.

## Open

- **OpenCode** reads `opencode.json` from the workspace, and documents its
  shell as running with the person's full authority; no documented way to
  have it ignore a project's configuration was found.
- Whether `agy acp` reads a workspace's `.agents/` at a prompt. Tried on
  1.5.14 with no model call: a server planted in `.agents/mcp_config.json`
  did not start on `initialize` and `session/new`.

## Rejected

- The Terminal reading none of the writing's settings, as the chats now
  don't: the writing's skills would show as `/lamp:…` from a plugin, an
  output style and remembered folders would not persist, a `CLAUDE.md` above
  the writing would stop loading, and Claude's "don't ask again" answers
  could be kept only by watching the file they are saved to (Fable). The
  owner chose the check instead.

- `--strict-mcp-config` alone: the workspace's hooks remain, and the person's
  own servers go.
- `--bare`: it drops hooks given by `--settings` and the subscription login.
- `disableAllHooks`: it ends Lamp's own permission hook.
- `--setting-sources user,local`: the local file is the one an agent writes.
- Lamp matching saved rules against requests itself: it would be a second
  copy of Claude Code's matcher.
- OpenCode's undocumented `OPENCODE_DISABLE_PROJECT_CONFIG`.
