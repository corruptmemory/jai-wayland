# Zero-copy GL presentation across GPUs (banked proposal)

**Status: banked 2026-10-31, not scheduled.** Picks up when something actually renders GL
on a GPU other than the compositor's. Since backport-audit item 11 (commit `b8fa4ec`),
nothing does by default: every GL window renders on the compositor's GPU, and the
cross-GPU GL path runs only when a client is pointed at the other GPU
(`JAI_WAYLAND_GPU_VENDOR` / `JAI_WAYLAND_RENDER_NODE`). **Prerequisite:** explicit sync
(`docs/plans/2026-10-31-explicit-sync-design.md`), whose fence plumbing this design
signals into; without it the Vulkan copy needs a CPU wait every frame and gives back most
of the gain.

## Where things stand

The GL path (`Wayland_Support`, every Simp example) presents across GPUs through the
`SHM_READBACK` backend (commit `3dffebb`). Each frame, `glReadPixels` copies the rendered
region into a memfd `wl_shm` buffer, and the compositor then uploads that buffer to its own
GPU. That is two copies per frame plus a CPU stall:

1. GPU -> CPU, inside `glReadPixels`, which also waits for the frame to finish.
2. CPU -> compositor GPU, done by the compositor for every shm commit.

Measured on `nomad-artix` (RTX 3050 Ti rendering, Hyprland 0.57 compositing on the Iris Xe),
`hello_simp`, averages of 240 frames:

| Window    | `glReadPixels` per frame | `glFinish` per frame |
|-----------|--------------------------|----------------------|
| 1016x1244 | 1.0-1.1 ms               | 0.05-0.07 ms         |
| 1960x1200 | 1.2-2.0 ms               | 0.05-0.10 ms         |

The compositor's per-frame upload (9.4 MB at 1960x1200) was not measured. It costs the
compositor's GPU, not the client.

The target is what NVIDIA's own drivers and `hello_vulkan_dmabuf`'s copy path already do
(audit, laptop section): one GPU-side copy per frame from video memory into a `LINEAR`
buffer in system memory, presented as a dma-buf that the compositor's GPU samples in place.
That means no CPU copy, no CPU stall and no compositor upload.

## What the drivers allow (probed 2026-10-31)

| Capability                                                    | NVIDIA 615.78      | Intel Mesa (Iris Xe) |
|---------------------------------------------------------------|--------------------|----------------------|
| `GL_EXT_memory_object`, `GL_EXT_memory_object_fd`             | yes                | yes                  |
| `GL_EXT_semaphore`, `GL_EXT_semaphore_fd`                     | yes                | yes                  |
| `EGL_ANDROID_native_fence_sync`, `EGL_KHR_wait_sync`          | yes                | yes                  |
| Vulkan semaphore export/import as `SYNC_FD`                   | yes                | yes                  |
| One buffer allocation exportable as `OPAQUE_FD` AND `DMA_BUF` | **no**             | yes                  |
| Renderable `LINEAR` (GBM with `GBM_BO_USE_RENDERING`, GL FBO) | no                 | yes                  |
| EGL import of `LINEAR` `ABGR8888` as `GL_TEXTURE_2D`          | no (external-only) | yes                  |

How the interop rows were read: `eglinfo -s -a glcore -p surfaceless` with
`__EGL_VENDOR_LIBRARY_FILENAMES` pointed at each glvnd vendor file. How the dual-export row
was read: a throwaway C probe calling `vkGetPhysicalDeviceExternalBufferProperties` for a
`TRANSFER_SRC | TRANSFER_DST` buffer. For NVIDIA, `compatibleHandleTypes` is `OPAQUE_FD`
alone for an `OPAQUE_FD` buffer and `DMA_BUF` alone for a `DMA_BUF` one. The last two rows
come from the 2026-10-31 copy-path work (`headless_cross_gpu`, the audit's laptop section).

The dual-export row decides the design. GL can import Vulkan memory only as an opaque fd
(`GL_HANDLE_TYPE_OPAQUE_FD_EXT`), and the compositor can take only a dma-buf. On NVIDIA no
single allocation is both, so GL cannot write straight into the buffer the compositor
reads.

## The design

GL renders into memory Vulkan owns, and Vulkan does the cross-GPU copy:

1. **Per slot, Vulkan allocates two things:**
   - a device-local `OPTIMAL` `VkImage` (`R8G8B8A8_UNORM`, `COLOR_ATTACHMENT | TRANSFER_SRC`)
     exported as `OPAQUE_FD`;
   - the copy path's system-memory `VkBuffer`, exported as `DMA_BUF` and wrapped as the
     slot's `wl_buffer` with modifier `LINEAR`. This is `hello_vulkan_dmabuf`'s
     `create_copy_path_buffer`, rows padded to 256 bytes.
2. **GL imports the image as the slot's colour attachment:** `glCreateMemoryObjectsEXT`,
   `glImportMemoryFdEXT(GL_HANDLE_TYPE_OPAQUE_FD_EXT)` (plus `GL_DEDICATED_MEMORY_OBJECT_EXT`
   when Vulkan required a dedicated allocation), then `glTexStorageMem2DEXT(GL_RGBA8)` with
   `GL_TEXTURE_TILING_EXT = GL_OPTIMAL_TILING_EXT`. The depth renderbuffer stays GL-native.
   Simp renders into the slot FBO exactly as it does now.
3. **Handoff, each frame:** GL signals a Vulkan-exported `OPAQUE_FD` semaphore with
   `glSignalSemaphoreEXT`, naming the texture with destination layout
   `GL_LAYOUT_TRANSFER_SRC_EXT`. Vulkan waits on it, runs the copy path's
   `vkCmdCopyImageToBuffer` plus the release to `VK_QUEUE_FAMILY_FOREIGN_EXT`, and signals a
   `SYNC_FD` semaphore. That fence becomes the commit's acquire point (explicit sync).
4. **Matching devices:** the Vulkan device must be the GL context's GPU. Match
   `GL_DEVICE_UUID_EXT` / `GL_DRIVER_UUID_EXT` (`glGetUnsignedBytevEXT`) against
   `VkPhysicalDeviceIDProperties.deviceUUID` / `.driverUUID`.

Row order is unchanged. Texel (0, 0) of the GL texture is texel (0, 0) of the `VkImage`, and
`vkCmdCopyImageToBuffer` writes row 0 first, so rows land in GL order as they do in a
BO-backed slot and in the readback. `FLIPPED_180` and the viewport crop apply unchanged.

**Structure:**
- Lift `hello_vulkan_dmabuf`'s copy-path pieces into a module that example and
  `Wayland_Support` both use: `find_system_memory_type`, `create_copy_path_buffer`,
  `choose_copy_path_config`, and the barrier / copy / foreign-release sequence.
- Add a third `Wl_Gl_Backend` beside the BO-backed and `SHM_READBACK` ones, chosen when the
  relation is not `SAME` and every requirement above holds.
- `SHM_READBACK` stays as the last resort, so every compositor keeps working. That includes
  one advertising no `LINEAR` format, or no `zwp_linux_dmabuf_v1` at all.
- Vulkan is `dlopen`ed only when this backend is chosen (linkage thesis). `Wayland_Support`
  owns one Vulkan instance and device for the process, as it owns the shared EGL context.

## Dead ends, so nobody re-walks them

- **A GL pixel-pack buffer over the presented memory.** `glBufferStorageMemEXT` on the
  dma-buf `VkBuffer`, with `glReadPixels` into it as a GPU copy, would be the smallest
  change. It needs one allocation exported as both handle types, which NVIDIA refuses.
- **GL writing into a dma-buf directly.** NVIDIA's EGL imports `LINEAR` `ABGR8888` as
  external-only (sample-only), and its GBM will not allocate a renderable `LINEAR` BO. An
  NVIDIA-allocated BO in video memory is what crashed Hyprland three times.
- **Asynchronous readback** (`glReadPixels` into a GL pixel-pack buffer, a fence, then a
  `memcpy` into the shm buffer next frame). It removes the stall but keeps the CPU copy and
  the compositor upload. Not worth its code next to the design above.

## Risks and open questions

- **Layout semantics.** `GL_EXT_semaphore`'s texture layouts must match the Vulkan barrier's
  `oldLayout`. Getting this wrong is silent corruption, not an error, so the first
  milestone should be headless: `headless_cross_gpu`'s pixel check, with GL as the writer.
- **Slot reallocation on resize.** Bucketed capacity (`wl_target_capacity`) now has to
  recreate Vulkan objects too, and retire them only after their release point signals.
- **Who owns the Vulkan device.** Process lifetime, created on first use. It has to stay
  independent of `hello_vulkan_dmabuf`'s own device, since that example does not use
  `Wayland_Support`.
- **Validation order.** As the copy path did it: headless first, then a nested Hyprland,
  then the live one. Check `bufinfo` for the compositor GPU attached to each buffer. To
  re-time, use the same throwaway patch as the measurements above: `seconds_since_init()`
  around `glFinish` in `wl_swap_buffers` and around `wl_read_back_slot` in
  `wl_present_and_pace`, logged as an average every 240 frames, then reverted.

## When to pick this up

When a real program renders GL on the dGPU: a game-bootstrap title choosing the discrete
GPU for performance, say. Until then the readback is correct everywhere and costs the client
1-2 ms per frame, on a path nothing takes by default.
