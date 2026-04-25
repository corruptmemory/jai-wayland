# NVIDIA / Hybrid GPU Support Implementation Plan

## Goal

Make the Phase 5 GL -> DMA-BUF -> Wayland path work on hybrid laptops with an
NVIDIA dGPU while preserving the project thesis:

- No `libwayland-client` dependency.
- No hard linkage to `libEGL`, `libgbm`, `libGL`, `libX11`, or `libxcb`.
- Application owns the event loop.
- The Mesa path continues to work unchanged.

This machine is a concrete target:

- Intel iGPU render node: `/dev/dri/renderD128` (`vendor = 0x8086`)
- NVIDIA dGPU render node: `/dev/dri/renderD129` (`vendor = 0x10de`)
- NVIDIA GBM/EGL support is installed:
  - `/usr/lib/gbm/nvidia-drm_gbm.so`
  - `/usr/share/egl/egl_external_platform.d/15_nvidia_gbm.json`

## Implementation Status

As of 2026-04-25:

- Tasks 1-3 are implemented in `headless_gl`.
- Default render-node selection preserves the current Intel/iGPU path on the
  laptop's integrated screen.
- `JAI_WAYLAND_RENDER_NODE=/dev/dri/renderD129` and
  `JAI_WAYLAND_GPU_VENDOR=nvidia` both select the NVIDIA render node.
- GBM BO creation/export probes work on Intel and NVIDIA.
- BO-backed FBO rendering works on Intel via `EGL_NATIVE_PIXMAP_KHR`.
- BO-backed FBO rendering works on NVIDIA via fallback import through
  `EGL_LINUX_DMA_BUF_EXT`; NVIDIA rejects direct native-pixmap import with
  `EGL_BAD_PARAMETER`.
- `ldd build/headless_gl` still shows no hard-linked EGL, gbm, GL, Wayland,
  X11, or xcb dependencies.

- Task 4 is implemented for the default Intel/iGPU path. `hello_gl` now selects
  the render node through `modules/gpu`, initializes both presentation slots as
  GBM BO-backed GL textures/FBOs, and keeps the old Mesa texture-export path as a
  local fallback if BO-backed slot setup fails.
- `hello_gl` handles compositor-driven post-map resizes. On Hyprland tiling
  resizes, it retires old in-flight buffers, commits replacement buffers at the
  new size immediately, and frees retired GPU/Wayland resources after
  `wl_buffer.release`.
- Shared GBM BO allocation and EGLImage import helpers live in
  `modules/gpu/dmabuf_bo.jai` and are used by both `headless_gl` and
  `hello_gl`.
- Task 5 first slice is implemented as read-only diagnostics:
  `modules/wayland/dmabuf.jai` can collect default and per-surface
  `zwp_linux_dmabuf_feedback_v1` snapshots, and `hello_dmabuf` prints the
  feedback main device, format table size, tranches, flags, and sample
  format/modifier entries. Buffer selection still uses the older global
  format/modifier list.
- Task 4 NVIDIA presentation is still pending a dGPU display/session test after
  rebooting into BIOS dGPU mode.

## Current State

`examples/headless_gl.jai` and `examples/hello_gl.jai` now select render nodes
through `modules/gpu`. The default policy preserves the current Mesa/iGPU path,
while `JAI_WAYLAND_RENDER_NODE` and `JAI_WAYLAND_GPU_VENDOR` allow explicit
selection.

`headless_gl` proves BO-backed FBO rendering on Intel and NVIDIA. `hello_gl`
uses BO-backed Wayland buffer slots on the Intel/iGPU path and keeps the older
`EGL_MESA_image_dma_buf_export` texture-export path as a local fallback. Modern
NVIDIA supports GBM, so the first NVIDIA implementation should remain
GBM/DMA-BUF first, not EGLStream first. EGLStream is legacy/compositor-dependent
and should only be considered as a later fallback if GBM cannot cover a required
target.

`modules/wayland/dmabuf.jai` can now read both the older global
`zwp_linux_dmabuf_v1.format` / `.modifier` events and read-only
`zwp_linux_dmabuf_feedback_v1` snapshots. `hello_gl` still selects buffers from
the global list; the next Task 5 slice should use feedback tranches as the
source of truth for cross-GPU/modifier selection.

## Design Direction

Add a small GPU backend layer rather than pushing vendor-specific decisions into
`hello_gl.jai`.

Proposed module shape:

```
modules/gpu/
  module.jai
  device.jai        -- render node discovery and selection
  egl_context.jai   -- shared EGL/GL/gbm context setup
  dmabuf_bo.jai     -- GBM BO-backed render target allocation/export
```

The existing `modules/EGL`, `modules/gbm`, and `modules/GL` stay as low-level
bindings. `modules/gpu` becomes the policy layer that chooses a device and a
buffer creation path.

## Generator Boundary

The Wayland protocol bindings remain reproducible from XML plus
`src/generator.jai`. If NVIDIA support requires a different generated protocol
shape, update the generator and regenerate rather than hand-editing generated
files under `modules/wayland/<protocol>/`.

Phases 1-2 are outside that boundary. Render-node discovery, GPU selection
policy, GBM BO function pointers, EGL/GL function pointers, and backend helpers
are handwritten tracked source, matching the existing `modules/EGL`,
`modules/gbm`, and `modules/GL` pattern.

For dmabuf feedback, the generated requests and events already exist:
`zwp_linux_dmabuf_v1.get_default_feedback`,
`zwp_linux_dmabuf_v1.get_surface_feedback`, and
`zwp_linux_dmabuf_feedback_v1` events. Task 5 should start by consuming those in
`modules/wayland/dmabuf.jai`; change the generator only if the generated shape
proves insufficient.

The preferred render target path should become:

1. Pick a render node.
2. Create a `gbm_device`.
3. Create an EGL display with `EGL_PLATFORM_GBM_KHR`.
4. Create a GL context.
5. Allocate a `gbm_bo` with compositor-compatible format/modifier.
6. Create an `EGLImage` from the BO.
7. Bind the image to a GL texture with `glEGLImageTargetTexture2DOES`.
8. Render to an FBO backed by that texture.
9. Export fd/stride/offset/modifier from the BO.
10. Create a Wayland `wl_buffer` through `zwp_linux_buffer_params_v1`.

Keep the current Mesa texture-export path available as a fallback until the BO
path is proven on both Intel and NVIDIA.

## Task 1: Render Node Discovery And Selection

Create `modules/gpu/device.jai`.

Requirements:

- Enumerate `/dev/dri/renderD*`.
- For each node, read `/sys/class/drm/renderD*/device/vendor`.
- Record at least:
  - path
  - render minor/name
  - vendor ID
  - whether it is Intel/AMD/NVIDIA/unknown
- Add explicit override:
  - `JAI_WAYLAND_RENDER_NODE=/dev/dri/renderD129`
- Add policy:
  - default: preserve current behavior by choosing the first usable render node
  - optional: `JAI_WAYLAND_GPU_VENDOR=nvidia|intel|amd`

Checkpoint:

- `headless_gl` can print which render node it selected.
- `JAI_WAYLAND_RENDER_NODE=/dev/dri/renderD129 ./build.sh - headless_gl`
  attempts NVIDIA explicitly.

Validation:

```bash
./build.sh - compile_test
./build.sh - headless_gl
JAI_WAYLAND_RENDER_NODE=/dev/dri/renderD129 ./build.sh - headless_gl
```

## Task 2: Extend GBM Bindings

Expand `modules/gbm/gbm.jai` and `modules/gbm/loader.jai`.

Add the BO allocation/export surface needed by the NVIDIA path:

- `gbm_bo_create`
- `gbm_bo_create_with_modifiers` if available
- `gbm_bo_destroy`
- `gbm_bo_get_fd`
- `gbm_bo_get_stride`
- `gbm_bo_get_offset`
- `gbm_bo_get_modifier`
- `gbm_bo_get_format`
- `gbm_bo_get_plane_count`
- `gbm_bo_get_handle_for_plane` if needed
- `gbm_bo_get_fd_for_plane` if available

Add constants/flags as needed:

- `GBM_BO_USE_RENDERING`
- `GBM_BO_USE_LINEAR`
- `GBM_BO_USE_SCANOUT` only if testing shows the compositor requires it

Checkpoint:

- A small headless path can create and destroy a BO on Intel and NVIDIA.
- No new hard-linked libraries appear in `ldd`.

Validation:

```bash
./build.sh - headless_gl
ldd build/headless_gl | grep -E 'libEGL|libgbm|libGL|libX11|libxcb' && false || true
```

## Task 3: EGLImage From GBM BO

Add BO-backed render target creation.

Implementation details:

- Add `EGL_LINUX_DMA_BUF_EXT` / `EGL_EXT_image_dma_buf_import` constants if
  needed.
- Add `glEGLImageTargetTexture2DOES` to `modules/GL`.
- Create an `EGLImage` from the BO.
- Bind the EGL image to a GL texture.
- Attach the texture to an FBO.
- Render/readback in `headless_gl` to prove the path works before touching
  Wayland.

Checkpoint:

- BO-backed FBO clear/readback works on Intel.
- BO-backed FBO clear/readback works on NVIDIA render node.

Validation:

```bash
./build.sh - headless_gl
JAI_WAYLAND_RENDER_NODE=/dev/dri/renderD129 ./build.sh - headless_gl
```

## Task 4: Wayland Buffer Creation From GBM BO

Refactor the GL slots in `hello_gl` so each slot is backed by a BO export
instead of the current Mesa texture-export path.

Each slot should own:

- `gbm_bo`
- GL texture
- FBO
- `EGLImage`
- DMA-BUF fd(s)
- stride(s)
- offset(s)
- modifier
- `wl_buffer`
- in-flight state

Start with single-plane formats only. Keep multi-plane structure in mind, but do
not implement it unless the selected format requires it.

Checkpoint:

- `hello_gl` works on the current Intel/Mesa path using BO-backed slots.
- The old Mesa texture-export path remains available as a local fallback when
  BO-backed slot setup fails before the Wayland buffer is submitted.
- NVIDIA `hello_gl` presentation remains to be tested after booting into a dGPU
  session.

Validation:

```bash
./build.sh - hello_gl
ldd build/hello_gl | grep -E 'libEGL|libgbm|libGL|libwayland|libX11|libxcb' && false || true
```

## Task 5: dmabuf Feedback API

Extend `modules/wayland/dmabuf.jai` beyond global format/modifier discovery.

Add support for:

- `zwp_linux_dmabuf_v1.get_default_feedback`
- `zwp_linux_dmabuf_v1.get_surface_feedback`
- `zwp_linux_dmabuf_feedback_v1` events
- tranche target device
- tranche formats
- tranche flags
- main device

Use the feedback data to choose:

- preferred render node/device
- format
- modifier

If feedback is unavailable or too incomplete, fall back to the existing global
format/modifier list.

Checkpoint:

- `hello_dmabuf` can print feedback data grouped by tranche.
- `hello_gl` can choose a format/modifier using feedback when available.

Validation:

```bash
./build.sh - hello_dmabuf
./build.sh - hello_gl
JAI_WAYLAND_RENDER_NODE=/dev/dri/renderD129 ./build.sh - hello_gl
```

## Task 6: Explicit Sync Planning Hook

Do not fully implement explicit sync in the first NVIDIA pass, but prepare the
backend boundary for it.

Current code uses `glFinish()` before sharing the buffer. That is simple and
safe enough for proof-of-concept, but it is too coarse for a serious NVIDIA path.

Add comments/types so the later sync work has a place to land:

- acquire fence fd
- release fence fd
- render completion fence
- compositor release integration

Likely protocols/extensions:

- `wp_linux_drm_syncobj_v1`
- `EGL_KHR_fence_sync`
- external fence fd extensions

Checkpoint:

- No behavior change required.
- The render-slot type has a clean place to store fence state later.

## Task 7: Backend Selection And Cleanup

Make backend selection explicit and observable.

Expected modes:

- `auto`
- `mesa_texture_export`
- `gbm_bo`

Environment override:

- `JAI_WAYLAND_GPU_BACKEND=auto|mesa_texture_export|gbm_bo`

`auto` should prefer `gbm_bo` once it works on Intel and NVIDIA, falling back to
`mesa_texture_export` only when required extensions are missing.

Print the selected backend and render node at startup in `headless_gl` and
`hello_gl`.

Checkpoint:

- Intel default works.
- NVIDIA override works or fails with an actionable message.
- Existing Mesa behavior remains available.

## Final Verification Matrix

Run on the hybrid laptop:

```bash
./build.sh - test gen_test wire_test marshal_test unmarshal_test compile_test
./build.sh - headless_gl
./build.sh - hello_dmabuf
./build.sh - hello_gl
JAI_WAYLAND_RENDER_NODE=/dev/dri/renderD129 ./build.sh - headless_gl
JAI_WAYLAND_RENDER_NODE=/dev/dri/renderD129 ./build.sh - hello_dmabuf
JAI_WAYLAND_RENDER_NODE=/dev/dri/renderD129 ./build.sh - hello_gl
```

Check linkage:

```bash
ldd build/headless_gl | grep -E 'libEGL|libgbm|libGL|libwayland|libX11|libxcb' && false || true
ldd build/hello_gl   | grep -E 'libEGL|libgbm|libGL|libwayland|libX11|libxcb' && false || true
```

Optional NVIDIA diagnostics:

```bash
__NV_GBM_TRACE_ENABLED=1 JAI_WAYLAND_RENDER_NODE=/dev/dri/renderD129 ./build.sh - headless_gl
__NV_GBM_TRACE_ENABLED=1 JAI_WAYLAND_RENDER_NODE=/dev/dri/renderD129 ./build.sh - hello_gl
```

## Rollback Plan

Keep the existing Mesa texture-export path intact until the BO-backed path works.
If NVIDIA support stalls:

1. Leave render-node discovery in place.
2. Leave expanded GBM bindings if they compile and are harmless.
3. Keep `hello_gl` defaulting to the known-good Mesa texture-export backend.
4. Gate unfinished NVIDIA work behind `JAI_WAYLAND_GPU_BACKEND=gbm_bo`.

## Out Of Scope For This Phase

- Full Vulkan WSI.
- EGLStream backend unless GBM proves impossible for a required target.
- Multi-plane YUV formats.
- Production-grade explicit sync.
- A high-level raylib-like API.
