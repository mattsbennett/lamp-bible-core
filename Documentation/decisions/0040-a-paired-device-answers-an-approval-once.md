# 0040. A paired device answers an approval once

Status: Proposed, 2026-11-27. Core's half is built (`LampAgentRemoteApproval`,
`LampAgentRemoteApprovalAnswer`, the `approvals` event and `answer-approval`,
held by `LampAgentRemoteApprovalTests` and the `approvalAnswer` and
`chatPlan` tables in `Verification/AgentRemote.lean`); the Mac host and the
iOS card are to come. Planned by Fable; the owner asked for it ("we need to
do codex approvals for phone too") and decided on 2026-11-26 that the phone
answers once only.

## Context

A writing chat's turn can stop to ask the person: a command Codex wants to
run outside its sandbox (0028), one Antigravity wants to run (0039), a tool
call Claude asks about. Lamp's card for it is drawn only in a Mac pane
showing that chat. A turn started from the phone, in a writing with no pane
open on the Mac, had no card anywhere: the phone showed "Waiting for your
answer on the Mac" until the request was declined, 580 seconds on.

## Decision

**A paired device following the chat may answer Allow Once or Deny, never a
remembered rule; the first answer anywhere, on the Mac or a device, is the
one taken.**

- **What travels.** `LampAgentRemoteApproval`: id, provider, kind (`command`
  or `tool`), title, the command whole, its folder, the agent's reason (shown
  as the agent's), Lamp's note, and `canAllow`. The host sends what the turn
  waits on in the snapshot and as an `approvals` event carrying the whole
  list, as a fragment carries the whole reply; a turn's start and end clear
  it, so none outlives its turn. An older device ignores the event and keeps
  the "on the Mac" step; a host older than this sends no approvals, and a
  device offers no answer where none came.
- **What an answer names.** `answer-approval` carries the request's id, the
  turn it was shown in (the question it answers, worked out the same way on
  both sides), and a digest of every field drawn, with the chat and turn
  (`LampAgentRemoteApproval.digest`). Codex numbers its requests afresh each
  turn (`codex-0`, `codex-1`, …), so an id alone could name another command
  in the next turn. The host recomputes the digest from the request as it
  waits, so a request changed, answered, timed out or ended is
  `approval-gone`; an answer taken is acknowledged with `approval-answered`,
  without which a phone could not tell its Allow landing from the Mac's
  answer arriving first.
- **What a device may allow.** Only what it can show whole: a command within
  8,000 characters with nothing that doesn't draw (a control character but a
  line break or tab, a bidirectional override, a zero-width character, a
  line separator, a private-use character, or anything Unicode lets be drawn
  as nothing: Codex's review found a combining grapheme joiner passing a
  check by category). The host sets `canAllow` itself;
  anything else, and every non-command tool call (Claude's file edits are
  excerpted even on the Mac, its other tools are raw JSON), is Deny-only on a
  device and answered on the Mac. Allow on a Deny-only request is refused as
  `not-allowed`, as is any decision but `allow-once` and `deny`.
- **What a device is sent is bounded**: the first 16 requests, every other
  field cut at 2,000 characters and a longer command at 8,000, which makes
  it Deny-only. Cut in the chat's state, so the host judges an answer
  against the same copy the device was sent; unbounded, a long request could
  push a frame past what a connection seals, and it would be dropped
  unsent.

## What follows

- A phone-started turn with no pane open can be answered only while the
  phone has the chat open: there is no push for a waiting request yet. One
  would need a new CloudKit record, never carrying the command, and an older
  phone would read a waiting turn's push as an ended one.
- Claude's requests and answers pass through files in the user's temporary
  folder, which any command its agent was allowed could write. A device's
  answer does not widen that; it deserves its own look.

## Rejected

- **Always Allow from a device:** a rule kept for every later run, given
  from a screen that may not show the whole command (owner's decision).
- **An answer by id alone:** the same id names a different command in the
  next Codex turn.
- **Only the device that started the turn may answer:** the useful case is a
  turn started on the Mac and answered away from it; any paired device the
  host lets act may already stop the turn.
