# 0025. A WebGPU frame is kept when it is submitted

Status: Accepted, 2026-11-27. Rebuilt from this record as item 2 of
`../AnimationRuntimePlan.md`, in `AnimationRuntime/webgpu-keep.js`
(`lamp-bible-macos`), held by `LampAnimationCaptureTests` and
`LampAnimationWebGPUTests`. Planned by Fable; the owner asked for richer agent
animations and chose to allow WebGPU, and, when the stop rule below fired on
the rebuild's review, chose to fix and review once more rather than hide it.

## Context

An agent's animation is a page Lamp draws offline, a frame at a time: it calls
the page's `render(t)` and then snapshots the web view (`LampAnimationRenderer`).
A WebGL canvas holds what was drawn until it is drawn again, so the snapshot
sees it. A WebGPU canvas holds its frame only until the frame is shown, at the
end of the task that drew it, and the snapshot came too soon or too late: on
macOS 27.0.1 every frame of a WebGPU page's video was the frame before it, some
the one before that. Six of the eight capture tests failed on the renderer as
it stood. WebGPU is reachable from a page already, under the renderer's
`lamp-scene:` scheme, which is a secure context.

Probes before the plan: a canvas read back by the page in the same task as its
`submit` gave the colour drawn; the same read 300 ms later gave black; a
snapshot taken after a 300 ms wait gave the colour. WebKit trunk keeps the
last shown frame for a read where 27.0.1 gives black, so neither behaviour can
be leant on.

## Decision

**Lamp keeps a WebGPU frame at the moment work reaches it, on the page's own
canvas, and snapshots the view as before.** A script at document start hands
`getContext("webgpu")` the context of a twin canvas that is never put on the
page; the page's canvas becomes a plain 2D canvas. Whenever the page submits
work, or writes or copies straight into a texture (`writeTexture`,
`copyExternalImageToTexture`), every twin whose frame is being drawn — it asked
for that frame's texture in this task — is copied onto its page's canvas there
and then, so even a page reading its own canvas on the next line reads this
frame.

The canvas otherwise behaves as one with a WebGPU context does: it refuses a
second kind of context, and a canvas that already gave another kind refuses
WebGPU; the twin takes the canvas's size however it was set, attributes
included, before each frame's texture is handed out; `context.canvas` answers
with the page's canvas; unconfiguring clears it. An empty canvas is skipped,
and a copy that fails fails the render by name rather than leaving a frame
stale. Same-origin frames share what is being drawn, so a queue from one
copies a canvas drawn in another (by reading; no test draws across frames). A
canvas sent offscreen is refused WebGPU, since nothing here sees what it draws
there; in 2D or WebGL it is untouched.

A frame is a frame of the task that asked for its texture, as the browser's
own is: a page that asks for the texture and submits only after waiting on a
timer is not kept. three.js asks and submits in one go.

**What is copied, and when.** A submit copies only the canvases its command
buffers drew on, found from the views their render passes attach and the
textures their copies write; a write or copy straight into a texture copies
only when that texture is a canvas's current one. Copying every canvas being
drawn at any submit read a canvas before it was drawn, and a WebKit build that
keeps the first read of a frame would have kept that.

## What follows

- Rebuilt on 2026-11-27, the raw WebGPU page had every one of its 12 frames
  wrong without the copy, none with it. The rebuild's review fired the stop
  rule with two pages given a wrong frame silently: an upload before the draw
  copied the canvas early, which this Mac's WebKit doesn't keep but WebKit's
  trunk does (so its test can't fail here); and a canvas configured again and
  not drawn kept the frame before, where the spec empties it. The owner chose
  to fix both and to keep reviewing until a round found no P1, which the
  next did.
- Limits that round left, in the deck format too: a frame drawn in two
  submits to one canvas (a scene, then an overlay) is copied after each,
  and a WebKit that keeps a frame's first read would keep the scene alone;
  a canvas drawn in a worker is not caught; a canvas set up for a compute
  shader to write into is refused by name. The tracking is shared by every
  frame of the page, and a canvas texture given straight as an attachment
  is followed.
- Three's `RenderPipeline` shows nothing on its first draw, which builds its
  shaders, and the first frame is the still: on a page that drew with WebGPU,
  frame 0 is drawn once and not kept. A 2D or WebGL page is drawn once a
  frame, as before.
- The tool says which drew (`drewWith`), since a WebGPU page draws with WebGL
  on a Mac without WebGPU.

- Measured at 1920×1080, 600 frames, 30 fps, on a quiet machine: 28.4 ms a
  frame with the first version of the copy, 27.9 ms without it — inside
  run-to-run noise — and 28.5 ms with the final one; the colour sampled at
  every frame's time right with it (600 decoded), several wrong without.
- WebGL needs nothing: with the default drawing buffer, which a browser may
  clear once it is shown, every frame was still right, drawn at once or after
  a 200 ms wait, because the snapshot is taken in the same rendering update.
  `preserveDrawingBuffer` is not forced.
- A WebGPU scene drawn in a worker, on a canvas sent offscreen, cannot be
  kept and is refused; the deck skill is to say so when it offers WebGPU
  (`../AnimationRuntimePlan.md`, item 4).
- WebGPU is allowed, so a page may draw with WebGPU on one Mac and fall back to
  WebGL on another (WebGPU reaches a web view from macOS 26; Lamp runs from
  macOS 15). The owner accepted that a page can render a little differently
  between them; the deck plays only the video, wherever it is shown.
- `requestAnimationFrame` is not touched: it is throttled for a view in no
  window, and a page's own loop driven by it would draw frames between
  `render` and the snapshot.

## Rejected

- **Waiting for the frame to be shown, then snapshotting.** No signal says it
  has been; `requestAnimationFrame` is throttled here; a fixed wait of 300 ms
  is three minutes on a 600-frame loop, and what is shown differs by WebKit
  version.
- **A `lamp.capture` hook the page calls.** Right only if every agent gets the
  timing right.
- **Reading the canvas back after `render` returns.** Wrong when `render`
  awaits past the end of the task that drew: the frame is gone by then.
- **Encoding the canvas's pixels directly instead of snapshotting.** Loses
  HTML and CSS over or under the canvas, and stacked canvases.
- **Hiding `navigator.gpu` so every Mac uses WebGL.** Every Mac would draw
  alike, but agents would lose GPU compute, which is most of what WebGPU adds;
  the owner chose to allow it.

## Wrong first

The first version copied in a microtask after the turn's submits, gave any
canvas a WebGPU context, followed only the `width` and `height` properties,
copied every drawn twin even when one was empty, and refused
`transferControlToOffscreen` outright. Codex's first review found each
failing a page: a page drawing its WebGPU canvas onto another straight after
submitting got the previous frame; a texture written without a submit was
never kept; a 2D or WebGL canvas handed out WebGPU too, and one probing for
WebGL after WebGPU blocked every copy; a canvas given no width mid-frame
threw in the copy and stopped every other canvas being kept; a canvas sized by
attribute drew at its old size; and a 2D page sending its canvas offscreen
threw. Each had a test that failed with its fault put back.

The second review found four more of the same kind — a resize or reconfigure
leaving a stale frame on the page's canvas, frames of one page disagreeing
about which context a canvas gave, and a transferred canvas still handing out
WebGPU — which is what sent the design back to the planner. Fable's revision:
one registry in the top window that every realm's wrappers read; one
end-of-frame wherever the spec empties a canvas (the size setters, always,
width and height attributes, `configure`, `unconfigure`); never scaling a
copy; taking the page canvas's 2D context when the twin is made; refusing as
the browser does on a transferred canvas; and a stop rule that a P1 is a page
inside that contract given a wrong frame silently.
