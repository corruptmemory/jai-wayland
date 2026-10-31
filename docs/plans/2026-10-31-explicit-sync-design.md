# Explicit sync for the dma-buf present paths (design)

**Status: implemented 2026-10-31, validated on the hybrid laptop** (commits `d60c43f`
syncobj wrappers, `39672af` EGL native fence, `660ba99` GL path, `cf65b25`
`hello_vulkan_dmabuf`). **Still to run in dGPU-only mode** (NVIDIA as the compositor's
GPU): `hello_simp` and `skeletal_animation` on the NVIDIA GL BO path, `hello_vulkan_dmabuf`
driver-first, and `JAI_WAYLAND_EXPLICIT_SYNC=0` once. Covers the GL path in
`Wayland_Support` (every Simp example) and `hello_vulkan_dmabuf`, both its same-GPU
(driver-first) mode and its cross-GPU copy path. The `wl_shm` readback is out of scope: the
protocol guarantees explicit sync only for dma-buf buffers, and an shm commit on a surface
using it can be an `unsupported_buffer` protocol error.

## Why

Today the CPU synchronises with the GPU before every commit:

- **GL:** Simp's `wl_swap_buffers` calls `glFinish()`, which blocks until the GPU has drawn
  the frame.
- **Vulkan:** `draw_vulkan_triangle` calls `vkQueueWaitIdle` after every submit. Before the
  copy path reuses a buffer, `wait_for_compositor_reads` polls its dma-buf fd for `POLLOUT`
  to wait out the read fences i915 attaches.

Measured on `nomad-artix` (Iris Xe, Hyprland 0.57), `hello_simp` on the default Intel dma-buf
path blocks in `glFinish` for **2.7-4.0 ms every frame** (240-frame averages at 1016x1244 and
1960x1200). The iGPU also composites the desktop, so a heavier scene waits longer. On the
desktop's AMD card it was 0.68 ms.

With `linux-drm-syncobj-v1` the client gives the compositor a fence to wait on (the acquire
point) and gets back a fence that tells it when the compositor has finished with the buffer
(the release point). The CPU never waits for the GPU on the way out.

The protocol also takes away what we lean on now. Once a surface has a
`wp_linux_drm_syncobj_surface_v1`, "the compositor may ignore implicit synchronization" and
"the delivery of wl_buffer.release events ... becomes undefined". So the copy path's
`POLLOUT` wait and the release-event slot rotation both stop being reliable. Release points
replace both.

NVIDIA's own driver presents on this laptop exactly this way: acquire and release points on
every one of 1500 `vkcube` frames (backport audit, laptop section).

## What the laptop supports (probed 2026-10-31)

- Hyprland 0.57 advertises `wp_linux_drm_syncobj_manager_v1` (global 70, v1).
- Both kernel drivers, `i915` (renderD128) and `nvidia-drm` (renderD129), report
  `DRM_CAP_SYNCOBJ` and `DRM_CAP_SYNCOBJ_TIMELINE`.
- Both EGL stacks (Mesa, NVIDIA 615.78) list `EGL_ANDROID_native_fence_sync`,
  `EGL_KHR_fence_sync` and `EGL_KHR_wait_sync`.
- Both Vulkan drivers can export and import semaphores as `SYNC_FD`.
- The protocol XML is vendored (`staging/linux-drm-syncobj`), and the generated bindings
  exist (`modules/wayland/linux_drm_syncobj_v1/`).

## Design

### 1. `modules/gpu/syncobj.jai`: DRM sync objects

Raw `ioctl`s on a DRM fd, with no libdrm, so the linkage thesis holds (`ioctl` is libc).
The kernel ABI structs are declared locally. Each call retries `EINTR`/`EAGAIN`, as
`drmIoctl` does, and logs every failure with its errno. A wait that times out is an
answer, not an error.

| Procedure                                                          | Kernel calls                                                                                               |
|--------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------|
| `syncobj_timeline_supported(drm_fd) -> bool`                       | `GET_CAP(DRM_CAP_SYNCOBJ_TIMELINE)`                                                                        |
| `syncobj_create(drm_fd) -> u32, bool`                              | `SYNCOBJ_CREATE`                                                                                           |
| `syncobj_destroy(drm_fd, handle)`                                  | `SYNCOBJ_DESTROY`                                                                                          |
| `syncobj_export(drm_fd, handle) -> s32`                            | `SYNCOBJ_HANDLE_TO_FD` (the fd the compositor imports)                                                     |
| `syncobj_import(drm_fd, fd) -> u32, bool`                          | `SYNCOBJ_FD_TO_HANDLE`                                                                                     |
| `syncobj_import_sync_file(drm_fd, timeline, point, sync_file)`     | `CREATE` a binary syncobj, `FD_TO_HANDLE(IMPORT_SYNC_FILE)` into it, `TRANSFER` it to the point, `DESTROY` |
| `syncobj_export_sync_file(drm_fd, timeline, point) -> s32`         | `TRANSFER` the point to a binary syncobj, `HANDLE_TO_FD(EXPORT_SYNC_FILE)`                                 |
| `syncobj_signal(drm_fd, timeline, point) -> bool`                  | `SYNCOBJ_TIMELINE_SIGNAL` (signals from the CPU)                                                           |
| `syncobj_wait(drm_fd, handles, points, timeout_ns) -> Wait_Result` | `SYNCOBJ_TIMELINE_WAIT` with `WAIT_FOR_SUBMIT`                                                             |
| `syncobj_point_signaled(drm_fd, handle, point) -> bool`            | `syncobj_wait` with timeout 0                                                                              |

Two kernel details the wrappers hide:
- The kernel's `timeout_nsec` is an **absolute `CLOCK_MONOTONIC`** time. `syncobj_wait`
  takes a relative timeout and converts it.
- `WAIT_FOR_SUBMIT` makes a point nobody has attached a fence to yet count as "not yet"
  instead of failing with `EINVAL`. That is the normal state of a release point before the
  compositor has used the buffer.

The structs use the long-standing 16-byte `drm_syncobj_handle` and the base
`drm_syncobj_timeline_wait` layouts. Newer kernels extend both, and the kernel zero-fills
the extensions for an older-sized request.

### 2. Point scheme: one timeline per buffer slot

Each slot owns one timeline syncobj, exported once and imported once into the compositor
(`import_timeline`). Its `n`th commit uses acquire point `2n-1` and release point `2n`. The
protocol allows one timeline for both, provided acquire < release.

Why per slot, and not one timeline for the window: every point on a timeline must be added
in increasing order (out-of-order points corrupt the kernel's chain). A slot is committed
again only after its previous release point has signalled, and therefore was attached. So on
a per-slot timeline the client's next acquire point always lands after the compositor's
release point. With one shared timeline, the compositor attaches release points in whatever
order it finishes with buffers. Mesa's Vulkan WSI also keeps timelines per image.

### 3. GL path (`Wayland_Support`)

**When it is on.** All of the following, decided per window in `wl_window_init_gl` and
logged once with the reason when it is off:
- the window's backend is a dma-buf one (not `SHM_READBACK`);
- the compositor advertises `wp_linux_drm_syncobj_manager_v1`;
- the shared EGL display exposes `EGL_ANDROID_native_fence_sync` and its entry points load;
- the render node reports `DRM_CAP_SYNCOBJ_TIMELINE`;
- `JAI_WAYLAND_EXPLICIT_SYNC` is not `0`. That escape hatch follows the other
  `JAI_WAYLAND_*` library knobs, since this is library code with no command line. It is for
  A/B timing and for working around a compositor bug.

The window then gets one `wp_linux_drm_syncobj_surface_v1`, created before its first commit
with a buffer. Every slot gets a timeline (`Wl_Gl_Slot` gains the DRM handle, the imported
`wp_linux_drm_syncobj_timeline_v1`, its last point, and its pending release point). The old
`acquire_fence_fd` / `release_fence_fd` placeholders become the pending sync_file and are
removed respectively.

**End of frame.** `wl_swap_buffers` calls a new `WS.wl_finish_frame(ww)` instead of
`glFinish()`:
- explicit: `eglCreateSyncKHR(EGL_SYNC_NATIVE_FENCE_ANDROID)`, `glFlush()`,
  `eglDupNativeFenceFDANDROID`, `eglDestroySyncKHR`. The sync_file waits in
  `slot.acquire_fence_fd`, and a stale one from an uncommitted frame is closed first.
- otherwise: `glFinish()`, as today.

If the fence cannot be made, `wl_finish_frame` logs one warning per window, falls back to
`glFinish()` for that frame, and leaves the fd at -1. The present then signals the acquire
point from the CPU, which is correct because the GPU is already done. The protocol requires
both points on every buffer commit, so there is no commit without them.

**Present.** After the pacing wait and the app-turn check (an app turn returns without
committing, as today):
1. import the sync_file at acquire point `2n-1`, or CPU-signal it;
2. `set_acquire_point`, `set_release_point(2n)`, then attach / damage / commit as today;
3. record the release point on the slot and mark it in flight.

**Slot reuse.** For an explicit window, `in_flight` is cleared only when the slot's release
point has signalled. Each rotation polls with a zero-timeout wait. The router keeps routing
`wl_buffer.release` but no longer clears `in_flight` for explicit windows: the event's timing
is undefined, and acting on it could let the GPU write a buffer the compositor's GPU is still
reading. If every slot is in flight, the fallback waits on their release points (any one
will do) in 10 ms slices, pumping Wayland between slices, until one frees or the connection
is lost. That mirrors today's blocking `wl_pump(true)` loop, plus one warning if the wait
passes a second. With three slots and vsync pacing, the N-2 slot's release has normally
signalled long before.

**Retired slots** (resize). A retired explicit slot is destroyed when its release point
signals, polled on every present, or on its `wl_buffer.release`, whichever comes first.
Destroying our side early is safe because a retired slot is never written again, and the
compositor holds its own references to the dma-buf and the timeline. The timeline's
`destroy` request "does not unset" points already set. `wl_slot_destroy` destroys the DRM
handle. The paths that send `wl_buffer.destroy` also send the timeline object's `destroy`.

### 4. Vulkan path (`hello_vulkan_dmabuf`)

**When it is on.** All of the following, plus no `--no-explicit-sync` on the command line
(examples take flags, not environment variables):
- the global is advertised;
- the device has `VK_KHR_external_semaphore_fd` and can export `SYNC_FD` semaphores;
- the device's own render node (`VK_EXT_physical_device_drm`, matched through
  `modules/gpu`) opens and reports timelines.

**Per slot:** a persistent command buffer, a fence (created signalled), a render-done
semaphore exportable as `SYNC_FD`, and the timeline as above.

**Draw:**
1. Wait for the slot's fence (bounded; normally long signalled) and reset it.
2. Record and submit, signalling the semaphore and the fence.
3. Explicit: `vkGetSemaphoreFdKHR(SYNC_FD)` gives the sync_file for the acquire point, and
   `vkQueueWaitIdle` goes. Implicit: keep `vkQueueWaitIdle`.

Exporting a `SYNC_FD` has copy transference: the semaphore is unsignalled afterwards and can
be signalled by the next submit.

**Reuse.** Explicit: a slot is free when its release point has signalled. This replaces both
the release event and the copy path's `POLLOUT` wait for that mode. Because the event loop
sleeps on the Wayland socket and the release event is no longer a reliable wake-up, a frame
callback that finds no free slot waits on the release points (bounded, with a warning on
timeout). Before destroying a slot (resize, exit), wait for its fence, since the per-frame
queue wait is gone.

**DRM fd:** the device's render node, so the cross-GPU copy path keeps its timelines on
`nvidia-drm`. Syncobj fds are DRM-core objects, and the compositor imports them on its own
device.

### 5. Tests: `tests/syncobj_test.jai`

Runs on the box's render node with no compositor, and SKIPs with a reason when there is no
render node or no timeline support. It runs under the error-recording logger, which must see
no unexpected errors.
- A timeline signalled from the CPU at point 1: point 1 reads signalled and point 2 does not.
  A wait on point 3 times out within its relative timeout (checked against the clock), so
  the absolute-time conversion is exercised.
- An exported and re-imported handle sees the same timeline.
- Point 1 exported as a sync_file and imported at point 4 reads signalled. That
  round-trips the import path with no GPU work.
- A wait on a destroyed handle logs exactly one error (negative test).
- **GPU fence:** on a `wl_egl_init` context, a clear followed by the fence helper the present
  path uses gives a sync_file that, imported at a point, signals within a second. SKIPs
  without `EGL_ANDROID_native_fence_sync`.
- **Slot reuse:** a stack `Wayland_Window` whose slot has a real timeline and a pending
  release point stays in flight until that point is CPU-signalled, then
  `wl_refresh_slot_releases` frees it.

### 6. Validation

As the copy path did it, staged:
1. A nested Hyprland first. This is a new kind of commit, and a bad fence stalls or kills
   only the nested instance.
2. Then the live one.
3. Then the dGPU-only reboot, for NVIDIA as the compositor's GPU.

- **GL:** `hello_simp` on Intel. The temporary timing patch should show the 3-4 ms CPU wait
  gone. Then all ten Simp examples, resizes (reallocation and retirement),
  `simp_multiple_windows`, and a window moved to another workspace (release with no
  presentation).
- **Vulkan:** driver-first on Intel, `--copy-path` on Intel, the RTX 3050 Ti copy path
  (nested, then live).
- **Regression:** `JAI_WAYLAND_EXPLICIT_SYNC=0` and `--no-explicit-sync` keep today's paths.
- **dGPU-only mode:** the NVIDIA GL BO path and Vulkan driver-first, with NVIDIA's native
  fence and `nvidia-drm` timelines.

**As run.** The nested sandbox turned out not to apply: a nested Hyprland runs on the
Wayland backend and does not advertise `wp_linux_drm_syncobj_manager_v1`. It exercised the
fallback (`hello_simp`, "explicit sync off", rc 0), and every explicit-sync run went to the
live instance. Results are in the backport audit's laptop section. GL's end-of-frame CPU wait
fell from 3.2-4.1 ms to 0.13-0.17 ms, with no release-point wait in 1440 frames.

## Non-goals

- GPU-side waits on the release point (`eglWaitSyncKHR`, Vulkan wait semaphores). With three
  slots the CPU wait almost never blocks. Revisit if a profile says otherwise.
- `hello_gl` keeps its `glFinish()`. It is the Phase 5 milestone example, not the library
  path.
- The zero-copy GL path (`docs/plans/2026-10-31-zero-copy-gl-across-gpus.md`, banked).
  Explicit sync is its prerequisite.
- `wp_fifo_v1` and `wp_commit_timing_v1` (advertised, unrelated).

## Risks

- **A compositor that never signals a release point** (a bug, or an occluded surface whose
  old buffers it keeps). The bounded waits log instead of hanging silently.
- **Hyprland's syncobj path is where the earlier crashes surfaced** (`CEGLSync::create` in
  Mesa iris). Those crashes came from importing NVIDIA video memory, not from client fences;
  NVIDIA's system-memory buffers with explicit sync ran 1500 frames cleanly. The nested
  sandbox goes first anyway.
- **Protocol errors** (a commit missing a point, or points without a buffer) kill only the
  client, and loudly: `wl_display.error` is logged.
