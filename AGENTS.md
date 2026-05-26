# AGENTS.md

## Project Overview

`jai-wayland` is a Wayland client library for Jai. It bypasses
`libwayland-client` and speaks the Wayland wire protocol directly over a Unix
socket. Shared libraries for GPU work are loaded at runtime with `dlopen` and
function pointers; do not introduce hard link-time dependencies on Wayland, EGL,
gbm, GL, Vulkan, X11, or xcb.

Current status: phases 1-5 are complete, including NVIDIA/hybrid GPU support.
The primary GL path is GBM BO-backed: select a DRM render node, allocate a
`gbm_bo`, import it as an `EGLImage`, bind it to a GL texture/FBO, export the BO
fd/stride/offset/modifier, and present it through `zwp_linux_dmabuf_v1`. The
older Mesa `EGL_MESA_image_dma_buf_export` texture-export path remains as a
fallback. Current examples include double-buffered slots, frame callbacks,
keyboard/pointer input, XKB keysym translation, dmabuf feedback, and resizable
BO-backed GL windows.

## Required Skill

Before writing or modifying Jai code, use the `jai-language` skill if available.
The compiler is expected at `~/jai/jai/bin/jai-linux`, with standard library
modules under `~/jai/jai/modules/`.
The Vulkan triangle example expects `glslc` in `PATH`; keep shader compilation
inside `first.jai`.

## Build And Test

Use the project wrapper:

```bash
./build.sh
./build.sh - test
./build.sh - gen_test
./build.sh - wire_test
./build.sh - marshal_test
./build.sh - unmarshal_test
./build.sh - compile_test
```

To run all non-live tests in one invocation:

```bash
./build.sh - test gen_test wire_test marshal_test unmarshal_test compile_test
```

Live compositor / GPU examples:

```bash
./build.sh - hello_globals
./build.sh - hello_screens
./build.sh - hello_window
./build.sh - dump_keymap
./build.sh - headless_gl
./build.sh - headless_vulkan
./build.sh - headless_vulkan_dmabuf
./build.sh - x11_smoke
./build.sh - hello_x11_gl
./build.sh - hello_dmabuf
./build.sh - hello_gl
./build.sh - hello_vulkan_dmabuf
./build.sh - invaders
```

The lone `-` separates Jai compiler arguments from metaprogram arguments. Do not
repeat it before each target.

## Architecture

- `first.jai` is the build metaprogram. It creates compiler workspaces and uses
  `Autorun` for test executables.
- `src/xml.jai` is a zero-copy XML pull parser.
- `src/protocol.jai` turns Wayland XML into protocol data structures.
- `src/generator.jai` and `src/generate_main.jai` generate Jai bindings in
  `modules/wayland/`.
- `modules/wayland/wire.jai` contains primitive wire encoding helpers.
- `modules/wayland/connection.jai` owns the socket, object ID allocator,
  `MessageBuilder`, `ReceiveBuffer`, and `sendmsg`/`recvmsg` fd passing.
- `modules/wayland/marshal.jai` and `modules/wayland/unmarshal.jai` are
  compile-time macro systems using `#expand` plus `#insert #run` over
  `type_info`.
- `modules/wayland/session.jai` provides the `WaylandSession` context and
  `for session()` event-loop expansion.
- `modules/gpu` owns render-node discovery/selection, GBM BO allocation, and
  EGLImage import policy for Mesa, NVIDIA, and hybrid machines.
- `modules/EGL`, `modules/gbm`, `modules/GL`, `modules/Vulkan`, and
  `modules/X11` are low-level runtime-loaded bindings. Keep them free of
  `#foreign` declarations that force linkage.
  `modules/Vulkan/linux_drm_format_modifier.jai` supplements the stock Jai
  Vulkan headers for Linux DMA-BUF export.
- `modules/X11` vendors Jai's stock `X11/module.jai` without `X11/sofd`.
  Xlib and GLX entry points are function-pointer variables loaded by
  `init_x11()` / `init_glx()`. This module is a compatibility backend for
  future vendored `Window_Creation` / `Simp` / `GetRect`, not part of the
  Wayland wire-protocol implementation. Also exports
  `glx_create_context(window, major, minor)` ported from upstream
  `~/jai/jai/modules/GL/GL.jai` so vendored Simp's GLX context creation
  works without vendoring stock GL (which would introduce `#foreign`
  linkage).
- `modules/Window_Creation`, `modules/Simp`, `modules/GetRect`, and
  `modules/GetRect_LeftHanded` are upstream Jai distribution modules
  vendored verbatim from `~/jai/jai/modules/` for compatibility with
  upstream graphical examples. Three minimal patch sites:
  `modules/X11/module.jai` self-initializes in `init_global_display`;
  `modules/Simp/backend/gl.jai` uses our `gl_load(glXGetProcAddress)`
  signature; `modules/Simp/bitmap.jai` and
  `modules/Sound_Player/cached_decoder.jai` get `init_stb_*()` lazy-init
  calls at the entry points that consume the runtime-loaded stb_image /
  stb_image_write / stb_image_resize / stb_vorbis function pointers.
  `./build.sh - invaders` compiles upstream's
  `~/jai/jai/examples/invaders/source/invaders.jai` against these.
- `modules/stb_image`, `modules/stb_image_write`, `modules/stb_image_resize`,
  `modules/stb_vorbis`, and `modules/Sound_Player` are runtime-loaded
  image/audio modules needed by Simp + invaders. They replace upstream's
  `#library` / `#foreign` declarations with `dlopen` + `dlsym`. The three
  `stb_*` modules that call libm symbols (stb_image, stb_image_resize,
  stb_vorbis) also dlopen `libm.so.6` with `RTLD_GLOBAL` so their bundled
  `.so` files (which call `pow` / `cos` / `floor` without a `DT_NEEDED
  libm`) can resolve math symbols at runtime, preserving the ldd-clean
  invariant. (stb_image_write has no libm symbols and skips that step.)

## Core Invariants

- Do not add `libwayland-client` usage.
- Do not use `VK_KHR_wayland_surface` with jai-wayland object IDs directly: the
  extension expects real `libwayland-client` `wl_display*` and `wl_surface*`
  proxy objects, not wire-protocol IDs. Prefer Vulkan external-memory /
  DMA-BUF export unless an explicit compatibility shim is designed.
- Do not add hard-linked `#library` / `#foreign` dependencies for GPU or window
  libraries.
- Preserve the `ldd build/hello_gl` invariant: no `libEGL`, `libgbm`, `libGL`,
  `libwayland`, `libX11`, or `libxcb`. Preserve the matching
  `ldd build/headless_vulkan` invariant: no `libvulkan`.
- Preserve the `ldd build/x11_smoke` invariant: no `libX11`, `libGLX`,
  `libGL`, or `libxcb`.
- Preserve the matching `ldd build/hello_x11_gl` invariant: no `libX11`,
  `libGLX`, `libGL`, or `libxcb`. Use `JAI_WAYLAND_X11_GL_FRAMES=N` for
  bounded live smoke runs.
- `hello_vulkan_dmabuf` is the first live Vulkan presentation smoke: Vulkan
  renders a rotating triangle into DRM-modifier images, exports them as DMA-BUF,
  wraps them as Wayland `wl_buffer` objects, and presents them through
  double-buffered, frame-paced, resize-safe slots. `first.jai` compiles its GLSL
  shaders with `glslc`; use `JAI_WAYLAND_VULKAN_FRAMES=N` for bounded smoke
  runs.
- Application code owns the event loop. Do not introduce callback-driven proxy
  managers or hidden event queues.
- Requests are message-shaped: build into `MessageBuilder`, then explicitly send.
- Generated interface structs are lightweight object handles, primarily `id:
  u32`.
- Constructor request functions take caller-provided `new_id`; do not allocate
  object IDs inside generated request functions.

## Jai Patterns And Gotchas

- `marshal` and `unmarshal` are not normal runtime functions. They are
  `#expand` macros that emit specialized serialization/deserialization code for
  the concrete arg/event struct type.
- `Fd` is a distinct `s32` type and is passed out-of-band via `SCM_RIGHTS`, not
  in the byte payload.
- Client-allocated Wayland IDs must be monotonic in wire-send order. Allocate an
  ID immediately before queueing the request that creates that object.
- Opcodes are per-interface, not global. Always route events by object ID first,
  then opcode. Many unrelated Wayland events have opcode `0`.
- The `for session()` expansion uses `defer` to consume messages even when loop
  bodies `continue`. Do not move cleanup after `#insert body` unless it is also
  protected by `defer`.
- Jai `cast` binds looser than `<<`. Use explicit parentheses for bit packing:
  `((cast(u32) b) << 8)`.

## Generated Code

Most files under `modules/wayland/<protocol>/` are generated. Prefer changing
`src/generator.jai` and regenerating with:

```bash
./build.sh - generate
```

Generated destructor functions currently contain lifecycle-manager TODO
comments. That does not mean the wire request is missing; this project
intentionally has no proxy lifecycle manager.

## Tests

Test style is simple named procedures with `assert()` and `print("  PASS: ...")`
from `main()`.

Use focused tests first:

- Parser changes: `./build.sh - test`
- Generator changes: `./build.sh - gen_test`, then `./build.sh - generate`,
  then `./build.sh - compile_test`
- Wire encoding changes: `./build.sh - wire_test`
- Marshal changes: `./build.sh - marshal_test`
- Unmarshal changes: `./build.sh - unmarshal_test`
- Generated binding smoke checks: `./build.sh - compile_test`

For substantial changes, run:

```bash
./build.sh - test gen_test wire_test marshal_test unmarshal_test compile_test
```

## Current Roadmap

Known future areas:

- Explicit sync / syncobj integration.
- Deeper Vulkan examples beyond the triangle DMA-BUF smoke path.
- Vulkan WSI compatibility shim, if a future layer needs swapchains.
- Vendored `Window_Creation`, `Simp`, `GetRect`, and `GetRect_LeftHanded` with
  Linux runtime backend selection between Wayland and X11. Phase 6 in
  progress: upstream `invaders` is playable via `./build.sh - invaders`
  against our vendored stack on X11 (ldd-clean). **Wayland backend dispatch
  within Window_Creation is the remaining ~70% of the work and the design
  question is open** — see `docs/plans/2026-05-26-wayland-backend-question.md`.
  The load-bearing decision is how GL actually works on Wayland under our
  "no libwayland linkage" thesis (same fundamental incompatibility as
  `VK_KHR_wayland_surface`).
- Server-allocated Wayland object IDs.
- Fractional scaling.
- Higher-level "raylib-light" ergonomic layer.
