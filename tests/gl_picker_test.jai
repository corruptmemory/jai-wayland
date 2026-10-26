// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jim Powers

// Wayland_Support's GL format pickers against a real GBM device. No compositor:
// a render node, a GBM device on it and an EGL display on that are enough to ask
// the driver which modifiers it has and how many planes each one needs. On a box
// with no render node, or a driver with no multi-plane modifier for ABGR8888
// (NVIDIA, Intel without CCS), the test says SKIP and why.

#import "Basic";
#import "POSIX";
WS  :: #import,file "../modules/Wayland_Support.jai";
// By NAME, so these are the instances Wayland_Support itself uses.
Wl  :: #import "wayland";
EGL :: #import "EGL";
Gbm :: #import "gbm";
Gpu :: #import "gpu";

main :: () {
    print("=== GL Picker Tests ===\n\n");

    test_gl_picker_rejects_multiplane_modifier();

    print("\n=== All GL picker tests passed ===\n");
}

// radeonsi lists its DCC modifiers (2 or 3 planes) ahead of the single-plane
// ones. The present path exports one fd per buffer and wl_slot_init_bo refuses a
// BO with more than one plane, with no fallback, so a picker that returns a
// multi-plane modifier fails every window's GL init. Both pickers must skip it.
test_gl_picker_rejects_multiplane_modifier :: () {
    format := Gbm.GBM_FORMAT_ABGR8888;
    flags  := cast(u32) Gbm.GBM_BO_USE_RENDERING;

    gbm, modifiers, ok := open_gbm_and_query_modifiers(format);
    if !ok  return;  // the helper printed the SKIP reason

    multi, single: u64;
    have_multi, have_single: bool;
    for modifiers {
        planes := Gbm.gbm_device_get_format_modifier_plane_count(gbm, format, it);
        if planes >  1 && !have_multi  { multi  = it; have_multi  = true; }
        if planes == 1 && !have_single { single = it; have_single = true; }
    }
    if !have_multi || !have_single {
        print("  SKIP: gl_picker_rejects_multiplane_modifier (% ABGR8888 modifiers; multi-plane=%, single-plane=%)\n",
              modifiers.count, have_multi, have_single);
        return;
    }

    assert(!Gpu.supports_bo_format_modifier(gbm, format, multi, flags),
           "multi-plane modifier 0x% passed supports_bo_format_modifier", formatInt(multi, base = 16));

    // The multi-plane modifier comes first in tranche order, as radeonsi lists it.
    feedback: Wl.Dmabuf_Feedback_Info;
    feedback.complete = true;
    tranche := array_add(*feedback.tranches);
    array_add(*tranche.formats, .{ format = format, modifier = multi });
    array_add(*tranche.formats, .{ format = format, modifier = single });
    _, picked, found := WS.wl_pick_format_from_feedback_for_gbm(gbm, feedback, format, flags);
    assert(found && picked == single, "feedback picker chose 0x% (found=%); wanted single-plane 0x%, not multi-plane 0x%",
           formatInt(picked, base = 16), found, formatInt(single, base = 16), formatInt(multi, base = 16));

    // The global list's last, any-modifier pass must not fall through to it either.
    only_multi := Wl.Format_Modifier.[ .{ format = format, modifier = multi } ];
    _, picked, found = WS.wl_pick_global_format_for_gbm(gbm, only_multi, format, flags);
    assert(!found, "global picker chose multi-plane 0x%", formatInt(picked, base = 16));

    print("  PASS: gl_picker_rejects_multiplane_modifier\n");
}

// Opens the selected render node, a GBM device on it and an EGL display on that,
// and returns the driver's modifiers for `format` via eglQueryDmaBufModifiersEXT.
// The fd, device and display live as long as the test process.
open_gbm_and_query_modifiers :: (format: u32) -> Gbm.Gbm_Device, [] u64, bool {
    node, node_ok := Gpu.select_render_node();
    if !node_ok { print("  SKIP: no DRM render node\n"); return null, .[], false; }

    fd := open(temp_c_string(node.path), O_RDWR | O_CLOEXEC);
    assert(fd >= 0, "open % failed, errno=%", node.path, errno());
    assert(Gbm.init_gbm() && EGL.init_egl(), "libgbm or libEGL did not load");
    gbm := Gbm.gbm_create_device(fd);
    assert(gbm != null, "gbm_create_device failed on %", node.path);
    dpy := EGL.eglGetPlatformDisplay(EGL.EGL_PLATFORM_GBM_KHR, gbm, null);
    assert(dpy != EGL.EGL_NO_DISPLAY && EGL.eglInitialize(dpy, null, null) == EGL.EGL_TRUE, "no EGL display on GBM");

    Query :: #type (dpy: EGL.EGLDisplay, format: EGL.EGLint, max: EGL.EGLint, modifiers: *u64,
                    external_only: *EGL.EGLBoolean, count: *EGL.EGLint) -> EGL.EGLBoolean #c_call;
    query: Query = xx EGL.eglGetProcAddress("eglQueryDmaBufModifiersEXT");
    if query == null { print("  SKIP: no eglQueryDmaBufModifiersEXT\n"); return gbm, .[], false; }

    count: EGL.EGLint;
    assert(query(dpy, cast(EGL.EGLint) format, 0, null, null, *count) == EGL.EGL_TRUE, "modifier count query failed");
    modifiers := NewArray(count, u64);
    assert(query(dpy, cast(EGL.EGLint) format, count, modifiers.data, null, *count) == EGL.EGL_TRUE, "modifier query failed");
    modifiers.count = count;
    return gbm, modifiers, true;
}
