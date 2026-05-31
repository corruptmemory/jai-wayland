# jai-wayland

Wayland client support for the [Jai](https://jai.community/) programming language.

> **Built with Jai `beta 0.2.029`** (compiler built 25 April 2026) — the most recent version everything here was compiled and tested against.
>
> **A note on paths:** some code and documentation reference a hard-coded path to the unpacked Jai distribution, `~/jai/jai` — but that's just where I unpacked mine. Please update this path in your clone/fork (in `build.sh` and throughout the docs) to point to your own distribution.

## Design

This library takes the same approach as [zig-wayland](https://github.com/ifreund/zig-wayland) and [wayland-rs](https://github.com/Smithay/wayland-rs): bypass `libwayland-client.so` entirely and speak the Wayland wire protocol directly.

**Key decisions:**

- **No libwayland dependency.** The Wayland wire protocol is simple — structured messages over a Unix socket with fd passing via `sendmsg`/`recvmsg`. No reason to link a C library for that.
- **No hard-linked shared objects.** Like many OpenGL and Vulkan loaders, we use function pointer tables populated at runtime via `dlopen`. Nothing shows up under `ldd`.
- **Code generation from protocol XML.** Wayland protocols are defined in XML files. We parse them and generate Jai bindings — interface structs, opcode constants, and dispatch tables.
- **Compile-time marshalling.** Request functions use a compile-time `marshal` macro that walks arg struct types via `type_info` and emits specialized serialization code. Zero runtime reflection, zero branches — just raw stores.

## Status

**Phase 1 (complete):** XML parser and protocol data model.

- Zero-copy pull parser for XML (~290 lines)
- Protocol data model: `Protocol`, `Interface`, `Message`, `Arg`, `Enum_Def`, `Entry`
- Parses all 59 vendored protocol XML files (189 interfaces) with zero failures

**Phase 2 (complete):** Code generator — emit Jai source from parsed protocols.

- Standalone tool reads protocol XML and emits idiomatic Jai source files
- Per-interface files with typed structs, opcode constants, event tagged unions, enum definitions, and request functions
- Full protocol descriptions as doc comments for traceability to the spec
- 56 protocols, 175 interfaces in `modules/wayland/`
- 92 tests across 5 test suites

**Phase 3 (complete):** Wire protocol — message framing, compile-time marshalling, fd passing.

- `inline` primitive writers for native-endian 4-byte-aligned wire encoding
- `marshal` / `unmarshal` macros: `#expand` + `#insert #run generate_marshal_code(type_info(T))` — walk arg struct fields at compile time, emit type-specific (de)serialization code
- `marshal_constructor` variant: caller provides pre-allocated object ID, writes it as first arg
- `Fd :: #type,distinct s32` — file descriptors tagged for the compile-time walker, routed to `SCM_RIGHTS` out-of-band
- Split types: `Connection` (socket + ID allocator), `MessageBuilder` (outgoing batch, string-builder pattern), `ReceiveBuffer` (incoming). `sendmsg`/`recvmsg` with `SCM_RIGHTS` ancillary data.
- Object ID allocator (client IDs from 1, incrementing, monotonic-on-wire)
- Generated request functions call `marshal()` / `marshal_constructor()` targeting `*MessageBuilder`

**Phase 4 (complete):** Client API — no inversion of control, full input + windowing.

- **Design principle: simple things MUST be simple.** Application owns the event loop. No callbacks, no dispatch tables, no event queues, no proxy lifecycle manager.
- `WaylandSession` — holds `Connection`, `ReceiveBuffer`, bound globals (compositor, wm_base); lives in `#add_context wayland_session: *WaylandSession`. `for session()` for-expansion yields `WaylandMessageHeader` and transparently handles ping/pong + `wl_display.error`.
- Global discovery: `discover_globals()` performs `wl_display.get_registry` + sync roundtrip and returns all compositor globals. Type registry for automatic version negotiation in `wl_registry_bind`.
- Screen discovery: `get_screens_info()` — binds every `wl_output`, returns `[] Screen_Info` with modes, scale, geometry.
- Seat-based input: `get_seats_info()` → `get_keyboards_info(seats)` + `get_pointers_info(seats)`. `get_keyboard_event` / `get_pointer_event` route incoming messages by object ID into tagged-union events. Works for multi-seat setups.
- XKB keymap parsing (`xkb.jai`): mmap's the keymap fd from `wl_keyboard.keymap`, parses the xkb text format into a 768-entry evdev→keysym lookup table. Layout-independent keysyms replace raw scancodes.
- `wl_shm` path with pooled buffers sized to the native screen resolution, so resize is a cheap `wl_buffer` re-describe (no remap, no syscalls).
- Double-buffered painting: two `Buffer_Slot` records carve the pool at offsets `0` and `frame_max_bytes`. Paint picks a non-in-flight slot; `wl_buffer.release` events free slots. Persistent `dirty` flag queues paints when both slots are in flight.
- Examples:
  - `hello_globals.jai` — prints all compositor globals (~20 lines)
  - `hello_screens.jai` — prints each output's modes, scale, geometry (~30 lines)
  - `hello_window.jai` — double-buffered resizable window, keyboard (r/g/b/q keysyms) + pointer (click cycles color), dynamic resize (~220 lines)
  - `dump_keymap.jai` — diagnostic: prints evdev→keysym mappings from the live compositor's keymap
- 111 tests across 6 test suites (xml, generator, wire, marshal, unmarshal, compile)
- Tested live against Hyprland compositor on Artix Linux

**Phase 5 (complete, Mesa + NVIDIA/hybrid):** GPU rendering via OpenGL 3.3 core, end-to-end GL → DMA-BUF → Wayland without any libwayland or libGL linkage.

- **Vendored GPU bindings** — `modules/EGL/`, `modules/gbm/`, `modules/GL/`. Same pattern as the Wayland wire code: types + constants + function-pointer variable declarations in one file, `init_X()` loader in another (`dlopen` + `dlsym`). No `#foreign`, no build-time linkage. We vendor our own minimal GL instead of using Jai's stock GL module because Jai's `glad_core.jai` hard-links `libGL` and its `GL.jai` imports `Window_Type` which pulls in X11 transitively.
- **GPU selection** — `modules/gpu/` discovers DRM render nodes, reads vendor IDs, and supports `JAI_WAYLAND_RENDER_NODE=/dev/dri/renderD129` or `JAI_WAYLAND_GPU_VENDOR=nvidia|intel|amd` overrides. The default policy preserves the first usable render node.
- **EGL setup** — `EGL_PLATFORM_GBM_KHR` on a non-privileged DRM render node. GL 3.3 core context, surfaceless (render to FBOs, never bind a surface).
- **Primary DMA-BUF path** — GBM BO-backed render targets: allocate `gbm_bo`, import it as an `EGLImage`, bind it to a GL texture with `glEGLImageTargetTexture2DOES`, render through an FBO, then export the BO fd/stride/offset/modifier to Wayland. Mesa uses `EGL_NATIVE_PIXMAP_KHR`; NVIDIA falls back to `EGL_LINUX_DMA_BUF_EXT` import because proprietary NVIDIA rejects native pixmap import.
- **Fallback DMA-BUF path** — the older Mesa texture-export route remains available: `eglCreateImageKHR(EGL_GL_TEXTURE_2D_KHR, tex)` plus `EGL_MESA_image_dma_buf_export`.
- **wl_buffer from DMA-BUF** — `modules/wayland/dmabuf.jai` discovers compositor formats via `zwp_linux_dmabuf_v1` and, when available, `zwp_linux_dmabuf_feedback_v1` per-surface tranches. `hello_gl` filters feedback through GBM device capability before creating `wl_buffer` objects with `zwp_linux_buffer_params_v1.add/create_immed`.
- **Frame pacing** — `wl_surface.frame` callbacks gate the next render to compositor vsync. `wl_callback.done` clears the `frame_requested` flag and lets the render defer re-fire.
- **Double-buffered and resize-safe** — two `Gl_Slot` records (each holding `tex` + `fbo` + `EGLImage` + optional `gbm_bo` + DMA-BUF fd + `wl_buffer`) rotate on `wl_buffer.release`. Resizes retire in-flight slots and destroy them only after their release event arrives.
- **Input** — the Phase 4 seat/keyboard/pointer/xkb helpers plug directly into the GL render loop unchanged.
- **`ldd build/hello_gl`** — `libc.so.6` only. Zero hard-linkage to libEGL, libgbm, libGL, libwayland, libX11, libxcb.
- **Vulkan binding baseline** — `modules/Vulkan/` vendors Jai's stock Vulkan module, with generated commands converted from `#foreign libvulkan` declarations into runtime-loaded `PFN_vk*` function-pointer variables. `init_vulkan()` loads the platform loader with `dlopen` / `LoadLibrary`, then populates global, instance, and device commands through `vkGetInstanceProcAddr` / `vkGetDeviceProcAddr`. Convenience enumeration wrappers are retained with `_Array` suffixes to avoid colliding with raw command pointers.
- **Vulkan DMA-BUF baseline** — `headless_vulkan_dmabuf.jai` creates a Vulkan image using `VK_EXT_image_drm_format_modifier`, allocates exportable external memory, binds it, and exports the image memory as a DMA-BUF fd via `vkGetMemoryFdKHR`. This is the project-compatible Vulkan presentation direction. `VK_KHR_wayland_surface` expects `libwayland-client` `wl_display*` / `wl_surface*` proxy objects, not jai-wayland wire IDs, so direct WSI swapchains are intentionally not the first path.
- **Vulkan presentation smoke** — `hello_vulkan_dmabuf.jai` creates a real Wayland window, selects a compositor-compatible DRM modifier from dmabuf surface feedback, renders a rotating RGB triangle through a Vulkan graphics pipeline, releases images to `VK_QUEUE_FAMILY_EXTERNAL`, exports their fds, creates `wl_buffer` objects, and presents them through double-buffered, frame-paced, resize-safe slots. `first.jai` compiles its GLSL shaders with `glslc`. Set `JAI_WAYLAND_VULKAN_FRAMES=N` for bounded live smoke runs.
- **X11 compatibility binding baseline** — `modules/X11/` vendors Jai's stock `X11/module.jai` without `X11/sofd`, converts Xlib/GLX `#foreign` calls into runtime-loaded function pointers, and exposes `init_x11()` / `init_glx()` loaders. This is separate from the Wayland implementation and is intended for future vendored `Window_Creation` / `Simp` / `GetRect` Linux backend selection. `x11_smoke.jai` and `hello_x11_gl.jai` verify Xlib/GLX loading and GL rendering without `libX11`, `libGLX`, `libGL`, or `libxcb` under `ldd`. Set `JAI_WAYLAND_X11_GL_FRAMES=N` for bounded `hello_x11_gl` smoke runs.
- **Examples added:**
  - `headless_gl.jai` — EGL/GL/gbm smoke test (BO-backed FBO readback + DMA-BUF export, no Wayland)
  - `headless_vulkan.jai` — Vulkan loader smoke test (no Wayland, no link-time libvulkan)
  - `headless_vulkan_dmabuf.jai` — Vulkan external-memory / DMA-BUF export smoke test
  - `x11_smoke.jai` — Xlib/GLX runtime-loader smoke test (no Wayland, no link-time X11/GLX)
  - `hello_x11_gl.jai` — rotating GL triangle in an X11/GLX window through runtime-loaded Xlib/GLX/GL
  - `hello_dmabuf.jai` — prints the compositor's advertised format/modifier table plus dmabuf feedback snapshots
  - `hello_gl.jai` — rotating RGB triangle in a resizable Wayland window with keyboard + pointer input (the Phase 5 + NVIDIA shippable milestone)
  - `hello_vulkan_dmabuf.jai` — rotating Vulkan triangle → DMA-BUF → Wayland presentation smoke test
- **Tested live against Hyprland + Mesa radeonsi on AMD and on a hybrid Intel iGPU + NVIDIA dGPU laptop.**

**Phase 6 (complete):** Vendored upstream window/graphics stack on Wayland — `Window_Creation` / `Simp` / `Input` / `GetRect` run on the Wayland backend, picking X11 vs Wayland by runtime *value*, not link-time `#if`.

- **`modules/Wayland_Support.jai`** — the GPU-aware support layer above the pure wire `wayland` module, imported by name from Simp/Input/Window_Creation. The Wayland analogue of `modules/X11`: a bag of shared module-scope globals (the `wayland_global_windows` registry, the acquired keyboard/pointer/touch/data-device, the parsed keymap) plus the SINGLE event pump (`wl_pump`) that drains the one compositor connection and routes every message — render (frame callback / buffer release / configure / close) and input (decoded into stable `Wl_Input_Event`s) — in one pass. Backend selection is a `Display_Manager` enum value branched at the backend op sites, replacing the earlier `context.simp_dispatch` function-pointer indirection.
- **Full input** — keyboard (modifier-aware xkb keysyms + `TEXT_INPUT`, client-synthesized **autorepeat** replayed at the compositor's `wl_keyboard.repeat_info` rate since Wayland sends no repeat events, and **command-chord suppression** so `Ctrl`/`Alt`/`Meta` + key never inserts a literal character — e.g. `Ctrl+C`/`V`/`X` in a text field), pointer (motion / buttons / wheel / focus), structural touch, compositor-driven resize (`Window_Resize_Record`s), and `.QUIT` / Alt+F4 / close-button quit.
- **Drag-and-drop** — `wl_data_device` file drops: the pump decodes the drag session (server-allocated `wl_data_offer` ids ride through `unmarshal`'s `*Interface` path), pipes the `text/uri-list` transfer over `SCM_RIGHTS` on drop, and emits `Event.DRAG_AND_DROP_FILES` — full parity with X11's `enable_drag_and_drop`. Verified by dropping a file from PCManFM-Qt onto the GetRect example.
- **Clipboard copy/paste** — text selection over the same `wl_data_device`, backing the vendored `Clipboard` module's `os_clipboard_get_text` / `set_text` (so GetRect's text-input Ctrl+C/V works). Paste reads the current selection offer; copy owns the selection via a `wl_data_source` and serves `send` requests. Verified end-to-end with `wl-copy` / `wl-paste` + `wtype` against the `hello_clipboard` example.
- **Four upstream-unmodified graphical examples run on Wayland** — `invaders` (2D game), `skeletal-animation` (3D depth-tested skinned mesh + GetRect UI), and the `GetRect` / `GetRect_LeftHanded` immediate-mode widget showcases. Each links zero display-server/GPU libs (`libm` + invaders' `libasound` only — verify with `ldd build/{invaders,getrect_example}`).
- **Project Phase 6 smoke examples** — `hello_simp.jai` (vendored Simp + Input on Wayland: an animated quad, compositor-driven resize, `q` to quit) and `hello_clipboard.jai` (clipboard copy/paste through the vendored `Clipboard` module — `c` copies, `p` pastes, `q` quits). `hello_clipboard` also echoes every key press and `TEXT_INPUT` char with its modifier + autorepeat flags, which doubles as the keyboard input smoke test for autorepeat and command-chord suppression. Both accept a `JAI_WAYLAND_{SIMP,CLIPBOARD}_FRAMES=N` cap for bounded headless runs.

**Known gaps (next phases):**
- **Clipboard bitmaps** — `os_clipboard_set_bitmap` is a logged no-op on the Wayland backend; text copy/paste works.
- **Explicit fence sync** — current GL presentation uses `glFinish()` before handing buffers to the compositor. `Gl_Slot` has placeholder fence fd fields for future `EGL_KHR_fence_sync` / `wp_linux_drm_syncobj_v1` work. (Profiling note, 2026-05-31: the present path is *not* the frame-rate bottleneck — `glFinish` ≈0.68 ms and the vsync block ≈3.3 ms per frame, versus ~28.5 ms of backend-agnostic GetRect+Simp CPU work that caps **both** X11 and Wayland at ~30–34 fps. Fence sync is a minor cleanup, not a smoothness fix; the perceived X11-vs-Wayland difference is the ~4 ms present overhead plus vsync-coupling jitter. See `CLAUDE.md` Next Steps for the full breakdown.)
- **Explicit Vulkan/Wayland sync**, **AltGr / level-3 keysyms**, **`wp_relative_pointer_v1`**, **fractional scaling** — see `CLAUDE.md` Next Steps.
- **Tiling-WM floating-widget sizing (curiosity, not a rendering bug).** Under a tiling compositor that force-resizes a window away from its requested size (e.g. Hyprland tiling a 1920×1080 request to fill a tile), GetRect's once-baked floating sub-windows render larger on the Wayland backend than on XWayland / Windows / macOS — the per-frame UI (title, background) is pixel-identical. Cause is first-frame ordering: xdg-shell makes our Wayland `create_window` learn the forced size *synchronously* (wait-for-configure-before-map), so the app bakes its sub-windows against it on frame 1, whereas X11/Win/macOS deliver the forced size as an *asynchronous* resize processed *after* the first bake. It vanishes entirely when the window opens at its requested size (any floating/stacking WM — verified). A future opt-in `JAI_WAYLAND_ENABLE_TM_QUIRKS` would defer Wayland's first resize event by one frame to match the other platforms; **default off**, since most users run floating/stacking WMs where it can't arise. See `CLAUDE.md` Next Steps for the full mechanism.
- **Ergonomic "raylib-light" layer** on top of the raw primitives is the eventual target; the current `hello_gl.jai` is the proving ground, not the user-facing API.

## Building

Requires the Jai compiler (beta 0.2.029 — see the note at the top of this file) at `~/jai/jai/`. The Vulkan triangle
example also expects `glslc` in `PATH`; `first.jai` invokes it to compile GLSL
into SPIR-V under `build/shaders/`.

```bash
./build.sh                     # Build → build/main
./build.sh - test              # 22 XML/protocol tests
./build.sh - gen_test          # 35 generator tests
./build.sh - wire_test         # 22 wire protocol tests
./build.sh - marshal_test      # 9 marshal macro tests
./build.sh - unmarshal_test    # 12 unmarshal macro tests
./build.sh - compile_test      # 11 compilation smoke tests
./build.sh - generate          # Regenerate modules/wayland/ from protocol XML
./build.sh - hello_globals     # Build and run: print compositor globals
./build.sh - hello_screens     # Build and run: print output discovery
./build.sh - hello_window      # Build and run: resizable double-buffered shm window
./build.sh - dump_keymap       # Build and run: xkb keymap diagnostic
./build.sh - headless_gl       # Build and run: EGL/GL/gbm + DMA-BUF export smoke test
./build.sh - headless_vulkan   # Build and run: runtime-loaded Vulkan loader smoke test
./build.sh - headless_vulkan_dmabuf # Build and run: Vulkan image external-memory / DMA-BUF export smoke test
./build.sh - x11_smoke         # Build and run: runtime-loaded Xlib/GLX smoke test
./build.sh - hello_x11_gl      # Build and run: X11/GLX rotating triangle
./build.sh - hello_dmabuf      # Build and run: zwp_linux_dmabuf_v1 format discovery
./build.sh - hello_gl          # Build and run: GPU-rendered rotating triangle (GL → DMA-BUF → Wayland)
./build.sh - hello_vulkan_dmabuf # Build and run: Vulkan triangle → DMA-BUF → Wayland window
./build.sh - hello_simp        # Build and run: vendored Simp + Input smoke (animated quad, resize, q quits)
./build.sh - hello_clipboard   # Build and run: clipboard copy/paste + input echo (c copies, p pastes, q quits)
./build.sh - invaders          # Build and run: upstream invaders (2D game) on the Wayland backend
./build.sh - skeletal_animation # Build and run: upstream skeletal-animation (3D mesh + GetRect UI) on Wayland
./build.sh - getrect_example   # Build and run: upstream GetRect immediate-mode UI showcase (RIGHT_HANDED)
./build.sh - getrect_lh_example # Build and run: upstream GetRect_LeftHanded UI showcase (LEFT_HANDED)
./build.sh - compile_only <target> # Compile a target headlessly without running it (gate for GUI examples that would otherwise hang)
```

The build uses Jai's compile-time metaprogramming via `first.jai`; use the
project wrapper instead of invoking shader compilers or examples by hand. The
`invaders`, `skeletal_animation`, `getrect_example`, and `getrect_lh_example`
targets compile upstream's unmodified example sources from `~/jai/jai/examples/`
against the vendored modules.

## Project Structure

```
src/
  xml.jai            — Zero-copy XML pull parser
  protocol.jai       — Protocol data model + parser
  generator.jai      — Code generator (naming, enums, events, requests, assembly)
  generate_main.jai  — Generator entry point (file I/O, deduplication)
  main.jai           — Validation harness
tests/
  xml_test.jai       — 22 tests (parser, entities, protocol)
  generator_test.jai — 35 tests (naming, enums, events, requests, assembly)
  wire_test.jai      — 22 tests (primitive read/write, header, string/array, buffers)
  marshal_test.jai   — 9 tests (fixed args, fd, string, array, constructors)
  unmarshal_test.jai — 12 tests (round-trip, tagged union dispatch)
  compile_test.jai   — 11 tests (imports generated module, verifies types)
examples/
  hello_globals.jai  — ~20 lines: connect, discover globals, print them
  hello_screens.jai  — ~30 lines: output discovery (modes, scale, geometry)
  hello_window.jai   — ~270 lines: double-buffered resizable shm window, keyboard + pointer input, XKB keysym translation
  dump_keymap.jai    — ~55 lines: mmap keymap fd, print evdev→keysym mappings
  headless_gl.jai    — EGL/GL/gbm smoke test + BO-backed DMA-BUF export (no Wayland)
  headless_vulkan.jai — Vulkan loader smoke test (no Wayland, no libvulkan link)
  headless_vulkan_dmabuf.jai — Vulkan image + external memory + DMA-BUF fd export smoke test
  x11_smoke.jai      — Xlib/GLX runtime-loader smoke test
  hello_x11_gl.jai   — rotating GL triangle through X11/GLX runtime-loaded bindings
  hello_dmabuf.jai   — print compositor format/modifier pairs and dmabuf feedback snapshots
  hello_gl.jai       — GPU-rendered rotating triangle via GL → DMA-BUF → Wayland, BO-backed, resizable, frame-paced, keyboard + pointer input
  hello_vulkan_dmabuf.jai — rotating Vulkan triangle via DRM-modifier DMA-BUF in a Wayland window
  hello_simp.jai     — ~120 lines: vendored Simp + Input smoke (animated quad, resize, q quits)
  hello_clipboard.jai — ~105 lines: clipboard copy/paste via the vendored Clipboard module + keyboard echo (autorepeat + command-chord-suppression smoke test)
  shaders/           — GLSL sources compiled by first.jai for Vulkan examples
modules/
  wayland/           — Generated Jai bindings (56 protocols, 175 interfaces)
    module.jai       — Module root (#load chain)
    types.jai        — Shared types (Fixed, Fd, Interface_Descriptor, Wire_Arg_Type)
    wire.jai         — Wire primitives (read/write, header, string/array encoding)
    connection.jai   — Connection / MessageBuilder / ReceiveBuffer; sendmsg/recvmsg with SCM_RIGHTS
    marshal.jai      — Compile-time marshal macro (#expand + #insert #run)
    unmarshal.jai    — Compile-time unmarshal macro (event decode + tagged union dispatch)
    session.jai      — WaylandSession actor, for_expansion event loop, context-based convenience API
    registry.jai     — discover_globals, find_global, init_display helpers
    output.jai       — get_screens_info (wl_output discovery)
    input.jai        — Seat-based input: get_seats_info, get_keyboards_info, get_pointers_info
    xkb.jai          — XKB keymap parser (evdev keycode → keysym lookup)
    shm.jai          — memfd_create syscall wrapper
    dmabuf.jai       — zwp_linux_dmabuf_v1 discovery and dmabuf feedback helpers
    wayland/         — Core protocol (wl_display, wl_surface, wl_buffer, etc.)
    xdg_shell/       — XDG shell (xdg_toplevel, xdg_surface, etc.)
    ...              — 54 more protocol directories
  gpu/               — Render-node selection, GBM BO allocation, EGLImage import helpers
  EGL/               — Runtime-dlopen'd EGL 1.5 bindings (core + image/dmabuf extension entry points)
  gbm/               — Runtime-dlopen'd libgbm bindings (device + BO allocation/export helpers)
  GL/                — Runtime-dlopen'd minimal GL 3.3 core bindings (~40 entry points, loaded via eglGetProcAddress)
  Vulkan/            — Vendored Vulkan bindings with runtime-loaded PFN_vk* command pointers and Linux DRM modifier supplement
  X11/               — Vendored Xlib/GLX bindings with runtime-loaded function pointers; no sofd in first pass
  Wayland_Support.jai — Phase 6 backend layer: shared-globals window registry + single event pump (wl_pump); GL-on-GBM, DMA-BUF present, input decode, drag-and-drop + clipboard
  Window_Type.jai    — Tagged Window_Type (X11 | Wayland identity) + the drag-and-drop opt-in flag both backends share
  Window_Creation/   — Vendored upstream window creation; Linux create_window picks Wayland vs X11 by runtime value
  Simp/              — Vendored upstream Simp renderer; backend/{x11,wayland}_dispatch.jai select per-op by value
  Input/             — Vendored upstream Input; wayland.jai drains Wayland_Support's decoded input events
  GetRect/           — Vendored upstream immediate-mode UI toolkit (RIGHT_HANDED)
  GetRect_LeftHanded/ — Vendored upstream immediate-mode UI toolkit (LEFT_HANDED)
  Clipboard/         — Vendored upstream Clipboard; Linux os_clipboard_* routes to Wayland_Support under running_wayland()
vendor/
  wayland-protocols/   — Vendored protocol XML (core, stable, staging, unstable) — regenerated into modules/wayland/
  reference/           — zig-wayland and wayland-rs sources for reference
docs/plans/            — Design + implementation plan docs (one per phase/feature)
first.jai            — Build metaprogram
```

## Vendored Protocols

59 XML protocol definitions from `/usr/share/wayland/` and `/usr/share/wayland-protocols/`:

- **Core:** `wayland.xml` (23 interfaces)
- **Stable:** xdg-shell, viewporter, tablet, presentation-time, linux-dmabuf
- **Staging:** 31 protocols (cursor-shape, fractional-scale, xdg-dialog, etc.)
- **Unstable:** 20 protocols (xdg-decoration, pointer-constraints, relative-pointer, etc.)

## License

MIT
