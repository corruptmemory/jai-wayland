// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jim Powers

// hello_vulkan_dmabuf — present a Vulkan-rendered DRM-modifier DMA-BUF in a
// Wayland window. Deliberately avoids VK_KHR_wayland_surface: that WSI path wants
// libwayland-client proxy pointers, while jai-wayland owns only the wire objects.
//
// Format/modifier selection is DRIVER-FIRST: we enumerate the Vulkan driver's own
// supported modifiers (VkDrmFormatModifierPropertiesListEXT) and probe each against
// the compositor with the async zwp_linux_buffer_params_v1.create + created/failed
// arbiter — driver-tiled modifiers first, DRM_FORMAT_MOD_LINEAR as the safety net.
// The first modifier the compositor ACCEPTS wins. This is the Vulkan analogue of the
// GL/GBM "request DRM_FORMAT_MOD_INVALID, let the driver pick its own native
// modifier" path, and it is what makes this work on NVIDIA pure-dGPU — where the
// compositor's advertised dmabuf feedback under-reports the modifiers it will
// actually import. Falls back to selecting from the compositor's advertised list if
// the probe finds nothing accepted (never worse than feedback-only selection).
// Validated on Mesa (AMD/Intel) and NVIDIA pure-dGPU (RTX 3050 Ti).
//
// All of that is only for the compositor's own GPU, because a probe already hands the
// compositor a real dma-buf straight from the Vulkan device, and a compositor may
// accept a buffer it cannot read: Hyprland 0.57 on an Intel iGPU accepted
// NVIDIA-rendered buffers, block-linear and advertised LINEAR alike, then aborted inside
// Mesa on its next frame, three times (2026-10-31, nomad-artix).
//
// So when the Vulkan device is a different GPU from the compositor's main device (a
// hybrid laptop compositing on the iGPU while this renders on the dGPU), or when that
// cannot be established, it presents through the COPY PATH instead, which is what
// NVIDIA's own Wayland WSI does: render into a device-local OPTIMAL image as usual, then
// every frame vkCmdCopyImageToBuffer it into a VkBuffer in SYSTEM memory (rows padded to
// a 256-byte pitch), and hand the compositor that buffer as LINEAR. No probe runs and no
// device-memory buffer is ever sent. headless_cross_gpu proves the compositor's GPU reads
// such a buffer correctly. The format is one the compositor advertises with the LINEAR
// modifier; if it advertises none, the example refuses. `--copy-path` forces the copy
// path on the compositor's own GPU too (a safe way to exercise it on any box).

#import,dir "../modules/wayland";
Vulkan :: #import,dir "../modules/Vulkan";
Gpu    :: #import,dir "../modules/gpu";

#import "Basic";
#import "File";
#import "POSIX";
#import "String";
#import "System";

DEFAULT_WIDTH  :: 640;
DEFAULT_HEIGHT :: 480;

DRM_FORMAT_ARGB8888 :: #run fourcc(#char "A", #char "R", #char "2", #char "4");
DRM_FORMAT_XRGB8888 :: #run fourcc(#char "X", #char "R", #char "2", #char "4");
DRM_FORMAT_ABGR8888 :: #run fourcc(#char "A", #char "B", #char "2", #char "4");
DRM_FORMAT_XBGR8888 :: #run fourcc(#char "X", #char "B", #char "2", #char "4");

Image_Config :: struct {
    vk_format:           Vulkan.VkFormat;
    wayland_format:      u32;
    usage:               Vulkan.VkImageUsageFlags;
    label:               string;
    drm_format_modifier: u64;
    plane_count:         u32;
    copy_path:           bool;   // render OPTIMAL, copy each frame into a system-memory LINEAR buffer
}

Vulkan_Context :: struct {
    instance:     Vulkan.VkInstance;
    physical:     Vulkan.VkPhysicalDevice;
    device:       Vulkan.VkDevice;
    queue:        Vulkan.VkQueue;
    queue_family: u32;
    command_pool: Vulkan.VkCommandPool;
    has_foreign:  bool;   // VK_EXT_queue_family_foreign enabled
    integrated:   bool;   // an iGPU: all of its memory is system memory
    has_semaphore_fd: bool;   // VK_KHR_external_semaphore_fd enabled
    // Explicit sync (linux-drm-syncobj-v1): each commit carries an acquire point (the
    // submit's SYNC_FD semaphore) and a release point the compositor signals; see
    // setup_explicit_sync. drm_fd is this device's render node, where the timelines live.
    explicit_sync: bool;
    drm_fd:        s32 = -1;
    syncobj_manager: Wp_Linux_Drm_Syncobj_Manager_V1;
}

Vulkan_Triangle :: struct {
    render_pass:     Vulkan.VkRenderPass;
    pipeline_layout: Vulkan.VkPipelineLayout;
    pipeline:        Vulkan.VkPipeline;
}

Vulkan_Buffer :: struct {
    image:       Vulkan.VkImage;
    image_view:  Vulkan.VkImageView;
    framebuffer: Vulkan.VkFramebuffer;
    memory:      Vulkan.VkDeviceMemory;
    copy_buffer: Vulkan.VkBuffer;         // copy path only: the system-memory buffer the compositor reads
    copy_memory: Vulkan.VkDeviceMemory;   // copy path only: its memory, which `fd` exports
    buffer:      Wl_Buffer;
    fd:          s32 = -1;
    offset:      u32;
    stride:      u32;
    format:      u32;
    modifier:    u64;
    width:       s32;
    height:      s32;
    in_flight: bool;
    ever_used: bool;
    // Per slot, both modes: a reusable command buffer and the fence of its last submit.
    cmd:   Vulkan.VkCommandBuffer;
    fence: Vulkan.VkFence;
    // Explicit sync only. render_done is signalled by each submit and exported as the
    // commit's acquire fence (acquire_fd). One timeline per slot: commit n uses acquire
    // point 2n-1 and release point 2n, so points are always added in increasing order.
    render_done:       Vulkan.VkSemaphore;
    acquire_fd:        s32 = -1;
    sync_timeline:     u32;
    sync_timeline_fd:  s32 = -1;
    sync_timeline_obj: Wp_Linux_Drm_Syncobj_Timeline_V1;
    sync_point:        u64;
    release_point:     u64;   // pending; 0 when the compositor holds nothing
}

main :: () {
    force_copy_path := false;
    want_explicit_sync := true;
    args := get_command_line_arguments();
    for args {
        if it_index == 0  continue;
        if it == "--copy-path"  force_copy_path = true;
        else if it == "--no-explicit-sync"  want_explicit_sync = false;
        else {
            print("Unknown argument '%'.\nUsage: % [--copy-path] [--no-explicit-sync]\n", it, args[0]);
            print("  --copy-path         present through the system-memory copy even on the compositor's own GPU\n");
            print("  --no-explicit-sync  wait for the GPU before each commit instead of handing the compositor fences\n");
            exit(1);
        }
    }

    if !init_wayland_session() {
        print("Failed to create Wayland session\n");
        return;
    }
    defer end_wayland_session();

    dmabuf_info, dmabuf_ok := get_dmabuf_info();
    if !dmabuf_ok {
        print("Compositor does not support zwp_linux_dmabuf_v1\n");
        return;
    }

    batch: MessageBuilder;
    surface := Wl_Surface.{ id = allocate_id() };
    xdg_surface := Xdg_Surface.{ id = allocate_id() };
    toplevel := Xdg_Toplevel.{ id = allocate_id() };
    wl_compositor_create_surface(*batch, compositor(), surface.id);
    xdg_wm_base_get_xdg_surface(*batch, wm_base(), xdg_surface.id, *surface);
    xdg_surface_get_toplevel(*batch, *xdg_surface, toplevel.id);
    xdg_toplevel_set_title(*batch, *toplevel, "hello_vulkan_dmabuf");
    xdg_toplevel_set_app_id(*batch, *toplevel, "hello_vulkan_dmabuf");
    wl_surface_commit(*batch, *surface);
    wayland_send(*batch);

    win_width:  s32 = DEFAULT_WIDTH;
    win_height: s32 = DEFAULT_HEIGHT;
    configure_serial: u32 = 0;
    for session() {
        if it.object_id == toplevel.id && it.opcode == XDG_TOPLEVEL_CONFIGURE {
            args: Xdg_Toplevel_Configure_Args;
            unmarshal(*args, it.payload, recv);
            if args.width > 0 && args.height > 0 {
                win_width = args.width;
                win_height = args.height;
            }
        } else if it.object_id == xdg_surface.id && it.opcode == XDG_SURFACE_CONFIGURE {
            configure_serial = read_u32(it.payload);
            break;
        }
    }
    if configure_serial == 0 {
        print("Did not receive xdg_surface.configure\n");
        return;
    }
    print("Configured window: %x%\n", win_width, win_height);

    // The feedback names the compositor's main device, which picks the Vulkan device
    // (its GPU by default) and decides between the probe and the copy path.
    feedback: Dmabuf_Feedback_Info;
    feedback_ok := false;
    if dmabuf_info.feedback_supported {
        feedback, feedback_ok = get_surface_dmabuf_feedback(*dmabuf_info.dmabuf, *surface);
    }
    main_major, main_minor: u32;
    main_known := false;
    if feedback_ok && feedback.complete  main_major, main_minor, main_known = dev_major_minor(feedback.main_device);

    ctx: Vulkan_Context;
    if !init_vulkan_context(*ctx, main_major, main_minor, main_known)  return;
    defer destroy_vulkan_context(*ctx);
    // Decided before the first probe: a probe already hands the compositor a real dma-buf.
    relation := compositor_gpu_relation(ctx.physical, feedback, feedback_ok);
    copy_path := force_copy_path || relation != .SAME;
    if copy_path {
        if relation == .SAME  print("--copy-path: presenting through the system-memory copy on the compositor's own GPU\n");
        else                  print("Presenting through the system-memory copy: the compositor may not be able to read this GPU's memory\n");
    }

    config: Image_Config;
    config_ok: bool;
    if copy_path {
        config, config_ok = choose_copy_path_config(*ctx, dmabuf_info, feedback, feedback_ok);
        if !config_ok {
            print("Refusing to present: the copy path needs a LINEAR ARGB/XRGB/ABGR/XBGR 8888 format the compositor\n");
            print("advertises and a Vulkan device that can export a transfer-destination buffer from system memory,\n");
            print("and one of them is missing (see above). Handing over this GPU's own buffers instead is what crashed\n");
            print("Hyprland 0.57 on an Intel iGPU.\n");
            exit(1);
        }
    } else {
        // Driver-first selection: enumerate the Vulkan driver's own modifiers and probe
        // each against the compositor; only fall back to the compositor-advertised list
        // if nothing is accepted. See the file header for why (NVIDIA pure-dGPU).
        config, config_ok = choose_image_config_driver_first(*ctx, *dmabuf_info.dmabuf);
    }

    if !config_ok {
        print("Driver-enumerated probe found no compositor-accepted modifier; falling back to compositor-advertised selection.\n");
        if feedback_ok  print("Using dmabuf surface feedback for Vulkan format selection\n");
        config, config_ok = choose_image_config(ctx.physical, dmabuf_info, feedback, feedback_ok);
    }

    if !config_ok {
        print("No compatible Vulkan DMA-BUF image configuration found (driver-enumerated AND compositor-advertised).\n");
        return;
    }

    print("Using image config: % fourcc=0x% modifier=0x% planes=%%\n",
        config.label,
        formatInt(config.wayland_format, base=16),
        formatInt(config.drm_format_modifier, base=16, minimum_digits=16),
        config.plane_count,
        ifx config.copy_path then " (copy path: OPTIMAL render, system-memory LINEAR present)" else "");

    tri: Vulkan_Triangle;
    if !init_vulkan_triangle(*ctx, config, *tri)  return;
    defer destroy_vulkan_triangle(*ctx, *tri);

    reason := setup_explicit_sync(*ctx, want_explicit_sync);
    if ctx.explicit_sync  print("Explicit sync: on (wp_linux_drm_syncobj_v1, SYNC_FD semaphores, timelines on the render node)\n");
    else                  print("Explicit sync: off (%); waiting for the GPU before each commit\n", reason);
    defer if ctx.drm_fd >= 0  close(ctx.drm_fd);
    syncobj_surface: Wp_Linux_Drm_Syncobj_Surface_V1;
    if ctx.explicit_sync {
        // Before the first buffer commit: from here on every commit that attaches a
        // buffer must carry both points (commit_slot).
        syncobj_surface.id = allocate_id();
        wp_linux_drm_syncobj_manager_v1_get_surface(*batch, *ctx.syncobj_manager, syncobj_surface.id, *surface);
    }

    slots: [2] Vulkan_Buffer;
    for * slot, i: slots {
        if !init_vulkan_slot(*ctx, *tri, config, *dmabuf_info.dmabuf, *batch, win_width, win_height, slot) {
            print("Failed to initialize Vulkan slot %\n", i);
            return;
        }
    }
    defer for * slots  destroy_vulkan_buffer(*ctx, it);

    rotation_start := monotonic_seconds();
    if !paint_vulkan_slot(ctx, tri, *slots[0], rotation_angle(rotation_start))  return;

    frame_cache: Id_Cache;
    frame_callback_id := cache_alloc(*frame_cache);
    xdg_surface_ack_configure(*batch, *xdg_surface, configure_serial);
    wl_surface_frame(*batch, *surface, frame_callback_id);
    if !commit_slot(*batch, *surface, *ctx, *syncobj_surface, *slots[0])  return;
    wayland_send(*batch);
    slots[0].in_flight = true;

    frame_limit := frame_limit_from_env();
    frames_submitted: u32 = 1;
    frame_requested := true;
    dirty := true;
    pending_width:  s32 = 0;
    pending_height: s32 = 0;
    resize_width:   s32 = 0;
    resize_height:  s32 = 0;
    resize_serial:  u32 = 0;
    resize_pending := false;
    retired_slots: [..] Vulkan_Buffer;
    defer for * retired_slots  destroy_vulkan_buffer(*ctx, it);

    if frame_limit > 0 {
        print("hello_vulkan_dmabuf: frame-paced Vulkan triangle smoke (% frames).\n", frame_limit);
    } else {
        print("hello_vulkan_dmabuf: spinning Vulkan triangle. Close the window to exit.\n");
    }

    for session() {
        defer {
            if ctx.explicit_sync {
                // wl_buffer.release is undefined under explicit sync: release points decide.
                refresh_slot_releases(*ctx, slots);
                if reap_retired_slots(*ctx, *batch, *retired_slots)  wayland_send(*batch);
            }
            if resize_pending && !frame_requested {
                retire_slots(*ctx, *batch, *retired_slots, slots);

                for * slot, i: slots {
                    if !init_vulkan_slot(*ctx, *tri, config, *dmabuf_info.dmabuf, *batch, resize_width, resize_height, slot) {
                        assert(false, "Failed to initialize resized Vulkan slot %", i);
                    }
                }

                win_width = resize_width;
                win_height = resize_height;

                if !paint_vulkan_slot(ctx, tri, *slots[0], rotation_angle(rotation_start)) {
                    assert(false, "Failed to draw resized Vulkan slot");
                }

                frame_callback_id = cache_alloc(*frame_cache);
                xdg_surface_ack_configure(*batch, *xdg_surface, resize_serial);
                wl_surface_frame(*batch, *surface, frame_callback_id);
                if !commit_slot(*batch, *surface, *ctx, *syncobj_surface, *slots[0]) {
                    assert(false, "Failed to commit resized Vulkan slot");
                }
                wayland_send(*batch);

                slots[0].in_flight = true;
                frames_submitted += 1;
                frame_requested = true;
                dirty = false;
                resize_pending = false;
            } else if dirty && !frame_requested && !resize_pending {
                slot_idx := find_free_slot(slots);
                if slot_idx < 0 && ctx.explicit_sync  slot_idx = wait_for_released_slot(*ctx, slots);
                if slot_idx >= 0 {
                    slot := *slots[slot_idx];
                    if !paint_vulkan_slot(ctx, tri, slot, rotation_angle(rotation_start)) {
                        assert(false, "Failed to draw Vulkan slot");
                    }

                    frame_callback_id = cache_alloc(*frame_cache);
                    wl_surface_frame(*batch, *surface, frame_callback_id);
                    if !commit_slot(*batch, *surface, *ctx, *syncobj_surface, slot) {
                        assert(false, "Failed to commit Vulkan slot");
                    }
                    wayland_send(*batch);

                    slot.in_flight = true;
                    frames_submitted += 1;
                    frame_requested = true;
                    dirty = false;
                }
            }
        };

        if it.object_id == frame_callback_id && it.opcode == WL_CALLBACK_DONE {
            cache_free(*frame_cache, frame_callback_id);
            frame_requested = false;
            if frame_limit > 0 && frames_submitted >= frame_limit {
                dirty = false;
                print("Frame limit reached (% frames submitted).\n", frames_submitted);
                break;
            }
            dirty = true;
            continue;
        }

        if it.opcode == WL_BUFFER_RELEASE {
            matched := false;
            obj_id := it.object_id;
            for * slots  if it.buffer.id == obj_id {
                // Under explicit sync the event's timing is undefined and the
                // compositor's GPU may still be reading: the release point decides.
                if !ctx.explicit_sync  it.in_flight = false;
                matched = true;
                break;
            }
            if matched  continue;
            if release_retired_slot(*ctx, *batch, *retired_slots, obj_id) {
                wayland_send(*batch);
                continue;
            }
        }

        if it.object_id == toplevel.id {
            if it.opcode == XDG_TOPLEVEL_CLOSE {
                print("Close requested.\n");
                break;
            } else if it.opcode == XDG_TOPLEVEL_CONFIGURE {
                args: Xdg_Toplevel_Configure_Args;
                unmarshal(*args, it.payload, recv);
                if args.width > 0 && args.height > 0 {
                    pending_width = args.width;
                    pending_height = args.height;
                }
                continue;
            }
        } else if it.object_id == xdg_surface.id && it.opcode == XDG_SURFACE_CONFIGURE {
            serial := read_u32(it.payload);
            if pending_width > 0 && pending_height > 0 &&
               (pending_width != win_width || pending_height != win_height)
            {
                resize_width = pending_width;
                resize_height = pending_height;
                resize_serial = serial;
                resize_pending = true;
                dirty = false;
            } else {
                xdg_surface_ack_configure(*batch, *xdg_surface, serial);
                wayland_send(*batch);
            }
            continue;
        }
    }
}

fourcc :: (a: u8, b: u8, c: u8, d: u8) -> u32 {
    return (cast(u32) a)
         | ((cast(u32) b) << 8)
         | ((cast(u32) c) << 16)
         | ((cast(u32) d) << 24);
}

queue_dmabuf_buffer :: (batch: *MessageBuilder, dmabuf: *Zwp_Linux_Dmabuf_V1, buffer: *Wl_Buffer,
                        fd: s32, offset: u32, stride: u32, format: u32, modifier: u64, width: s32, height: s32) {
    params := Zwp_Linux_Buffer_Params_V1.{ id = allocate_id() };
    zwp_linux_dmabuf_v1_create_params(batch, dmabuf, params.id);
    zwp_linux_buffer_params_v1_add(batch, *params,
        fd          = cast(Fd) fd,
        plane_idx   = 0,
        offset      = offset,
        stride      = stride,
        modifier_hi = cast(u32)(modifier >> 32),
        modifier_lo = cast(u32)(modifier & 0xFFFFFFFF));

    buffer.* = Wl_Buffer.{ id = allocate_id() };
    zwp_linux_buffer_params_v1_create_immed(batch, *params,
        new_id = buffer.id,
        width  = width,
        height = height,
        format = format,
        flags  = 0);
    zwp_linux_buffer_params_v1_destroy(batch, *params);
}

init_vulkan_slot :: (ctx: *Vulkan_Context, tri: *Vulkan_Triangle, config: Image_Config, dmabuf: *Zwp_Linux_Dmabuf_V1,
                     batch: *MessageBuilder, width: s32, height: s32, slot: *Vulkan_Buffer) -> bool {
    slot.* = .{};
    if !create_vulkan_buffer(ctx, config, width, height, slot)  return false;
    if !create_vulkan_slot_render_targets(ctx, tri, config, slot) || !create_slot_sync(ctx, slot) {
        destroy_vulkan_buffer_without_wayland(ctx, slot);
        return false;
    }
    queue_dmabuf_buffer(batch, dmabuf, *slot.buffer,
        slot.fd, slot.offset, slot.stride, slot.format, slot.modifier, slot.width, slot.height);
    if ctx.explicit_sync {
        slot.sync_timeline_obj = .{ id = allocate_id() };
        wp_linux_drm_syncobj_manager_v1_import_timeline(batch, *ctx.syncobj_manager, slot.sync_timeline_obj.id, cast(Fd) slot.sync_timeline_fd);
    }
    return true;
}

// The slot's command buffer and fence (created signalled, so the first draw does not
// wait), plus, under explicit sync, its exportable semaphore and its timeline (the fd
// stays open until the slot is destroyed, past the send of its import).
create_slot_sync :: (ctx: *Vulkan_Context, slot: *Vulkan_Buffer) -> bool {
    alloc := Vulkan.VkCommandBufferAllocateInfo.{ commandPool = ctx.command_pool, level = .PRIMARY, commandBufferCount = 1 };
    result := Vulkan.vkAllocateCommandBuffers(ctx.device, *alloc, *slot.cmd);
    if result != .SUCCESS { print("vkAllocateCommandBuffers failed: %\n", result); return false; }

    fence_info := Vulkan.VkFenceCreateInfo.{ flags = .SIGNALED_BIT };
    result = Vulkan.vkCreateFence(ctx.device, *fence_info, null, *slot.fence);
    if result != .SUCCESS { print("vkCreateFence failed: %\n", result); return false; }

    if !ctx.explicit_sync  return true;

    export := Vulkan.VkExportSemaphoreCreateInfo.{ handleTypes = .SYNC_FD_BIT };
    sem_info := Vulkan.VkSemaphoreCreateInfo.{ pNext = *export };
    result = Vulkan.vkCreateSemaphore(ctx.device, *sem_info, null, *slot.render_done);
    if result != .SUCCESS { print("vkCreateSemaphore(SYNC_FD export) failed: %\n", result); return false; }

    ok: bool;
    slot.sync_timeline, ok = Gpu.syncobj_create(ctx.drm_fd);
    if !ok  return false;
    slot.sync_timeline_fd = Gpu.syncobj_export(ctx.drm_fd, slot.sync_timeline);
    return slot.sync_timeline_fd >= 0;
}

// The one place a buffer is attached and committed. Under explicit sync it first
// attaches the submit's fence to the slot's next acquire point and sets both points.
commit_slot :: (batch: *MessageBuilder, surface: *Wl_Surface, ctx: *Vulkan_Context,
                syncobj_surface: *Wp_Linux_Drm_Syncobj_Surface_V1, slot: *Vulkan_Buffer) -> bool {
    if ctx.explicit_sync {
        acquire := slot.sync_point + 1;
        release := acquire + 1;
        // acquire_fd is -1 when the export found the semaphore already signalled
        // (spec-legal): the point is then signalled from the CPU.
        ok := Gpu.syncobj_attach_fence(ctx.drm_fd, slot.sync_timeline, acquire, slot.acquire_fd);
        if slot.acquire_fd >= 0  close(slot.acquire_fd);
        slot.acquire_fd = -1;
        if !ok {
            log_error("Could not set the acquire point for slot buffer %; cannot commit it under explicit sync", slot.buffer.id);
            return false;
        }
        wp_linux_drm_syncobj_surface_v1_set_acquire_point(batch, syncobj_surface, *slot.sync_timeline_obj,
            cast(u32) (acquire >> 32), cast(u32) (acquire & 0xFFFF_FFFF));
        wp_linux_drm_syncobj_surface_v1_set_release_point(batch, syncobj_surface, *slot.sync_timeline_obj,
            cast(u32) (release >> 32), cast(u32) (release & 0xFFFF_FFFF));
        slot.sync_point    = release;
        slot.release_point = release;
    }
    wl_surface_attach(batch, surface, *slot.buffer, 0, 0);
    wl_surface_damage_buffer(batch, surface, 0, 0, slot.width, slot.height);
    wl_surface_commit(batch, surface);
    return true;
}

// Explicit sync: a slot leaves flight when its release point has signalled.
refresh_slot_releases :: (ctx: *Vulkan_Context, slots: [] Vulkan_Buffer) {
    for * slots {
        if !it.in_flight || it.release_point == 0  continue;
        if Gpu.syncobj_point_signaled(ctx.drm_fd, it.sync_timeline, it.release_point) {
            it.in_flight     = false;
            it.release_point = 0;
        }
    }
}

// Explicit sync, a frame is due and both slots are in flight: the event loop sleeps on
// the Wayland socket and wl_buffer.release can no longer be relied on to wake it, so
// wait here on the release points, bounded. -1 (with a warning) on timeout; the next
// event retries.
RELEASE_WAIT_NS :: 1_000_000_000;
// How long a slot's last submit may take before a draw or a destroy gives up on it.
FENCE_WAIT_NS   :: 1_000_000_000;

wait_for_released_slot :: (ctx: *Vulkan_Context, slots: [] Vulkan_Buffer) -> int {
    handles: [2] u32;
    points:  [2] u64;
    n := 0;
    for slots {
        if !it.in_flight || it.release_point == 0 || n >= handles.count  continue;
        handles[n] = it.sync_timeline;
        points[n]  = it.release_point;
        n += 1;
    }
    if n == 0  return -1;
    result := Gpu.syncobj_wait(ctx.drm_fd, array_view(handles, 0, n), array_view(points, 0, n), RELEASE_WAIT_NS);
    if result == .TIMED_OUT  log("No release point signalled within % ms; skipping this frame", RELEASE_WAIT_NS / 1_000_000, flags = .WARNING);
    refresh_slot_releases(ctx, slots);
    return find_free_slot(slots);
}

// Explicit sync: destroy retired slots whose release point has signalled (a
// wl_buffer.release for one still destroys it first if it comes). True if anything
// was queued into `batch`.
reap_retired_slots :: (ctx: *Vulkan_Context, batch: *MessageBuilder, retired: *[..] Vulkan_Buffer) -> bool {
    queued := false;
    i := 0;
    while i < retired.count {
        slot := *(retired.*)[i];
        if slot.release_point == 0 || Gpu.syncobj_point_signaled(ctx.drm_fd, slot.sync_timeline, slot.release_point) {
            queue_slot_destroy(batch, slot);
            destroy_vulkan_buffer_without_wayland(ctx, slot);
            array_unordered_remove_by_index(retired, i);
            queued = true;
            continue;
        }
        i += 1;
    }
    return queued;
}

// The protocol objects of a slot being destroyed: its wl_buffer and, under explicit
// sync, the compositor's import of its timeline (points already set stay set).
queue_slot_destroy :: (batch: *MessageBuilder, slot: *Vulkan_Buffer) {
    wl_buffer_destroy(batch, *slot.buffer);
    if slot.sync_timeline_obj.id != 0  wp_linux_drm_syncobj_timeline_v1_destroy(batch, *slot.sync_timeline_obj);
}

// Turns explicit sync on when everything it needs is present; otherwise says why not.
setup_explicit_sync :: (ctx: *Vulkan_Context, wanted: bool) -> reason: string {
    if !wanted  return "--no-explicit-sync";
    _, advertised := get_global("wp_linux_drm_syncobj_manager_v1");
    if !advertised  return "the compositor does not advertise wp_linux_drm_syncobj_manager_v1";
    if !ctx.has_semaphore_fd || Vulkan.vkGetSemaphoreFdKHR == null  return "the device lacks VK_KHR_external_semaphore_fd";
    // Core in Vulkan 1.1; a 1.0 instance (see init_vulkan_context) may not have it.
    if Vulkan.vkGetPhysicalDeviceExternalSemaphoreProperties == null  return "the Vulkan instance lacks vkGetPhysicalDeviceExternalSemaphoreProperties (Vulkan 1.1)";

    info := Vulkan.VkPhysicalDeviceExternalSemaphoreInfo.{ handleType = .SYNC_FD_BIT };
    props: Vulkan.VkExternalSemaphoreProperties;
    Vulkan.vkGetPhysicalDeviceExternalSemaphoreProperties(ctx.physical, *info, *props);
    if !(props.externalSemaphoreFeatures & .EXPORTABLE_BIT)  return "the device cannot export SYNC_FD semaphores";

    drm, drm_ok := vulkan_device_drm_properties(ctx.physical);
    if !drm_ok || !drm.hasRender  return "the device does not name its DRM render node (VK_EXT_physical_device_drm)";
    nodes: [..] Gpu.Render_Node_Info;
    Gpu.discover_render_nodes(*nodes);
    path := "";
    for nodes  if it.major == cast(u32) drm.renderMajor && it.minor == cast(u32) drm.renderMinor  path = it.path;
    if path == ""  return tprint("no render node matches the device's %:%", drm.renderMajor, drm.renderMinor);
    fd := open(temp_c_string(path), O_RDWR | O_CLOEXEC);
    if fd < 0  return tprint("cannot open % (errno %)", path, errno());
    if !Gpu.syncobj_timeline_supported(fd) {
        close(fd);
        return tprint("% has no timeline sync objects", path);
    }

    ctx.syncobj_manager = .{ id = allocate_id() };
    batch: MessageBuilder;
    if !wl_registry_bind(*batch, registry(), *ctx.syncobj_manager) || !wayland_send(*batch) {
        close(fd);
        ctx.syncobj_manager = .{};
        return "binding wp_linux_drm_syncobj_manager_v1 failed";
    }
    ctx.drm_fd = fd;
    ctx.explicit_sync = true;
    return "";
}

paint_vulkan_slot :: (ctx: Vulkan_Context, tri: Vulkan_Triangle, slot: *Vulkan_Buffer, angle: float) -> bool {
    first_use := !slot.ever_used;
    // Under explicit sync the slot was chosen only after its release point signalled,
    // which covers the compositor GPU's reads; the compositor may also stop attaching
    // the implicit read fences POLLOUT waits on.
    if slot.copy_buffer != null && !first_use && !ctx.explicit_sync  wait_for_compositor_reads(slot);
    if !draw_vulkan_triangle(ctx, tri, slot, angle, first_use)  return false;
    slot.ever_used = true;
    return true;
}

// VK_QUEUE_FAMILY_FOREIGN_EXT. The generated binding spells it `~0-2`, an untyped
// constant; this is the u32 the spec defines.
QUEUE_FAMILY_FOREIGN : u32 : 0xffff_fffd;

// wl_buffer.release says the compositor is done with a buffer, but its GPU may still be
// reading: i915 attaches a read fence to the dma-buf for every use (step 1's bufinfo
// showed one). Vulkan's writes do not wait on those, so the copy path waits on the CPU:
// POLLOUT on a dma-buf fd is ready once every fence on it has signalled.
COMPOSITOR_READ_WAIT_MS :: 100;

wait_for_compositor_reads :: (slot: *Vulkan_Buffer) {
    fds := pollfd.{ fd = slot.fd, events = POLLOUT };
    ready := poll(*fds, 1, COMPOSITOR_READ_WAIT_MS);
    if ready < 0 {
        log_error("poll(POLLOUT) on copy-path dma-buf fd % failed (errno %); drawing without waiting for the compositor's reads", slot.fd, errno());
    } else if ready == 0 {
        log("Compositor reads of dma-buf fd % still pending after % ms; drawing anyway (expect a torn frame)", slot.fd, COMPOSITOR_READ_WAIT_MS, flags = .WARNING);
    }
}

frame_limit_from_env :: () -> u32 {
    value_ptr := getenv("JAI_WAYLAND_VULKAN_FRAMES");
    if value_ptr == null  return 0;

    text := to_string(value_ptr);
    if text.count == 0  return 0;

    value: u32 = 0;
    for text {
        if it < #char "0" || it > #char "9"  break;
        value = value * 10 + cast(u32)(it - #char "0");
    }

    return value;
}

find_free_slot :: (slots: [] Vulkan_Buffer) -> int {
    for slots  if !it.in_flight  return it_index;
    return -1;
}

retire_slots :: (ctx: *Vulkan_Context, batch: *MessageBuilder, retired: *[..] Vulkan_Buffer, slots: [] Vulkan_Buffer) {
    for * slot: slots {
        if slot.buffer.id == 0  continue;

        if slot.in_flight {
            array_add(retired, slot.*);
        } else {
            queue_slot_destroy(batch, slot);
            destroy_vulkan_buffer_without_wayland(ctx, slot);
        }

        slot.* = .{};
    }
}

release_retired_slot :: (ctx: *Vulkan_Context, batch: *MessageBuilder, retired: *[..] Vulkan_Buffer, object_id: u32) -> bool {
    for * slot, i: retired.* {
        if slot.buffer.id == object_id {
            queue_slot_destroy(batch, slot);
            destroy_vulkan_buffer_without_wayland(ctx, slot);
            array_unordered_remove_by_index(retired, i);
            return true;
        }
    }

    return false;
}

init_vulkan_context :: (ctx: *Vulkan_Context, main_major: u32, main_minor: u32, main_known: bool) -> bool {
    if !Vulkan.init_vulkan() {
        print("Could not load Vulkan runtime.\n");
        return false;
    }

    api_version := get_loader_api_version();
    version := Vulkan.vk_unmake_version(api_version);
    print("Vulkan loader API %.%.%\n", version.major, version.minor, version.patch);

    app_info: Vulkan.VkApplicationInfo;
    app_info.pApplicationName = "jai-wayland hello_vulkan_dmabuf".data;
    app_info.applicationVersion = Vulkan.VK_MAKE_VERSION(0, 1, 0);
    app_info.pEngineName = "jai-wayland".data;
    app_info.engineVersion = Vulkan.VK_MAKE_VERSION(0, 1, 0);
    app_info.apiVersion = ifx api_version >= Vulkan.VK_API_VERSION_1_1 then Vulkan.VK_API_VERSION_1_1 else Vulkan.VK_API_VERSION_1_0;

    create_info: Vulkan.VkInstanceCreateInfo;
    create_info.pApplicationInfo = *app_info;

    result := Vulkan.vkCreateInstance(*create_info, null, *ctx.instance);
    if result != .SUCCESS {
        print("vkCreateInstance failed: %\n", result);
        if result == .ERROR_INCOMPATIBLE_DRIVER  print_vulkan_loader_overrides();
        return false;
    }

    if !Vulkan.load_vulkan_instance_functions(ctx.instance) {
        print("Could not load required Vulkan instance functions.\n");
        return false;
    }

    ok: bool;
    ctx.physical, ok = choose_physical_device(ctx.instance, main_major, main_minor, main_known);
    if !ok  return false;

    props: Vulkan.VkPhysicalDeviceProperties;
    Vulkan.vkGetPhysicalDeviceProperties(ctx.physical, *props);
    device_version := Vulkan.vk_unmake_version(props.apiVersion);
    print("Physical device: % vendor=0x% device=0x% api=%.%.%\n",
        to_string(props.deviceName.data),
        formatInt(props.vendorID, base=16, minimum_digits=4),
        formatInt(props.deviceID, base=16, minimum_digits=4),
        device_version.major, device_version.minor, device_version.patch);

    ctx.queue_family, ok = find_graphics_queue_family(ctx.physical);
    if !ok {
        print("No graphics queue family found.\n");
        return false;
    }

    ctx.device, ok = create_device(ctx.physical, ctx.queue_family);
    if !ok  return false;
    ctx.has_foreign = device_supports_extension(ctx.physical, Vulkan.VK_EXT_QUEUE_FAMILY_FOREIGN_EXTENSION_NAME);
    ctx.has_semaphore_fd = device_supports_extension(ctx.physical, Vulkan.VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME);
    ctx.integrated  = props.deviceType == .INTEGRATED_GPU;
    if !Vulkan.load_vulkan_device_functions(ctx.device) ||
       Vulkan.vkGetMemoryFdKHR == null ||
       Vulkan.vkGetImageDrmFormatModifierPropertiesEXT == null ||
       Vulkan.vkCreateImageView == null ||
       Vulkan.vkCreateFramebuffer == null ||
       Vulkan.vkCreateRenderPass == null ||
       Vulkan.vkCreateShaderModule == null ||
       Vulkan.vkCreatePipelineLayout == null ||
       Vulkan.vkCreateGraphicsPipelines == null ||
       Vulkan.vkCmdBeginRenderPass == null ||
       Vulkan.vkCmdEndRenderPass == null ||
       Vulkan.vkCmdBindPipeline == null ||
       Vulkan.vkCmdSetViewport == null ||
       Vulkan.vkCmdSetScissor == null ||
       Vulkan.vkCmdPushConstants == null ||
       Vulkan.vkCmdDraw == null ||
       Vulkan.vkCmdCopyImageToBuffer == null ||
       Vulkan.vkCreateBuffer == null
    {
        print("Could not load required Vulkan device functions.\n");
        return false;
    }

    Vulkan.vkGetDeviceQueue(ctx.device, ctx.queue_family, 0, *ctx.queue);

    pool_info: Vulkan.VkCommandPoolCreateInfo;
    pool_info.flags = .RESET_COMMAND_BUFFER_BIT;
    pool_info.queueFamilyIndex = ctx.queue_family;
    result = Vulkan.vkCreateCommandPool(ctx.device, *pool_info, null, *ctx.command_pool);
    if result != .SUCCESS {
        print("vkCreateCommandPool failed: %\n", result);
        return false;
    }

    return true;
}

destroy_vulkan_context :: (ctx: *Vulkan_Context) {
    if ctx.device != null {
        Vulkan.vkDeviceWaitIdle(ctx.device);
        if ctx.command_pool != null  Vulkan.vkDestroyCommandPool(ctx.device, ctx.command_pool, null);
        Vulkan.vkDestroyDevice(ctx.device, null);
    }
    if ctx.instance != null  Vulkan.vkDestroyInstance(ctx.instance, null);
}

get_loader_api_version :: () -> Vulkan.VkVersion {
    api_version := Vulkan.VK_API_VERSION_1_0;
    if Vulkan.vkEnumerateInstanceVersion != null {
        result := Vulkan.vkEnumerateInstanceVersion(*api_version);
        if result != .SUCCESS  api_version = Vulkan.VK_API_VERSION_1_0;
    }
    return api_version;
}

// The first device that can export DMA-BUF memory, preferring the one on the
// compositor's GPU (its DRM primary or render node is the feedback's main device) when
// that is known: on a hybrid laptop that keeps it off the dGPU, whatever order the
// loader lists devices in. VK_DRIVER_FILES narrows the list to pick a GPU explicitly.
choose_physical_device :: (instance: Vulkan.VkInstance, main_major: u32, main_minor: u32, main_known: bool) -> Vulkan.VkPhysicalDevice, bool {
    count: u32;
    result := Vulkan.vkEnumeratePhysicalDevices(instance, *count, null);
    if result != .SUCCESS || count == 0  return null, false;

    devices: [32] Vulkan.VkPhysicalDevice;
    if count > devices.count  return null, false;

    result = Vulkan.vkEnumeratePhysicalDevices(instance, *count, devices.data);
    if result != .SUCCESS  return null, false;

    first: Vulkan.VkPhysicalDevice;
    for 0..count - 1 {
        if !device_supports_extension(devices[it], Vulkan.VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME) ||
           !device_supports_extension(devices[it], Vulkan.VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME) ||
           !device_supports_extension(devices[it], Vulkan.VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME)
        {
            continue;
        }
        if !first  first = devices[it];
        if !main_known  break;

        drm, drm_ok := vulkan_device_drm_properties(devices[it]);
        if !drm_ok  continue;
        major := cast(s64) main_major;
        minor := cast(s64) main_minor;
        if (drm.hasPrimary != 0 && drm.primaryMajor == major && drm.primaryMinor == minor) ||
           (drm.hasRender  != 0 && drm.renderMajor  == major && drm.renderMinor  == minor)
        {
            return devices[it], true;
        }
    }

    if first {
        if main_known  print("No Vulkan device is on the compositor's GPU (%:%); using the first that can export DMA-BUF memory.\n", main_major, main_minor);
        return first, true;
    }
    print("No Vulkan physical device supports DRM-modifier DMA-BUF export.\n");
    return null, false;
}

find_graphics_queue_family :: (physical: Vulkan.VkPhysicalDevice) -> u32, bool {
    count: u32;
    Vulkan.vkGetPhysicalDeviceQueueFamilyProperties(physical, *count, null);
    if count == 0  return 0, false;

    props: [64] Vulkan.VkQueueFamilyProperties;
    if count > props.count  count = cast(u32) props.count;
    Vulkan.vkGetPhysicalDeviceQueueFamilyProperties(physical, *count, props.data);

    for 0..count - 1 {
        flags := cast(u32) props[it].queueFlags;
        if (flags & cast(u32) Vulkan.VkQueueFlagBits.GRAPHICS_BIT) != 0 && props[it].queueCount > 0 {
            return it, true;
        }
    }

    return 0, false;
}

device_supports_extension :: (physical: Vulkan.VkPhysicalDevice, name: string) -> bool {
    count: u32;
    result := Vulkan.vkEnumerateDeviceExtensionProperties(physical, null, *count, null);
    if result != .SUCCESS || count == 0  return false;

    props: [512] Vulkan.VkExtensionProperties;
    if count > props.count  count = cast(u32) props.count;

    result = Vulkan.vkEnumerateDeviceExtensionProperties(physical, null, *count, props.data);
    if result != .SUCCESS  return false;

    for 0..count - 1 {
        if to_string(props[it].extensionName.data) == name  return true;
    }

    return false;
}

create_device :: (physical: Vulkan.VkPhysicalDevice, queue_family: u32) -> Vulkan.VkDevice, bool {
    priority: float = 1.0;
    queue_info: Vulkan.VkDeviceQueueCreateInfo;
    queue_info.queueFamilyIndex = queue_family;
    queue_info.queueCount = 1;
    queue_info.pQueuePriorities = *priority;

    extension_names: [14] *u8;
    extension_count: u32;
    extension_names[extension_count] = Vulkan.VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME.data; extension_count += 1;
    extension_names[extension_count] = Vulkan.VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME.data; extension_count += 1;
    extension_names[extension_count] = Vulkan.VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME.data; extension_count += 1;
    // The copy path releases its buffer to the foreign queue family (another driver).
    if device_supports_extension(physical, Vulkan.VK_EXT_QUEUE_FAMILY_FOREIGN_EXTENSION_NAME) {
        extension_names[extension_count] = Vulkan.VK_EXT_QUEUE_FAMILY_FOREIGN_EXTENSION_NAME.data; extension_count += 1;
    }

    if device_supports_extension(physical, Vulkan.VK_KHR_EXTERNAL_MEMORY_EXTENSION_NAME) {
        extension_names[extension_count] = Vulkan.VK_KHR_EXTERNAL_MEMORY_EXTENSION_NAME.data; extension_count += 1;
    }
    if device_supports_extension(physical, Vulkan.VK_KHR_DEDICATED_ALLOCATION_EXTENSION_NAME) {
        extension_names[extension_count] = Vulkan.VK_KHR_DEDICATED_ALLOCATION_EXTENSION_NAME.data; extension_count += 1;
    }
    if device_supports_extension(physical, Vulkan.VK_KHR_GET_MEMORY_REQUIREMENTS_2_EXTENSION_NAME) {
        extension_names[extension_count] = Vulkan.VK_KHR_GET_MEMORY_REQUIREMENTS_2_EXTENSION_NAME.data; extension_count += 1;
    }
    if device_supports_extension(physical, Vulkan.VK_KHR_BIND_MEMORY_2_EXTENSION_NAME) {
        extension_names[extension_count] = Vulkan.VK_KHR_BIND_MEMORY_2_EXTENSION_NAME.data; extension_count += 1;
    }
    // Explicit sync exports each submit's semaphore as a SYNC_FD (VK_KHR_external_semaphore
    // is core in 1.1; the fd half is not).
    if device_supports_extension(physical, Vulkan.VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME) {
        extension_names[extension_count] = Vulkan.VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME.data; extension_count += 1;
    }
    if device_supports_extension(physical, Vulkan.VK_KHR_IMAGE_FORMAT_LIST_EXTENSION_NAME) {
        extension_names[extension_count] = Vulkan.VK_KHR_IMAGE_FORMAT_LIST_EXTENSION_NAME.data; extension_count += 1;
    }

    create_info: Vulkan.VkDeviceCreateInfo;
    create_info.queueCreateInfoCount = 1;
    create_info.pQueueCreateInfos = *queue_info;
    create_info.enabledExtensionCount = extension_count;
    create_info.ppEnabledExtensionNames = extension_names.data;

    device: Vulkan.VkDevice;
    result := Vulkan.vkCreateDevice(physical, *create_info, null, *device);
    if result != .SUCCESS {
        print("vkCreateDevice failed: %\n", result);
        return null, false;
    }

    return device, true;
}

choose_image_config :: (physical: Vulkan.VkPhysicalDevice, info: Dmabuf_Info, feedback: Dmabuf_Feedback_Info, feedback_ok: bool) -> Image_Config, bool {
    usage := Vulkan.VkImageUsageFlagBits.COLOR_ATTACHMENT_BIT
           | Vulkan.VkImageUsageFlagBits.TRANSFER_SRC_BIT
           | Vulkan.VkImageUsageFlagBits.TRANSFER_DST_BIT;

    if feedback_ok && feedback.complete {
        for tranche: feedback.tranches {
            for fm: tranche.formats {
                cfg, ok := config_for_wayland_format(fm.format, fm.modifier, usage);
                if !ok  continue;
                if config_supported_by_vulkan(physical, *cfg)  return cfg, true;
            }
        }
    }

    for fm: info.supported {
        cfg, ok := config_for_wayland_format(fm.format, fm.modifier, usage);
        if !ok  continue;
        if config_supported_by_vulkan(physical, *cfg)  return cfg, true;
    }

    return .{}, false;
}

// ── Driver-first selection: driver-enumerated modifiers, probed against the compositor ──

Format_Candidate :: struct { vk: Vulkan.VkFormat; fourcc: u32; label: string; }

// vk_format ↔ wayland fourcc pairs the renderer can draw. We enumerate the driver's
// modifiers for each and probe them; order here is just the format-try order.
CANDIDATE_FORMATS :: Format_Candidate.[
    .{ .B8G8R8A8_UNORM, DRM_FORMAT_ARGB8888, "B8G8R8A8/AR24" },
    .{ .B8G8R8A8_UNORM, DRM_FORMAT_XRGB8888, "B8G8R8A8/XR24" },
    .{ .R8G8B8A8_UNORM, DRM_FORMAT_ABGR8888, "R8G8B8A8/AB24" },
    .{ .R8G8B8A8_UNORM, DRM_FORMAT_XBGR8888, "R8G8B8A8/XB24" },
];

// Enumerate the MODIFIERS THE VULKAN DRIVER itself supports for `format` (not the
// compositor's advertised set) via VkDrmFormatModifierPropertiesListEXT. Fills `out`,
// returns the count written. This is the crux: trust the producing driver, then let the
// compositor's created/failed be the only arbiter of what it will actually import.
enumerate_driver_modifiers :: (physical: Vulkan.VkPhysicalDevice, format: Vulkan.VkFormat, out: [] Vulkan.VkDrmFormatModifierPropertiesEXT) -> int {
    list: Vulkan.VkDrmFormatModifierPropertiesListEXT;
    props: Vulkan.VkFormatProperties2;
    props.pNext = *list;
    Vulkan.vkGetPhysicalDeviceFormatProperties2(physical, format, *props);
    if list.drmFormatModifierCount == 0  return 0;

    count := list.drmFormatModifierCount;
    if count > cast(u32) out.count  count = cast(u32) out.count;
    list.drmFormatModifierCount        = count;
    list.pDrmFormatModifierProperties  = out.data;
    props.pNext = *list;
    Vulkan.vkGetPhysicalDeviceFormatProperties2(physical, format, *props);
    return cast(int) count;
}

modifier_is_renderable_single_plane :: (m: Vulkan.VkDrmFormatModifierPropertiesEXT) -> bool {
    if m.drmFormatModifierPlaneCount != 1  return false;  // keep the single-fd export path
    feats := cast(u32) m.drmFormatModifierTilingFeatures;
    return (feats & cast(u32) Vulkan.VkFormatFeatureFlagBits.COLOR_ATTACHMENT_BIT) != 0;
}

make_candidate_config :: (pair: Format_Candidate, modifier: u64, usage: Vulkan.VkImageUsageFlags) -> Image_Config {
    return .{
        vk_format = pair.vk,
        wayland_format = pair.fourcc,
        usage = usage,
        label = pair.label,
        drm_format_modifier = modifier,
        plane_count = 1,
    };
}

// Build the ordered candidate list straight from the driver's enumeration: driver-native
// tiled modifiers first (the fast path), then DRM_FORMAT_MOD_LINEAR as the
// universal-interchange safety net.
gather_driver_candidates :: (physical: Vulkan.VkPhysicalDevice) -> [..] Image_Config {
    usage := Vulkan.VkImageUsageFlagBits.COLOR_ATTACHMENT_BIT
           | Vulkan.VkImageUsageFlagBits.TRANSFER_SRC_BIT
           | Vulkan.VkImageUsageFlagBits.TRANSFER_DST_BIT;

    out: [..] Image_Config;
    buf: [256] Vulkan.VkDrmFormatModifierPropertiesEXT;

    for pair: CANDIDATE_FORMATS {
        n := enumerate_driver_modifiers(physical, pair.vk, buf);

        for i: 0..n-1 {  // pass 1: tiled (non-LINEAR)
            m := buf[i];
            if !modifier_is_renderable_single_plane(m)  continue;
            if m.drmFormatModifier == DRM_FORMAT_MOD_LINEAR  continue;
            array_add(*out, make_candidate_config(pair, m.drmFormatModifier, usage));
        }
        for i: 0..n-1 {  // pass 2: LINEAR safety net
            m := buf[i];
            if m.drmFormatModifier != DRM_FORMAT_MOD_LINEAR  continue;
            if !modifier_is_renderable_single_plane(m)  continue;
            array_add(*out, make_candidate_config(pair, DRM_FORMAT_MOD_LINEAR, usage));
        }
    }
    return out;
}

// Drive selection from the driver, then let the COMPOSITOR be the arbiter: probe each
// candidate with the async create + created/failed handshake; first ACCEPTED wins.
// Only valid on the compositor's own GPU; main() refuses before getting here otherwise.
choose_image_config_driver_first :: (ctx: *Vulkan_Context, dmabuf: *Zwp_Linux_Dmabuf_V1) -> Image_Config, bool {
    candidates := gather_driver_candidates(ctx.physical);
    defer array_free(candidates);

    if candidates.count == 0 {
        print("Vulkan driver enumerated no renderable single-plane DRM modifiers.\n");
        return .{}, false;
    }

    print("Driver enumerated % candidate (format, modifier) pairs; probing against compositor:\n", candidates.count);
    for * cfg: candidates {
        if !config_supported_by_vulkan(ctx.physical, cfg)  continue;  // confirms exportable + sets plane_count
        accepted := probe_config_against_compositor(ctx, dmabuf, cfg.*);
        print("  % fourcc=0x% modifier=0x% -> %\n",
            cfg.label,
            formatInt(cfg.wayland_format, base=16),
            formatInt(cfg.drm_format_modifier, base=16, minimum_digits=16),
            ifx accepted then "ACCEPTED" else "rejected");
        if accepted  return cfg.*, true;
    }
    return .{}, false;
}

GPU_Relation :: enum { SAME; DIFFERENT; UNKNOWN; }

// Whether the Vulkan device is the GPU the compositor composites on: its primary or
// render node equals the feedback's main device (compositors report either node).
// Anything unprovable (no feedback, a non-Linux dev_t, no VK_EXT_physical_device_drm)
// is UNKNOWN, which main() treats like a different GPU: the copy path, never a probe.
compositor_gpu_relation :: (physical: Vulkan.VkPhysicalDevice, feedback: Dmabuf_Feedback_Info, feedback_ok: bool) -> GPU_Relation {
    if !feedback_ok || !feedback.complete {
        print("Compositor sent no dmabuf feedback, so its main device is unknown; treating this as a different GPU.\n");
        return .UNKNOWN;
    }
    main_major, main_minor, main_ok := dev_major_minor(feedback.main_device);
    if !main_ok {
        print("Compositor main device is a %-byte dev_t, not a Linux one; treating this as a different GPU.\n",
            feedback.main_device.count);
        return .UNKNOWN;
    }
    drm, drm_ok := vulkan_device_drm_properties(physical);
    if !drm_ok {
        print("Vulkan device reports no DRM node (% unsupported); treating it as a different GPU from the compositor's %:%.\n",
            Vulkan.VK_EXT_PHYSICAL_DEVICE_DRM_EXTENSION_NAME, main_major, main_minor);
        return .UNKNOWN;
    }

    major := cast(s64) main_major;
    minor := cast(s64) main_minor;
    is_primary := drm.hasPrimary != 0 && drm.primaryMajor == major && drm.primaryMinor == minor;
    is_render  := drm.hasRender  != 0 && drm.renderMajor  == major && drm.renderMinor  == minor;
    same := is_primary || is_render;
    print("Compositor main device %:%; Vulkan device primary %:% render %:% -> %\n",
        main_major, main_minor, drm.primaryMajor, drm.primaryMinor, drm.renderMajor, drm.renderMinor,
        ifx same then "same GPU" else "different GPU");
    return ifx same then GPU_Relation.SAME else .DIFFERENT;
}

// ── The copy path ──

COPY_PATH_PITCH_ALIGN :: 256;   // NVIDIA's own WSI pads LINEAR rows to 256 bytes too

// A format the compositor advertises with the LINEAR modifier, in its preference order
// (feedback tranches first, then the v3 global list), that this device can render
// OPTIMAL and copy out of, with a buffer it can export as a dma-buf.
choose_copy_path_config :: (ctx: *Vulkan_Context, info: Dmabuf_Info, feedback: Dmabuf_Feedback_Info, feedback_ok: bool) -> Image_Config, bool {
    query: Vulkan.VkPhysicalDeviceExternalBufferInfo;
    query.usage      = .TRANSFER_DST_BIT;
    query.handleType = .DMA_BUF_BIT_EXT;
    buffer_props: Vulkan.VkExternalBufferProperties;
    Vulkan.vkGetPhysicalDeviceExternalBufferProperties(ctx.physical, *query, *buffer_props);
    if !(buffer_props.externalMemoryProperties.externalMemoryFeatures & .EXPORTABLE_BIT) {
        print("The Vulkan device cannot export a transfer-destination buffer as a dma-buf.\n");
        return .{}, false;
    }

    usage := Vulkan.VkImageUsageFlagBits.COLOR_ATTACHMENT_BIT | .TRANSFER_SRC_BIT;
    try :: (ctx: *Vulkan_Context, fm: Format_Modifier, usage: Vulkan.VkImageUsageFlags) -> Image_Config, bool {
        if fm.modifier != DRM_FORMAT_MOD_LINEAR  return .{}, false;
        cfg, ok := config_for_wayland_format(fm.format, fm.modifier, usage);
        if !ok  return .{}, false;
        props: Vulkan.VkFormatProperties;
        Vulkan.vkGetPhysicalDeviceFormatProperties(ctx.physical, cfg.vk_format, *props);
        need := Vulkan.VkFormatFeatureFlagBits.COLOR_ATTACHMENT_BIT | .TRANSFER_SRC_BIT;
        if (props.optimalTilingFeatures & need) != need  return .{}, false;
        cfg.copy_path   = true;
        cfg.plane_count = 1;
        return cfg, true;
    }

    if feedback_ok && feedback.complete {
        for tranche: feedback.tranches  for fm: tranche.formats {
            cfg, ok := try(ctx, fm, usage);
            if ok  return cfg, true;
        }
    }
    for fm: info.supported {
        cfg, ok := try(ctx, fm, usage);
        if ok  return cfg, true;
    }
    print("The compositor advertises no LINEAR ARGB/XRGB/ABGR/XBGR 8888 format this device can render.\n");
    return .{}, false;
}

// A memory type the copy buffer may use that lives in system memory. On a discrete GPU
// that is a type whose HEAP is not device-local; the type's own DEVICE_LOCAL bit is not
// enough on its own, because a resizable-BAR type is host-visible and device-local at
// once (NVIDIA's type 5 on the RTX 3050 Ti), and its pages are VRAM, which is what a
// compositor on another GPU cannot read. An integrated GPU has no VRAM: it flags every
// heap device-local, and all of them are system memory, so for it any type qualifies.
find_system_memory_type :: (ctx: *Vulkan_Context, type_bits: u32) -> u32, bool {
    props: Vulkan.VkPhysicalDeviceMemoryProperties;
    Vulkan.vkGetPhysicalDeviceMemoryProperties(ctx.physical, *props);
    for i: 0..cast(s64) props.memoryTypeCount - 1 {
        if !(type_bits & (cast(u32) 1 << i))  continue;
        type := props.memoryTypes[i];
        heap := props.memoryHeaps[type.heapIndex];
        if !ctx.integrated && ((heap.flags & .DEVICE_LOCAL_BIT) || (type.propertyFlags & .DEVICE_LOCAL_BIT))  continue;
        return cast(u32) i, true;
    }
    return 0, false;
}

// The copy path's slot: a device-local OPTIMAL image to render into (never exported)
// and a system-memory buffer, exported as the dma-buf, that every frame is copied into.
create_copy_path_buffer :: (ctx: *Vulkan_Context, config: Image_Config, width: s32, height: s32, out: *Vulkan_Buffer) -> bool {
    image_info: Vulkan.VkImageCreateInfo;
    image_info.imageType     = ._2D;
    image_info.format        = config.vk_format;
    image_info.extent        = .{ width = cast(u32) width, height = cast(u32) height, depth = 1 };
    image_info.mipLevels     = 1;
    image_info.arrayLayers   = 1;
    image_info.samples       = ._1_BIT;
    image_info.tiling        = .OPTIMAL;
    image_info.usage         = config.usage;
    image_info.sharingMode   = .EXCLUSIVE;
    image_info.initialLayout = .UNDEFINED;
    result := Vulkan.vkCreateImage(ctx.device, *image_info, null, *out.image);
    if result != .SUCCESS {
        print("vkCreateImage(copy-path render target) failed: %\n", result);
        return false;
    }
    req: Vulkan.VkMemoryRequirements;
    Vulkan.vkGetImageMemoryRequirements(ctx.device, out.image, *req);
    image_type, image_type_ok := find_memory_type(ctx.physical, req.memoryTypeBits, .DEVICE_LOCAL_BIT);
    if !image_type_ok {
        print("No device-local memory type for the copy-path render target.\n");
        return false;
    }
    image_alloc: Vulkan.VkMemoryAllocateInfo;
    image_alloc.allocationSize  = req.size;
    image_alloc.memoryTypeIndex = image_type;
    result = Vulkan.vkAllocateMemory(ctx.device, *image_alloc, null, *out.memory);
    if result != .SUCCESS {
        print("vkAllocateMemory(copy-path render target) failed: %\n", result);
        return false;
    }
    result = Vulkan.vkBindImageMemory(ctx.device, out.image, out.memory, 0);
    if result != .SUCCESS {
        print("vkBindImageMemory(copy-path render target) failed: %\n", result);
        return false;
    }

    stride := ((cast(u32) width * 4 + COPY_PATH_PITCH_ALIGN - 1) / COPY_PATH_PITCH_ALIGN) * COPY_PATH_PITCH_ALIGN;
    external_info: Vulkan.VkExternalMemoryBufferCreateInfo;
    external_info.handleTypes = .DMA_BUF_BIT_EXT;
    buffer_info: Vulkan.VkBufferCreateInfo;
    buffer_info.pNext       = *external_info;
    buffer_info.size        = cast(u64) stride * cast(u64) height;
    buffer_info.usage       = .TRANSFER_DST_BIT;
    buffer_info.sharingMode = .EXCLUSIVE;
    result = Vulkan.vkCreateBuffer(ctx.device, *buffer_info, null, *out.copy_buffer);
    if result != .SUCCESS {
        print("vkCreateBuffer(copy-path dma-buf) failed: %\n", result);
        return false;
    }
    Vulkan.vkGetBufferMemoryRequirements(ctx.device, out.copy_buffer, *req);
    // The invariant the copy path exists for: never hand the compositor device memory.
    copy_type, copy_type_ok := find_system_memory_type(ctx, req.memoryTypeBits);
    if !copy_type_ok {
        print("No system-memory type fits the copy-path buffer (type bits 0x%); refusing to export device memory.\n",
            formatInt(req.memoryTypeBits, base=16));
        return false;
    }
    dedicated: Vulkan.VkMemoryDedicatedAllocateInfo;
    dedicated.buffer = out.copy_buffer;
    export_info: Vulkan.VkExportMemoryAllocateInfo;
    export_info.pNext       = *dedicated;
    export_info.handleTypes = .DMA_BUF_BIT_EXT;
    copy_alloc: Vulkan.VkMemoryAllocateInfo;
    copy_alloc.pNext           = *export_info;
    copy_alloc.allocationSize  = req.size;
    copy_alloc.memoryTypeIndex = copy_type;
    result = Vulkan.vkAllocateMemory(ctx.device, *copy_alloc, null, *out.copy_memory);
    if result != .SUCCESS {
        print("vkAllocateMemory(copy-path dma-buf, system memory) failed: %\n", result);
        return false;
    }
    result = Vulkan.vkBindBufferMemory(ctx.device, out.copy_buffer, out.copy_memory, 0);
    if result != .SUCCESS {
        print("vkBindBufferMemory(copy-path dma-buf) failed: %\n", result);
        return false;
    }

    get_fd: Vulkan.VkMemoryGetFdInfoKHR;
    get_fd.memory     = out.copy_memory;
    get_fd.handleType = .DMA_BUF_BIT_EXT;
    result = Vulkan.vkGetMemoryFdKHR(ctx.device, *get_fd, *out.fd);
    if result != .SUCCESS {
        print("vkGetMemoryFdKHR(copy-path dma-buf) failed: %\n", result);
        return false;
    }

    out.offset   = 0;
    out.stride   = stride;
    out.modifier = DRM_FORMAT_MOD_LINEAR;
    out.format   = config.wayland_format;
    out.width    = width;
    out.height   = height;
    print("Copy-path DMA-BUF fd=% stride=% memory type % (system memory) modifier=LINEAR\n", out.fd, out.stride, copy_type);
    return true;
}

vulkan_device_drm_properties :: (physical: Vulkan.VkPhysicalDevice) -> Vulkan.VkPhysicalDeviceDrmPropertiesEXT, bool {
    drm: Vulkan.VkPhysicalDeviceDrmPropertiesEXT;
    if Vulkan.vkGetPhysicalDeviceProperties2 == null  return drm, false;
    if !device_supports_extension(physical, Vulkan.VK_EXT_PHYSICAL_DEVICE_DRM_EXTENSION_NAME)  return drm, false;

    props: Vulkan.VkPhysicalDeviceProperties2;
    props.pNext = *drm;
    Vulkan.vkGetPhysicalDeviceProperties2(physical, *props);
    return drm, true;
}

// Create a small Vulkan image with `config`'s modifier, export it, hand it to the
// compositor via the ASYNC zwp_linux_buffer_params_v1.create, and report whether the
// compositor said `created` (importable) or `failed`. Self-contained: cleans up the
// probe buffer, the (server-allocated) wl_buffer, and the params object.
probe_config_against_compositor :: (ctx: *Vulkan_Context, dmabuf: *Zwp_Linux_Dmabuf_V1, config: Image_Config) -> bool {
    PROBE_SIZE :: 256;

    probe: Vulkan_Buffer;
    if !create_vulkan_buffer(ctx, config, PROBE_SIZE, PROBE_SIZE, *probe) {
        destroy_vulkan_buffer_without_wayland(ctx, *probe);
        return false;
    }
    defer destroy_vulkan_buffer_without_wayland(ctx, *probe);

    batch: MessageBuilder;
    params := Zwp_Linux_Buffer_Params_V1.{ id = allocate_id() };
    zwp_linux_dmabuf_v1_create_params(*batch, dmabuf, params.id);
    zwp_linux_buffer_params_v1_add(*batch, *params,
        fd          = cast(Fd) probe.fd,
        plane_idx   = 0,
        offset      = probe.offset,
        stride      = probe.stride,
        modifier_hi = cast(u32)(probe.modifier >> 32),
        modifier_lo = cast(u32)(probe.modifier & 0xFFFFFFFF));
    zwp_linux_buffer_params_v1_create(*batch, *params, PROBE_SIZE, PROBE_SIZE, config.wayland_format, 0);

    // Sync acts as a backstop so a (mis)behaving compositor that emits neither
    // created nor failed can't hang the probe.
    display := Wl_Display.{ id = 1 };
    sync_id := allocate_id();
    wl_display_sync(*batch, *display, sync_id);
    wayland_send(*batch);

    created := false;
    created_buffer_id: u32 = 0;
    for session() {
        if it.object_id == params.id && it.opcode == ZWP_LINUX_BUFFER_PARAMS_V1_CREATED {
            args: Zwp_Linux_Buffer_Params_V1_Created_Args;
            unmarshal(*args, it.payload, recv);
            if args.buffer != null  created_buffer_id = args.buffer.id;
            created = true;
            break;
        } else if it.object_id == params.id && it.opcode == ZWP_LINUX_BUFFER_PARAMS_V1_FAILED {
            created = false;
            break;
        } else if it.object_id == sync_id && it.opcode == WL_CALLBACK_DONE {
            created = false;  // drained without created/failed → treat as reject
            break;
        }
    }

    cleanup: MessageBuilder;
    if created && created_buffer_id != 0 {
        leftover := Wl_Buffer.{ id = created_buffer_id };
        wl_buffer_destroy(*cleanup, *leftover);
    }
    zwp_linux_buffer_params_v1_destroy(*cleanup, *params);
    wayland_send(*cleanup);

    return created;
}

config_for_wayland_format :: (format: u32, modifier: u64, usage: Vulkan.VkImageUsageFlags) -> Image_Config, bool {
    if modifier == DRM_FORMAT_MOD_INVALID  return .{}, false;

    if format == DRM_FORMAT_ARGB8888 || format == DRM_FORMAT_XRGB8888 {
        return .{
            vk_format = .B8G8R8A8_UNORM,
            wayland_format = format,
            usage = usage,
            label = ifx format == DRM_FORMAT_ARGB8888 then "B8G8R8A8/AR24" else "B8G8R8A8/XR24",
            drm_format_modifier = modifier,
        }, true;
    }

    if format == DRM_FORMAT_ABGR8888 || format == DRM_FORMAT_XBGR8888 {
        return .{
            vk_format = .R8G8B8A8_UNORM,
            wayland_format = format,
            usage = usage,
            label = ifx format == DRM_FORMAT_ABGR8888 then "R8G8B8A8/AB24" else "R8G8B8A8/XB24",
            drm_format_modifier = modifier,
        }, true;
    }

    return .{}, false;
}

config_supported_by_vulkan :: (physical: Vulkan.VkPhysicalDevice, config: *Image_Config) -> bool {
    modifier_props, mod_ok := get_modifier_properties(physical, config.vk_format, config.drm_format_modifier);
    if !mod_ok || modifier_props.drmFormatModifierPlaneCount != 1  return false;

    external_info: Vulkan.VkPhysicalDeviceExternalImageFormatInfo;
    external_info.handleType = .DMA_BUF_BIT_EXT;

    drm_info: Vulkan.VkPhysicalDeviceImageDrmFormatModifierInfoEXT;
    drm_info.pNext = *external_info;
    drm_info.drmFormatModifier = config.drm_format_modifier;
    drm_info.sharingMode = .EXCLUSIVE;

    format_info: Vulkan.VkPhysicalDeviceImageFormatInfo2;
    format_info.pNext = *drm_info;
    format_info.format = config.vk_format;
    format_info.type = ._2D;
    format_info.tiling = Vulkan.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT;
    format_info.usage = config.usage;

    external_props: Vulkan.VkExternalImageFormatProperties;
    image_props: Vulkan.VkImageFormatProperties2;
    image_props.pNext = *external_props;

    result := Vulkan.vkGetPhysicalDeviceImageFormatProperties2(physical, *format_info, *image_props);
    if result != .SUCCESS  return false;

    feature_bits := cast(u32) external_props.externalMemoryProperties.externalMemoryFeatures;
    if (feature_bits & cast(u32) Vulkan.VkExternalMemoryFeatureFlagBits.EXPORTABLE_BIT) == 0  return false;

    config.plane_count = modifier_props.drmFormatModifierPlaneCount;
    return true;
}

get_modifier_properties :: (physical: Vulkan.VkPhysicalDevice, format: Vulkan.VkFormat, modifier: u64) -> Vulkan.VkDrmFormatModifierPropertiesEXT, bool {
    list: Vulkan.VkDrmFormatModifierPropertiesListEXT;
    props: Vulkan.VkFormatProperties2;
    props.pNext = *list;
    Vulkan.vkGetPhysicalDeviceFormatProperties2(physical, format, *props);
    if list.drmFormatModifierCount == 0  return .{}, false;

    modifiers: [256] Vulkan.VkDrmFormatModifierPropertiesEXT;
    if list.drmFormatModifierCount > modifiers.count {
        list.drmFormatModifierCount = cast(u32) modifiers.count;
    }

    list.pDrmFormatModifierProperties = modifiers.data;
    props.pNext = *list;
    Vulkan.vkGetPhysicalDeviceFormatProperties2(physical, format, *props);

    for 0..list.drmFormatModifierCount - 1 {
        if modifiers[it].drmFormatModifier == modifier  return modifiers[it], true;
    }

    return .{}, false;
}

create_vulkan_buffer :: (ctx: *Vulkan_Context, config: Image_Config, width: s32, height: s32, out: *Vulkan_Buffer) -> bool {
    if config.copy_path  return create_copy_path_buffer(ctx, config, width, height, out);

    external_info: Vulkan.VkExternalMemoryImageCreateInfo;
    external_info.handleTypes = .DMA_BUF_BIT_EXT;

    modifier := config.drm_format_modifier;
    modifier_info: Vulkan.VkImageDrmFormatModifierListCreateInfoEXT;
    modifier_info.pNext = *external_info;
    modifier_info.drmFormatModifierCount = 1;
    modifier_info.pDrmFormatModifiers = *modifier;

    image_info: Vulkan.VkImageCreateInfo;
    image_info.pNext = *modifier_info;
    image_info.imageType = ._2D;
    image_info.format = config.vk_format;
    image_info.extent = .{ width = cast(u32) width, height = cast(u32) height, depth = 1 };
    image_info.mipLevels = 1;
    image_info.arrayLayers = 1;
    image_info.samples = ._1_BIT;
    image_info.tiling = Vulkan.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT;
    image_info.usage = config.usage;
    image_info.sharingMode = .EXCLUSIVE;
    image_info.initialLayout = .UNDEFINED;

    result := Vulkan.vkCreateImage(ctx.device, *image_info, null, *out.image);
    if result != .SUCCESS {
        print("vkCreateImage failed: %\n", result);
        return false;
    }

    actual_mod: Vulkan.VkImageDrmFormatModifierPropertiesEXT;
    result = Vulkan.vkGetImageDrmFormatModifierPropertiesEXT(ctx.device, out.image, *actual_mod);
    if result == .SUCCESS {
        out.modifier = actual_mod.drmFormatModifier;
    } else {
        out.modifier = config.drm_format_modifier;
    }

    req: Vulkan.VkMemoryRequirements;
    Vulkan.vkGetImageMemoryRequirements(ctx.device, out.image, *req);

    memory_type, memory_ok := find_memory_type(ctx.physical, req.memoryTypeBits, .DEVICE_LOCAL_BIT);
    if !memory_ok {
        memory_type, memory_ok = find_memory_type(ctx.physical, req.memoryTypeBits, cast(Vulkan.VkMemoryPropertyFlags) 0);
    }
    if !memory_ok {
        print("No compatible memory type for exportable image.\n");
        return false;
    }

    dedicated_info: Vulkan.VkMemoryDedicatedAllocateInfo;
    dedicated_info.image = out.image;

    export_info: Vulkan.VkExportMemoryAllocateInfo;
    export_info.pNext = *dedicated_info;
    export_info.handleTypes = .DMA_BUF_BIT_EXT;

    alloc_info: Vulkan.VkMemoryAllocateInfo;
    alloc_info.pNext = *export_info;
    alloc_info.allocationSize = req.size;
    alloc_info.memoryTypeIndex = memory_type;

    result = Vulkan.vkAllocateMemory(ctx.device, *alloc_info, null, *out.memory);
    if result != .SUCCESS {
        print("vkAllocateMemory failed: %\n", result);
        return false;
    }

    result = Vulkan.vkBindImageMemory(ctx.device, out.image, out.memory, 0);
    if result != .SUCCESS {
        print("vkBindImageMemory failed: %\n", result);
        return false;
    }

    sub: Vulkan.VkImageSubresource;
    sub.aspectMask = Vulkan.VK_IMAGE_ASPECT_MEMORY_PLANE_0_BIT_EXT;
    layout: Vulkan.VkSubresourceLayout;
    Vulkan.vkGetImageSubresourceLayout(ctx.device, out.image, *sub, *layout);

    get_fd: Vulkan.VkMemoryGetFdInfoKHR;
    get_fd.memory = out.memory;
    get_fd.handleType = .DMA_BUF_BIT_EXT;
    result = Vulkan.vkGetMemoryFdKHR(ctx.device, *get_fd, *out.fd);
    if result != .SUCCESS {
        print("vkGetMemoryFdKHR failed: %\n", result);
        return false;
    }

    out.offset = cast(u32) layout.offset;
    out.stride = cast(u32) layout.rowPitch;
    out.format = config.wayland_format;
    out.width = width;
    out.height = height;

    print("Vulkan DMA-BUF fd=% offset=% stride=% image_modifier=0x%\n",
        out.fd, out.offset, out.stride, formatInt(out.modifier, base=16, minimum_digits=16));

    return true;
}

destroy_vulkan_buffer :: (ctx: *Vulkan_Context, buf: *Vulkan_Buffer) {
    if buf.buffer.id != 0 {
        batch: MessageBuilder;
        queue_slot_destroy(*batch, buf);
        wayland_send(*batch);
    }
    destroy_vulkan_buffer_without_wayland(ctx, buf);
}

destroy_vulkan_buffer_without_wayland :: (ctx: *Vulkan_Context, buf: *Vulkan_Buffer) {
    // The per-frame queue wait is gone under explicit sync: let this slot's last
    // submit finish before freeing what it uses.
    if buf.fence != null {
        result := Vulkan.vkWaitForFences(ctx.device, 1, *buf.fence, Vulkan.VK_TRUE, FENCE_WAIT_NS);
        if result != .SUCCESS {
            // Destroying objects a pending submit still uses is undefined behaviour:
            // say so, and wait for the whole device instead.
            print("Warning: slot buffer %'s last submit is not done after % ms (%); waiting for the device before destroying it\n",
                  buf.buffer.id, FENCE_WAIT_NS / 1_000_000, result);
            Vulkan.vkDeviceWaitIdle(ctx.device);
        }
        Vulkan.vkDestroyFence(ctx.device, buf.fence, null);
    }
    if buf.cmd != null          Vulkan.vkFreeCommandBuffers(ctx.device, ctx.command_pool, 1, *buf.cmd);
    if buf.render_done != null  Vulkan.vkDestroySemaphore(ctx.device, buf.render_done, null);
    if buf.acquire_fd >= 0        close(buf.acquire_fd);
    if buf.sync_timeline_fd >= 0  close(buf.sync_timeline_fd);
    if buf.sync_timeline != 0     Gpu.syncobj_destroy(ctx.drm_fd, buf.sync_timeline);
    if buf.framebuffer != null  Vulkan.vkDestroyFramebuffer(ctx.device, buf.framebuffer, null);
    if buf.image_view != null   Vulkan.vkDestroyImageView(ctx.device, buf.image_view, null);
    if buf.fd >= 0  close(buf.fd);
    if buf.memory != null  Vulkan.vkFreeMemory(ctx.device, buf.memory, null);
    if buf.image != null  Vulkan.vkDestroyImage(ctx.device, buf.image, null);
    if buf.copy_buffer != null  Vulkan.vkDestroyBuffer(ctx.device, buf.copy_buffer, null);
    if buf.copy_memory != null  Vulkan.vkFreeMemory(ctx.device, buf.copy_memory, null);
    buf.* = .{};
}

find_memory_type :: (physical: Vulkan.VkPhysicalDevice, type_bits: u32, required: Vulkan.VkMemoryPropertyFlags) -> u32, bool {
    props: Vulkan.VkPhysicalDeviceMemoryProperties;
    Vulkan.vkGetPhysicalDeviceMemoryProperties(physical, *props);

    for 0..props.memoryTypeCount - 1 {
        bit := (cast(u32) 1) << it;
        if (type_bits & bit) == 0  continue;

        flags := cast(u32) props.memoryTypes[it].propertyFlags;
        want := cast(u32) required;
        if (flags & want) == want  return it, true;
    }

    return 0, false;
}

ROTATION_RADIANS_PER_SECOND :: 1.2;

monotonic_seconds :: () -> float64 {
    ts: timespec;
    if clock_gettime(.MONOTONIC, *ts) != 0  return 0;
    return cast(float64) ts.tv_sec + cast(float64) ts.tv_nsec / 1000000000.0;
}

rotation_angle :: (start_time: float64) -> float {
    return cast(float) ((monotonic_seconds() - start_time) * ROTATION_RADIANS_PER_SECOND);
}

init_vulkan_triangle :: (ctx: *Vulkan_Context, config: Image_Config, tri: *Vulkan_Triangle) -> bool {
    tri.* = .{};

    ok: bool;
    tri.render_pass, ok = create_triangle_render_pass(ctx, config);
    if !ok  return false;

    tri.pipeline_layout, tri.pipeline, ok = create_triangle_pipeline(ctx, config, tri.render_pass);
    if !ok {
        destroy_vulkan_triangle(ctx, tri);
        return false;
    }

    return true;
}

destroy_vulkan_triangle :: (ctx: *Vulkan_Context, tri: *Vulkan_Triangle) {
    if tri.pipeline != null         Vulkan.vkDestroyPipeline(ctx.device, tri.pipeline, null);
    if tri.pipeline_layout != null  Vulkan.vkDestroyPipelineLayout(ctx.device, tri.pipeline_layout, null);
    if tri.render_pass != null      Vulkan.vkDestroyRenderPass(ctx.device, tri.render_pass, null);
    tri.* = .{};
}

create_triangle_render_pass :: (ctx: *Vulkan_Context, config: Image_Config) -> Vulkan.VkRenderPass, bool {
    attachment := Vulkan.VkAttachmentDescription.{
        format         = config.vk_format,
        samples        = ._1_BIT,
        loadOp         = .CLEAR,
        storeOp        = .STORE,
        stencilLoadOp  = .DONT_CARE,
        stencilStoreOp = .DONT_CARE,
        initialLayout  = .COLOR_ATTACHMENT_OPTIMAL,
        finalLayout    = .COLOR_ATTACHMENT_OPTIMAL,
    };

    color_ref := Vulkan.VkAttachmentReference.{
        attachment = 0,
        layout     = .COLOR_ATTACHMENT_OPTIMAL,
    };

    subpass := Vulkan.VkSubpassDescription.{
        pipelineBindPoint    = .GRAPHICS,
        colorAttachmentCount = 1,
        pColorAttachments    = *color_ref,
    };

    info := Vulkan.VkRenderPassCreateInfo.{
        attachmentCount = 1,
        pAttachments    = *attachment,
        subpassCount    = 1,
        pSubpasses      = *subpass,
    };

    render_pass: Vulkan.VkRenderPass;
    result := Vulkan.vkCreateRenderPass(ctx.device, *info, null, *render_pass);
    if result != .SUCCESS {
        print("vkCreateRenderPass failed: %\n", result);
        return null, false;
    }

    return render_pass, true;
}

create_triangle_pipeline :: (ctx: *Vulkan_Context, config: Image_Config, render_pass: Vulkan.VkRenderPass) -> Vulkan.VkPipelineLayout, Vulkan.VkPipeline, bool {
    vertex_module, vertex_ok := load_shader_module(ctx, "hello_vulkan_triangle.vert.spv");
    if !vertex_ok  return null, null, false;
    defer Vulkan.vkDestroyShaderModule(ctx.device, vertex_module, null);

    fragment_module, fragment_ok := load_shader_module(ctx, "hello_vulkan_triangle.frag.spv");
    if !fragment_ok  return null, null, false;
    defer Vulkan.vkDestroyShaderModule(ctx.device, fragment_module, null);

    shader_stages := Vulkan.VkPipelineShaderStageCreateInfo.[
        .{ stage = .VERTEX_BIT,   module = vertex_module,   pName = "main".data },
        .{ stage = .FRAGMENT_BIT, module = fragment_module, pName = "main".data },
    ];

    push_range := Vulkan.VkPushConstantRange.{
        stageFlags = .VERTEX_BIT,
        offset     = 0,
        size       = cast(u32) size_of(float),
    };

    layout_info := Vulkan.VkPipelineLayoutCreateInfo.{
        pushConstantRangeCount = 1,
        pPushConstantRanges    = *push_range,
    };

    pipeline_layout: Vulkan.VkPipelineLayout;
    result := Vulkan.vkCreatePipelineLayout(ctx.device, *layout_info, null, *pipeline_layout);
    if result != .SUCCESS {
        print("vkCreatePipelineLayout failed: %\n", result);
        return null, null, false;
    }

    vertex_input: Vulkan.VkPipelineVertexInputStateCreateInfo;

    input_assembly := Vulkan.VkPipelineInputAssemblyStateCreateInfo.{
        topology = .TRIANGLE_LIST,
    };

    viewport := Vulkan.VkViewport.{
        width    = 1.0,
        height   = 1.0,
        maxDepth = 1.0,
    };

    scissor := Vulkan.VkRect2D.{
        extent = .{ width = 1, height = 1 },
    };

    viewport_state := Vulkan.VkPipelineViewportStateCreateInfo.{
        viewportCount = 1,
        pViewports    = *viewport,
        scissorCount  = 1,
        pScissors     = *scissor,
    };

    rasterizer := Vulkan.VkPipelineRasterizationStateCreateInfo.{
        polygonMode = .FILL,
        cullMode    = .NONE,
        frontFace   = .COUNTER_CLOCKWISE,
        lineWidth   = 1.0,
    };

    multisample := Vulkan.VkPipelineMultisampleStateCreateInfo.{
        rasterizationSamples = ._1_BIT,
    };

    color_blend_attachment := Vulkan.VkPipelineColorBlendAttachmentState.{
        colorWriteMask      = .R_BIT | .G_BIT | .B_BIT | .A_BIT,
        srcColorBlendFactor = .ONE,
        dstColorBlendFactor = .ZERO,
        colorBlendOp        = .ADD,
        srcAlphaBlendFactor = .ONE,
        dstAlphaBlendFactor = .ZERO,
        alphaBlendOp        = .ADD,
    };

    color_blend := Vulkan.VkPipelineColorBlendStateCreateInfo.{
        attachmentCount = 1,
        pAttachments    = *color_blend_attachment,
    };

    dynamic_states := Vulkan.VkDynamicState.[.VIEWPORT, .SCISSOR];
    dynamic_state := Vulkan.VkPipelineDynamicStateCreateInfo.{
        dynamicStateCount = cast(u32) dynamic_states.count,
        pDynamicStates    = dynamic_states.data,
    };

    pipeline_info := Vulkan.VkGraphicsPipelineCreateInfo.{
        stageCount          = cast(u32) shader_stages.count,
        pStages             = shader_stages.data,
        pVertexInputState   = *vertex_input,
        pInputAssemblyState = *input_assembly,
        pViewportState      = *viewport_state,
        pRasterizationState = *rasterizer,
        pMultisampleState   = *multisample,
        pColorBlendState    = *color_blend,
        pDynamicState       = *dynamic_state,
        layout              = pipeline_layout,
        renderPass          = render_pass,
    };

    pipeline: Vulkan.VkPipeline;
    result = Vulkan.vkCreateGraphicsPipelines(ctx.device, null, 1, *pipeline_info, null, *pipeline);
    if result != .SUCCESS {
        print("vkCreateGraphicsPipelines failed: %\n", result);
        Vulkan.vkDestroyPipelineLayout(ctx.device, pipeline_layout, null);
        return null, null, false;
    }

    return pipeline_layout, pipeline, true;
}

load_shader_module :: (ctx: *Vulkan_Context, filename: string) -> Vulkan.VkShaderModule, bool {
    shader_path := tprint("%shaders/%", path_strip_filename(get_path_of_running_executable()), filename);
    code, ok := read_entire_file(shader_path);
    if !ok {
        print("Could not read shader: %\n", shader_path);
        return null, false;
    }
    defer free(code);

    if (code.count & 3) != 0 {
        print("SPIR-V file size is not 4-byte aligned: %\n", shader_path);
        return null, false;
    }

    info := Vulkan.VkShaderModuleCreateInfo.{
        codeSize = cast(u64) code.count,
        pCode    = cast(*u32) code.data,
    };

    module: Vulkan.VkShaderModule;
    result := Vulkan.vkCreateShaderModule(ctx.device, *info, null, *module);
    if result != .SUCCESS {
        print("vkCreateShaderModule failed for %: %\n", filename, result);
        return null, false;
    }

    return module, true;
}

create_vulkan_slot_render_targets :: (ctx: *Vulkan_Context, tri: *Vulkan_Triangle, config: Image_Config, slot: *Vulkan_Buffer) -> bool {
    view_info := Vulkan.VkImageViewCreateInfo.{
        image            = slot.image,
        viewType         = ._2D,
        format           = config.vk_format,
        subresourceRange = .{
            aspectMask = .COLOR_BIT,
            levelCount = 1,
            layerCount = 1,
        },
    };

    result := Vulkan.vkCreateImageView(ctx.device, *view_info, null, *slot.image_view);
    if result != .SUCCESS {
        print("vkCreateImageView failed: %\n", result);
        return false;
    }

    fb_info := Vulkan.VkFramebufferCreateInfo.{
        renderPass      = tri.render_pass,
        attachmentCount = 1,
        pAttachments    = *slot.image_view,
        width           = cast(u32) slot.width,
        height          = cast(u32) slot.height,
        layers          = 1,
    };

    result = Vulkan.vkCreateFramebuffer(ctx.device, *fb_info, null, *slot.framebuffer);
    if result != .SUCCESS {
        print("vkCreateFramebuffer failed: %\n", result);
        Vulkan.vkDestroyImageView(ctx.device, slot.image_view, null);
        slot.image_view = null;
        return false;
    }

    return true;
}

draw_vulkan_triangle :: (ctx: Vulkan_Context, tri: Vulkan_Triangle, slot: *Vulkan_Buffer, angle: float, first_use: bool) -> bool {
    // The slot's last submit must be done with its command buffer before it is
    // re-recorded. Normally long signalled: the slot was presented and released since.
    result := Vulkan.vkWaitForFences(ctx.device, 1, *slot.fence, Vulkan.VK_TRUE, FENCE_WAIT_NS);
    if result != .SUCCESS {
        print("vkWaitForFences on the slot's last submit failed: %\n", result);
        return false;
    }
    Vulkan.vkResetFences(ctx.device, 1, *slot.fence);
    cmd := slot.cmd;
    Vulkan.vkResetCommandBuffer(cmd, 0);

    begin := Vulkan.VkCommandBufferBeginInfo.{
        flags = .ONE_TIME_SUBMIT_BIT,
    };
    result = Vulkan.vkBeginCommandBuffer(cmd, *begin);
    if result != .SUCCESS {
        print("vkBeginCommandBuffer failed: %\n", result);
        return false;
    }

    range := Vulkan.VkImageSubresourceRange.{
        aspectMask = .COLOR_BIT,
        levelCount = 1,
        layerCount = 1,
    };

    acquire_src_family := ifx first_use then Vulkan.VK_QUEUE_FAMILY_IGNORED else Vulkan.VK_QUEUE_FAMILY_EXTERNAL;
    acquire_dst_family := ifx first_use then Vulkan.VK_QUEUE_FAMILY_IGNORED else ctx.queue_family;
    to_color := Vulkan.VkImageMemoryBarrier.{
        dstAccessMask       = .COLOR_ATTACHMENT_WRITE_BIT,
        oldLayout           = ifx first_use then Vulkan.VkImageLayout.UNDEFINED else Vulkan.VkImageLayout.GENERAL,
        newLayout           = .COLOR_ATTACHMENT_OPTIMAL,
        srcQueueFamilyIndex = acquire_src_family,
        dstQueueFamilyIndex = acquire_dst_family,
        image               = slot.image,
        subresourceRange    = range,
    };
    copy_path := slot.copy_buffer != null;
    foreign := ifx ctx.has_foreign then QUEUE_FAMILY_FOREIGN else Vulkan.VK_QUEUE_FAMILY_EXTERNAL;
    if copy_path {
        // The render target never leaves this queue, and the pass clears it: discard
        // last frame's contents instead of transferring ownership back.
        to_color.oldLayout           = .UNDEFINED;
        to_color.srcQueueFamilyIndex = Vulkan.VK_QUEUE_FAMILY_IGNORED;
        to_color.dstQueueFamilyIndex = Vulkan.VK_QUEUE_FAMILY_IGNORED;
        if !first_use {
            // Take the copy buffer back from the compositor's driver before writing it.
            acquire := Vulkan.VkBufferMemoryBarrier.{
                dstAccessMask       = .TRANSFER_WRITE_BIT,
                srcQueueFamilyIndex = foreign,
                dstQueueFamilyIndex = ctx.queue_family,
                buffer              = slot.copy_buffer,
                size                = Vulkan.VK_WHOLE_SIZE,
            };
            Vulkan.vkCmdPipelineBarrier(cmd, .TOP_OF_PIPE_BIT, .TRANSFER_BIT, 0, 0, null, 1, *acquire, 0, null);
        }
    }
    Vulkan.vkCmdPipelineBarrier(cmd,
        .TOP_OF_PIPE_BIT, .COLOR_ATTACHMENT_OUTPUT_BIT,
        cast(Vulkan.VkDependencyFlags) 0,
        0, null, 0, null, 1, *to_color);

    clear: Vulkan.VkClearValue;
    clear.color._float32[0] = 0.05;
    clear.color._float32[1] = 0.05;
    clear.color._float32[2] = 0.08;
    clear.color._float32[3] = 1.0;

    render_area := Vulkan.VkRect2D.{
        extent = .{ width = cast(u32) slot.width, height = cast(u32) slot.height },
    };

    pass_begin := Vulkan.VkRenderPassBeginInfo.{
        renderPass      = tri.render_pass,
        framebuffer     = slot.framebuffer,
        renderArea      = render_area,
        clearValueCount = 1,
        pClearValues    = *clear,
    };

    Vulkan.vkCmdBeginRenderPass(cmd, *pass_begin, .INLINE);

    viewport := Vulkan.VkViewport.{
        width    = cast(float) slot.width,
        height   = cast(float) slot.height,
        maxDepth = 1.0,
    };
    Vulkan.vkCmdSetViewport(cmd, 0, 1, *viewport);

    scissor := Vulkan.VkRect2D.{
        extent = .{ width = cast(u32) slot.width, height = cast(u32) slot.height },
    };
    Vulkan.vkCmdSetScissor(cmd, 0, 1, *scissor);

    Vulkan.vkCmdBindPipeline(cmd, .GRAPHICS, tri.pipeline);
    Vulkan.vkCmdPushConstants(cmd, tri.pipeline_layout, .VERTEX_BIT, 0, cast(u32) size_of(float), cast(*void) *angle);
    Vulkan.vkCmdDraw(cmd, 3, 1, 0, 0);
    Vulkan.vkCmdEndRenderPass(cmd);

    if copy_path {
        // The copy: OPTIMAL render target -> LINEAR rows in system memory, `stride` apart.
        to_src := Vulkan.VkImageMemoryBarrier.{
            srcAccessMask       = .COLOR_ATTACHMENT_WRITE_BIT,
            dstAccessMask       = .TRANSFER_READ_BIT,
            oldLayout           = .COLOR_ATTACHMENT_OPTIMAL,
            newLayout           = .TRANSFER_SRC_OPTIMAL,
            srcQueueFamilyIndex = Vulkan.VK_QUEUE_FAMILY_IGNORED,
            dstQueueFamilyIndex = Vulkan.VK_QUEUE_FAMILY_IGNORED,
            image               = slot.image,
            subresourceRange    = range,
        };
        Vulkan.vkCmdPipelineBarrier(cmd, .COLOR_ATTACHMENT_OUTPUT_BIT, .TRANSFER_BIT, 0, 0, null, 0, null, 1, *to_src);

        region := Vulkan.VkBufferImageCopy.{
            bufferRowLength   = slot.stride / 4,   // in texels
            bufferImageHeight = cast(u32) slot.height,
            imageSubresource  = .{ aspectMask = .COLOR_BIT, layerCount = 1 },
            imageExtent       = .{ width = cast(u32) slot.width, height = cast(u32) slot.height, depth = 1 },
        };
        Vulkan.vkCmdCopyImageToBuffer(cmd, slot.image, .TRANSFER_SRC_OPTIMAL, slot.copy_buffer, 1, *region);

        // Hand the buffer to the compositor's driver, which acquires it implicitly.
        release := Vulkan.VkBufferMemoryBarrier.{
            srcAccessMask       = .TRANSFER_WRITE_BIT,
            srcQueueFamilyIndex = ctx.queue_family,
            dstQueueFamilyIndex = foreign,
            buffer              = slot.copy_buffer,
            size                = Vulkan.VK_WHOLE_SIZE,
        };
        Vulkan.vkCmdPipelineBarrier(cmd, .TRANSFER_BIT, .BOTTOM_OF_PIPE_BIT, 0, 0, null, 1, *release, 0, null);
    } else {
        to_general := Vulkan.VkImageMemoryBarrier.{
            srcAccessMask       = .COLOR_ATTACHMENT_WRITE_BIT,
            oldLayout           = .COLOR_ATTACHMENT_OPTIMAL,
            newLayout           = .GENERAL,
            srcQueueFamilyIndex = ctx.queue_family,
            dstQueueFamilyIndex = Vulkan.VK_QUEUE_FAMILY_EXTERNAL,
            image               = slot.image,
            subresourceRange    = range,
        };
        Vulkan.vkCmdPipelineBarrier(cmd,
            .COLOR_ATTACHMENT_OUTPUT_BIT, .BOTTOM_OF_PIPE_BIT,
            cast(Vulkan.VkDependencyFlags) 0,
            0, null, 0, null, 1, *to_general);
    }

    result = Vulkan.vkEndCommandBuffer(cmd);
    if result != .SUCCESS {
        print("vkEndCommandBuffer failed: %\n", result);
        return false;
    }

    submit := Vulkan.VkSubmitInfo.{
        commandBufferCount = 1,
        pCommandBuffers    = *cmd,
    };
    if ctx.explicit_sync {
        submit.signalSemaphoreCount = 1;
        submit.pSignalSemaphores    = *slot.render_done;
    }
    result = Vulkan.vkQueueSubmit(ctx.queue, 1, *submit, slot.fence);
    if result != .SUCCESS {
        print("vkQueueSubmit failed: %\n", result);
        return false;
    }

    if ctx.explicit_sync {
        // The compositor waits on this fence (the commit's acquire point), not the CPU.
        // Exporting a SYNC_FD has copy transference: the semaphore is unsignalled again
        // afterwards, ready for the next submit. A driver may return SUCCESS with fd -1
        // when the semaphore has already signalled; commit_slot treats that as done.
        get_fd := Vulkan.VkSemaphoreGetFdInfoKHR.{ semaphore = slot.render_done, handleType = .SYNC_FD_BIT };
        if slot.acquire_fd >= 0  close(slot.acquire_fd);
        slot.acquire_fd = -1;
        result = Vulkan.vkGetSemaphoreFdKHR(ctx.device, *get_fd, *slot.acquire_fd);
        if result != .SUCCESS {
            print("vkGetSemaphoreFdKHR(SYNC_FD) failed: %\n", result);
            return false;
        }
        return true;
    }

    result = Vulkan.vkQueueWaitIdle(ctx.queue);
    if result != .SUCCESS {
        print("vkQueueWaitIdle failed: %\n", result);
        return false;
    }

    return true;
}

print_vulkan_loader_overrides :: () {
    icd_filenames := getenv("VK_ICD_FILENAMES");
    driver_files := getenv("VK_DRIVER_FILES");

    if icd_filenames != null {
        print("  VK_ICD_FILENAMES=%\n", to_string(icd_filenames));
        print("  This overrides Vulkan ICD discovery; stale manifest paths can hide installed drivers.\n");
    }

    if driver_files != null {
        print("  VK_DRIVER_FILES=%\n", to_string(driver_files));
        print("  This overrides Vulkan ICD discovery; stale manifest paths can hide installed drivers.\n");
    }
}
