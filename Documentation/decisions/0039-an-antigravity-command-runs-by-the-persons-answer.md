# 0039. An Antigravity command runs by the person's answer

Status: Accepted, 2026-11-26. Built in `lamp-bible-macos`, held by
`AgentACPCommandTests` (a request recorded from `agy acp` 1.5.14) and
`AgentACPCommandRunnerTests` (a fake `agy`). Planned by Fable; the owner
asked for Antigravity's commands to reach the same card as Codex's
(`0028`).

## Context

Lamp answers every `session/request_permission` an Antigravity chat sends
by rule (`AgentACPRun.decide`): Lamp's tools, reads in the workspace and, in
a writing, edits there are allowed; a command was always rejected, unasked.
Recorded on 1.5.14, a command arrives as a tool call of kind `execute`
named `run_command`, the command whole in `rawInput.CommandLine` (its title
repeats it; `toolSummary` describes it), no working folder, and the options
`allow_once` and `reject_once`; the request's id is a string.

Lamp does not sandbox Antigravity. Antigravity has a sandbox of its own,
off by default (`--sandbox`, `enableTerminalSandbox`), which Lamp does not
set.

## Decision

**In a writing chat, a command whose full text is given and which offers a
once-only allow comes to the person on Lamp's approval card.** The card
shows the command whole, never its title or summary, and says that Lamp
does not sandbox Antigravity, so unless the person's own settings do, the
command can read and change anything their account can, and use the
network. Allow selects `allow_once`; Deny, or no answer within 580 seconds,
selects `reject_once`. Stop answers every waiting request `cancelled` before
asking the agent to cancel, and a request arriving after Stop is cancelled
unshown. Requests are kept by their JSON-RPC id.

Everything else is answered by rule as before: web fetches, edits outside
the workspace, other servers' tools, questions, and every reader chat's
request, which never asks.

## What follows

- The person's own Antigravity allow rules, and `toolPermission`
  `always-proceed`, answer before Lamp is asked.
- While a command waits, the turn's step reads "Waiting for your answer on
  the Mac", as for Codex.

## Rejected

- `allow_always`: Antigravity saves it as a `command(...)` rule in the
  person's settings, for every Antigravity session, and `readerRefusal` would
  then refuse every Antigravity reader chat. A request offering only it is
  not asked.
- `--sandbox` with sandboxed commands allowed by rule: the request does not
  say whether a command would run sandboxed, and `agy acp` takes no settings
  of Lamp's.
- Showing the title or summary as the command: they are the agent's words
  about it.
