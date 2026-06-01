# AGENTS.md

> **Built with Jai `beta 0.2.029`** (compiler built 25 April 2026) — the most recent version everything here was compiled and tested against.
>
> **A note on paths:** code and documentation hard-code `~/jai/jai` as the unpacked Jai distribution — that's just where I unpacked mine. In your clone/fork, update this path (in `build.sh` and throughout the docs) to point to your own distribution.

## Project Overview

`jai-wayland` is a Wayland client library for Jai. It bypasses
`libwayland-client` and speaks the Wayland wire protocol directly over a Unix
socket. Display-server and GPU libraries are loaded at runtime with `dlopen` and
function pointers; do not introduce hard link-time dependencies on Wayland, X11,
xcb, EGL, gbm, GL/GLX, or Vulkan.

Current status: phases 1-5 are complete, including NVIDIA/hybrid GPU support,
plus Vulkan DMA-BUF presentation and Phase 6's vendored upstream window/graphics
stack on Wayland. The primary GL path is GBM BO-backed: select a DRM render
node, allocate a `gbm_bo`, import it as an `EGLImage`, bind it to a GL
texture/FBO, export the BO fd/stride/offset/modifier, and present it through
`zwp_linux_dmabuf_v1`. The older Mesa `EGL_MESA_image_dma_buf_export`
texture-export path remains as a fallback.

The vendored `Window_Creation` / `Simp` / `Input` / `Clipboard` / `GetRect`
stack now runs on Wayland through `modules/Wayland_Support.jai`, with runtime
selection between Wayland and X11 by value (`Display_Manager` /
`running_wayland()`), not compile-time Linux branches or the old
`context.simp_dispatch` plan. Current examples cover SHM windows, GL and Vulkan
DMA-BUF presentation, runtime-loaded X11/GLX, async triple-buffered Simp present,
keyboard/pointer/touch-structural input, XKB keysyms, text clipboard,
drag-and-drop, compositor resize, and upstream-unmodified graphical examples.

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
./build.sh - generate
./build.sh - wire_test
./build.sh - xkb_test
./build.sh - marshal_test
./build.sh - unmarshal_test
./build.sh - compile_test
```

To run all non-live tests in one invocation:

```bash
./build.sh - test gen_test wire_test xkb_test marshal_test unmarshal_test compile_test
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
./build.sh - hello_simp
./build.sh - hello_clipboard
./build.sh - invaders
./build.sh - skeletal_animation
./build.sh - getrect_example
./build.sh - getrect_lh_example
./build.sh - treemap
./build.sh - codex_view
./build.sh - simp_example
./build.sh - simp_multiple_windows
./build.sh - simp_render_to_texture
./build.sh - compile_only <target>
```

The lone `-` separates Jai compiler arguments from metaprogram arguments. Do not
repeat it before each target.
`compile_only` must appear before the target; use it as the headless compile
gate for GUI examples that would otherwise open a live window.
The `treemap` target stages `OpenSans-BoldItalic.ttf` next to `build/treemap`.
The `codex_view` target stages `data/`, `codex_view.codex`, and
`sokoban.codex` next to `build/codex_view`.
The `simp_example` target stages `OpenSans-BoldItalic.ttf` and
`image_test.jpg`; `simp_multiple_windows` stages `OpenSans-BoldItalic.ttf`.

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
  `init_x11()` / `init_glx()`. This module is the X11 compatibility backend for
  the vendored `Window_Creation` / `Simp` / `GetRect` stack, not part of the
  Wayland wire-protocol implementation. Also exports
  `glx_create_context(window, major, minor)` ported from upstream
  `~/jai/jai/modules/GL/GL.jai` so vendored Simp's GLX context creation
  works without vendoring stock GL (which would introduce `#foreign`
  linkage).
- `modules/Wayland_Support.jai` is the Phase 6 support layer above the pure
  `wayland` wire module. It is the Wayland analogue of `modules/X11`: shared
  module-scope globals plus the single `wl_pump` that drains the compositor
  connection and routes render, resize, input, data-device, clipboard, and
  drag-and-drop events. It owns `wayland_global_windows`, the shared
  EGL/GBM/GL context used by all Simp Wayland windows, per-window BO slots and
  dmabuf choices, triple-buffered async `wl_present_and_pace`, the parsed
  keymap, acquired seats/devices, and the stable `Wl_Input_Event` queue
  consumed by `Input`.
- `modules/Window_Type.jai` vendors the upstream Linux window type as a tagged
  union (`X11 | Wayland`) with equality overloads and the shared
  `wayland_drag_and_drop_requested` opt-in flag used by X11 and Wayland paths.
- `modules/Window_Creation`, `modules/Simp`, `modules/Input`, `modules/GetRect`,
  `modules/GetRect_LeftHanded`, and `modules/Clipboard` are Jai distribution
  modules vendored for compatibility with upstream graphical examples. Linux
  patch sites keep their public shape while routing by runtime backend value:
  `Window_Creation/linux.jai` chooses Wayland vs X11 with `WS.running_wayland()`;
  `Simp/backend/gl.jai` branches on `context.simp.specific.display_manager`;
  `Simp/backend/{x11_dispatch,wayland_dispatch}.jai` hold the per-op backend
  glue; `Input/wayland.jai` drains `Wayland_Support` events; `Clipboard` routes
  no-arg text clipboard calls to `Wayland_Support` under Wayland.
- `stb_image`, `stb_image_write`, `stb_image_resize`, `stb_vorbis`, and
  `Sound_Player` are not vendored here. Upstream examples resolve those through
  the Jai distribution via the `modules`-first import path. Their normal
  `libm` / `libasound` linkage is allowed because those are not display-server
  or GPU-driver libraries.

## Core Invariants

- Do not add `libwayland-client` usage.
- Do not use `VK_KHR_wayland_surface` with jai-wayland object IDs directly: the
  extension expects real `libwayland-client` `wl_display*` and `wl_surface*`
  proxy objects, not wire-protocol IDs. Prefer Vulkan external-memory /
  DMA-BUF export unless an explicit compatibility shim is designed.
- Do not add hard-linked `#library` / `#foreign` dependencies for display-server
  or GPU-driver libraries. Universal Linux libraries such as `libm`, `libasound`,
  and `libstdc++` are allowed when pulled by upstream-compatible modules.
- Preserve the `ldd build/hello_gl` invariant: no `libEGL`, `libgbm`, `libGL`,
  `libwayland`, `libX11`, or `libxcb`. Preserve the matching
  `ldd build/headless_vulkan` invariant: no `libvulkan`.
- Preserve the `ldd build/x11_smoke` invariant: no `libX11`, `libGLX`,
  `libGL`, or `libxcb`.
- Preserve the matching `ldd build/hello_x11_gl` invariant: no `libX11`,
  `libGLX`, `libGL`, or `libxcb`. Use `JAI_WAYLAND_X11_GL_FRAMES=N` for
  bounded live smoke runs.
- Preserve the vendored-stack linkage invariant for `hello_simp`,
  `hello_clipboard`, `invaders`, `anim`, `getrect_example`,
  `getrect_lh_example`, `treemap`, `codex_view`, `simp_example`,
  `simp_multiple_windows`, and `simp_render_to_texture`: no `libwayland`,
  `libX11`, `libxcb`, `libGL`, `libGLX`, `libEGL`, `libgbm`, or
  `libvulkan`. `libm` and invaders' `libasound` linkage are expected.
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
- `Wayland_Support` is the only event pump for the vendored Wayland backend.
  Keep Simp/Input/Window_Creation sharing the same name-based import instance;
  do not split the compositor connection or create hidden queues.

## Jai Patterns And Gotchas

- `marshal` and `unmarshal` are not normal runtime functions. They are
  `#expand` macros that emit specialized serialization/deserialization code for
  the concrete arg/event struct type.
- `Fd` is a distinct `s32` type and is passed out-of-band via `SCM_RIGHTS`, not
  in the byte payload.
- Client-allocated Wayland IDs must be monotonic in wire-send order. Allocate an
  ID immediately before queueing the request that creates that object.
- Some compositors effectively require contiguous client IDs with no gaps. Do
  not pre-reserve object ID ranges; use the existing short-lived ID cache pattern
  only after an object has been destroyed.
- Server-allocated object IDs arrive inside events (for example `wl_data_offer`
  during data-device handling) and flow through `unmarshal`'s `*Interface` path.
  Do not allocate those IDs client-side.
- Opcodes are per-interface, not global. Always route events by object ID first,
  then opcode. Many unrelated Wayland events have opcode `0`.
- The `for session()` expansion uses `defer` to consume messages even when loop
  bodies `continue`. Do not move cleanup after `#insert body` unless it is also
  protected by `defer`.
- Jai `cast` binds looser than `<<`. Use explicit parentheses for bit packing:
  `((cast(u32) b) << 8)`.
- Phase 6 backend selection is a runtime value: `WS.Display_Manager` /
  `running_wayland()`. Do not reintroduce the deleted `context.simp_dispatch`
  function-pointer dispatcher or Linux-only inline backend bodies.
- Wayland input synthesizes key autorepeat from `wl_keyboard.repeat_info` and
  suppresses `TEXT_INPUT` under Ctrl/Alt/Meta command chords. Preserve both when
  touching keyboard paths.
- The XKB parser must handle both compact hex lists and named-key `symbols[N]`
  group forms (`F4`, `Escape`, `Alt_L`, etc.). Physical Alt+F4 under Hyprland
  depends on this.
- The X11 backend selected `MotionNotify` from the start; keep translating it
  into `mouse_delta_x/y` with enter/leave baselining so XWayland camera control
  paths continue to work.
- Use `JAI_WAYLAND_LOG_KEYS=1` for temporary Wayland keyboard traces. It logs
  raw `wl_keyboard` keys/modifiers and the final `Input` key events.
- `wl_present_and_pace` is asynchronous and triple-buffered: it throttles on the
  previous frame callback. Do not restore the old synchronous wait-on-this-frame
  present path.
- Simp's Wayland GL context is process-global, matching Simp's process-global
  shader/VBO/font GL objects and the X11 backend's single GLX context. Do not
  put `Wl_Egl_State` back on `Wayland_Window`; that struct owns per-window
  surface roles, BO slots, dmabuf format/modifier, resize/close state, and
  frame pacing only.
- `wl_present_and_pace` must yield back to the app when configure/close arrives
  while waiting on a previous frame callback. Hyprland can withhold the callback
  until the client handles the configure; continuing to wait stalls animation,
  resize handling, and compositor close on multi-window Simp examples.
- `create_window_wayland` can receive configure/close events for already
  registered windows while synchronously waiting for a new window's first
  configure. Route those through `Wayland_Support` rather than consuming and
  dropping them.
- Code under `modules/` should use `log` / `log_error`, not `print`; examples
  may still print user-facing diagnostics.

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
- XKB keymap parser changes: `./build.sh - xkb_test`, then
  `./build.sh - dump_keymap` against the live compositor when useful.
- Marshal changes: `./build.sh - marshal_test`
- Unmarshal changes: `./build.sh - unmarshal_test`
- Generated binding smoke checks: `./build.sh - compile_test`
- Vendored GUI stack compile gates:
  `./build.sh - compile_only hello_simp`,
  `./build.sh - compile_only hello_clipboard`,
  `./build.sh - compile_only invaders`,
  `./build.sh - compile_only skeletal_animation`,
  `./build.sh - compile_only getrect_example`,
  `./build.sh - compile_only getrect_lh_example`,
  `./build.sh - compile_only treemap`,
  `./build.sh - compile_only codex_view`,
  `./build.sh - compile_only simp_example`,
  `./build.sh - compile_only simp_multiple_windows`,
  `./build.sh - compile_only simp_render_to_texture`
- Bounded live smokes use frame caps where available:
  `JAI_WAYLAND_SIMP_FRAMES=N ./build.sh - hello_simp`,
  `JAI_WAYLAND_CLIPBOARD_FRAMES=N ./build.sh - hello_clipboard`,
  `JAI_WAYLAND_X11_GL_FRAMES=N ./build.sh - hello_x11_gl`,
  `JAI_WAYLAND_VULKAN_FRAMES=N ./build.sh - hello_vulkan_dmabuf`

For substantial changes, run:

```bash
./build.sh - test gen_test wire_test xkb_test marshal_test unmarshal_test compile_test
```

## Current Roadmap

Known future areas:

- Explicit sync / syncobj integration.
- Deeper Vulkan examples beyond the triangle DMA-BUF smoke path.
- Vulkan WSI compatibility shim, if a future layer needs swapchains.
- Clipboard bitmaps on the Wayland backend.
- AltGr / level-3 keysyms and `wp_relative_pointer_v1` support.
- Touch runtime validation on real hardware.
- Fractional scaling.
- Tiling-WM floating-widget first-size compatibility quirk, if we decide to add
  the documented default-off opt-in.
- Higher-level "raylib-light" ergonomic layer.
