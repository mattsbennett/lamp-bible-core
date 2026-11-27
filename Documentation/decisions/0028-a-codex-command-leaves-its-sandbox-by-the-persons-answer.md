# 0028. A Codex command leaves its sandbox by the person's answer

Status: Accepted, 2026-11-26. The owner allowed a Blender render on Lamp's
card in the installed app, and it rendered; allowed over the protocol by a
test client, the same Codex 0.170 turn rendered with Eevee on Metal in
0.38 s. In the sandbox Blender cannot start Eevee, and crashes on the window
server before Codex asks, so the deck guidance says to ask from the start.
Built in the Mac app (`lamp-bible-macos`): Lamp's server,
held by `codexIsGivenLampsServerApprovedInEveryHeadlessChat` and
`WritingChatServerTests`; reader chats, by
`aReaderChatCannotChangeOrImportWritings`; the app-server turn, by
`AgentCodexRunTests` (a turn recorded from Codex 0.170) and
`AgentCodexRunnerTests` (a fake Codex). Planned by Fable; the owner chose it
over pre-approved command rules, a no-sandbox mode, and leaving Codex
sandboxed.

## Context

An end-to-end run of Codex, as Lamp runs it (`codex exec --sandbox
workspace-write`), making a video in Blender for `prepare_video`
(`0026`) found three things:

- **No GPU.** Codex's macOS sandbox opens a fixed list of hardware, and the
  GPU is not on it ("Could not initialize Metal: no default Metal device
  available"); Blender fell back to the CPU at about 2 s a frame against
  0.1 s with the GPU. No sandbox setting grants it. Codex can ask to run a
  command outside the sandbox, but `codex exec` fixes the approval policy at
  `never` and refuses every request, so Lamp's chats could never ask.
- **No Lamp tools in a writing.** Codex reads a project's own
  `.codex/config.toml` only in a folder the person trusted, and no writing
  workspace is one; asked in such a folder, Codex said it had no `lamp`
  server.
- **Lamp's writing tools refused.** Given the server, Codex refused every
  Lamp tool marked as changing anything ("MCP tool call requires approval,
  but approval policy is never"): under `default_tools_approval_mode =
  "auto"` it asks before them, and `codex exec` cannot ask.

## Decision

**A Codex writing chat runs on `codex app-server`, with approval policy
`on-request` and the person as reviewer, so a request to run a command
outside the sandbox reaches the person on Lamp's approval card; reader chats
stay on `codex exec` and can never ask.** The card shows the command, its
folder and Codex's reason, and offers Allow Once and Deny; unanswered, it is
declined. The phone may answer it too, once at a time (owner's choice).
"Allow for this chat", an exact command in one folder until the chat ends,
comes after (owner's choice).

Built first:

1. **Lamp's server, approved, in every headless chat.** A writing chat is
   given Lamp's server on its command line, made by Lamp from the
   workspace's path (the helper in the app, the library, its access policy,
   the bundled modules) — never from a file in the workspace, which the
   agent can change, and which would name a program for Codex to start
   outside the sandbox (Codex's review found the first version reading
   `.mcp.json`). Writing and reader chats give it as `"approve"`, as Claude
   and Antigravity already run Lamp's tools. The workspace's own settings
   file stays `"auto"`: the Codex terminal reads it, and can ask.
2. **Reader chats change no writing, and read no Codex rules.** The helper
   refuses `write_writing_draft` and `import_writings` in a reader chat,
   whichever provider asks; Claude's reader chats could call them when "Allow
   other apps to change my writings" was on, against the chat's own rule. A
   Codex reader chat passes `--ignore-rules`, where its Codex takes it: an
   `allow` rule runs a matching command outside the sandbox without asking,
   whatever the policy.

3. **The turn** (`AgentCodexRun`, `runCodexAppServer`): `initialize`,
   `thread/start` or `thread/resume` with the sandbox, the policy and the
   reviewer set every time, `turn/start`, ending at `turn/completed`; Stop
   sends `turn/interrupt`. A thread `codex exec` made resumes on it, so
   existing chats carry over; one Codex no longer has answers "no rollout
   found for thread id …", which the resume path already reads. Closing the
   server's input ends it, and no daemon is left. Codex streams its
   commentary in the same deltas as its answer; the runner keeps it out of
   the reply by the item's `phase`.
4. **What comes to the card:** a command request with the command, unwrapped
   from the `zsh -lc '…'` Codex puts round it only where the body holds no
   quote, its folder, and Codex's reason, said to be Codex's. Allow sends
   `accept`, once; Deny sends `decline`, which Codex accepts though its
   request lists only `accept`, a rule and `cancel` (recorded), and the turn
   goes on. Unanswered after 580 seconds it is declined; after Stop nothing
   waiting is allowed, and a request arriving after Stop is declined unshown.
   While a request waits, the turn's step reads "Waiting for your answer on
   the Mac", so a phone following the turn, which has no card yet, shows it
   waiting rather than working; answered, the step goes back to what it was.
   A step names a command shortened, as Claude's do, since steps are kept in
   the transcript and sent to the phone; the card alone has it whole. A
   command's streamed output is dropped as it arrives: Lamp reads nothing
   from it, and a render's log is long.
5. **Turned down where it stands,** the turn going on: a network prompt; a
   file change outside the workspace, since what it writes is not in the
   request and a card must show what it allows; more permissions (an empty
   grant); a question for the person (no answers); an MCP server's form; the
   older approval messages; anything else, refused as not provided.
6. **Antigravity's writing chats** are given the server Lamp makes the same
   way, no longer the one named in the workspace's `.mcp.json`.
7. **The deck guidance** says to set the render device first, then that a
   renderer still reporting no Metal device is in a sandbox, and to ask
   rather than fall back to the CPU unsaid.

## What follows

- `--ignore-rules` drops the person's `forbidden` rules too; a reader chat
  stays read-only and offline in its sandbox without them.
- Codex merges a server given on the command line into one of the same name
  in the person's settings. Lamp's own external-app setup writes a
  compatible `lamp`; a `lamp` of the person's that is a web server, or
  switched off, would stop a writing chat starting or leave it without
  tools. Renaming Lamp's server would change every Lamp tool's name to the
  agent, so it is left.
- The app-server is labelled experimental; its messages are pinned by the
  recorded turn, and anything unrecognised is refused.
- The person's own Codex hooks still run in a turn, as their Claude settings
  do in Claude's; a `PermissionRequest` hook of theirs that allows a command
  answers before Lamp's card.
- Claude and OpenCode writing chats still take Lamp's server from files in
  the workspace (`.mcp.json` with `enableAllProjectMcpServers`, and
  `opencode.json`), which their agents can rewrite; open, for the owner.

## Rejected

- **A Codex `PermissionRequest` hook:** under `exec`'s fixed `never` no
  request is made for it to answer, and a hook needs the person's trust by
  its exact text.
- **`--approve-for-me`:** a model answers, not the person.
- **Codex's own remembered approvals** (`acceptWithExecpolicyAmendment`): a
  rule in the person's settings that would apply to every Codex session on
  the Mac, reader chats included.
- **Pre-approved rules, or no sandbox at all:** more than the GPU, for every
  command.
