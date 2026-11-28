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
  Deleted when nothing waits, or the turn ends, unless another turn of the
  phone's in the same chat still waits under the same name; a delivered alert can't be
  recalled, and the phone removes it when it next sees the chat.
- **On the Mac,** a turn started there whose pane isn't watched as the wait
  begins posts a notification under the same setting, in the chat's place, so
  the end's notice replaces it; taken back once it is answered. Never for a
  phone's turn.

The phone's contract: tell it from an end by the record name; never count it
as hearing the turn; hide it while the chat is on screen and connected; a tap
opens the chat; no Allow or Deny on the alert. The phone takes a delivered
alert away only once it finds the record gone (asked of CloudKit when the
Mac says nothing waits, and when Lamp comes to the front), so **the Mac's
delete is part of the contract**: never a record left for a wait that ended.
A delete that fails (offline, signed out) or is cut short by a quit is kept
on a list across launches and tried again, in batches, with every push and
as remote chats start; one already gone counts as done. A wait is put on that list before
it is saved, so one saved just before a crash is deleted on the next launch;
the retries leave alone a wait still lasting in this launch, so an older
delete can't take a new record of the same name. Each wait's `turnID` is
fresh, which the phone also uses to clear an answered wait's alert behind a
later one.

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
- A wait's notice is named by its provider too, so answering one provider's
  wait can't take another's notice away.
- **Left, an edge case:** a click opens the writing's chat on the provider
  the pane has chosen; a wait from a provider moved away from while its turn
  ran shows its card only once the pane is moved back to it. Raised by Codex
  as a P2; rare, and choosing for the person on a click would change the
  writing's provider.
- **Left, an edge case:** the list of deletes to retry isn't kept per iCloud
  account; one left pending when the Mac changes account is tried in the new
  account, found gone there, and dropped, leaving the record in the old one
  until its daily sweep. Raised by Codex as a P3.
- A wait in a chat its pane keeps drawn behind the Terminal is told as
  unwatched: the card can't be seen there.
- A click on a wait's notice shows that writing's chat, where the card is,
  though its pane was on Terminal, in that pane alone, until the person picks
  a mode; asked of a pane the click is opening, it is kept until that pane
  appears. Switching the Chat or Terminal setting was built first and taken
  out: it is one for every writing, so a click hid a Terminal being watched
  in another window (Codex, P2).
- Taking a wait's notice back removes one not yet shown too.
- **Left, an edge case:** the host tells a wait from the chat's list of
  requests waiting, which the card's own answer shortens a moment before the
  run's next list arrives; a second request asked just as the first is
  answered can make that list go empty and fill again, and the phone be told
  twice for what was one wait. Raised by Codex as a P3.
- **Left, an edge case:** with one writing open in several windows, a click
  shows the assistant in each that has it closed, not only the window
  brought forward. Raised by Codex as a P3.
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
