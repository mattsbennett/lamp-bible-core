# 0044. A command allowed for the chat is remembered by Lamp, by its bytes

Status: Accepted, 2026-11-27. Built (`lamp-bible-macos`:
`AgentChatCommandGrant`, `AgentChatCommandGrants`,
`AgentToolApprovalRequest.chatGrant`, the runners' `isAllowedForChat`, held by
`AgentChatCommandGrantTests` and `AgentChatCommandGrantRunnerTests`). The owner
asked for it on 2026-11-26 ("Allow for this chat": the exact command and
folder, until the chat ends, after Allow Once had shipped); planned by Fable
(`../AgentHoldsAndApprovalsPlan.md`).

## Context

A Codex writing chat rendering with Blender asks to leave its sandbox for
every render, and an Antigravity chat asks for every command; the card asks
each time. 0028 and 0039 answer only Allow once and Deny, never the
providers' own remembered approvals, which write rules into the person's
settings for every session on the Mac. Claude's Always Allow (0038) is a rule
of Claude Code's own syntax, kept by Lamp.

## Decision

The Mac's card offers **Allow for This Chat** on a Codex or Antigravity
command that names the folder it runs in. It allows the command once, as
Allow does, and Lamp remembers it for the chat: the same command, byte for
byte as the provider sent it (Codex's shell wrapper included), in the same
folder, is answered Allow once without a card for the rest of the chat,
whoever started the turn, the phone included.

- **Bytes, not a rule.** Two spellings Swift's `==` takes for one, a
  precomposed accent and a combining one, are two; a trailing space,
  another folder, a trailing slash, another shell wrapper or another provider
  all ask. Nothing about it is a pattern, so it is not the second copy of
  Claude Code's matcher 0038 rejected.
- **Not for Claude.** A `Bash(…)` rule can't bind a folder, and matching the
  hook's input here would be that second matcher. Claude keeps Always Allow.
- **The chat ends** at a new conversation (New Chat, or one arriving from
  another Mac), and at a quit: grants are held in memory by provider,
  workspace and conversation, and written nowhere. Stop, a turn's end or a
  closed pane don't end it. They can be seen and removed from the chat's
  header.
- **Answered as the card would be:** through the run's own writer, judged as
  it is written, so a Stop pressed meanwhile still declines; and the network
  decline (0028) comes before any grant is looked at. Remembered only once the
  answer went as given, so one pressed as Stop refused it remembers nothing.
  Codex's first review found the grant kept late (after a poll, so an
  immediate repeat was asked again) and blind to `additionalPermissions`.
- **Only a request to leave the sandbox and nothing more.** A Codex request
  naming further permissions (`additionalPermissions`) could ask for more
  next time under the same command, so it is asked about each time; and a
  grant holds only in the environment Codex named (`environmentId`). The card
  shows the command exactly as remembered where that isn't what it shows
  above (Codex's shell wrapper).
- **Kept as the answer is written,** before the bytes go, so a provider asking
  again the moment it reads it finds it, and taken back if the write fails;
  and looked at again as an unasked answer is written, so a grant removed
  meanwhile puts the request on the card. The list shows each command and
  folder whole.
- A conversation saved before conversations had ids is given one for its
  grants alone, in memory, a new chat another.
- The answer sent is the provider's once-only one: Codex's `accept`,
  Antigravity's `allow_once`, never a session, rule or `allow_always` answer.
- **The phone** still answers once only (0040): a device can't remember a
  command, though a turn it starts is answered by what the Mac remembered.

## What follows

- For Codex the command runs outside the sandbox, while the sandboxed agent
  can rewrite the files it runs: `python3 make.py` allowed for the chat is any
  code at all for the rest of it. The card says so ("Lamp doesn't check what
  the command's files hold by then"); this record owns it.
- A grant is the chat's on this Mac only; another Mac continuing the chat
  asks again.

## Rejected

- **Codex's session acceptance:** the recorded request doesn't offer it, and a
  Lamp turn is one process, so it wouldn't outlast the turn.
- **Antigravity's `allow_always`:** it saves a rule in the person's settings
  (0039).
- **Matching the command shown** (Codex's command without its wrapper): what
  is remembered is what ran.
