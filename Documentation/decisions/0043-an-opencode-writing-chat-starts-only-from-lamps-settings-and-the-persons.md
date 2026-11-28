# 0043. An OpenCode writing chat starts only from Lamp's settings and the person's

Status: Accepted, 2026-11-27. Built (`lamp-bible-macos`:
`WritingChatTurns.checkOpenCode`, `KeptAgentChats.takeOpenCodeCheck`,
`AgentTerminalLaunchCheck.openCodeScope`, `openCodeReads` and
`openCodeAncestorFindings`, held by `OpenCodeWritingCheckTests`). Closes
0038's open item on OpenCode; planned by Fable
(`../AgentHoldsAndApprovalsPlan.md`), whose first plan, an approval sheet,
was wrong (below).

## Context

0038 left OpenCode's writing chats reading the workspace's `opencode.json`,
which another provider's agent in the same writing can write: a server, a
plugin or a shell setting put there runs with OpenCode's authority.

What OpenCode 2.0.32 does, tried 2026-11-27 with no model call (a server
planted in a scratch folder, read back through `opencode api GET /api/config`
and `/api/mcp`):

- It reads `opencode.json`, `opencode.jsonc` and `.opencode/` in the folder it
  runs in **and in every folder above it**, and finds skills in
  `.claude/skills` and `.agents/skills` there too.
- It reads them **again at every request**: a server added while the server
  process ran was listed at the next request.
- Its V2 documentation names no `OPENCODE_CONFIG`, `OPENCODE_CONFIG_CONTENT`
  or `OPENCODE_CONFIG_DIR` (only V1's does), `opencode run` has no `--dir`,
  and V2's one background server per account owns configuration, so an
  environment variable on a `run` client need not reach it. No documented
  way to have it leave a project's configuration alone was found.

## Decision

0038's rule, reached by refusal since OpenCode has no flag for it: before
every OpenCode writing turn, from a pane or a paired device, Lamp writes its
own `opencode.json` again whole, then looks at everything else OpenCode would
read in the writing and in the three Lamp-owned folders above it
(`<library>/AgentWorkspaces/Writing`, `AgentWorkspaces`, the library),
walked from the writing as it resolves up to the library as it resolves, so
a linked parent can't shorten or lead the walk elsewhere; a writing that
resolves outside the library stops the turn. If
anything is there that Lamp can't vouch for, the turn doesn't start, and
nothing is asked and no answer kept:

> OpenCode wasn't started: this writing holds settings for OpenCode that Lamp
> didn't put there (…up to five paths, and N more). OpenCode chats start from
> Lamp's settings and your own in ~/.config/opencode. Remove these from the
> writing's folder, or use the Terminal, which asks about them.

with Show in Finder beside it on the Mac, selecting them; where some are
above the writing, the Terminal, which looks only in the writing, isn't
offered, and the words say those are in Lamp's library folder. A paired
device is told the same words under a code of its own,
`writing-settings` (`LampAgentRemoteFailure.writingSettings`), so a phone
that doesn't know it shows them; `needs-setup` would show the phone's own
words for setting OpenCode up. For the same reason a Terminal open in the
writing is told as `terminal-open`, and another chat answering as `busy`. What passes names no program an agent can write:
Lamp's own `opencode.json`, byte-equal; a built-in skill, by its tree's
digest against the bundle, with no link or hidden entry; a custom skill as
plain as Lamp writes one (`SKILL.md` alone, prose). A `.claude` folder above
the writing counts only for a `skills` folder in it.

- **Bound to the turn.** A clear check is noted against the turns begun on
  the writing when it began, and the chat model's send, the last line for
  every caller, runs an OpenCode writing turn only if one was noted with no
  turn begun since, once only; between the check and the send nothing is
  awaited.
- **Run alone.** Since OpenCode rereads its settings at each request, a check
  binds only if nothing else writes while it runs: an OpenCode writing turn
  isn't checked, nor started, while any chat runs in the writing (OpenCode's
  own from another pane included) or any provider's Terminal is open in it,
  and while it runs no other chat there starts.
- A refused message waits on the chat, held, with Send Them, rather than in a
  pane's field that may have gone; refused by the send itself (a check gone
  stale) too. No turn's end lets that hold go, nor a quit (0042): only the
  person's Send. A writing reached through a link out of the library is
  written nothing, its message left in the field.
- Nothing is written into a writing that resolves outside the library: that
  is looked at first, since a linked parent would lead the write elsewhere.
  The boundary: a writing's workspace is prepared for every turn, by any
  provider, before this check, as it always has been, through the library's
  own folders; no agent may relink those unasked, being outside every
  writing. Codex raised preparation through a relinked parent as a P1 against
  this check; it is not this check's, and was not changed here.
  A write of Lamp's file that fails is told to a phone as
  `writing-settings` too, its words naming the writing on the Mac.
- Only OpenCode's own file is written before the check, so another
  provider's file Lamp can't write doesn't stop an OpenCode turn.

## What follows

- OpenCode can't be customised per writing for chats. The Terminal, which
  asks about such settings, keeps its sheet and its boundary (0038): approving
  a setting there approves what it names, which can change afterwards.
- `AGENTS.md` and skills are prose an agent can write, as the draft is.
- What is left writing while a turn runs is OpenCode's own agent, whose own
  settings it can change anyway, and sync bringing a change from another
  Mac; the next OpenCode turn checks again.
- **Left, an edge case:** the folders above the writing are shared by every
  writing in the library, and the check binds only this writing's turns; an
  agent in another writing could change them after the check. No agent may
  write there unasked (Codex's sandbox is its own writing; Claude and
  Antigravity ask for anything outside it). Raised by Codex as a P2.
- **Left, an edge case:** a first message refused before the chat has a
  conversation waits with none, and if another Mac's conversation for the
  writing syncs in before Send Them, it goes into that one. Rare, and it is
  the person's message in the same writing's chat. Raised by Codex as a P2.
- Reader chats aren't checked: each has a workspace of its own.
- Still to try by hand: a real OpenCode turn and a Terminal session in a
  scratch writing leave nothing the next check refuses.

## Rejected

- **An approval sheet, as the Terminal has** (Fable's first plan; built and
  taken out). An approval held per writing by a setting's bytes binds the
  setting, not what it names, while OpenCode rereads it at every request.
  Codex found the same hole four rounds running: an approved link, whose
  target could change (round 2); a file above the writing, and then one in
  it, approved by its size unseen (rounds 3 and 4); and an approved
  `opencode.jsonc` whose plugin names code elsewhere (round 5, and round 1,
  when it was answered as 0038's boundary). Each was patched; the class
  stayed open. A chat turn can also start from the phone or the queue with
  nobody at the Mac, which is not the Terminal's situation.
- **Parsing OpenCode's settings for the paths they name:** a second reading of
  a schema OpenCode has already changed once (V2's `agents`), which 0038
  rejected for Claude's.
- `OPENCODE_DISABLE_PROJECT_CONFIG` and the V1 environment variables: not
  documented for the OpenCode installed.
- Running OpenCode from a folder of Lamp's: the session would no longer be
  the writing's, and relative paths would land elsewhere.
- Letting other chats run beside an OpenCode turn, which the first version
  did: Codex's first round showed a check then binds nothing.
