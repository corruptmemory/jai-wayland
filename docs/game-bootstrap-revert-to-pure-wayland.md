<!-- SPDX-License-Identifier: MIT -->
<!-- Copyright (c) 2026 Jim Powers -->

# Reverting game-bootstrap off libwayland-client → the pure Jai wire client

**Audience:** the `game-bootstrap` project (and any consumer that adopted
real-`libwayland-client` + `VK_KHR_wayland_surface` because it believed NVIDIA forced
Vulkan WSI). This document explains why that constraint is gone and how to migrate back
to jai-wayland's from-scratch wire client + DMA-BUF export present.

## Why this exists — the constraint that justified libwayland is falsified

game-bootstrap chose real-`libwayland-client` + a Vulkan swapchain over
`VK_KHR_wayland_surface` (the **2026-06-15 windowing pivot**) because the alternative —
present your own buffers over the raw wire protocol — appeared to fail on NVIDIA: NVIDIA's
Vulkan DMA-BUF *export* broke in pure-dGPU mode, and WSI was the only path that worked. The
duck-type libwayland proxy (have the ICD drive *our* wire client through a faked libwayland
C ABI) was rejected on 2026-06-14 as "too complex" (over-priced by a now-falsified
assumption that libwayland manages internal threads — it spawns none).

**That NVIDIA failure is now understood and fixed (jai-wayland, 2026-06-24).** It was never
a hardware/driver wall — it was a *modifier-negotiation* mistake:

- The GL/GBM path already worked on NVIDIA pure-dGPU because GBM lets you request
  `DRM_FORMAT_MOD_INVALID` ("you pick"), the driver chooses its own native tiled modifier,
  and its own compositor imports it. The compositor's advertised dmabuf *feedback*
  under-reports on NVIDIA, but that advertisement is not the authority on what it will
  actually import.
- Vulkan's `VK_EXT_image_drm_format_modifier` has no `INVALID` "you-pick" sentinel, so the
  stock code constrained the modifier to the compositor's advertised list — which on NVIDIA
  is empty → it bailed. **That was the bug.**
- **Fix:** drive the modifier from the *Vulkan driver's own* enumeration
  (`VkDrmFormatModifierPropertiesListEXT`) instead of the compositor's advertisement, and
  let the compositor's `created`/`failed` be the only arbiter. Validated presenting on an
  **NVIDIA RTX 3050 Ti pure-dGPU** (first candidate `0x0300000000606015`, an NVIDIA
  block-linear tiled modifier, ACCEPTED) and on AMD. See
  `jai-wayland/examples/hello_vulkan_dmabuf.jai` → `choose_image_config_driver_first`.

**Consequence:** the clean, libwayland-free model-1 path (app owns its own event loop, no
inversion of control, zero display/GPU libs linked) now presents on **every GPU for both
GL and Vulkan**. Nothing forces WSI. game-bootstrap can drop real libwayland entirely.

## The decision being reverted

| | Current (libwayland) | Target (pure wire) |
|---|---|---|
| Compositor protocol | `modules/Wayland_Client` (dlopen'd real `libwayland-client.so.0`) | `modules/wayland` (raw `AF_UNIX` socket, from-scratch marshal/unmarshal) |
| Event delivery | libwayland callback dispatch (inversion of control) | `for session()` loop; switch on `(object_id, opcode)` (you own the loop) |
| Vulkan present | swapchain over `VK_KHR_wayland_surface` (driver owns present + pacing) | render to DRM-modifier `VkImage`, export DMA-BUF, wrap as `wl_buffer`, you own present + frame-callback pacing |
| libwayland | dlopen'd at runtime (ldd clean, but the dependency exists) | **none** — not even dlopen'd |
| Mental models | two (raw-wire generator *and* libwayland-shaped consumer) | one (raw wire everywhere) |

Both satisfy the linkage thesis (`ldd` clean), but the target removes the libwayland
dependency *and* the callback-inversion model the project exists to avoid.

## Target architecture

```
app / render loop  ──drives──▶  for session()  (modules/wayland: no IoC)
        │                              │
        │ render Vulkan triangle/scene │ marshal requests, unmarshal events
        ▼                              ▼
  DRM-modifier VkImage  ──export fd──▶  zwp_linux_dmabuf_v1 → wl_buffer
        │                              │
        └── driver-first modifier ─────┘  attach + commit + wl_surface.frame pacing
            selection (the NVIDIA fix)
```

The reference implementation of the entire present path is
`jai-wayland/examples/hello_vulkan_dmabuf.jai` — it is exactly this, end to end, validated
on Mesa and NVIDIA.

## Migration steps

1. **Adopt the complete pure wire client.** game-bootstrap's `modules/wayland` is currently
   only a *code-generator* (`code-generator/`, `tests/`); it has no runtime `module.jai`.
   Either run that generator to emit the full module, or vendor jai-wayland's
   `modules/wayland/` wholesale — it is the proven runtime client:
   `module.jai` → `wire.jai`, `connection.jai`, `marshal.jai`, `unmarshal.jai`,
   `session.jai`, `registry.jai`, `output.jai`, `input.jai`, `xkb.jai`, `dmabuf.jai`, plus
   the generated per-protocol interface files. Key entry points:
   - `init_wayland_session()` — connect, discover globals, bind compositor/wm_base. Replaces
     the libwayland two-call init (`init_wayland_client()` + `wl_protocol_tables_init()`).
   - `for session() { ... }` — the event loop. Each `it` is a `WaylandMessageHeader`; route
     by `(it.object_id, it.opcode)`, decode with `unmarshal`/`unmarshal_event` or inline
     `read_u32`/`read_string`. **Gotcha:** opcodes are per-interface — `wl_buffer.release`,
     `wl_callback.done`, `xdg_surface.configure` can collide on the wire; always match on
     `(object_id, opcode)`, never opcode alone.
   - `MessageBuilder` + `wayland_send()` — batch requests, flush explicitly. No hidden flush.

2. **Delete `modules/Wayland_Client`** (the real-libwayland binding) once nothing imports
   it. Its `protocol.generated.jai` / `core.generated.jai` and the two-call init contract go
   away with it.

3. **Rewrite `modules/Wayland_Support` to present via DMA-BUF export, not WSI.** The
   2026-06-15 pivot *removed* the dmabuf slot seam, format negotiation, and frame-callback
   pacing because the swapchain owned them. Reverting restores them — copy the shapes from
   `hello_vulkan_dmabuf.jai`:
   - Replace `vkCreateWaylandSurfaceKHR` + `VK_KHR_swapchain` with: render into
     DRM-modifier-backed `VkImage`s (`VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT` +
     `VkImageDrmFormatModifierListCreateInfoEXT`), export each via `vkGetMemoryFdKHR`
     (`VK_EXT_external_memory_dma_buf` + `VK_KHR_external_memory_fd`), and wrap as a
     `wl_buffer` through `zwp_linux_dmabuf_v1` (`create_params` → `add` → `create_immed`).
     See `create_vulkan_buffer` and `queue_dmabuf_buffer`.
   - Reintroduce the **double/triple-buffered slot** model with `wl_buffer.release` routing
     and `wl_surface.frame`-callback pacing (the `slots` + `find_free_slot` + `dirty`/
     `frame_requested` loop in `hello_vulkan_dmabuf.jai`). The driver, not the WSI swapchain,
     no longer paces you — you pace on the frame callback.
   - The `wl_display_handle` / `wl_surface_handle` accessors the render backend used to feed
     `vkCreateWaylandSurfaceKHR` are no longer needed — the render backend now owns the
     `VkImage`s and hands their exported fds to the support layer instead.

4. **Use the driver-first modifier selection — this is the load-bearing piece for NVIDIA.**
   Do not pick the format/modifier from the compositor's advertised dmabuf list. Instead, for
   each candidate `vk_format`/wayland-fourcc pair:
   - Enumerate the **driver's** modifiers via `vkGetPhysicalDeviceFormatProperties2` +
     `VkDrmFormatModifierPropertiesListEXT` (keep single-plane, `COLOR_ATTACHMENT`-capable
     ones; driver-tiled first, `DRM_FORMAT_MOD_LINEAR` as the safety net).
   - **Probe each against the compositor** with the *async*
     `zwp_linux_buffer_params_v1.create` + `created`/`failed` events (a `wl_display.sync`
     backstop avoids hangs). The first modifier the compositor reports `created` wins.
   - Fall back to compositor-advertised selection only if the probe finds nothing — so it is
     never worse than feedback-only.

   This is `choose_image_config_driver_first` + `probe_config_against_compositor` +
   `gather_driver_candidates` + `enumerate_driver_modifiers` in `hello_vulkan_dmabuf.jai`.
   Copy them. On a hybrid box (render NVIDIA, composite Intel) the same ladder degrades to
   `LINEAR`, the universal interchange format.

5. **Input / clipboard / resize** come from the same `for session()` pump: keyboard via
   `modules/wayland/{input,xkb}.jai` (seat discovery, keymap parse, keysym translation),
   pointer/touch, `xdg_toplevel.configure`/`close`, and `xdg_wm_base.ping`→`pong`. jai-wayland's
   `Wayland_Support` (the X11-mirror shared-globals layer + single pump) is the working
   reference for wiring all of this over one connection.

## What you gain / trade-offs

- **Gain:** no libwayland dependency at all; a single mental model (raw wire everywhere); the
  no-inversion-of-control thesis restored (the app owns its loop, no callback dispatch tables);
  the duck-type `modules/libwayland_shim` is unnecessary (it remains in jai-wayland's
  `libwayland-client-proxy` branch as a proven-but-unused receipt that the charade *works*).
- **Trade-off:** you re-own the swapchain — buffer allocation, present, release tracking, and
  frame-callback pacing — instead of letting the WSI driver do it. That is more code, but it
  is the clean model and it is already written and validated in `hello_vulkan_dmabuf.jai`;
  port it rather than reinventing it.

## References (jai-wayland, the templates to port)

- `examples/hello_vulkan_dmabuf.jai` — the full Vulkan → DRM-modifier `VkImage` → DMA-BUF →
  `wl_buffer` present, with driver-first modifier selection. **The primary template.**
- `examples/hello_gl.jai` — the GL/GBM equivalent (BO → EGLImage → FBO → DMA-BUF export).
- `modules/wayland/` — the pure wire client (`session.jai`, `dmabuf.jai`, …).
- `modules/gpu/` — render-node selection + shared BO/EGLImage helpers.
- `docs/plans/2026-06-24-libwayland-proxy-plan.md` (Task 8) — the NVIDIA resolution writeup
  and why the duck-type WSI shim turned out unnecessary.
