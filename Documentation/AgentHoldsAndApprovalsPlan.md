# Agent holds and approvals plan

Four changes to Lamp's agent chats, asked for by the owner on 2026-11-27,
planned by Fable and checked against the code before each item starts. Records
0042 to 0045. Each item is reviewed by Codex under the change workflow's loop
(`.claude/skills/lamp-change-workflow/SKILL.md`, step 4), and the edge cases
left at its end are written down in its record.

## Order

1. **The Terminal hold (0042).** It closes the gap 0038 left open, it is the
   only item that adds core vocabulary (so the phone can start on it at once),
   and its gate is where item 2 plugs in.
2. **OpenCode's settings (0043).** Same family, same gate. It starts with two
   probes that cost no model call.
3. **Allow for this chat (0044).** Mac only, no protocol change. It widens what
   runs unasked, so it comes after the two that narrow.
4. **The waiting push (0045).** Needs the phone session's half and a real
   phone to prove, so it goes last.

## Facts corrected before starting

- The remote model's boundary prose is "Agent chats on the phone" in
  `Verification/README.md`, not `coverage.json`, whose patterns are the sync
  sources only.
- Codex's recorded escalation offers `accept`, `acceptWithExecpolicyAmendment`
  and `cancel`; no session decision. The binary knows `acceptForSession`, but
  this request doesn't list it.
- Record 0040 still read Proposed with the host and the phone's card to come;
  both are on main. `LampAgentRemoteApproval.swift` cited 0037 for 0040.
- In the writing pane, `activeProvider != nil` is not "the Terminal is live":
  it stays set after the CLI exits, and only `terminalExitCode` changes. The
  process Lamp starts is a login shell that is typed `exec /bin/sh <script>`,
  whose last line `exec`s the CLI, so one pid is the shell and then the CLI.
- OpenCode 2 is not the OpenCode 0038 reasoned about (item 2).

## 1. The Terminal hold (0042)

The hold 0038 took out failed because it tried to learn when the CLI had read
its settings, from timers and capture data an agent could write, and it closed
Terminals. This one uses only what Lamp owns: it started the process, and it
reaps it.

- **A registry**, on the main actor, keyed by the workspace's standardised
  path as every other per-writing count is, one entry per launch:
  `.starting`, then `.running(pid)`.
- **Held from the hand-over:** the entry is made in `launch()` on the line that
  sets `activeProvider`, after the last busy check, with nothing awaited
  between. Registering when the view is made would leave a gap.
- **Released only when the process is gone:** by the coordinator's exit
  source, which outlives a dismantled view; and, when asked, by checking the
  pid is still alive, so a missed event can't strand the hold. Never by time,
  capture data, pane visibility or mode. A launch whose view never mounted is
  ended by its pane going, or by the control.
- **Scope:** a Claude Terminal holds every provider's chats in its writing.
  Codex and OpenCode Terminals hold nothing until one is shown to reload its
  settings while running.
- **Gates:** before `beginTurn` where a pane sends; in the host before any
  workspace write and again just before the send; and at the top of
  `NativeAgentChatModel.send` as the last line. A queued message is held, not
  re-tried in a loop.
- **On the Mac:** a line over the composer in every pane on that writing, with
  Send disabled: "Claude is running in this writing's Terminal. Chats here
  wait until that session ends." Buttons: End Terminal Session, Show Terminal.
  Ending sends nothing: it collects the Terminal's last turns, which the person
  should see before their message goes on top. Ending always clears: it
  terminates, then kills a process still alive, and drops a `.starting` entry.
- **Core and Lean:** `LampAgentRemoteFailure.terminalOpen` ("terminal-open");
  `LampAgentRemoteTurnAdmission.refusal(aiOn:terminalOpen:running:)`, which
  the host calls; Lean `admitTurn` with `aLiveTerminalAdmitsNoTurn` and
  `terminalOpenIsSaidBeforeBusy`; an eight-row conformance table; the README's
  counts.
- **The phone's contract:** the host answers `send` and `start-chat` on a
  writing's chat with `failed`, code `terminal-open`, with the request and
  chat ids, before the turn is taken; no `turn-started` follows; the words
  weren't sent and stay in the composer; it may be retried at any time, and no
  event says the hold ended. The message is always written: "Claude is open in
  this writing's Terminal on your Mac. End that session there, then send
  again." A shipped phone shows the Mac's words for a code it doesn't know.
  The phone gets no control to end the session.

Tests that must bite: held from the hand-over with no pid yet; capture data, a
mode switch, a hidden pane and a closed window don't release it, only exit
does; two Terminals hold until both end; another writing isn't held; a Codex or
OpenCode Terminal holds nothing; a real process killed from outside releases
it; a child that traps TERM holds until it's gone; a turn in hand then a launch
is refused, and a hand-over then Send is refused; a held queued message
attempts no send; a phone turn is refused with the workspace untouched; a hold
begun during a phone turn's preparation still refuses it; End clears a
`.starting` entry.

Doubt: a shell profile that attaches tmux puts Claude in a server Lamp never
sees. The hold covers the process Lamp started, and the record says so.

## 2. OpenCode's settings (0043)

OpenCode 2's documentation names no `OPENCODE_CONFIG`, `OPENCODE_CONFIG_CONTENT`
or `OPENCODE_CONFIG_DIR` (only the V1 pages do); `opencode run` has no `--dir`;
V2 runs one shared background server per account that owns configuration and
tool execution, so an environment variable on a `run` client need not reach
it; project config is searched from the current folder to the root. No
documented way to have a chat ignore the workspace's config exists, and running
from another folder would break the session the Terminal resumes.

- **Two probes first, no model call:** plant a server in a scratch project's
  `opencode.json` and read `opencode mcp list` and `opencode debug config`,
  with the background server already running (does it cache a location's
  config?) and after editing the file (does it reload live?). If it caches,
  the check binds nothing without `--standalone`, gated by version. If it
  reloads live, a running OpenCode turn holds the writing's other chats
  through item 1's registry.
- **Then the Terminal's check before every OpenCode writing turn:** restore
  Lamp's provider files, scan, and stop on anything unapproved, naming it, with
  the same approvals and sheet; a phone turn is refused as `needs-setup` with
  words. Checked again if a turn began meanwhile. `opencode.json(c)` and
  `.opencode` in the folders above the writing inside Lamp's library count too.

Tests that must bite: a planted `opencode.jsonc` or `.opencode/plugin/x.js`
stops the turn and no process starts; an altered `opencode.json` is put back
whole and the turn runs; an approval given for the Terminal passes for the
chat, and one changed byte asks again; a link where the file should be stops
it; other providers' chats aren't scanned; a turn begun between check and
launch means checking again.

Doubt: OpenCode's own agent may write anywhere, so this guards against the
other providers' agents only.

## 3. Allow for this chat (0044)

Exact command and folder, remembered until the chat ends, on the Mac's card
only. For Codex and Antigravity this is different in kind from the matcher
0038 rejected: the request is the command and folder, and byte equality has no
rule syntax to drift from. Claude keeps Always Allow and gets no new button: a
`Bash(...)` rule can't bind the folder, and matching the hook's input
ourselves would be that second matcher.

- **The chat ends** at New Chat (the conversation id changes), a move to
  another provider, or Lamp quitting. Not at Stop, a turn's end, or a closed
  pane. Grants are held in memory by provider, workspace and conversation id,
  never on the model, which goes with its last pane. Nothing is written.
- `AgentToolApprovalRequest.chatGrant`: tool, command as the provider sent it,
  folder; nil where no folder is named, nil for Claude.
- Compared by UTF-8 bytes.
- `.allowForChat` sends `accept` or `allow_once`, never a session or remembered
  decision. The grant is kept only once the answer went as answered.
- A match found before the card would show is answered through the same path,
  so Stop still wins, and shows as a step the phone sees too. The network
  decline comes first.
- Card: a third button and "Runs this exact command in this folder again
  without asking, until you start a new chat. Lamp doesn't check what the
  command's files hold by then." A list with Remove.
- A grant applies to a later turn in the chat whoever starts it.

Tests that must bite: a grant for the raw wrapped command and folder; no match
for a trailing space, another folder, a trailing slash, NFC against NFD, another
shell wrapper, or another provider; the decision is exactly `accept`; with the
fake Codex, a second identical ask shows no card in the same turn and the next,
is declined after Stop, and a grant pressed just before Stop remembers nothing;
ACP chooses `allow_once` with `allow_always` on offer; New Chat forgets, Stop
keeps; another writing and provider still ask; `AgentAllowRules.json` is
untouched; a Claude request offers no grant; `decide` refuses `allow-for-chat`.

Doubt: for Codex the command runs outside the sandbox while the sandboxed agent
can rewrite the files it runs. `python3 make.py` allowed for the chat is any
code at all for the rest of it. The card says so and the record owns it.

## 4. The waiting push (0045)

On the existing `AgentTurnEnded` type with its existing fields only, named
`wait.<deviceID>.<chatID>`: no schema deploy, no new subscription, and shipped
phones alert today. A new type would need the container's owner to create and
deploy it, and every production save would fail until then.

- `turnID` is always present and is the wait's own fresh id, never the turn's,
  so a shipped phone doesn't take it for the turn's end.
- Phone-started turns only, to the device that asked. Any waiting request,
  Deny-only included.
- Title: the writing's name; `summary` and `body`: "<Provider> is waiting for
  your answer." Never the command, the folder or the agent's reason.
  `outcome` "waiting", `endedAt` when it began to wait, `subtitle` empty.
- One push per wait, when the list goes from none to some; saved only if
  something still waits when its turn in the line comes; deleted when nothing
  waits.
- On the Mac: a local notification for a Mac-started turn whose pane is
  unwatched as the wait begins, under the same setting and route, so the end's
  notice replaces it; taken back on answer.
- The phone's contract: tell it from an end by the record name; never count it
  as hearing the turn; hide it while the chat is on screen and connected; a tap
  opens the chat; no Allow or Deny on the alert.

Tests that must bite: the waiting record's keys are a subset of the ended
record's; markers in the command, folder and reason appear in no field;
`turnID` isn't the turn's; `summary` equals `body`; tell, nothing, clear and
tell-again as the rules say; a Mac-started turn tells no phone; answered before
its save, it isn't saved; the Mac notice is posted once, taken back, and not
posted for a watched pane or a phone turn. By hand: a locked phone.
