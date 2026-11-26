# 0026. An agent's own video comes in through `prepare_video`

Status: Accepted for the Mac, 2026-11-26, held by `LampVideoPreparationTests`
and `onlyTheWriteToolsSayTheyWrite` (`lamp-bible-macos`). Planned by Fable
(`../AnimationRuntimePlan.md`); the owner asked that agents be "completely
unshackled to create immersive visualizations", and chose where their scratch
output goes.

## Context

An agent working in a writing's workspace has a shell, under its own
harness's permissions, and can make a video with anything installed: Blender,
Manim, Remotion, a Metal program, a browser. A deck could already name any
`.mp4`, `.mov` or `.m4v` in `Assets`, but nothing checked it beyond its
extension: no size limit (Slide Studio and `render_animation` enforce one, an
agent's own file met neither), no codec a phone can play, no still, and a
video re-made under the same name was never brought in again, since Lamp
re-imports a deck's files only when the deck changes.

Lamp's own page renderer (`render_animation`) covers what a three.js page can
draw. Making it cover everything (a bundled Chromium, compositor capture) was
weighed and rejected in the plan: 150–200 MB and a security update every week
or two, or a Screen Recording permission and real time.

## Decision

**A video file is Lamp's interface to whatever made it.** `prepare_video`, an
MCP tool offered only to a session opened on a writing's workspace, takes a
video inside that workspace as a `loop` (silent) or a `clip` (with its sound)
and:

- encodes it with `LampVisuallyLosslessVideo` (HEVC Main10, up to 4K), and
  over the deck's limit (`LampPresentationVideo.largestFileBytes`, 100 MB, for
  a loop; `LampPresentationClip.largestFileBytes`, 250 MB, for a clip) again
  at 1080p — its shorter side 1080 pixels — refusing it past that with
  nothing written;
- takes the first frame as its still;
- writes both into the workspace's `Assets`, named after the video and the
  first eight hex digits of its SHA-256, through the animation renderer's
  all-or-none publish, so a changed video arrives under new names;
- returns frames from across it, no larger than 640 pixels either way, and
  for a loop its last frame, found by its own presentation time, and how far
  that is from its first (a mean colour difference at 32 pixels across; over
  0.08 is reported as a jump);
- says so when what it was given was see-through, which a slide's video
  cannot be: it is laid on black.

What it reads and writes stays inside the workspace, which it holds open for
the whole call:

- **The source** is reached from the workspace one folder at a time, the path
  split on the slash scalar as the kernel splits it and refused with a NUL in
  it, each folder opened without following a link, the file itself without waiting (a pipe
  would never answer), and taken only if it is a plain file. It is cloned, or
  copied a piece at a time where there is room, into a private folder before
  anything reads it, off the main actor and stopped if the call is.
- **Another file's media**: the encoder refuses any track it would read that
  AVFoundation does not call self-contained (`AVAssetTrack.isSelfContained`),
  before reading a frame. The framework that would follow a reference is the
  one answering. Its reference restrictions alone did not stop a reference
  from one file on this Mac to another.
- **`Assets`** is made and opened inside the workspace without following a
  link, and checked to be the same folder before the files are written. If,
  after writing, the session's workspace or its `Assets` is no longer the one
  held, the call says where the files went, and leaves them: a deck may
  already name a fingerprinted name.
- **One encode at a time** on the Mac (`LampVideoEncodeGate`), across Lamp
  and every `lamp-mcp`, shared with `render_animation` and Slide Studio. Within
  a process by a queue; between processes by a lock on a file in the user's
  temporary folder, which is best effort: if that file cannot be opened, the
  queue still holds in each process.
- **Sound** keeps the volume each track is set to play at.

The adversary is an agent that can write only inside its workspace: any file,
any content, any race there. It is outside this to change the path that leads
to the workspace, to make hard links or copies the harness allows, or to
attack AVFoundation's own decoder, which Slide Studio's chooser already
reaches. Lamp ships none of the tools; the agent installs and runs them with
the writer's leave.

Scratch output — a frame sequence runs to gigabytes — goes in `.lamp-renders/`
at the top of the workspace, as the deck skill says. A workspace syncs only its
top-level documents, `context/`, its skill choices, `.lamp/revisions` and its
chats, so nothing there syncs and no sync rule changed for it.

## What follows

- The encoder read a file's size through the URL it wrote to, and a URL keeps
  the first size it reads: the 1080p retry reported the 4K size and was
  refused as still too large. This hit Slide Studio's own 1080p retry too. The
  size is now read from the file system.
- Any file under the workspace can be a source, not only `.lamp-renders/`
  and `Assets/`: with the walk, every file there is reached as safely, and a
  rule would only force copies from where a tool wrote and bar a writer's own
  footage.
- 1080p is by the shorter side (`longestSideAt1080p`), shared with Slide
  Studio: by the longer side, as both had it, a square video was retried at
  1920 square and a 1440 square one not retried at all.
- A deck naming a video over its limit, or in a codec a phone cannot play,
  is to get a validator warning pointing to `prepare_video`, not an error, so
  decks already made keep opening (owner's decision; not built yet).
- The deck tools (`validate_deck`, `render_deck`) asked from a workspace look
  for the deck's files there, reached the same way (`LampWorkspaceFiles`):
  given only the deck's text, they had called every file missing and drawn
  every picture as a placeholder, in any writing. A file missing now counts
  against its own slide.
- The answer also says what sound came in and was kept, shows a clip's last
  frame, takes the still at `still_at` where asked, and lists files named as
  the video's, from earlier prepares, which Lamp leaves.
- A folder of numbered frames with a frame rate is planned as a second input,
  since frames are what every program can write.
- An encode is not stopped part way when the call is cancelled; it runs to its
  end and its result is dropped before anything is written. One cancelled
  while it waits its turn gives the turn up unused.
- A workspace's Codex sessions allow a tool call ten minutes, not one: making
  an animation or preparing a video can take longer, and waits its turn at
  the encoder. Claude Code and OpenCode set no such limit in Lamp's files.
- Only the first picture track that plays is read. A movie laying a second
  track over the first is shown by AVFoundation as its first track alone —
  tried with a self-contained movie of two enabled tracks, out of any
  alternate group, layered and transformed — so what comes out is what
  QuickTime Player, built on AVFoundation, shows.
- A file swapped into `Assets` under one of the staged names between its copy
  and its rename would be published in place of Lamp's; every write still
  lands in the `Assets` held, and the race is the agent's own folder.
- A loop's last frame is found from its own samples: the latest sample time
  less the earliest, since a track whose frames are reordered is timed on a
  line that starts later than the video (two frames late, for H.264 with
  B-frames). The reader is tested directly on an unevenly timed movie; end to
  end, the encoder re-times frames to a steady rate, so working it out from
  the frame rate would land on the same frame.

## Wrong first, and what it cost

The first version checked the source's path and handed the path on, so the
file could be swapped for a link before the encoder opened it, twice; it
followed reference movies; it created `Assets` through `FileManager`, which
follows a linked one; it took a loop's last frame a frame-length before the
end, which on uneven frames is an earlier one; it stepped to 1080p by the
longer side; and it laid a see-through video on black without saying.
Codex's first review found each. The first answer to reference movies,
`AVURLAssetReferenceRestrictionsKey` set to forbid all, did nothing: its test
still read the other file's pictures.

The second answers brought the second round's findings, of the same kind: a
parser of the movie's own data references could be made to trap `lamp-mcp`,
and refused an ordinary QuickTime movie Apple ships (its `meta` box has no
version prefix); comparing the source's real path with the workspace's as
strings refused a workspace reached through `/System/Volumes/Data`; and a
pipe, opened and waited on, hung the call. That sent the design back to the
planner. The walk replaced the string comparison, AVFoundation's own
`isSelfContained` replaced the parser, and the transparency check moved to
the track the encoder reads. A direct test of the last-frame reader then
showed it reading two frames late on H.264, which the end-to-end tests could
not see.

The third round, under the planner's stop rule, found the walk splitting the
path on Swift's characters, where a slash with a combining mark after it is
one character the kernel walks through, following a link there, and where a
name ending in a NUL is read by the kernel as the part before it (`..`, out
of the workspace); and a clip's sound coming out at full volume when its
track was set quieter. It also found a movie with a second picture track laid
over the first losing that track, which could not be shown: AVFoundation
itself draws only the first. Each fix has a test that fails with its fault
put back; the linked-`Assets` and turn-taking tests fail only with both their
guards removed, either alone being enough.

The tests themselves did harm. Built at first on videos of random noise at 4K
and 1440 square, written as H.264 at 200 Mbps and re-encoded, several at once,
they hung the hardware encoder for four minutes, and a probe that opened more
encoder sessions after it brought the owner's Mac down with a kernel panic in
the encoder (`dart-ave`). The suite now uses videos no more than 640 pixels
across (one 720 tall for the frame-size test), plain, at an ordinary bit
rate, one test at a time, and tests the 1080p step by asking for a smaller
size rather than making a larger video.

## Rejected

- **Leaving it as it was**, the agent naming its file directly: unchecked
  size, codec and still, and a re-made video never arriving.
- **A source anywhere on disk**: Lamp's sample frames would show an agent
  confined to its workspace what lies outside it.
- **Bundling the tools**: each is large and moves fast; the agent's harness
  already governs installing and running them.
