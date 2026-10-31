# Explicit Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the CPU-side GPU waits in the GL (`Wayland_Support`) and Vulkan
(`hello_vulkan_dmabuf`) dma-buf present paths with `linux-drm-syncobj-v1` acquire/release
points.

**Architecture:** There is one new GPU-layer file of raw DRM syncobj ioctls. Each buffer slot
owns one timeline (acquire `2n-1`, release `2n`). GL makes its acquire fence with
`EGL_ANDROID_native_fence_sync`, Vulkan with a `SYNC_FD` semaphore. A slot is reused when
its release point signals, never on `wl_buffer.release`. Every condition that disables it
falls back to today's path.

**Tech Stack:** Jai beta 0.2.030, raw `ioctl` (libc), runtime-loaded EGL/GL/Vulkan, the
generated `linux_drm_syncobj_v1` bindings.

**Spec:** `docs/plans/2026-10-31-explicit-sync-design.md`

## Global Constraints

- No new build-time linkage: no libdrm. DRM calls are `ioctl` on an fd; EGL and Vulkan entry
  points load at runtime.
- Modules log, examples print. Failures go to `log_error`; an expected timeout is not one.
  Fallbacks warn once (`.WARNING`).
- The library knob is `JAI_WAYLAND_EXPLICIT_SYNC=0` (off). The example flag is
  `--no-explicit-sync`.
- `SHM_READBACK` windows never get a `wp_linux_drm_syncobj_surface_v1`.
- Every commit that attaches a buffer to an explicit surface sets both points. A commit
  without a buffer sets neither.
- Per-slot timeline: the `n`th commit uses acquire `2n-1` and release `2n`.
- Test new commit kinds on a nested Hyprland before the live one. Stop instances with
  `pgrep -x`, never `pgrep -f`.
- Markdown tables aligned in source.

## Review Focus

1. **Resize while slots are in flight.** Retired explicit slots must be reaped by release
   point, or they leak forever. Tested in Task 3 (retired-slot reaping).
2. **An app turn between `wl_finish_frame` and the commit.** The stale sync_file must be
   closed when the next frame replaces it. Tested in Task 2 (fd closed on replace).
3. **Fence creation failing mid-session.** The commit must still carry a signalled acquire
   point. Tested in Task 3 (`wl_set_acquire_point` with fd -1 CPU-signals).
4. **A compositor without the global** (other compositors, or the desktop's Hyprland
   0.56.2 if it lacks it). Behaviour must be byte-for-byte today's. Checked in Task 3's
   live step with `JAI_WAYLAND_EXPLICIT_SYNC=0`, and in Task 4 with `--no-explicit-sync`.
5. **An occluded window** (another workspace). Release points must still free slots; if
   none ever signals, the GL wait warns once and keeps waiting, as the design (section 3)
   and the old `wl_pump(true)` loop do. Visible, not silent; not bounded. Checked in Task 3's
   live step (corrected after the final review).

---

### Task 1: DRM syncobj wrappers

**Files:**
- Create: `modules/gpu/syncobj.jai`
- Modify: `modules/gpu/module.jai` (`#load "syncobj.jai";`)
- Create: `tests/syncobj_test.jai`
- Modify: `first.jai` (target `syncobj_test`, plus the valid-options list)

**Interfaces:**
- Produces (all in module `gpu`):
  - `Syncobj_Wait_Result :: enum { SIGNALED; TIMED_OUT; ERROR; }`
  - `syncobj_timeline_supported :: (drm_fd: s32) -> bool`
  - `syncobj_create :: (drm_fd: s32) -> u32, bool`
  - `syncobj_destroy :: (drm_fd: s32, handle: u32)`
  - `syncobj_export :: (drm_fd: s32, handle: u32) -> s32` (-1 on failure)
  - `syncobj_import :: (drm_fd: s32, fd: s32) -> u32, bool`
  - `syncobj_import_sync_file :: (drm_fd: s32, timeline: u32, point: u64, sync_file: s32) -> bool`
    (does not close `sync_file`)
  - `syncobj_export_sync_file :: (drm_fd: s32, timeline: u32, point: u64) -> s32`
  - `syncobj_signal :: (drm_fd: s32, timeline: u32, point: u64) -> bool`
  - `syncobj_wait :: (drm_fd: s32, handles: [] u32, points: [] u64, timeout_ns: s64) -> Syncobj_Wait_Result, first_signaled: u32`
    (relative timeout, waits for ANY, always `WAIT_FOR_SUBMIT`)
  - `syncobj_point_signaled :: (drm_fd: s32, handle: u32, point: u64) -> bool`

- [ ] **Step 1: Write the failing tests.** Open the first render node from
  `Gpu.discover_render_nodes`. Print SKIP and return if there is none or if
  `!syncobj_timeline_supported`. Run under an error-recording logger (gpu_test's shape) and
  finish with `rec.errors == expected`.
  - `test_cpu_signal_and_poll`: create; `syncobj_signal(t, 1)`; assert point 1 signalled
    and point 2 not.
  - `test_wait_times_out_relative`: `syncobj_wait([t], [3], 20_000_000)` returns
    `TIMED_OUT`, and the elapsed `seconds_since_init()` is ≥ 0.015 and < 1.0.
  - `test_export_import_same_timeline`: export t, import it as t2, signal t2 at 5, assert t
    point 5 signalled.
  - `test_sync_file_round_trip`: `export_sync_file(t, 1)`, then `import_sync_file(t, 6, fd)`
    with t at 5 already, then assert point 6 signalled. Close the fd.
  - `test_wait_on_destroyed_handle_logs_one_error`: destroy a handle, `syncobj_wait` on it,
    assert `ERROR` and exactly one more recorded error.
- [ ] **Step 2: Run it to see it fail:** `./build.sh - syncobj_test` should fail to compile
  (undeclared `syncobj_create`).
- [ ] **Step 3: Implement `modules/gpu/syncobj.jai`.**
  - Request codes: `DRM_IOWR(nr, size) = 0xC000_0000 | (size << 16) | (0x64 << 8) | nr`.
  - nrs: GET_CAP 0x0C (`{capability: u64; value: u64}`), CREATE 0xBF, DESTROY 0xC0,
    HANDLE_TO_FD 0xC1, FD_TO_HANDLE 0xC2, TIMELINE_WAIT 0xCA, TRANSFER 0xCC,
    TIMELINE_SIGNAL 0xCD.
  - Structs: `drm_syncobj_create {handle, flags: u32}`, `drm_syncobj_destroy {handle, pad}`,
    `drm_syncobj_handle {handle: u32; flags: u32; fd: s32; pad: u32}` (16 bytes),
    `drm_syncobj_timeline_wait {handles: u64; points: u64; timeout_nsec: s64;
    count_handles: u32; flags: u32; first_signaled: u32; pad: u32}`,
    `drm_syncobj_transfer {src_handle, dst_handle: u32; src_point, dst_point: u64; flags, pad: u32}`,
    `drm_syncobj_timeline_array {handles: u64; points: u64; count_handles: u32; flags: u32}`.
  - Flags: `DRM_CAP_SYNCOBJ_TIMELINE` 0x14; `IMPORT_SYNC_FILE` and `EXPORT_SYNC_FILE`
    1 << 0; `WAIT_FOR_SUBMIT` 1 << 1.
  - The timeout is absolute: `clock_gettime(CLOCK_MONOTONIC)` + relative. A timeout of 0
    means "now", and a relative 0 stays 0.
  - `ETIME` → `TIMED_OUT`, no log. Retry `EINTR` and `EAGAIN`.
- [ ] **Step 4: Run** `./build.sh - syncobj_test`. Expect five PASS lines on this laptop.
- [ ] **Step 5: Commit** with message `feat(gpu): DRM syncobj timeline wrappers (raw ioctl, no libdrm)`.

### Task 2: EGL native fence → sync_file

**Files:**
- Modify: `modules/EGL/egl.jai` (`EGLSyncKHR :: *void`; `EGL_SYNC_NATIVE_FENCE_ANDROID :: 0x3144`;
  `EGL_NO_NATIVE_FENCE_FD_ANDROID :: -1`; pointers `eglCreateSyncKHR`, `eglDestroySyncKHR`,
  `eglDupNativeFenceFDANDROID`)
- Modify: `modules/EGL/loader.jai` (`init_egl_fence_extensions :: (dpy: EGLDisplay) -> bool`,
  true only when the display's `EGL_EXTENSIONS` lists `EGL_ANDROID_native_fence_sync` and
  all three pointers load)
- Modify: `modules/Wayland_Support.jai` (fence helper)
- Test: `tests/syncobj_test.jai`

**Interfaces:**
- Consumes: Task 1.
- Produces: in `Wayland_Support`, `wl_native_fence_fd :: (egl: Wl_Egl_State) -> s32` (flushes
  and returns a sync_file, or -1 after logging why), and
  `wl_have_native_fence: bool` (set by `wl_egl_init` from `init_egl_fence_extensions`).

- [ ] **Step 1: Write the failing tests** in `syncobj_test`, importing `Wayland_Support` by
  file with the `modules/`-first path, as `gl_picker_test` does.
  - `test_gl_fence_signals_timeline_point`: `WS.wl_egl_init(*egl, .{})`. SKIP when
    `!WS.wl_have_native_fence`. Then `glClear`, `fd := WS.wl_native_fence_fd(egl)`, assert
    fd ≥ 0, import it at point 1 of a new timeline on `egl.drm_fd`, and assert that
    `syncobj_wait(..., 1_000_000_000)` returns `SIGNALED`.
  - `test_finish_frame_replaces_stale_fence`: put a stale fd in a slot's `acquire_fence_fd`,
    call `wl_store_acquire_fence(slot, new_fd)`, and assert that `fcntl(old, F_GETFD) == -1`
    (closed) and the slot holds `new_fd`.
- [ ] **Step 2: Run** `./build.sh - syncobj_test`. It should fail to compile.
- [ ] **Step 3: Implement.** `wl_store_acquire_fence :: (slot: *Wl_Gl_Slot, fd: s32)` closes
  any previous fd. `wl_native_fence_fd` does
  `eglCreateSyncKHR(dpy, EGL_SYNC_NATIVE_FENCE_ANDROID, [EGL_NONE])`, then `glFlush`, then
  `eglDupNativeFenceFDANDROID`, then `eglDestroySyncKHR`.
- [ ] **Step 4: Run** `./build.sh - syncobj_test`. All PASS.
- [ ] **Step 5: Commit** with message `feat(EGL): native fence sync_file export for explicit sync`.

### Task 3: Explicit sync in the GL path

**Files:**
- Modify: `modules/Wayland_Support.jai`:
  - `Wl_Gl_Slot`: add `sync_timeline: u32`, `sync_timeline_obj: Wl.Wp_Linux_Drm_Syncobj_Timeline_V1`,
    `sync_point: u64`, `release_point: u64`; drop `release_fence_fd`.
  - `Wayland_Window`: add `wl_explicit_sync: bool`,
    `wl_syncobj_surface: Wl.Wp_Linux_Drm_Syncobj_Surface_V1`, `wl_sync_wait_warned: bool`,
    `wl_fence_warned: bool`.
  - Globals: `wl_syncobj_manager`, `wl_have_syncobj`, plus `wl_ensure_syncobj()` (bound
    like `wl_ensure_viewporter`).
- Modify: `modules/Simp/backend/wayland_dispatch.jai:80-82` (`glFinish()` → `WS.wl_finish_frame(ww)`)
- Test: `tests/syncobj_test.jai`

**Interfaces:**
- Consumes: Tasks 1-2.
- Produces:
  - `wl_explicit_sync_available :: () -> bool, reason: string`
  - `wl_finish_frame :: (ww: *Wayland_Window)`
  - `wl_set_acquire_point :: (drm_fd: s32, slot: *Wl_Gl_Slot) -> acquire: u64, release: u64, ok: bool`
    (imports `acquire_fence_fd`, or CPU-signals when it is -1; consumes and closes the fd;
    advances `sync_point` by 2)
  - `wl_refresh_slot_releases :: (drm_fd: s32, ww: *Wayland_Window)` (clears `in_flight`
    and `release_point` for every signalled slot)
  - `wl_reap_retired :: (batch: *Wl.MessageBuilder, drm_fd: s32, ww: *Wayland_Window)`

- [ ] **Step 1: Write the failing tests.**
  - `test_cpu_signal_fallback_sets_acquire`: a slot with a real timeline and
    `acquire_fence_fd = -1`. `wl_set_acquire_point` returns (1, 2, true) and point 1 reads
    signalled. A second call returns (3, 4).
  - `test_release_point_frees_slot`: a stack `Wayland_Window` with slot 0 `in_flight` and
    `release_point = 2`. `wl_refresh_slot_releases` leaves it in flight; after
    `syncobj_signal(t, 2)` it frees it.
  - `test_retired_slot_reaped_on_release_point`: a retired slot with `release_point = 2`
    survives `wl_reap_retired` until point 2 is signalled, then is removed (`wl_retired.count == 0`).
- [ ] **Step 2: Run them to see them fail** (compile errors).
- [ ] **Step 3: Implement** per the design's GL section:
  - In `wl_window_init_gl`, after the backend is chosen, decide `wl_explicit_sync`. When it
    is on, create the syncobj surface; log once in either case.
  - Slot init creates, exports, imports and closes the timeline fd after the send.
  - `wl_retire_slots`, `wl_release_retired_slot` and the reaper send
    `wp_linux_drm_syncobj_timeline_v1_destroy`. `wl_slot_destroy` destroys the handle.
  - In `wl_present_and_pace`, after the app-turn return: call `wl_set_acquire_point`, then
    `set_acquire_point` and `set_release_point` (hi/lo split), then commit, then record
    `release_point`.
  - Rotation runs `wl_refresh_slot_releases` and `wl_reap_retired`. Its blocking fallback
    waits on the in-flight release points in 10 ms slices, with `wl_pump_timed(0)` between
    them and one WARNING after 1 s.
  - The router stops clearing `in_flight` for explicit windows.
- [ ] **Step 4: Run** `./build.sh - syncobj_test` (all PASS), then the whole suite: every
  `*_test` target, all PASS, totals as in CLAUDE.md plus the new suite.
- [ ] **Step 5: Live check, nested first.** Run `hello_simp` on the nested Hyprland
  (wayland-2). Expect the log line saying explicit sync is on, an animating quad, and a
  clean close. Then on the live instance, with the temporary timing patch (`glFinish` was
  2.7-4.0 ms; expect `wl_finish_frame` under 0.2 ms). Revert the patch.
- [ ] **Step 6: Live sweep.**
  - All ten Simp examples (`wlrun.sh`), rc 0 and no errors.
  - A float with five resizes of `hello_simp`; `simp_multiple_windows`.
  - `hello_simp` moved to an empty workspace for 5 s and back: it stays alive, with no hang
    and at most one wait warning.
  - `JAI_WAYLAND_EXPLICIT_SYNC=0 hello_simp` logs that explicit sync is off and animates.
- [ ] **Step 7: Commit** with message `feat(Wayland_Support): explicit sync for the GL dma-buf path`.
  Update CLAUDE.md (backend layer, tests list and totals, known gaps, Next Steps #1) in the
  same commit.

### Task 4: Explicit sync in `hello_vulkan_dmabuf`

**Files:**
- Modify: `modules/Vulkan/module.jai` (`vkGetSemaphoreFdKHR: PFN_vkGetSemaphoreFdKHR;` beside
  `vkGetMemoryFdKHR`) and `modules/Vulkan/loader.jai` (load it in the device section)
- Modify: `examples/hello_vulkan_dmabuf.jai`

**Interfaces:**
- Consumes: Task 1.
- Produces (example-local):
  - `Vulkan_Context` gains `explicit_sync: bool`, `drm_fd: s32 = -1`, `has_semaphore_fd: bool`.
  - `Vulkan_Buffer` gains `cmd`, `fence`, `render_done`, `sync_timeline: u32`,
    `sync_timeline_obj`, `sync_point: u64`, `release_point: u64`, `acquire_fd: s32 = -1`.
  - `commit_slot :: (batch, surface, syncobj_surface, ctx, slot) -> bool` is the one place
    that attaches, sets points and commits.

- [ ] **Step 1: Implement:**
  - the `--no-explicit-sync` flag;
  - an availability check that enables `VK_KHR_external_semaphore_fd` when present and asks
    `vkGetPhysicalDeviceExternalSemaphoreProperties(SYNC_FD)` for export;
  - the DRM fd from the device's render node (`VkPhysicalDeviceDrmPropertiesEXT.renderMinor`,
    matched in `Gpu.discover_render_nodes`);
  - per-slot objects, created in `init_vulkan_slot` and destroyed after a fence wait;
  - the draw changes, a `commit_slot` used at all three commit sites, release-point reuse,
    the bounded wait when no slot is free, and retired-slot reaping by release point.

  The implicit path keeps `vkQueueWaitIdle`, `POLLOUT` and the release event.
- [ ] **Step 2: Compile:** `./build.sh - compile_only hello_vulkan_dmabuf`.
- [ ] **Step 3: Live:** each run 600 frames plus a float and resizes, rc 0, no errors:
  - Intel driver-first, live;
  - Intel `--copy-path`, live;
  - RTX 3050 Ti on the nested Hyprland, then live, with `bufinfo` (sudo) showing the iGPU
    attached;
  - `--no-explicit-sync` once, the regression check.
- [ ] **Step 4: Commit** with message `feat(hello_vulkan_dmabuf): explicit sync (SYNC_FD semaphores, per-slot timelines)`.
  Update CLAUDE.md's example entry and the audit doc in the same commit.

### Task 5: Hand-off for the dGPU-only reboot

- [ ] **Step 1:** Mark the design doc `Status: implemented on the hybrid laptop`. Note the
  dGPU-only checks still to run: `hello_simp`, `skeletal_animation`, Vulkan driver-first and
  `JAI_WAYLAND_EXPLICIT_SYNC=0`. Commit.
- [ ] **Step 2:** Report to Jim. Pushing waits for his word.
