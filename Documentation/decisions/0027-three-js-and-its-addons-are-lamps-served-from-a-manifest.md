# 0027. three.js and its addons are Lamp's, served from a manifest

Status: Accepted, 2026-11-27. Built in the Mac app (`lamp-bible-macos`):
`scripts/vendor_three.py`, `LampAnimationRuntime`, the renderer's file
server, held by `LampAnimationThreeTests` and the notices script's
`check_three`. Item 3 of `../AnimationRuntimePlan.md`, planned by Fable.

## Context

An animation page imported three.js as `three`, which Lamp served from a
copy of 0.170's module build inside the deck skill. That was the core
library alone: no bloom, no glTF, no lines, no sky, none of what three's
own examples import from `three/addons/`. And the skill is copied into every
writing's workspace, for Codex and for Claude, so each writing carried
690 KB twice for a renderer that runs in Lamp.

## Decision

**three.js 0.187.0 and the addons Lamp ships are in Lamp's own resources,
`AnimationRuntime/three`, at npm's paths, and served only by their manifest.**

- **What is in it.** The five module builds (module, core, webgpu,
  webgpu.nodes, tsl); all of `postprocessing`, `shaders`, `tsl`,
  `geometries`, `curves`, `math`, `objects`, `environments`, `lines`,
  `lights`, `helpers`, `csm`, `textures` and `capabilities`; `utils` and
  `modifiers` less the files that import `libs/`; the glTF, font, HDR/RGBE,
  SVG, OBJ, MTL, STL, PLY and LUT loaders; `GPUComputationRenderer`,
  `CSS2DRenderer`, `CSS3DRenderer`; and everything those import. 274 files,
  9.5 MB, 2.2 MB deflated; 0.187 ships no minified builds, which is most of
  the difference from the plan's estimate of 7 MB.
- **What is not.** `libs/` (Draco, KTX2, EXR, FBX decoders, which bring
  WebAssembly and workers), `controls` (nothing is interactive), `webxr`,
  `inspector`, `exporters`, `physics`, `generators`, and `TTFLoader`, which
  imports from a CDN.
- **How it is made.** `scripts/vendor_three.py` reads npm's tarball, checked
  against the integrity npm published, without unpacking it, and writes the
  chosen files and their import closure, three's licence and a
  `MANIFEST.json` of every file's SHA-256. It refuses an import of anything
  but `three`, `three/webgpu`, `three/tsl`, `three/addons/...` and relative
  paths, and any file it was told to leave out. Imports are read only where a
  statement starts a line: the WebGPU build writes WGSL with the word
  `import` in it, which the first pattern took for one.
- **How it is served.** `/lamp/three/<path>` for a path in the manifest and
  no other; a page's import map gives `three`, `three/addons/` and
  `three/examples/jsm/`, so an addon Lamp lacks stops the render by its
  name. `/lamp/three.module.min.js`, where pages written before this import
  from, is one line re-exporting the module build, so it is the same three.
  `three/webgpu` and `three/tsl` are vendored but not mapped until WebGPU is
  exposed (item 4).
- **How it is kept.** The notices script pins the manifest's hash and checks
  every listed file, and that nothing unlisted is there. A writing's deck
  skill loses its `scene` folder the next time its skills are refreshed,
  which replaces a built-in skill's folder whole.

## What follows

- A page written for 0.170 that uses something three has removed since
  (`WebGLMultipleRenderTargets`, gone in r172) stops with the name of what is
  missing when it is drawn again; its video is untouched. Keeping 0.170
  beside 0.187 for such pages was weighed and left: a page is the agent's,
  and fixing it is one line.
- The WebGPU variants of addons (`WaterMesh`, `lines/webgpu/`, `tsl/`) are
  vendored but can't load until `three/webgpu` and `three/tsl` are mapped;
  the deck format says to use their WebGL forms.

- A model compressed with Draco or KTX2, or an EXR environment, can't be
  loaded; the deck format says to save plain glTF.
- Updating three is running the script on a newer tarball, with its
  integrity, and updating the notices script's pin.

## Rejected

- **Leaving three in the deck skill:** every writing carried it twice, and
  the addons would have made that 19 MB.
- **Serving all of `examples/jsm`:** 9.9 MB of addons, much of it needing
  `libs/` or input a rendered frame never has.
- **Importing from a CDN:** nothing a page loads may come from the network.
