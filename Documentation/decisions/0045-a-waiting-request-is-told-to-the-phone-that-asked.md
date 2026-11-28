# 0045. A waiting request is told to the phone that asked, without the command

Status: Accepted, 2026-11-27, on the Mac (`lamp-bible-macos`:
`AgentTurnPush.Waiting`, `tellWaiting`, `clearWaiting`, the host's
`tellsWaits`, the chat model's `noticeWait`, held by
`AgentTurnNotificationsTests`); the phone's half, hiding and opening it, is
the iOS session's. Planned by Fable (`../AgentHoldsAndApprovalsPlan.md`).

## Context

Since 0040 a paired phone can answer what a turn waits on, but only while the
chat is open on it: a phone left in a pocket after asking for a render never
hears that Codex is waiting to run Blender, and the request times out. The
phone already hears a turn's end through a record in the person's iCloud
database that it subscribes to (`AgentTurnEnded`, production schema deployed
by the iOS session).

## Decision

When a turn a phone asked for begins to wait on the person, the Mac writes a
record for that phone, once per wait, and takes it away once nothing waits.

- **The same record type and fields as a turn's end,** so no schema changes
  and a shipped phone alerts: type `AgentTurnEnded`, named
  `wait.<deviceID>.<chatID>`, which is how the phone tells it from an end
  (`turn.…`). `turnID` is the wait's own fresh id, never the turn's, so a phone
  that matches it against an end it heard doesn't take one for the other.
  `outcome` is `waiting`, `endedAt` when it began to wait (which the daily
  sweep reads), `subtitle` empty, `summary` and `body` both
  "<Provider> is waiting for your answer."
- **Who waits, never on what:** the command, its folder and the agent's reason
  are left out, since an alert can show on a locked phone. The phone shows
  them on the card once the chat is open.
- **Only the phone that asked,** for a turn it started; any waiting request,
  Deny-only included. Saved only if that wait, and not a later one, still
  lasts, and the device may still be told, when its turn comes in the line
  every push is written in.
  Deleted when nothing waits, or the turn ends; a delivered alert can't be
  recalled, and the phone removes it when it next sees the chat.
- **On the Mac,** a turn started there whose pane isn't watched as the wait
  begins posts a notification under the same setting, in the chat's place, so
  the end's notice replaces it; taken back once it is answered. Never for a
  phone's turn.

The phone's contract: tell it from an end by the record name; never count it
as hearing the turn; hide it while the chat is on screen and connected; a tap
opens the chat; no Allow or Deny on the alert.

## What follows

- A turn started on the Mac and walked away from tells no phone; a phone that
  had the chat open while it ran is the next step, left out of the first cut.
- Not proved off a device: a CloudKit alert on a locked phone is tried by
  hand, and a shipped phone's reading of the record is from its code.
- **On phones shipped before this** (checked by the iOS session against
  `aa4ac5f`): a tap on a wait whose push CloudKit sent without its fields
  opens the app but not the chat, since that phone reads only `turn.` names;
  and a wait shown with the app in front is noted as heard, which can let a
  late end push for an earlier turn show twice. Both are gone in the phone's
  next build; neither shows the wrong chat or hides an end.
- **Every device on the iCloud account,** not only the phone named, can be
  handed the alert, as with a turn's end: a subscription's predicate chooses
  records, not devices. What it shows is the chat's title and the
  provider's name.
- **Left, an edge case:** a click on a wait's notice shows the writing's
  assistant in whichever mode it was left in; left in Terminal mode, the
  person switches to Chat to see the card. Raised by Codex as a P3.
- On the Mac, a wait's notice has a name of its own, so taking it back leaves
  an end's notice alone; and a click on either shows the writing's
  assistant, in a window already open too.

## Rejected

- **A new record type:** the container's owner would create it in
  Development, index `deviceID` and deploy it to Production, which can't be
  undone; every save would fail until then, and each phone would need a second
  subscription and a new build.
- **The command in the alert:** a lock screen is not where a command to run
  outside a sandbox is shown.
