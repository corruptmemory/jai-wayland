# jai-wayland

Wayland client support for the [Jai](https://jai.community/) programming language.

## Design

This library takes the same approach as [zig-wayland](https://github.com/ifreund/zig-wayland) and [wayland-rs](https://github.com/Smithay/wayland-rs): bypass `libwayland-client.so` entirely and speak the Wayland wire protocol directly.

**Key decisions:**

- **No libwayland dependency.** The Wayland wire protocol is simple — structured messages over a Unix socket with fd passing via `sendmsg`/`recvmsg`. No reason to link a C library for that.
- **No hard-linked shared objects.** Like many OpenGL loaders, we use function pointer tables populated at runtime via `dlopen`. Nothing shows up under `ldd`.
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
- 109 tests across 6 test suites (xml, generator, wire, marshal, unmarshal, compile)
- Tested live against Hyprland compositor on Artix Linux

**Phase 5 (complete, GL path on Mesa):** GPU rendering via OpenGL 3.3 core, end-to-end GL → DMA-BUF → Wayland without any libwayland or libGL linkage.

- **Vendored GPU bindings** — `modules/EGL/`, `modules/gbm/`, `modules/GL/`. Same pattern as the Wayland wire code: types + constants + function-pointer variable declarations in one file, `init_X()` loader in another (`dlopen` + `dlsym`). No `#foreign`, no build-time linkage. We vendor our own minimal GL instead of using Jai's stock GL module because Jai's `glad_core.jai` hard-links `libGL` and its `GL.jai` imports `Window_Type` which pulls in X11 transitively.
- **EGL setup** — `EGL_PLATFORM_GBM_KHR` on `/dev/dri/renderD128` (the non-privileged render node). GL 3.3 core context, surfaceless (render to FBOs, never bind a surface).
- **DMA-BUF export** — `eglCreateImageKHR(EGL_GL_TEXTURE_2D_KHR, tex)` wraps a GL texture as an EGLImage. `eglExportDMABUFImageMESA` returns fd + stride + offset. `eglExportDMABUFImageQueryMESA` returns fourcc + modifier.
- **wl_buffer from DMA-BUF** — `modules/wayland/dmabuf.jai` helper discovers what formats the compositor advertises via `zwp_linux_dmabuf_v1.modifier` events. `zwp_linux_buffer_params_v1.add/create_immed` wraps the DMA-BUF fd as a `wl_buffer`. Attach to `wl_surface` through the existing path.
- **Frame pacing** — `wl_surface.frame` callbacks gate the next render to compositor vsync. `wl_callback.done` clears the `frame_requested` flag and lets the render defer re-fire.
- **Double-buffered** — two `Gl_Slot` records (each holding `tex` + `fbo` + `EGLImage` + `DMA-BUF fd` + `wl_buffer`) pre-allocated at startup. The render loop rotates between them; `wl_buffer.release` events free slots. Same architecture as the `wl_shm` path in `hello_window.jai`, substituting GL paint for CPU paint.
- **Input** — the Phase 4 seat/keyboard/pointer/xkb helpers plug directly into the GL render loop unchanged.
- **`ldd build/hello_gl`** — `libc.so.6` only. Zero hard-linkage to libEGL, libgbm, libGL, libwayland, libX11, libxcb.
- **Examples added:**
  - `headless_gl.jai` — EGL/GL/gbm smoke test (FBO glClear + readback + DMA-BUF export, no Wayland)
  - `hello_dmabuf.jai` — prints the compositor's advertised (format, modifier) table
  - `hello_gl.jai` — rotating RGB triangle in a Wayland window with keyboard + pointer input (the Phase 5 shippable milestone)
- **Tested live against Hyprland + Mesa radeonsi on AMD.**

**Known gaps (next phases):**
- **nVidia support** — the current GL path assumes Mesa's `gbm` + `EGL_MESA_image_dma_buf_export`. nVidia's proprietary stack needs a separate code path (likely `EGL_PLATFORM_DEVICE_EXT` + `EGL_NV_stream_*` or a surfaceless fallback). **Not optional** — planned as runtime-conditional logic in `init_egl_extensions()`.
- **Vulkan WSI**, **explicit fence sync**, **server-allocated object IDs**, **fractional scaling** — see `CLAUDE.md` Next Steps.
- **Ergonomic "raylib-light" layer** on top of the raw primitives is the eventual target; the current `hello_gl.jai` is the proving ground, not the user-facing API.

## Building

Requires the Jai compiler (beta 0.2.028+) at `~/jai/jai/`.

```bash
./build.sh                     # Build → build/main
./build.sh - test              # 22 XML/protocol tests
./build.sh - gen_test          # 36 generator tests
./build.sh - wire_test         # 22 wire protocol tests
./build.sh - marshal_test      # 9 marshal macro tests
./build.sh - unmarshal_test    # 12 unmarshal macro tests
./build.sh - compile_test      # 8 compilation smoke tests
./build.sh - generate          # Regenerate modules/wayland/ from protocol XML
./build.sh - hello_globals     # Build and run: print compositor globals
./build.sh - hello_screens     # Build and run: print output discovery
./build.sh - hello_window      # Build and run: resizable double-buffered shm window
./build.sh - dump_keymap       # Build and run: xkb keymap diagnostic
./build.sh - headless_gl       # Build and run: EGL/GL/gbm + DMA-BUF export smoke test
./build.sh - hello_dmabuf      # Build and run: zwp_linux_dmabuf_v1 format discovery
./build.sh - hello_gl          # Build and run: GPU-rendered rotating triangle (GL → DMA-BUF → Wayland)
```

The build uses Jai's compile-time metaprogramming via `first.jai` — no external build tools required.

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
  generator_test.jai — 36 tests (naming, enums, events, requests, assembly)
  wire_test.jai      — 22 tests (primitive read/write, header, string/array, buffers)
  marshal_test.jai   — 9 tests (fixed args, fd, string, array, constructors)
  unmarshal_test.jai — 12 tests (round-trip, tagged union dispatch)
  compile_test.jai   — 8 tests (imports generated module, verifies types)
examples/
  hello_globals.jai  — ~20 lines: connect, discover globals, print them
  hello_screens.jai  — ~30 lines: output discovery (modes, scale, geometry)
  hello_window.jai   — ~270 lines: double-buffered resizable shm window, keyboard + pointer input, XKB keysym translation
  dump_keymap.jai    — ~55 lines: mmap keymap fd, print evdev→keysym mappings
  headless_gl.jai    — ~150 lines: EGL/GL/gbm smoke test + DMA-BUF export (no Wayland)
  hello_dmabuf.jai   — ~45 lines: print compositor's advertised (format, modifier) pairs
  hello_gl.jai       — ~500 lines: GPU-rendered rotating triangle via GL → DMA-BUF → Wayland, double-buffered, frame-paced, keyboard + pointer input
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
    dmabuf.jai       — zwp_linux_dmabuf_v1 discovery: get_dmabuf_info, pick_format
    wayland/         — Core protocol (wl_display, wl_surface, wl_buffer, etc.)
    xdg_shell/       — XDG shell (xdg_toplevel, xdg_surface, etc.)
    ...              — 54 more protocol directories
  EGL/               — Runtime-dlopen'd EGL 1.5 bindings (types + core entry points + MESA_image_dma_buf_export)
  gbm/               — Runtime-dlopen'd libgbm bindings (device creation + DRM fourcc helpers)
  GL/                — Runtime-dlopen'd minimal GL 3.3 core bindings (~40 entry points, loaded via eglGetProcAddress)
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
