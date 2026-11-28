# 0042. A writing's chats wait while a Claude Terminal runs in it

Status: Accepted, 2026-11-27. Built (`lamp-bible-macos`: `AgentTerminalHolds`,
`AgentTerminalHoldsTests`; core: `LampAgentRemoteFailure.terminalOpen`,
`LampAgentRemoteTurnAdmission`, the `turnAdmission` table in
`Verification/AgentRemote.lean`). The owner chose it ("hold and provide an end
terminal session control"); planned by Fable (`../AgentHoldsAndApprovalsPlan.md`).

## Context

0038 checks a writing's settings before its Terminal opens, and left one gap
open for the owner: Claude Code reloads its settings while it runs, so a rule a
chat's agent writes into the writing's `.claude/settings.local.json` applies in
an open Claude Terminal at once, past the check.

The Terminal and the chat can't be on screen together, but switching the pane
to Chat only hides the Terminal: its CLI keeps running, since taking the view
down would kill it. The Terminal resumes the chat's own conversation and its
turns are captured into it, so ending the Terminal loses nothing.

## Decision

While a Claude Terminal's process runs in a writing, no chat in that writing
starts a turn: no pane on the Mac, and no paired device.

- **Held from the hand-over.** The hold is made in the launch on the line that
  hands the Terminal its command, after the last busy check with nothing
  awaited between, before the process exists.
- **Let go only when the process Lamp started is gone:** by its exit, which
  the Terminal's watch reports even once its view is taken down, or found gone
  when asked (the kernel's record of the pid, by its start time, so a reused
  pid doesn't hold; a lookup that fails is never taken for an exit, the
  process held while it can still be signalled). Never by time, by the capture files (an agent could write
  them), by the pane being hidden or by the mode. One that never started is
  dropped when its view goes, a newer launch replaces it, or it is ended.
- **Claude's only.** Codex and OpenCode read their settings as they start, so
  the check covers them; their Terminals hold nothing until one is shown to
  reload while running. A Claude Terminal holds every provider's chats in the
  writing.
- **Gates:** where a pane sends, before its turn is counted; the queue's
  drain, so a held message is not tried again in a loop; the host, before any
  workspace write and again just before the send; and the chat model's send,
  the last line for every caller.
- **On the Mac,** over the composer of every chat on the writing: "Claude is
  running in this writing's Terminal. Chats here wait until that session
  ends.", with End Terminal Session and Show Terminal. Typing goes on; Send
  doesn't. Ending asks the Claude Terminal's process to stop (another
  provider's Terminal in the writing is left) and kills it if it is still the
  same process three seconds on; its exit collects its last turns as any exit
  does, and a shell that ignored the request isn't given Claude's command.
  An exit End caused is never taken for a resume that failed, which would
  start the Terminal again in its place. **Ending sends nothing:** the Terminal's last turns come into the chat
  first, for the person to read before their message goes on top, and a
  queued message goes with their next Send: every chat's waiting messages in
  the writing are held from the hand-over, a chat not yet loaded as it loads.
- **To a device,** a turn on a held writing (`send`, `start-chat`) is answered
  `failed`, code `terminal-open`, with the request and chat ids, before the
  turn is taken, and always with the words "Claude is open in this writing's
  Terminal on your Mac. End that session there, then send again." No
  `turn-started` follows, the words weren't sent, and it may be asked again
  at any time; no event says the session ended. A phone that doesn't know the
  code shows the words. The phone gets no control to end the session.
- **The order a device is told,** `LampAgentRemoteTurnAdmission`: AI features
  off, then an open Terminal, then a reply already arriving. Lean's
  `admitTurn` holds it (`aLiveTerminalAdmitsNoTurn`,
  `terminalOpenIsSaidBeforeBusy`) and its table is asked of the Swift.

## What follows

- The boundary is the process Lamp started. A shell profile that hands the
  session to tmux, or a Claude started by hand in another terminal in the
  writing's folder, is not seen.
- A Claude Terminal left running in a writing that isn't on screen holds that
  writing's chats, from the phone too, until it is ended on the Mac.
- A hold for the person's word outlasts a quit: kept in this Mac's
  preferences by provider and writing, not in the queue file every Mac
  syncs, and let go only by their Send; for a chat not loaded, kept the
  moment the Terminal begins, where it has messages waiting on disk. Codex raised its loss at a quit six
  rounds running; it was first left as an edge case, then closed.
- The converse is unchanged: the Terminal doesn't open while a chat in the
  writing is busy (0038), so a hold can't begin under a turn being prepared.

## Rejected

- **A hold until the CLI has read its settings** (0038's first version): it
  needed a sign no provider gives, and five review rounds found it released
  early or closed a working Terminal.
- **Holding only while the Terminal is on screen:** a hidden Terminal runs
  and reloads its settings all the same.
- **End sending the waiting message:** it would go before the person had seen
  what the Terminal did last.
