# 0043. An OpenCode writing turn is checked before it starts, as the Terminal is

Status: Accepted, 2026-11-27. Built (`lamp-bible-macos`:
`WritingChatTurns.checkOpenCode`, `KeptAgentChats.takeOpenCodeCheck`,
`AgentTerminalLaunchCheck.openCodeReads` and `openCodeAncestorFindings`,
held by `OpenCodeWritingCheckTests`). Closes 0038's open item on OpenCode;
planned by Fable (`../AgentHoldsAndApprovalsPlan.md`).

## Context

0038 left OpenCode's writing chats reading the workspace's `opencode.json`,
which another provider's agent in the same writing can write: a server, a
plugin or a shell setting put there runs with OpenCode's authority.

What OpenCode 2.0.32 does, tried 2026-11-27 with no model call (a server
planted in a scratch folder, read back through `opencode api GET /api/config`
and `/api/mcp`):

- It reads `opencode.json`, `opencode.jsonc` and `.opencode/` in the folder it
  runs in **and in every folder above it**.
- It reads them **again at every request**: a server added to the file while
  the server process ran was listed at the next request, and a `.opencode/`
  made then too. There is no settling once at start for a check to bind.
- Its V2 documentation names no `OPENCODE_CONFIG`, `OPENCODE_CONFIG_CONTENT`
  or `OPENCODE_CONFIG_DIR` (only V1's does), `opencode run` has no `--dir`,
  and V2 runs one background server per account that owns configuration, so
  an environment variable on a `run` client need not reach it. No documented
  way to have it leave a project's configuration alone was found. Running
  from another folder would break the session the Terminal resumes.

## Decision

Before every OpenCode writing turn, from a pane or a paired device, Lamp does
what it does before a Terminal opens (0038): writes its own provider files
again whole, scans what is there, and puts to the person anything it can't
vouch for, with the same sheet ("Send Anyway", "Don't Send") and the same
answers, held per writing by the bytes' fingerprints. Only what OpenCode
reads is asked about: its own files and the skill folders it reads
(`.claude/skills`, `.agents/skills`); Claude's settings are asked about before
a Claude Terminal opens. The three folders above the workspace that are
Lamp's own (`<library>/AgentWorkspaces/Writing`, `AgentWorkspaces`, the
library) are looked in too; a file there is shown and asked about, and a
folder or link there can't be vouched for and stops the turn.

- **Bound to the turn.** A clear check is noted against the turns begun on
  the writing so far, and the chat model's send, the last line for every
  caller, runs an OpenCode writing turn only if one was noted with no turn
  begun since, from any pane, the phone or a Terminal; once only. Between
  the check and the send nothing is awaited.
- **On a paired device,** a turn that needs an answer is refused as
  `needs-setup` with words ("…Look at them by sending from the writing on
  your Mac."): the answer is given on the Mac.
- Anything the scan couldn't look at stops the turn, as for the Terminal.

## What follows

- What runs while a turn runs isn't bound: OpenCode rereads its settings at
  each request, so a change during the turn applies. No Terminal opens while
  it runs (0038) and the phone starts no turn in the writing then; the
  writers left are OpenCode's own agent, whose own settings it can change
  anyway, another provider's chat started from the Mac in the same writing,
  a Codex or OpenCode Terminal already open in it, and sync. All but sync
  are started by the person on this Mac, and the next OpenCode turn checks
  again.
- OpenCode's own agent may write its settings; this guards against the other
  providers' agents and Lamp's sync, not against OpenCode.
- Above the library is the person's own, and isn't looked at.
- Reader chats aren't checked: each has a workspace of its own, with no other
  provider's agent in it.

## Rejected

- `OPENCODE_DISABLE_PROJECT_CONFIG` and the V1 environment variables: not
  documented for the OpenCode installed.
- Holding every chat while an OpenCode turn runs: OpenCode rereads its
  settings at each request, so it would have to hold for the whole turn, and
  the writers it would stop are ones the person starts on this Mac.
- Running OpenCode from a folder of Lamp's: the session would no longer be
  the writing's, and relative paths would land elsewhere.
