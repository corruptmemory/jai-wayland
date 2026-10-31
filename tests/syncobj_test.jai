// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jim Powers

// DRM sync objects (modules/gpu/syncobj.jai) on the box's render node, with no
// compositor. The kernel lets the CPU signal a timeline point, so creating, waiting,
// sharing a timeline through an fd and moving a fence in and out as a sync_file all
// run without GPU work. Prints SKIP, naming the reason, on a box with no render node
// or a driver without timeline sync objects.

#import "Basic";
#import "POSIX";
// By NAME, with the modules/-first import path, so this is the instance
// Wayland_Support itself uses.
Gpu :: #import "gpu";
#import "GL";
EGL :: #import "EGL";
WS  :: #import,file "../modules/Wayland_Support.jai";
Wl  :: #import "wayland";

main :: () {
    print("=== Syncobj Tests ===\n\n");

    drm_fd, ok := open_render_node();
    if !ok {
        print("\n=== Syncobj tests skipped ===\n");
        return;
    }
    defer close(drm_fd);

    rec: Error_Recorder;
    ctx := context;
    ctx.logger      = record_errors;
    ctx.logger_data = *rec;
    push_context ctx {
        test_cpu_signal_and_poll(drm_fd);
        test_wait_times_out_relative(drm_fd);
        test_export_import_same_timeline(drm_fd);
        test_sync_file_round_trip(drm_fd);
        test_wait_on_destroyed_handle_logs_one_error(drm_fd);
        test_attach_fence_without_fd_signals_point(drm_fd);
        test_store_acquire_fence_closes_stale_fd();
        test_gl_fence_signals_timeline_point();
        test_cpu_signal_fallback_sets_acquire(drm_fd);
        test_release_point_frees_slot(drm_fd);
        test_retired_slot_reaped_on_release_point(drm_fd);
    }
    if rec.errors.count != rec.expected_errors {
        for rec.errors  print("  logged error: %\n", it);
    }
    assert(rec.errors.count == rec.expected_errors, "% error(s) logged, % expected", rec.errors.count, rec.expected_errors);

    print("\n=== All syncobj tests passed ===\n");
}

Error_Recorder :: struct {
    errors:          [..] string;
    expected_errors: int;   // raised by negative tests before the call that must log
}

record_errors :: (message: string, data: *void, info: Log_Info) {
    if info.common_flags & .ERROR {
        rec := cast(*Error_Recorder) data;
        array_add(*rec.errors, copy_string(message));
    }
}

open_render_node :: () -> s32, bool {
    nodes: [..] Gpu.Render_Node_Info;
    if !Gpu.discover_render_nodes(*nodes) {
        print("  SKIP: no DRM render nodes on this box\n");
        return -1, false;
    }
    fd := open(temp_c_string(nodes[0].path), O_RDWR | O_CLOEXEC);
    if fd < 0 {
        print("  SKIP: cannot open % (errno %)\n", nodes[0].path, errno());
        return -1, false;
    }
    if !Gpu.syncobj_timeline_supported(fd) {
        print("  SKIP: % (%) has no timeline sync objects\n", nodes[0].path, Gpu.vendor_name(nodes[0].vendor));
        close(fd);
        return -1, false;
    }
    print("  render node: % (%)\n", nodes[0].path, Gpu.vendor_name(nodes[0].vendor));
    return fd, true;
}

test_cpu_signal_and_poll :: (drm_fd: s32) {
    t, ok := Gpu.syncobj_create(drm_fd);
    assert(ok, "syncobj_create failed");
    defer Gpu.syncobj_destroy(drm_fd, t);

    assert(Gpu.syncobj_signal(drm_fd, t, 1), "signalling point 1 from the CPU failed");
    assert(Gpu.syncobj_point_signaled(drm_fd, t, 1), "point 1 should read signalled");
    assert(!Gpu.syncobj_point_signaled(drm_fd, t, 2), "point 2 was never submitted and should not read signalled");
    print("  PASS: a CPU-signalled point reads signalled, the next one does not\n");
}

test_wait_times_out_relative :: (drm_fd: s32) {
    t, ok := Gpu.syncobj_create(drm_fd);
    assert(ok, "syncobj_create failed");
    defer Gpu.syncobj_destroy(drm_fd, t);

    // The kernel's timeout is an absolute CLOCK_MONOTONIC time. Passed through
    // unconverted, 20 ms would be a moment in 1970 and the wait would return at once.
    start := seconds_since_init();
    result := Gpu.syncobj_wait(drm_fd, .[t], .[3], 20_000_000);
    elapsed := seconds_since_init() - start;
    assert(result == .TIMED_OUT, "a wait on a point nobody signals should time out, got %", result);
    assert(elapsed >= 0.015 && elapsed < 1.0, "a 20 ms wait took % s", elapsed);
    print("  PASS: a wait on an unsignalled point times out after its relative timeout (% ms)\n", formatFloat(elapsed * 1000.0, trailing_width=1));
}

test_export_import_same_timeline :: (drm_fd: s32) {
    t, ok := Gpu.syncobj_create(drm_fd);
    assert(ok, "syncobj_create failed");
    defer Gpu.syncobj_destroy(drm_fd, t);

    fd := Gpu.syncobj_export(drm_fd, t);
    assert(fd >= 0, "syncobj_export failed");
    t2, imported := Gpu.syncobj_import(drm_fd, fd);
    close(fd);
    assert(imported, "syncobj_import failed");
    defer Gpu.syncobj_destroy(drm_fd, t2);

    assert(Gpu.syncobj_signal(drm_fd, t2, 5), "signalling through the imported handle failed");
    assert(Gpu.syncobj_point_signaled(drm_fd, t, 5), "the exported timeline should see a point signalled through its import");
    print("  PASS: an exported and re-imported handle is the same timeline\n");
}

test_sync_file_round_trip :: (drm_fd: s32) {
    t, ok := Gpu.syncobj_create(drm_fd);
    assert(ok, "syncobj_create failed");
    defer Gpu.syncobj_destroy(drm_fd, t);

    assert(Gpu.syncobj_signal(drm_fd, t, 1), "signalling point 1 failed");
    sync_file := Gpu.syncobj_export_sync_file(drm_fd, t, 1);
    assert(sync_file >= 0, "exporting point 1 as a sync_file failed");
    defer close(sync_file);

    assert(Gpu.syncobj_import_sync_file(drm_fd, t, 6, sync_file), "importing the sync_file at point 6 failed");
    assert(Gpu.syncobj_point_signaled(drm_fd, t, 6), "point 6 carries an already-signalled fence and should read signalled");
    assert(fcntl(sync_file, F_GETFD) >= 0, "syncobj_import_sync_file must leave the caller's fd open");
    print("  PASS: a point exported as a sync_file and imported at a later point reads signalled\n");
}

test_wait_on_destroyed_handle_logs_one_error :: (drm_fd: s32) {
    t, ok := Gpu.syncobj_create(drm_fd);
    assert(ok, "syncobj_create failed");
    Gpu.syncobj_destroy(drm_fd, t);

    rec := cast(*Error_Recorder) context.logger_data;
    before := rec.errors.count;
    rec.expected_errors += 1;
    result := Gpu.syncobj_wait(drm_fd, .[t], .[1], 0);
    assert(result == .ERROR, "a wait on a destroyed handle should fail, got %", result);
    assert(rec.errors.count == before + 1, "a failed wait should log one error, logged %", rec.errors.count - before);
    print("  PASS: a wait on a destroyed handle fails and logs one error\n");
}

// An app turn (a configure arriving while the present waits on the previous frame)
// returns to the app without committing, so the next frame's fence replaces one that
// never reached the compositor. The stale fd must be closed, not leaked.
test_store_acquire_fence_closes_stale_fd :: () {
    pipe_fds: [2] s32;
    assert(pipe(*pipe_fds) == 0, "pipe failed");
    defer close(pipe_fds[1]);
    stale, fresh := pipe_fds[0], dup(pipe_fds[1]);

    slot: WS.Wl_Gl_Slot;
    WS.wl_store_acquire_fence(*slot, stale);
    WS.wl_store_acquire_fence(*slot, fresh);
    assert(slot.acquire_fence_fd == fresh, "the slot should hold the newest fence");
    assert(fcntl(stale, F_GETFD) == -1, "the replaced fence fd % should have been closed", stale);
    close(fresh);
    print("  PASS: storing a new acquire fence closes the stale one\n");
}

// The present path's GL fence: on the render node Wayland_Support would use, a
// clear followed by wl_native_fence_fd yields a sync_file that, attached to a
// timeline point, signals once the GPU has done the clear.
test_gl_fence_signals_timeline_point :: () {
    egl: WS.Wl_Egl_State;
    if !WS.wl_egl_init(*egl, .{}) {
        print("  SKIP: no EGL/GBM context on this box\n");
        return;
    }
    defer WS.wl_egl_destroy(*egl);
    if !WS.wl_have_native_fence {
        print("  SKIP: the EGL display has no EGL_ANDROID_native_fence_sync\n");
        return;
    }
    if !Gpu.syncobj_timeline_supported(egl.drm_fd) {
        print("  SKIP: the EGL render node has no timeline sync objects\n");
        return;
    }

    glClearColor(0.25, 0.5, 0.75, 1.0);
    glClear(GL_COLOR_BUFFER_BIT);
    fd := WS.wl_native_fence_fd(egl);
    assert(fd >= 0, "wl_native_fence_fd returned no sync_file");
    defer close(fd);

    t, ok := Gpu.syncobj_create(egl.drm_fd);
    assert(ok, "syncobj_create failed");
    defer Gpu.syncobj_destroy(egl.drm_fd, t);
    assert(Gpu.syncobj_import_sync_file(egl.drm_fd, t, 1, fd), "importing the GL fence failed");
    result := Gpu.syncobj_wait(egl.drm_fd, .[t], .[1], 1_000_000_000);
    assert(result == .SIGNALED, "the GL fence should signal within a second, got %", result);
    print("  PASS: a GL native fence imported at a timeline point signals\n");
}

// A frame whose fence could not be made (the present falls back to glFinish) still
// has to commit with an acquire point: the protocol requires both points on every
// buffer commit. With no fence parked, the point is signalled from the CPU.
test_cpu_signal_fallback_sets_acquire :: (drm_fd: s32) {
    slot: WS.Wl_Gl_Slot;
    t, ok := Gpu.syncobj_create(drm_fd);
    assert(ok, "syncobj_create failed");
    defer Gpu.syncobj_destroy(drm_fd, t);
    slot.sync_timeline = t;

    acquire, release, set := WS.wl_set_acquire_point(drm_fd, *slot);
    assert(set && acquire == 1 && release == 2, "the first commit should use points 1 and 2, got % and % (ok %)", acquire, release, set);
    assert(Gpu.syncobj_point_signaled(drm_fd, t, 1), "with no fence parked the acquire point should be signalled from the CPU");
    assert(!Gpu.syncobj_point_signaled(drm_fd, t, 2), "the release point is the compositor's to signal");

    // The compositor's release of commit 1 lands before commit 2 reuses the slot.
    assert(Gpu.syncobj_signal(drm_fd, t, 2), "signalling the release point failed");
    acquire, release, set = WS.wl_set_acquire_point(drm_fd, *slot);
    assert(set && acquire == 3 && release == 4, "the second commit should use points 3 and 4, got % and %", acquire, release);
    print("  PASS: commit n uses acquire 2n-1 and release 2n; no fence means a CPU-signalled acquire\n");
}

// Once a surface uses explicit sync, wl_buffer.release is undefined: a slot is free
// again only when its release point has signalled.
test_release_point_frees_slot :: (drm_fd: s32) {
    ww: WS.Wayland_Window;
    ww.wl_explicit_sync = true;
    t, ok := Gpu.syncobj_create(drm_fd);
    assert(ok, "syncobj_create failed");
    defer Gpu.syncobj_destroy(drm_fd, t);
    ww.wl_slots[0].sync_timeline = t;
    ww.wl_slots[0].in_flight     = true;
    ww.wl_slots[0].release_point = 2;

    WS.wl_refresh_slot_releases(drm_fd, *ww);
    assert(ww.wl_slots[0].in_flight, "a slot whose release point has not signalled must stay in flight");
    assert(Gpu.syncobj_signal(drm_fd, t, 2), "signalling the release point failed");
    WS.wl_refresh_slot_releases(drm_fd, *ww);
    assert(!ww.wl_slots[0].in_flight && ww.wl_slots[0].release_point == 0, "a signalled release point should free the slot");
    print("  PASS: a slot leaves flight when its release point signals, not before\n");
}

// A slot retired by a resize while the compositor still held it must still be
// destroyed once released, although no wl_buffer.release can be relied on.
test_retired_slot_reaped_on_release_point :: (drm_fd: s32) {
    ww: WS.Wayland_Window;
    ww.wl_explicit_sync = true;
    t, ok := Gpu.syncobj_create(drm_fd);
    assert(ok, "syncobj_create failed");
    retired: WS.Wl_Gl_Slot;
    retired.buffer.id     = 1000;   // a destroy is queued for it, never sent
    retired.sync_timeline = t;      // owned by the slot now: reaping destroys it
    retired.in_flight     = true;
    retired.release_point = 2;
    array_add(*ww.wl_retired, retired);
    egl := WS.Wl_Egl_State.{ drm_fd = drm_fd };

    batch: Wl.MessageBuilder;
    WS.wl_reap_retired(*batch, egl, *ww);
    assert(ww.wl_retired.count == 1, "a retired slot whose release point has not signalled must be kept");
    assert(Gpu.syncobj_signal(drm_fd, t, 2), "signalling the release point failed");
    WS.wl_reap_retired(*batch, egl, *ww);
    assert(ww.wl_retired.count == 0, "a retired slot should be reaped once its release point signals");
    assert(batch.out_used > 0, "reaping should queue the wl_buffer and timeline destroys");
    print("  PASS: a retired slot is reaped when its release point signals\n");
}

// A Vulkan driver may export an already-signalled SYNC_FD semaphore as fd -1 (the
// spec allows it; a small frame can finish before the export). "No fence" then means
// "already done", as after the GL glFinish fallback: the point is signalled from the
// CPU instead of the commit failing.
test_attach_fence_without_fd_signals_point :: (drm_fd: s32) {
    t, ok := Gpu.syncobj_create(drm_fd);
    assert(ok, "syncobj_create failed");
    defer Gpu.syncobj_destroy(drm_fd, t);

    assert(Gpu.syncobj_attach_fence(drm_fd, t, 1, -1), "attaching 'no fence' should signal the point");
    assert(Gpu.syncobj_point_signaled(drm_fd, t, 1), "point 1 should read signalled");

    sync_file := Gpu.syncobj_export_sync_file(drm_fd, t, 1);
    assert(sync_file >= 0, "exporting point 1 failed");
    defer close(sync_file);
    assert(Gpu.syncobj_attach_fence(drm_fd, t, 2, sync_file), "attaching a real sync_file failed");
    assert(Gpu.syncobj_point_signaled(drm_fd, t, 2), "point 2 carries a signalled fence and should read signalled");
    print("  PASS: attaching fd -1 signals the point; a real sync_file is imported\n");
}
