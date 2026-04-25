# AGENTS.md

## Project Overview

`jai-wayland` is a Wayland client library for Jai. It bypasses
`libwayland-client` and speaks the Wayland wire protocol directly over a Unix
socket. Shared libraries for GPU work are loaded at runtime with `dlopen` and
function pointers; do not introduce hard link-time dependencies on Wayland, EGL,
gbm, GL, X11, or xcb.

Current status: phases 1-5 are complete. The Mesa path renders GL -> DMA-BUF ->
Wayland through `EGL_MESA_image_dma_buf_export`, double-buffered slots, frame
callbacks, keyboard/pointer input, and XKB keysym translation. NVIDIA/hybrid GPU
support is planned in `docs/plans/2026-04-25-nvidia-gpu-support.md`.

## Required Skill

Before writing or modifying Jai code, use the `jai-language` skill if available.
The compiler is expected at `~/jai/jai/bin/jai-linux`, with standard library
modules under `~/jai/jai/modules/`.

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
./build.sh - hello_dmabuf
./build.sh - hello_gl
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
- `modules/EGL`, `modules/gbm`, and `modules/GL` are low-level runtime-loaded
  bindings. Keep them free of `#foreign` declarations that force linkage.

## Core Invariants

- Do not add `libwayland-client` usage.
- Do not add hard-linked `#library` / `#foreign` dependencies for GPU or window
  libraries.
- Preserve the `ldd build/hello_gl` invariant: no `libEGL`, `libgbm`, `libGL`,
  `libwayland`, `libX11`, or `libxcb`.
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

Primary next work: NVIDIA / hybrid GPU support. Follow
`docs/plans/2026-04-25-nvidia-gpu-support.md`.

Known future areas:

- GBM BO-backed render targets.
- `zwp_linux_dmabuf_feedback_v1` support.
- Explicit sync / syncobj integration.
- Vulkan WSI or Vulkan DMA-BUF export path.
- Server-allocated Wayland object IDs.
- Fractional scaling.
- Higher-level "raylib-light" ergonomic layer.
