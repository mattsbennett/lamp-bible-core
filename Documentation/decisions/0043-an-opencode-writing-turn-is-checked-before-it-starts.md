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
  the writing when it began, and the chat model's send, the last line for
  every caller, runs an OpenCode writing turn only if one was noted with no
  turn begun since, from any pane, the phone or a Terminal; once only.
  Between the check and the send nothing is awaited.
- **Run alone.** Since OpenCode rereads its settings at each request, a check
  binds only if nothing else writes while it runs: an OpenCode writing turn
  isn't checked, nor started, while any chat runs in the writing (OpenCode's
  own from another pane included) or any provider's Terminal is open in it, and while it runs no
  other chat there starts (the Terminal already doesn't, 0038). A message
  queued behind that waits for the person's word.
- **Answers are kept per scope.** Each check lets go of the answers for what
  it looked at and found gone, and only those: OpenCode's leaves Claude's
  settings alone, the Terminal's leaves the folders above the writing alone.
- A link standing in for `.claude` or `.agents` is shown, since OpenCode
  would find skills through it.
- Only what OpenCode reads is walked, so a large folder of Claude's neither
  shows nor spends the scan's limit. A file above the writing is opened
  following no link and without blocking.
- **On a paired device,** a turn that needs an answer is refused as
  `needs-setup` with words ("…Look at them by sending from the writing on
  your Mac."): the answer is given on the Mac.
- Anything the scan couldn't look at stops the turn, as for the Terminal.

## What follows

- What is left writing while a turn runs is OpenCode's own agent, whose own
  settings it can change anyway, and sync bringing a change from another
  Mac; the next OpenCode turn checks again.
- **Approved only as shown.** A file the sheet could show only by its size
  (too long to show whole, or not text), in the writing or above it, stops
  the turn rather than being approved unseen. Codex found this class three
  times (a link, a file above, a file in the writing); it is closed here at
  the root, for everything OpenCode reads.
- **A link stops the turn** rather than being put to the person: it is
  fingerprinted by where it points, what it leads to can change unasked, and
  OpenCode rereads it at every request. Codex raised it as a P1 twice; the
  first time it was answered as 0038's boundary, the second it was closed.
- The boundary 0038 drew for the Terminal still holds for a setting naming a
  plugin folder or a file elsewhere: it is shown as that setting, and
  approving it approves what it names, which can change afterwards unasked.
- **Left, an edge case:** the folders above the writing are shared by every
  writing in the library, and the check binds only this writing's turns; an
  agent in another writing could change them after the check. No agent may
  write there unasked (Codex's sandbox is its own writing, Claude and
  Antigravity ask for anything outside it), so it takes the person allowing
  such an edit. Raised by Codex as a P2 and left so.
- Above the writing, the walk starts from where OpenCode runs, links
  resolved, and a file there that can't be shown whole (too long, or not
  text) stops the turn rather than be approved by its size.
- A message the check holds waits on the chat, not in a pane's field; Don't
  Send takes it off the chat and puts it back in the field, after whatever is
  being written there; Send Anyway sends that message, wherever it waits.
- Only OpenCode's own file is written before the check, so another
  provider's Lamp can't write doesn't stop an OpenCode turn.
- OpenCode's own agent may write its settings; this guards against the other
  providers' agents and Lamp's sync, not against OpenCode.
- Above the library is the person's own, and isn't looked at.
- Reader chats aren't checked: each has a workspace of its own, with no other
  provider's agent in it.

## Rejected

- `OPENCODE_DISABLE_PROJECT_CONFIG` and the V1 environment variables: not
  documented for the OpenCode installed.
- Running OpenCode from a folder of Lamp's: the session would no longer be
  the writing's, and relative paths would land elsewhere.
- **Left, an edge case:** with one writing open in two panes, each holding an
  OpenCode message for Send Anyway, confirming one approves the shared
  settings, and the other may be sent when the queue next moves while its
  sheet is still up. Rare, and what goes is a message the person wrote to be
  sent, on settings they had just approved. Raised by Codex as a P2.
- Letting other chats run beside an OpenCode turn, which the first version
  did, reasoning that the writers it would stop were ones the person starts:
  Codex's first round showed the check then binds nothing, since OpenCode
  rereads its settings at each request. Fable had planned the hold.
