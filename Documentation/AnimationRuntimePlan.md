# Animation runtime plan

Planned by Fable on 2026-11-26, for the owner's request that agents build
richer animations for slides. Animations stay baked: an agent's page is drawn
offline to a looping video (`LampAnimationRenderer`, Mac), and only the video
is ever presented. The owner chose to allow WebGPU (`decisions/0025`).

## Widened, 2026-11-26

The owner widened the goal: "I want agents completely unshackled to create
immersive visualizations. if there are better tools available for this,
consider them too". Fable's answer: make a video file Lamp's interface to the
agent, so any tool the agent runs (Blender, Manim, Remotion, a Metal program,
headless Chrome, ffmpeg) can make what a slide shows, and keep the in-Lamp page
renderer as the path that needs nothing installed. Lamp ships none of those
tools; the agent installs them under its own harness's permissions.

Already possible: an agent can name any `.mp4`/`.mov`/`.m4v` in `Assets` as a
picture's `video` or a clip's source. Nothing checks its size (100 MB for a
loop, `LampPresentationVideo.largestFileBytes`; 250 MB for a clip), its codec,
or makes its still, and a re-made video under the same name is not brought in
again.

Owner's decisions, 2026-11-26:
- Scratch output (a frame sequence can run to gigabytes) goes in one hidden
  folder at the top of a workspace that never syncs, `.lamp-renders`; the
  deck skill tells agents to render there. A workspace syncs only its
  top-level documents, `context/`, its skill choices, `.lamp/revisions` and
  its chats, so the folder needs no sync change (`decisions/0026`).
- A deck naming a video over its limit, or in a codec an iPhone cannot play,
  gets a warning pointing to `prepare_video`, not an error, in core and
  `validate_deck.py` together, so decks already made keep opening.

## Items, in order

1. **`prepare_video`** - an MCP tool, for a workspace session only, taking a
   video inside the workspace (later also a folder of numbered frames with an
   fps) as a loop or a clip: encodes it visually lossless
   (`LampVisuallyLosslessVideo`), retries at 1080p over the limit and refuses
   past it, writes the video and its first-frame still under fingerprinted
   names through the renderer's all-or-none publish, and reports sample frames
   (for a loop, also its last frame beside its first). Built in
   `LampBibleMacSupport` (`LampVideoPreparation`) beside Slide Studio's own
   import, which keeps its own still and HEVC check and shares the encoder
   and its 1080p rule. Landed for a video file (`decisions/0026`), and the
   validator warning with it: a deck's video over its limit or in a codec not
   every device plays (by its sample entries, and H.264's profile) is warned
   of by core's validator, `validate_deck`, a deck's import and
   `validate_deck.py`, all reading the same boxes (`LampPresentationVideoFacts`).
   The frames folder is still to come.
2. **Capture, narrowed** (`decisions/0025`, Proposed): keep the twin canvas
   for what three r187's `WebGPURenderer` does (size setters each frame,
   reconfigure after resize, repeated `getContext`, uploads then one submit in
   one task) on one registry in the top window, ending a frame wherever the
   spec empties a canvas, never scaling a copy, and failing a render by name
   outside that contract, with a pointer to `prepare_video`. One pass and one
   review; stop rule: a P1 is a page inside the contract getting a wrong frame
   silently. If one turns up, hide `navigator.gpu` so every Mac draws with
   WebGL2.
3. **Vendor three.js 0.187.0 with its standard addons**, WebGL specifiers
   only. Not in the deck skill (it is copied into every writing's workspace,
   twice), but in its own resource folder, `AnimationRuntime/three/`, mirroring
   npm's paths, with `LICENSE` and a `MANIFEST.json` of per-file hashes.
   Served under `/lamp/three/...` only for files in the manifest; pages import
   through an import map Lamp injects: `three`, `three/addons/...` (and
   `three/examples/jsm/...`). `/lamp/three.module.min.js` stays, as one line
   re-exporting the module build, for pages already written.
   - The set: the four builds' module and core files; whole `postprocessing`,
     `shaders`, `tsl`, `geometries`, `curves`, `math`, `objects`,
     `environments`, `lines`, `lights`, `helpers`, `csm`, `textures`,
     `capabilities`; `utils` and `modifiers` less the files importing `libs/`;
     the GLTF, Font, HDR/RGBE, SVG, OBJ, MTL, STL, PLY and LUT loaders;
     `GPUComputationRenderer`, `CSS2DRenderer`, `CSS3DRenderer`. Left out:
     `libs/` (Draco, KTX2, EXR, FBX), `controls`, `webxr`, `inspector`,
     `exporters`, `physics`, `generators`, `TTFLoader` (it imports from a CDN).
     About 7 MB on disk, 1.6 MB deflated; three's MIT licence is the only
     notice.
   - `scripts/vendor_three.py` copies the listed roots and their import
     closure from the pinned tarball, checks npm's integrity, refuses any
     specifier outside the map and any `libs/` file, and writes the manifest;
     the notices script pins the manifest's hash.
   - Registered: `.copy` in `Package.swift`, a folder reference in the app's
     Resources phase and in lamp-mcp's skill-catalog copy phase.
   - Decision record 0027. Landed: 274 files, 9.5 MB (0.187 ships no
     minified builds), served from the manifest.
4. **Expose WebGPU**: `three/webgpu` and `three/tsl` in the map, after items 2
   and 3. The tool result says which backend drew.

Rejected for the renderer's capture: a second snapshot per frame (tried:
frames 0-3 black, later ones still one late); an off-screen window (no
presentation signal); compositor capture (Screen Recording permission, real
time); bundled Chromium (150-200 MB, frequent security updates);
`captureStream` (real time, drops frames); WebCodecs in the page (the canvas
alone, losing HTML over it).

## Tests per item

- `prepare_video`: an H.264 source comes out HEVC Main10 with a still under
  fingerprinted names; over the limit it is retried at 1080p, and refused
  past it with nothing written; a clip keeps its sound, a loop drops it; a
  source outside the workspace, through a link, or not a video is refused; a
  changed source arrives under new names; a loop whose last frame jumps is
  reported; numbered frames all decode right and a gap is refused; the tool
  is offered only with a workspace.
- Capture: `LampAnimationCaptureTests` — every frame of a raw WebGPU page;
  `render` waiting after and before drawing; HTML over a WebGPU canvas; a
  transparent canvas over a CSS background; a canvas sized after its context;
  WebGL without a kept buffer, at once and after a wait. Each WebGPU test
  failed before the copy at submit.
- Vendoring: the manifest matches the folder; a page importing every vendored
  non-TSL module; bloom through `EffectComposer` lights a pixel beside a bright
  box; the legacy path's `Vector3` is `three`'s; a left-out addon fails by
  name; GLTFLoader reads a `.gltf` from the folder; the installed skill has no
  `scene` folder; the example in `deck-format.md` renders; the notices script
  fails on a changed manifest; both builds carry the manifest.
- WebGPU: a `WebGPURenderer` cube with every frame checked and the backend
  asserted; the same with `forceWebGL`; the same with `navigator.gpu` hidden
  before import (what a macOS 15 Mac does); `RenderPipeline` with a TSL bloom;
  every TSL module loads. A real macOS 15 run is unverified until one is
  available.
