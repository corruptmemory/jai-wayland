// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jim Powers

// Wayland_Support — the GPU-aware support layer that sits ABOVE the pure
// wire-protocol `wayland` module and is imported by the windowing consumers
// (Simp, Input, GetRect). It is the Wayland analogue of `modules/X11`: a bag of
// well-known module-scope globals + the functions over them. Because Jai
// instantiates an imported module exactly once and name-based `#import` dedups
// across importers, the globals declared here (wayland_global_windows, …) are a
// SINGLE shared instance that every consumer reaches by name — the same way
// Window_Creation/Input/Simp all reach into X11's x_global_windows /
// x_global_display. That shared-global model is what lets one event pump serve
// both rendering (Simp) and input (Input) over the single compositor connection.
//
// Layering: `modules/wayland` stays pure wire protocol (no GPU deps) so minimal
// consumers (hello_globals, the tests) compile lean. The EGL/GBM/GL dependency
// lives HERE, one layer up, paid for only by consumers that render. ldd stays
// libc-only regardless — EGL/gbm/gpu/GL are runtime-dlopen bindings.
//
// The render machinery below is PORTED from examples/hello_gl.jai (the Option-B
// reference proven on Mesa AMD/Intel and NVIDIA) via the now-removed
// Simp/backend/wayland_gl.jai. hello_gl.jai stays frozen as the reference.

// Bare (anonymous) imports — GL entry points (glGenTextures, GL_TEXTURE_2D, …),
// POSIX (open/close/O_RDWR/O_CLOEXEC for the dmabuf/keymap fds), and Basic
// (log / to_string / temp_c_string / formatInt) are all referenced unqualified.
#import "Basic";
#import "POSIX";
#import "GL";

// Named imports — qualified at the call site. All name-based: first.jai's
// upstream_import_path() puts "modules" first, so these resolve to OUR vendored
// modules (not the stdlib), and name-based dedups across every importer so the
// wayland session / GL function pointers are one shared instance with Simp/Input.
Wl  :: #import "wayland";
EGL :: #import "EGL";
Gbm :: #import "gbm";
Gpu :: #import "gpu";

// Window_Type is the shared window-identity module. We read ONE field from it:
// wayland_drag_and_drop_requested, the opt-in flag X11.enable_drag_and_drop flips
// for the Wayland backend (see the DnD section below). Importing it here — rather
// than having X11 reach into Wayland_Support — keeps the two backend modules from
// importing each other, and keeps the pure-X11 examples (x11_smoke) from pulling
// in the EGL/GBM stack this module carries.
WT :: #import "Window_Type";

// ───────────────────────── Backend selection ──────────────────────────────

// Which display server a Simp/Input/GetRect process is talking to. Simp parks
// this on its per-state Backend_Platform_Specific (display_manager field) and
// branches on it at each backend op, in place of the old context.simp_dispatch
// function pointer. It lives here so the backend-selection vocabulary is owned
// by the windowing-support module — the X11 mirror — not buried in vendored Simp.
Display_Manager :: enum u8 {
    UNDEFINED;
    X11;
    WAYLAND;
}

// True when WAYLAND_DISPLAY is set (a Wayland session); false under X11 (an X11
// app on XWayland sees DISPLAY, not WAYLAND_DISPLAY). getenv returns a null *u8
// when unset — guard before to_string so we never walk null. Simp's CheckInit
// calls this once to set Display_Manager. (Window_Creation calls it too, for
// create-arm selection.)
running_wayland :: () -> bool {
    wd := getenv("WAYLAND_DISPLAY");
    if !wd  return false;
    return to_string(wd).count > 0;
}

// ───────────────────────── EGL / GL state ─────────────────────────────────

// Triple-buffered for the asynchronous (non-blocking) present: the compositor
// scans out one slot, one sits committed-waiting, and we render into the third,
// so the app never has to block waiting for a free buffer. wl_buffer.release
// marks a slot free again. (Was 2 under the old synchronous frame-callback
// present; see docs/plans/2026-05-31-wayland-async-present.md.)
SIMP_WL_SLOT_COUNT :: 3;

// Slot allocation capacity is bucketed: the logical size rounded up to
// BUCKET_STEP, capped at output resolution, grow-only. This decouples the
// logical window size (what Simp renders / what the compositor sees via
// wp_viewport) from the BO/FBO/wl_buffer allocation size, so interactive resize
// stops reallocating the whole slot stack on every configure.
// See docs/plans/2026-06-03-wayland-bucketed-slots-design.md.
BUCKET_STEP :: 256;

wl_round_up_to_step :: (v: s32, step: s32) -> s32 {
    if v <= 0  return step;
    return ((v + step - 1) / step) * step;
}

// Largest output dimensions, discovered once and cached. The capacity cap: a
// normal window cannot exceed its monitor, so this keeps a maximized window's
// buffer from rounding past the screen. Falls back to a generous 8K if output
// discovery yields nothing.
wl_output_cap_initialized: bool;
wl_output_cap_w: s32 = 7680;
wl_output_cap_h: s32 = 4320;

wl_output_cap :: () -> (w: s32, h: s32) {
    if wl_output_cap_initialized  return wl_output_cap_w, wl_output_cap_h;
    wl_output_cap_initialized = true;

    // get_screens_info allocates with the default allocator; this is a one-shot
    // cache read of int dimensions, so run it on temp and let the block free it.
    screens: [] Wl.Screen_Info;
    {
        push_allocator(temp);
        screens = Wl.get_screens_info();
    }
    max_w: s32 = 0;
    max_h: s32 = 0;
    for screens {
        if it.current_mode.width  > max_w  max_w = it.current_mode.width;
        if it.current_mode.height > max_h  max_h = it.current_mode.height;
    }
    if max_w > 0 && max_h > 0 {
        wl_output_cap_w = max_w;
        wl_output_cap_h = max_h;
    }
    return wl_output_cap_w, wl_output_cap_h;
}

// Grow-only bucketed capacity for a logical size: round up to BUCKET_STEP, cap at
// output resolution, never below the current capacity, and never below the
// logical size itself (logical can exceed the output cap on odd configs).
wl_target_capacity :: (logical_w: s32, logical_h: s32, cur_cap_w: s32, cur_cap_h: s32) -> (w: s32, h: s32) {
    cap_w, cap_h := wl_output_cap();
    want_w := min(wl_round_up_to_step(logical_w, BUCKET_STEP), cap_w);
    want_h := min(wl_round_up_to_step(logical_h, BUCKET_STEP), cap_h);
    out_w := max(max(want_w, cur_cap_w), logical_w);
    out_h := max(max(want_h, cur_cap_h), logical_h);
    return out_w, out_h;
}

// One slot holds a GL texture + FBO + EGLImage + (optional) GBM BO + the
// exported DMA-BUF fd wrapped as a wl_buffer. (hello_gl.jai:31-51 Gl_Slot.)
Wl_Gl_Slot :: struct {
    tex:       u32;
    fbo:       u32;
    depth_rbo: u32;   // depth renderbuffer (the BO-backed color texture has no depth; 3D apps need it)
    image:     EGL.EGLImage;
    bo:        Gbm.Gbm_Bo;
    buffer:    Wl.Wl_Buffer;
    fd:        s32 = -1;
    image_fd:  s32 = -1;
    stride:    u32;
    offset:    u32;
    modifier:  u64;
    format:    u32;
    width:     s32;
    height:    s32;
    bo_backed: bool;
    in_flight: bool;
    // Placeholders for EGL_KHR_fence_sync + wp_linux_drm_syncobj_v1 explicit sync.
    // Currently unused — glFinish() provides coarse but correct GPU ordering.
    acquire_fence_fd: s32 = -1;
    release_fence_fd: s32 = -1;
}

// EGL display/context + GBM device + drm fd. Simp's GL objects (shaders, VBOs,
// font/texture handles) are process-global, matching the stock X11 backend's
// single GLX context, so all Wayland windows render through one shared context.
Wl_Egl_State :: struct {
    drm_fd: s32 = -1;
    gbm:    Gbm.Gbm_Device;
    dpy:    EGL.EGLDisplay;
    ctx:    EGL.EGLContext;
}

// The GL backend selection hello_gl exposes. AUTO probes the loaded extensions
// and resolves to GBM_BO when available, MESA_TEXTURE_EXPORT otherwise.
Wl_Gl_Backend :: enum {
    AUTO;                // try GBM_BO, fall back to MESA_TEXTURE_EXPORT if unavailable
    GBM_BO;              // GBM BO → EGLImage → FBO; hard-fail if extensions absent
    MESA_TEXTURE_EXPORT; // EGL_MESA_image_dma_buf_export path
}

wl_gl_backend_name :: (b: Wl_Gl_Backend) -> string {
    if b == {
        case .GBM_BO;              return "gbm_bo";
        case .MESA_TEXTURE_EXPORT; return "mesa_texture_export";
        case .AUTO;                return "auto";
    }
    return "unknown";
}

// Which backend AUTO would resolve to given the currently-loaded extensions.
// (hello_gl.jai:357-361 choose_gl_backend.)
wl_choose_gl_backend :: () -> Wl_Gl_Backend {
    if Gbm.gbm_bo_create != null && Gbm.gbm_bo_destroy != null && glEGLImageTargetTexture2DOES != null
        return .GBM_BO;
    return .MESA_TEXTURE_EXPORT;
}

// Bring up render-node selection (modules/gpu) + EGL/GBM/GL loaders, writing
// into the passed struct. (hello_gl.jai:370-424 init_gl_stack.)
wl_egl_init :: (egl: *Wl_Egl_State) -> bool {
    nodes: [..] Gpu.Render_Node_Info;
    if !Gpu.discover_render_nodes(*nodes)  return false;
    Gpu.print_render_nodes(nodes);

    selected, selected_ok := Gpu.choose_render_node(nodes);
    if !selected_ok  return false;
    log("Selected render node: % (% id=0x%)",
        selected.path,
        Gpu.vendor_name(selected.vendor),
        formatInt(selected.vendor_id, base=16, minimum_digits=4));

    egl.drm_fd = open(temp_c_string(selected.path), O_RDWR | O_CLOEXEC);
    if egl.drm_fd < 0  return false;
    if !EGL.init_egl() || !Gbm.init_gbm()  return false;

    egl.gbm = Gbm.gbm_create_device(egl.drm_fd);
    if !egl.gbm  return false;
    if Gbm.gbm_device_get_backend_name != null {
        log("GBM backend: %", to_string(Gbm.gbm_device_get_backend_name(egl.gbm)));
    }

    egl.dpy = EGL.eglGetPlatformDisplay(EGL.EGL_PLATFORM_GBM_KHR, egl.gbm, null);
    if egl.dpy == EGL.EGL_NO_DISPLAY  return false;

    if EGL.eglInitialize(egl.dpy, null, null) != EGL.EGL_TRUE  return false;
    if !EGL.init_egl_extensions(egl.dpy)  return false;

    EGL.eglBindAPI(EGL.EGL_OPENGL_API);
    config_attrs := s32.[
        EGL.EGL_SURFACE_TYPE,    EGL.EGL_WINDOW_BIT,
        EGL.EGL_RENDERABLE_TYPE, EGL.EGL_OPENGL_BIT,
        EGL.EGL_RED_SIZE, 8, EGL.EGL_GREEN_SIZE, 8, EGL.EGL_BLUE_SIZE, 8, EGL.EGL_ALPHA_SIZE, 8,
        EGL.EGL_NONE,
    ];
    cfg: EGL.EGLConfig;
    n: EGL.EGLint;
    if EGL.eglChooseConfig(egl.dpy, config_attrs.data, *cfg, 1, *n) != EGL.EGL_TRUE || n == 0  return false;

    ctx_attrs := s32.[
        EGL.EGL_CONTEXT_MAJOR_VERSION_KHR, 3,
        EGL.EGL_CONTEXT_MINOR_VERSION_KHR, 3,
        EGL.EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT_KHR,
        EGL.EGL_NONE,
    ];
    egl.ctx = EGL.eglCreateContext(egl.dpy, cfg, EGL.EGL_NO_CONTEXT, ctx_attrs.data);
    if egl.ctx == EGL.EGL_NO_CONTEXT  return false;

    if EGL.eglMakeCurrent(egl.dpy, EGL.EGL_NO_SURFACE, EGL.EGL_NO_SURFACE, egl.ctx) != EGL.EGL_TRUE  return false;
    if !gl_load(EGL.eglGetProcAddress)  return false;
    if !gl_load_egl_image_extensions(EGL.eglGetProcAddress) {
        log("Warning: GL_OES_EGL_image missing; BO-backed slots disabled", flags=.WARNING);
    }
    return true;
}

// (hello_gl.jai:426-431 destroy_gl_stack.)
wl_egl_destroy :: (egl: *Wl_Egl_State) {
    if egl.ctx  EGL.eglDestroyContext(egl.dpy, egl.ctx);
    if egl.dpy != EGL.EGL_NO_DISPLAY  EGL.eglTerminate(egl.dpy);
    if egl.gbm  Gbm.gbm_device_destroy(egl.gbm);
    if egl.drm_fd >= 0  close(egl.drm_fd);
}

wl_shared_egl: Wl_Egl_State;
wl_shared_egl_initialized: bool;

wl_ensure_shared_egl :: () -> bool {
    if !wl_shared_egl_initialized {
        if !wl_egl_init(*wl_shared_egl)  return false;
        wl_shared_egl_initialized = true;
    }

    return true;
}

wl_make_current :: () -> bool {
    if !wl_ensure_shared_egl()  return false;

    if EGL.eglMakeCurrent(wl_shared_egl.dpy, EGL.EGL_NO_SURFACE, EGL.EGL_NO_SURFACE, wl_shared_egl.ctx) != EGL.EGL_TRUE {
        log_error("Wayland_Support: eglMakeCurrent failed");
        return false;
    }
    return true;
}

wl_shared_context :: () -> EGL.EGLContext {
    return wl_shared_egl.ctx;
}

// ─────────────────────── Viewporter (bucketed crop) ───────────────────────
// wp_viewporter lets us present only the logical sub-rect of an oversized
// (bucketed) buffer, so the slot allocation size can exceed the surface size.
// Bound once; absent on a compositor that does not advertise it (we then fall
// back to realloc-per-resize). See the design doc.

wl_viewporter: Wl.Wp_Viewporter;
wl_have_viewporter: bool;
wl_viewporter_initialized: bool;

wl_fixed_from_int :: (v: s32) -> Wl.Fixed {
    return .{ raw = v << 8 };
}

wl_ensure_viewporter :: () {
    if wl_viewporter_initialized  return;
    wl_viewporter_initialized = true;

    _, ok := Wl.get_global("wp_viewporter");
    if !ok  return;

    wl_viewporter = .{ id = Wl.allocate_id() };
    batch: Wl.MessageBuilder;
    if !Wl.wl_registry_bind(*batch, Wl.registry(), *wl_viewporter) {
        wl_viewporter = .{};
        return;
    }
    if !Wl.wayland_send(*batch) {
        wl_viewporter = .{};
        return;
    }
    wl_have_viewporter = true;
    log("Wayland_Support: wp_viewporter available; using bucketed slot capacity");
}

// Create a wp_viewport for this surface (once). No-op if viewporter is absent.
// TODO(teardown): the per-window wp_viewport created here should be destroyed in a
// future per-window teardown pass (like the surface roles, it is process-lifetime-
// owned today).
wl_window_init_viewport :: (ww: *Wayland_Window) {
    wl_ensure_viewporter();
    if !wl_have_viewporter  return;

    ww.wl_viewport = .{ id = Wl.allocate_id() };
    batch: Wl.MessageBuilder;
    Wl.wp_viewporter_get_viewport(*batch, *wl_viewporter, ww.wl_viewport.id, *ww.surface);
    if Wl.wayland_send(*batch)  ww.wl_have_viewport = true;
    else                        ww.wl_viewport = .{};
}

// Crop the (possibly oversized) buffer down to the logical region and set the
// surface (logical) size. Simp renders the logical content into glViewport(0,0,
// log_w,log_h) — the GL bottom-LEFT of the capacity-sized FBO. wp_viewport.set_source
// coordinates are in the buffer space AFTER set_buffer_transform(FLIPPED_180), in
// which that content lands at the TOP-RIGHT: the transform's horizontal-flip
// component moves it to the right (src_x = cap_w - log_w), while vertically it maps
// to the top (src_y = 0). Confirmed empirically with grim (Task 4) at non-step,
// sub-output sizes where cap > logical in both dimensions.
wl_update_viewport_crop :: (ww: *Wayland_Window) {
    if !ww.wl_have_viewport  return;

    cap_w := ww.wl_slot_width;
    cap_h := ww.wl_slot_height;
    log_w := ww.width;
    log_h := ww.height;
    if log_w <= 0 || log_h <= 0 || cap_w <= 0 || cap_h <= 0  return;

    src_x := cap_w - log_w;
    src_y: s32 = 0;

    batch: Wl.MessageBuilder;
    Wl.wp_viewport_set_source(*batch, *ww.wl_viewport,
        wl_fixed_from_int(src_x), wl_fixed_from_int(src_y),
        wl_fixed_from_int(log_w), wl_fixed_from_int(log_h));
    Wl.wp_viewport_set_destination(*batch, *ww.wl_viewport, log_w, log_h);
    Wl.wayland_send(*batch);
}

// ─────────────────── Format / modifier selection ──────────────────────────
// (Ported from hello_gl.jai:433-504.)

// Prefers per-surface dmabuf feedback (filtered through GBM device capability)
// when available, falling back to the global format list.
wl_choose_dmabuf_format :: (gbm: Gbm.Gbm_Device, info: Wl.Dmabuf_Info, surface: *Wl.Wl_Surface) -> format: u32, modifier: u64, found: bool {
    flags := cast(u32) Gbm.GBM_BO_USE_RENDERING;
    preferred := u32.[ Gbm.GBM_FORMAT_ABGR8888, Gbm.GBM_FORMAT_XBGR8888 ];
    format: u32;
    modifier: u64;
    found: bool;

    if info.feedback_supported {
        feedback, feedback_ok := Wl.get_surface_dmabuf_feedback(*info.dmabuf, surface);
        if feedback_ok {
            for preferred_format: preferred {
                format, modifier, found = wl_pick_format_from_feedback_for_gbm(gbm, feedback, preferred_format, flags);
                if found {
                    log("Using dmabuf surface feedback for format selection");
                    return format, modifier, true;
                }
            }

            log("dmabuf surface feedback had no GBM-usable ABGR/XBGR format; falling back to global list");
        }
    }

    for preferred_format: preferred {
        format, modifier, found = wl_pick_global_format_for_gbm(gbm, info.supported, preferred_format, flags);
        if found {
            log("Using dmabuf global format list for format selection");
            return format, modifier, true;
        }
    }

    return 0, 0, false;
}

wl_pick_format_from_feedback_for_gbm :: (gbm: Gbm.Gbm_Device, feedback: Wl.Dmabuf_Feedback_Info, preferred_fourcc: u32, flags: u32) -> format: u32, modifier: u64, found: bool {
    if !feedback.complete  return 0, 0, false;

    for tranche: feedback.tranches {
        for fm: tranche.formats {
            if fm.format != preferred_fourcc  continue;
            if !Gpu.supports_bo_format_modifier(gbm, fm.format, fm.modifier, flags)  continue;
            return fm.format, fm.modifier, true;
        }
    }

    return 0, 0, false;
}

wl_pick_global_format_for_gbm :: (gbm: Gbm.Gbm_Device, supported: [] Wl.Format_Modifier, preferred_fourcc: u32, flags: u32) -> format: u32, modifier: u64, found: bool {
    format: u32;
    modifier: u64;
    found: bool;

    format, modifier, found = wl_pick_global_format_for_gbm_pass(gbm, supported, preferred_fourcc, flags, Wl.DRM_FORMAT_MOD_LINEAR, require_modifier = true);
    if found  return format, modifier, true;

    format, modifier, found = wl_pick_global_format_for_gbm_pass(gbm, supported, preferred_fourcc, flags, Wl.DRM_FORMAT_MOD_INVALID, require_modifier = true);
    if found  return format, modifier, true;

    format, modifier, found = wl_pick_global_format_for_gbm_pass(gbm, supported, preferred_fourcc, flags, 0, require_modifier = false);
    return format, modifier, found;
}

wl_pick_global_format_for_gbm_pass :: (gbm: Gbm.Gbm_Device, supported: [] Wl.Format_Modifier, preferred_fourcc: u32, flags: u32, wanted_modifier: u64, require_modifier: bool) -> format: u32, modifier: u64, found: bool {
    for fm: supported {
        if fm.format != preferred_fourcc  continue;
        if require_modifier && fm.modifier != wanted_modifier  continue;
        if !Gpu.supports_bo_format_modifier(gbm, fm.format, fm.modifier, flags)  continue;
        return fm.format, fm.modifier, true;
    }

    return 0, 0, false;
}

// ───────────────────────── Slot allocation ────────────────────────────────
// (Ported from hello_gl.jai:506-619.)

// Attach a depth renderbuffer to the currently-bound FBO. The BO-backed color
// texture has no depth; 3D apps (skeletal-animation) need depth testing. 2D apps
// (invaders, hello_simp) simply never enable GL_DEPTH_TEST, so this is harmless
// for them. The FBO must already be bound when this is called.
wl_attach_depth_rbo :: (slot: *Wl_Gl_Slot, width: s32, height: s32) {
    if glGenRenderbuffers == null  return;  // GL too old to provide renderbuffers
    glGenRenderbuffers(1, *slot.depth_rbo);
    glBindRenderbuffer(GL_RENDERBUFFER, slot.depth_rbo);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, cast(GLsizei) width, cast(GLsizei) height);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, slot.depth_rbo);
}

// Allocate a GL texture + FBO, export as DMA-BUF, wrap as wl_buffer. The
// wl_buffer + params messages get queued into `batch`; the caller sends when
// ready (so multiple slots can batch into a single send).
wl_slot_init :: (slot: *Wl_Gl_Slot, egl: Wl_Egl_State, dmabuf: *Wl.Zwp_Linux_Dmabuf_V1,
                 batch: *Wl.MessageBuilder, format: u32, modifier: u64, width: s32, height: s32,
                 backend: Wl_Gl_Backend = .AUTO, log_success := true) -> bool
{
    if backend == .MESA_TEXTURE_EXPORT
        return wl_slot_init_mesa(slot, egl, dmabuf, batch, format, modifier, width, height);

    if wl_slot_init_bo(slot, egl, dmabuf, batch, format, modifier, width, height) {
        if log_success {
            log("Initialized BO-backed slot buffer=% format=0x% modifier=0x%",
                slot.buffer.id,
                formatInt(slot.format, base=16),
                formatInt(slot.modifier, base=16));
        }
        return true;
    }

    if backend == .GBM_BO  return false;

    // AUTO: BO init failed, fall back to Mesa texture export.
    wl_slot_destroy(slot, egl);
    slot.* = .{};
    log("BO-backed slot initialization failed; falling back to Mesa texture export", flags=.WARNING);
    return wl_slot_init_mesa(slot, egl, dmabuf, batch, format, modifier, width, height);
}

wl_slot_init_bo :: (slot: *Wl_Gl_Slot, egl: Wl_Egl_State, dmabuf: *Wl.Zwp_Linux_Dmabuf_V1,
                    batch: *Wl.MessageBuilder, format: u32, modifier: u64, width: s32, height: s32) -> bool
{
    if Gbm.gbm_bo_create == null || Gbm.gbm_bo_destroy == null  return false;
    if glEGLImageTargetTexture2DOES == null  return false;

    flags := cast(u32) Gbm.GBM_BO_USE_RENDERING;
    if Gbm.gbm_device_is_format_supported != null {
        if Gbm.gbm_device_is_format_supported(egl.gbm, format, flags) == 0  return false;
    }

    slot.bo = Gpu.create_bo_with_modifier(egl.gbm, width, height, format, modifier, flags);
    if slot.bo == null  return false;

    image_ok: bool;
    slot.image, slot.image_fd, image_ok = Gpu.create_image_from_gbm_bo(egl.dpy, slot.bo, width, height);
    if !image_ok  return false;

    glGenTextures(1, *slot.tex);
    glBindTexture(GL_TEXTURE_2D, slot.tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, slot.image);

    glGenFramebuffers(1, *slot.fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, slot.fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
        GL_TEXTURE_2D, slot.tex, 0);
    wl_attach_depth_rbo(slot, width, height);  // depth buffer for 3D apps (skeletal-animation)
    if glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE  return false;

    if Gbm.gbm_bo_get_fd == null || Gbm.gbm_bo_get_stride == null  return false;
    fd := Gbm.gbm_bo_get_fd(slot.bo);
    if fd < 0  return false;

    slot.fd = fd;
    slot.stride = Gbm.gbm_bo_get_stride(slot.bo);
    slot.offset = ifx Gbm.gbm_bo_get_offset != null then Gbm.gbm_bo_get_offset(slot.bo, 0) else 0;
    planes := ifx Gbm.gbm_bo_get_plane_count != null then Gbm.gbm_bo_get_plane_count(slot.bo) else 1;
    if planes != 1  return false;

    actual_format := ifx Gbm.gbm_bo_get_format != null then Gbm.gbm_bo_get_format(slot.bo) else format;
    actual_modifier := ifx Gbm.gbm_bo_get_modifier != null then Gbm.gbm_bo_get_modifier(slot.bo) else modifier;

    slot.format = actual_format;
    slot.modifier = actual_modifier;
    slot.width = width;
    slot.height = height;
    slot.bo_backed = true;
    wl_slot_make_buffer(batch, dmabuf, *slot.buffer, slot.fd, slot.offset, slot.stride, actual_format, actual_modifier, width, height);
    return true;
}

wl_slot_init_mesa :: (slot: *Wl_Gl_Slot, egl: Wl_Egl_State, dmabuf: *Wl.Zwp_Linux_Dmabuf_V1,
                      batch: *Wl.MessageBuilder, format: u32, modifier: u64, width: s32, height: s32) -> bool
{
    glGenTextures(1, *slot.tex);
    glBindTexture(GL_TEXTURE_2D, slot.tex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, cast(GLsizei) width, cast(GLsizei) height, 0,
        GL_RGBA, GL_UNSIGNED_BYTE, null);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

    glGenFramebuffers(1, *slot.fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, slot.fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
        GL_TEXTURE_2D, slot.tex, 0);
    wl_attach_depth_rbo(slot, width, height);  // depth buffer for 3D apps (skeletal-animation)
    if glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE  return false;

    slot.image = EGL.eglCreateImageKHR(egl.dpy, egl.ctx, EGL.EGL_GL_TEXTURE_2D_KHR,
        cast(EGL.EGLClientBuffer) cast(u64) slot.tex, null);
    if !slot.image  return false;

    fd, stride, offset: s32;
    if EGL.eglExportDMABUFImageMESA(egl.dpy, slot.image, *fd, *stride, *offset) != EGL.EGL_TRUE  return false;
    slot.fd = fd;
    slot.stride = cast(u32) stride;
    slot.offset = cast(u32) offset;
    slot.format = format;
    slot.modifier = modifier;
    slot.width = width;
    slot.height = height;

    wl_slot_make_buffer(batch, dmabuf, *slot.buffer, fd, cast(u32) offset, cast(u32) stride, format, modifier, width, height);
    return true;
}

// Builds the zwp_linux_dmabuf_v1 params and creates the wl_buffer into `buffer`.
// (hello_gl.jai:621-641 queue_dmabuf_buffer.)
wl_slot_make_buffer :: (batch: *Wl.MessageBuilder, dmabuf: *Wl.Zwp_Linux_Dmabuf_V1, buffer: *Wl.Wl_Buffer,
                        fd: s32, offset: u32, stride: u32, format: u32, modifier: u64, width: s32, height: s32) {
    params := Wl.Zwp_Linux_Buffer_Params_V1.{ id = Wl.allocate_id() };
    Wl.zwp_linux_dmabuf_v1_create_params(batch, dmabuf, params.id);
    Wl.zwp_linux_buffer_params_v1_add(batch, *params,
        fd          = cast(Wl.Fd) fd,
        plane_idx   = 0,
        offset      = offset,
        stride      = stride,
        modifier_hi = cast(u32)(modifier >> 32),
        modifier_lo = cast(u32)(modifier & 0xFFFFFFFF));

    buffer.* = Wl.Wl_Buffer.{ id = Wl.allocate_id() };
    Wl.zwp_linux_buffer_params_v1_create_immed(batch, *params,
        new_id = buffer.id,
        width  = width,
        height = height,
        format = format,
        flags  = 0);
    Wl.zwp_linux_buffer_params_v1_destroy(batch, *params);
}

// ─────────────────────── Slot teardown / retire ───────────────────────────
// (Ported from hello_gl.jai:643-685.)

wl_slot_destroy :: (slot: *Wl_Gl_Slot, egl: Wl_Egl_State) {
    if slot.fbo != 0  glDeleteFramebuffers(1, *slot.fbo);
    if slot.depth_rbo != 0 && glDeleteRenderbuffers != null  glDeleteRenderbuffers(1, *slot.depth_rbo);
    if slot.tex != 0  glDeleteTextures(1, *slot.tex);
    if slot.image != null  EGL.eglDestroyImageKHR(egl.dpy, slot.image);
    if slot.bo != null  Gbm.gbm_bo_destroy(slot.bo);
    if slot.fd >= 0  close(slot.fd);
    if slot.image_fd >= 0  close(slot.image_fd);
    if slot.acquire_fence_fd >= 0  close(slot.acquire_fence_fd);
    if slot.release_fence_fd >= 0  close(slot.release_fence_fd);
}

// In-flight slots whose compositor-held buffer hasn't been released yet are moved
// to `retired` and destroyed later on their wl_buffer.release; the rest now.
wl_retire_slots :: (batch: *Wl.MessageBuilder, retired: *[..] Wl_Gl_Slot, slots: [] Wl_Gl_Slot, egl: Wl_Egl_State) {
    for * slot: slots {
        if slot.buffer.id == 0  continue;

        if slot.in_flight {
            array_add(retired, slot.*);
        } else {
            Wl.wl_buffer_destroy(batch, *slot.buffer);
            wl_slot_destroy(slot, egl);
        }

        slot.* = .{};
    }
}

// Matches a wl_buffer.release object_id against the retired list and tears down
// the slot. Returns true (and queues a wl_buffer.destroy into `batch`) if matched.
wl_release_retired_slot :: (batch: *Wl.MessageBuilder, retired: *[..] Wl_Gl_Slot, object_id: u32, egl: Wl_Egl_State) -> bool {
    for * slot, i: retired.* {
        if slot.buffer.id == object_id {
            Wl.wl_buffer_destroy(batch, *slot.buffer);
            wl_slot_destroy(slot, egl);
            array_unordered_remove_by_index(retired, i);
            return true;
        }
    }

    return false;
}

wl_find_free_slot :: (slots: [] Wl_Gl_Slot) -> int {
    for slots  if !it.in_flight  return it_index;
    return -1;
}

// ──────────────────────── Window registry ─────────────────────────────────

// The shared per-window record — the Wayland analogue of an entry in X11's
// x_global_windows. It bundles window identity (surface/xdg roles) with the
// per-window render state (BO slots, chosen dmabuf format, frame callbacks),
// because the single event pump must route wl_buffer.release, configure, close,
// and input events in one pass. The EGL/GBM display/context is module-global.
// Created by Window_Creation.create_window (register_wayland_window); the slot
// fields are filled in by Simp's wl_backend_init.
Wayland_Window :: struct {
    id          : u32;          // == surface.id; the window's identity key
    width       : s32;          // current size (source of truth; pump updates on configure)
    height      : s32;
    size_dirty  : bool;         // set by the pump when a configure CHANGES the size; consumers (Input) emit a resize event and clear it
    surface     : Wl.Wl_Surface;
    xdg_surface : Wl.Xdg_Surface;
    toplevel    : Wl.Xdg_Toplevel;

    // Per-window GPU render state — filled by Simp's wl_backend_init. The EGL
    // display/context + GBM device live in wl_shared_egl above.
    wl_slots:    [SIMP_WL_SLOT_COUNT] Wl_Gl_Slot;
    wl_current:  s32 = -1;                       // index of the slot currently being rendered
    wl_initted:  bool;
    wl_slot_width:  s32;                          // current BO/FBO allocation size
    wl_slot_height: s32;

    // Per-window dmabuf negotiation result, kept for slot (re)allocation.
    wl_dmabuf_info: Wl.Dmabuf_Info;              // bound zwp_linux_dmabuf_v1 + advertised formats
    wl_format:      u32;                         // chosen DRM fourcc
    wl_modifier:    u64;                         // chosen DRM modifier

    // wp_viewport crops the bucketed buffer to the logical surface size.
    wl_viewport:      Wl.Wp_Viewport;
    wl_have_viewport: bool;

    // Frame-callback id recycler. cache_alloc per present, cache_free after
    // wl_pump(true) returns — keeps the client-id stream contiguous.
    wl_frame_cache: Wl.Id_Cache;

    // Slots from a prior resize whose buffers the compositor still holds; their
    // wl_buffer.release is matched inside wl_pump.
    wl_retired:     [..] Wl_Gl_Slot;

    // Set by the pump on xdg_toplevel.close. Read by Simp.window_should_close
    // (and, once wired, by Input to emit .QUIT).
    wl_close_requested: bool;

    // Vsync pacing for the asynchronous present. wl_pending_frame_callback is the
    // id of the in-flight wl_surface.frame callback (the PREVIOUS frame's); the
    // pump sets wl_frame_done when its wl_callback.done arrives. wl_present_and_pace
    // throttles on the PREVIOUS callback (already fired for a CPU-bound app → no
    // wait; not yet for a fast app → capped to vsync). See
    // docs/plans/2026-05-31-wayland-async-present.md.
    wl_pending_frame_callback: u32;
    wl_frame_done: bool;

    // Set when a present timed out waiting for this window's frame callback —
    // i.e. the compositor is not presenting this surface (occluded: a hidden tab
    // in a Hyprland group, minimized, or on another workspace), so it sends no
    // wl_surface.frame callbacks. While starved, wl_present_and_pace does not
    // block on this window's callback, so a VISIBLE sibling keeps full vsync
    // pacing. Cleared by the pump the instant a callback returns (the surface is
    // being presented again). See wl_present_and_pace.
    wl_pacing_starved: bool;
}

// THE shared global window registry — one instance across Simp/Input/GetRect
// (name-based import dedup). The X11 mirror of x_global_windows.
wayland_global_windows: [..] Wayland_Window;

// Look up a window record by its wl_surface id (the identity carried in
// Window_Type.Wayland_Window_State.surface). Returns a pointer INTO the registry
// array — valid only while nothing array_adds another window (single-window in
// the current draft; multi-window must revisit pointer stability).
find_wayland_window :: (surface_id: u32) -> *Wayland_Window {
    for * wayland_global_windows  if it.surface.id == surface_id  return it;
    return null;
}

// Registration side effect of Window_Creation.create_window — the mirror of
// X11's `array_add(*x_global_windows, win)`. Records window identity + initial
// size; the GPU fields stay zero until Simp's wl_backend_init fills them.
register_wayland_window :: (surface_id: u32, xdg_surface_id: u32, toplevel_id: u32, width: s32, height: s32) -> *Wayland_Window {
    ww := array_add(*wayland_global_windows);  // appends a zeroed element, returns a pointer to it
    ww.* = .{
        id          = surface_id,
        width       = width,
        height      = height,
        surface     = .{ id = surface_id },
        xdg_surface = .{ id = xdg_surface_id },
        toplevel    = .{ id = toplevel_id },
    };
    return ww;
}

wl_note_configure_size :: (ww: *Wayland_Window, width: s32, height: s32) -> bool {
    if width <= 0 || height <= 0  return false;

    changed := width != ww.width || height != ww.height;
    if changed {
        ww.width = width;
        ww.height = height;
        ww.size_dirty = true;
    }
    return changed;
}

// Used by Window_Creation while it is synchronously waiting for a newly-created
// window's first configure. A compositor may reconfigure already-registered
// windows during that wait (multiple_windows does this when the second window is
// tiled). Those events still belong to the shared Wayland state and must not be
// consumed by the creation loop and dropped.
wl_route_registered_window_control_event :: (header: Wl.WaylandMessageHeader, recv: *Wl.ReceiveBuffer) -> bool {
    for * ww: wayland_global_windows {
        if header.object_id == ww.xdg_surface.id && header.opcode == Wl.XDG_SURFACE_CONFIGURE {
            serial := Wl.read_u32(header.payload);
            ack_batch: Wl.MessageBuilder;
            Wl.xdg_surface_ack_configure(*ack_batch, *ww.xdg_surface, serial);
            Wl.wayland_send(*ack_batch);
            return true;
        }
        if header.object_id == ww.toplevel.id && header.opcode == Wl.XDG_TOPLEVEL_CONFIGURE {
            args: Wl.Xdg_Toplevel_Configure_Args;
            Wl.unmarshal(*args, header.payload, recv);
            wl_note_configure_size(ww, args.width, args.height);
            return true;
        }
        if header.object_id == ww.toplevel.id && header.opcode == Wl.XDG_TOPLEVEL_CLOSE {
            ww.wl_close_requested = true;
            return true;
        }
    }

    return false;
}

wl_any_window_needs_app_turn :: () -> bool {
    for wayland_global_windows  if it.size_dirty || it.wl_close_requested  return true;
    return false;
}

// ─────────────────────────── Present + pace ───────────────────────────────

// Upper bound on how long a present waits for a window's frame callback before
// concluding the compositor is not presenting that surface. Must be >= one
// display refresh so a VISIBLE window still paces to vsync (its callback arrives
// well inside this); 50 ms (≈ 3-4 refreshes) leaves slack for a momentarily
// janky-but-visible window without false-flagging it as occluded.
PRESENT_PACE_TIMEOUT_MS :: 50;

// Block up to timeout_ms for compositor data, then route whatever arrived
// (non-blocking). Unlike wl_pump(true) this NEVER blocks past the timeout:
// wl_pump(true) loops back into a blocking recvmsg whenever its buffer drains,
// so it can't bound a wait. Here we poll the fd, then do a single recvmsg +
// non-blocking drain only when data is actually ready. timeout_ms == 0 is a
// non-blocking poll; we never pass -1 (that would block forever).
wl_pump_timed :: (timeout_ms: s32) {
    sess := context.wayland_session;
    if !sess || sess.connection_lost  return;

    // Already-buffered data: route it without polling.
    msg, _ := Wl.receive_peek_message(*sess.recv);
    if msg != null {
        wl_pump(false);
        return;
    }

    pfd: pollfd;
    pfd.fd     = sess.conn.socket_fd;
    pfd.events = POLLIN;
    n := poll(*pfd, xx 1, timeout_ms);
    if n <= 0  return;   // 0 = timed out, <0 = EINTR/error
    if (pfd.revents & POLLIN) != 0 {
        bts := Wl.wayland_receive(*sess.conn, *sess.recv);
        if bts <= 0 { sess.connection_lost = true; return; }
        wl_pump(false);
    }
}

// True when EVERY registered window is starved — i.e. the whole app is occluded.
// In that case present keeps the full timeout (rather than the starved fast-path)
// so the render loop idles instead of busy-spinning the GPU on invisible frames.
wl_all_windows_starved :: () -> bool {
    if wayland_global_windows.count == 0  return false;
    for wayland_global_windows  if !it.wl_pacing_starved  return false;
    return true;
}

// Simp's present entry point. Attach the current slot, request a frame callback,
// commit, then wait (BOUNDED) for the previous frame's callback — vsync-equivalent
// pacing that degrades gracefully for occluded windows (see the wait below). This
// mirrors the blocking, vsync-locked buffer swap Simp inherits from the platform
// default on Windows/macOS/Android (SwapBuffers / flushBuffer / eglSwapBuffers);
// it is the only Wayland presentation policy, matching upstream Simp's contract.
// The caller (Simp's swap) does the glFinish before and the FBO rebind after.
// Ported from hello_gl.jai's steady-state present + the SWAP_BUFFERS path.
wl_present_and_pace :: (ww: *Wayland_Window) {
    if ww.wl_current < 0  return;

    // VSYNC PACING on the PREVIOUS frame's callback. The old path requested a
    // frame callback, committed, then blocked on THIS frame's callback — waiting
    // up to a full vsync for the compositor to present what we just sent (~3.3 ms
    // even for a slow app: the entire perceptible Wayland-vs-X11 gap). Instead we
    // block here on the PREVIOUS frame's callback, before committing the next:
    //   * CPU-bound app (GetRect ~28.5 ms/frame > 13.3 ms vsync): the prior
    //     callback already fired during this frame's render → no wait, no latency.
    //   * Fast app (faster than vsync): blocks until the compositor consumed the
    //     prior frame → capped to vsync, no uncapped GPU burn.
    // This is exactly GLX's triple-buffered swap behaviour. See
    // docs/plans/2026-05-31-wayland-async-present.md.
    if ww.wl_pending_frame_callback != 0 {
        pending_frame_callback := ww.wl_pending_frame_callback;

        // BOUNDED vsync wait. A surface the compositor is not presenting (an
        // occluded window: a hidden tab in a Hyprland group, minimized, or on
        // another workspace) receives NO wl_surface.frame callbacks, so an
        // unbounded wait here would stall this whole single-threaded render loop
        // on that one window — freezing every other (visible) window with it.
        //
        // Wait at most PRESENT_PACE_TIMEOUT_MS for the callback; on timeout, flag
        // the window starved and stop pacing it (it is invisible — we owe it no
        // vsync). A starved window then skips the wait (timeout 0) so a VISIBLE
        // sibling keeps full vsync smoothness — UNLESS every window is starved
        // (the whole app is occluded), where we keep the full timeout so the loop
        // idles rather than busy-spinning the GPU on invisible frames. The pump
        // clears wl_pacing_starved the instant a callback returns, so normal
        // pacing resumes as soon as the window is presented again.
        timeout_ms: s32 = PRESENT_PACE_TIMEOUT_MS;
        if ww.wl_pacing_starved && !wl_all_windows_starved()  timeout_ms = 0;
        deadline := seconds_since_init() + (cast(float64) timeout_ms) / 1000.0;

        while !ww.wl_frame_done {
            sess := context.wayland_session;
            if !sess || sess.connection_lost  break;
            if wl_any_window_needs_app_turn()  break;

            remaining := cast(s32)((deadline - seconds_since_init()) * 1000.0);
            if remaining < 0  remaining = 0;
            wl_pump_timed(remaining);
            if ww.wl_frame_done  break;
            if remaining <= 0  break;   // deadline reached (or starved fast-path: timeout 0)
        }

        if ww.wl_frame_done {
            Wl.cache_free(*ww.wl_frame_cache, pending_frame_callback);
            ww.wl_pacing_starved = false;
        } else {
            // No callback within the budget → the surface isn't being presented.
            // Leave the id unrecycled (it may still be live server-side, like the
            // app-turn yield) and mark starved so subsequent frames don't block.
            ww.wl_pacing_starved = true;
        }
        ww.wl_pending_frame_callback = 0;
        ww.wl_frame_done = false;
    }

    if wl_any_window_needs_app_turn() {
        // A configure/close arrived while pacing the previous frame. Return to
        // the app without committing another stale-size buffer; Input will emit
        // resize/quit on the next frame. If the old callback later arrives, its
        // id is intentionally not recycled because it may still be live server-side.
        ww.wl_pending_frame_callback = 0;
        ww.wl_frame_done = false;
        return;
    }

    slot := *ww.wl_slots[ww.wl_current];
    batch: Wl.MessageBuilder;
    frame_callback_id := Wl.cache_alloc(*ww.wl_frame_cache);
    ww.wl_pending_frame_callback = frame_callback_id;
    ww.wl_frame_done = false;
    Wl.wl_surface_frame(*batch, *ww.surface, frame_callback_id);
    Wl.wl_surface_attach(*batch, *ww.surface, *slot.buffer, 0, 0);
    Wl.wl_surface_damage_buffer(*batch, *ww.surface, 0, 0, slot.width, slot.height);
    Wl.wl_surface_commit(*batch, *ww.surface);
    Wl.wayland_send(*batch);
    slot.in_flight = true;

    // Rotate to a free slot for the next render. With 3 slots + vsync pacing the
    // N-2 slot is already released, so a free slot is normally available after a
    // non-blocking drain. Block only as a safety fallback if every slot is somehow
    // still in flight (buffer-release sets `done`). A slot is reused only after its
    // release, so we never overwrite an in-flight buffer (tear-safe); Simp's swap
    // glFinish already guaranteed the GPU finished before commit.
    wl_pump(false);
    nxt := wl_find_free_slot(ww.wl_slots);
    while nxt < 0 {
        sess := context.wayland_session;
        if !sess || sess.connection_lost  break;
        wl_pump(true);
        nxt = wl_find_free_slot(ww.wl_slots);
    }
    if nxt >= 0  ww.wl_current = cast(s32) nxt;
}

// ─────────────────── Per-window GL bring-up / ops ─────────────────────────
// These hold the Wayland GL backend work so the Simp dispatch glue
// (modules/Simp/backend/wayland_dispatch.jai) stays a thin display_manager
// branch. EGL/GBM/context state is shared module-wide; each Wayland_Window owns
// only its surface roles, chosen dmabuf format, slots, and frame state. (Old
// simp_wayland_dispatch BACKEND_INIT / RESIZE / SET bodies, retargeted off
// info.specific onto *Wayland_Window.)

// Bring up EGL-on-GBM, negotiate a dmabuf format, allocate the double-buffered
// slots at the window's current size. Leaves wl_initted=true on success.
wl_window_init_gl :: (ww: *Wayland_Window) -> bool {
    if !wl_ensure_shared_egl() {
        log_error("Wayland_Support: EGL/GBM init failed");
        return false;
    }
    if !wl_make_current()  return false;

    dmabuf_info, dmabuf_ok := Wl.get_dmabuf_info();
    if !dmabuf_ok {
        log_error("Wayland_Support: compositor does not advertise zwp_linux_dmabuf_v1");
        return false;
    }
    ww.wl_dmabuf_info = dmabuf_info;

    format, modifier, have_format := wl_choose_dmabuf_format(wl_shared_egl.gbm, ww.wl_dmabuf_info, *ww.surface);
    if !have_format {
        log_error("Wayland_Support: no GBM-usable ABGR/XBGR 8888 dmabuf format advertised");
        return false;
    }
    ww.wl_format   = format;
    ww.wl_modifier = modifier;
    log("Wayland_Support: using format=0x% modifier=0x%",
        formatInt(format, base=16), formatInt(modifier, base=16));

    // Decide the slot allocation capacity. With wp_viewporter we allocate at the
    // bucketed (grow-only) capacity and present only the logical sub-rect via the
    // viewport crop; without it we fall back to allocating at the exact logical size.
    cap_w := ww.width;
    cap_h := ww.height;
    wl_window_init_viewport(ww);
    if ww.wl_have_viewport  cap_w, cap_h = wl_target_capacity(ww.width, ww.height, 0, 0);

    backend := wl_choose_gl_backend();
    batch: Wl.MessageBuilder;
    for * slot, i: ww.wl_slots {
        if !wl_slot_init(slot, wl_shared_egl, *ww.wl_dmabuf_info.dmabuf, *batch,
                         ww.wl_format, ww.wl_modifier, cap_w, cap_h, backend) {
            // An earlier slot's batched create messages are abandoned unsent, yet
            // allocate_id() advanced next_id — a hole in the contiguous client-ID
            // stream. Tolerable only because we leave wl_initted=false, so SWAP /
            // SET no-op via their guards and the window is dead.
            log_error("Wayland_Support: failed to initialize slot %", i);
            return false;
        }
    }
    // GL renders into the FBO with row 0 at the BOTTOM (OpenGL convention); the
    // dma-buf is then scanned out top-down, so every frame would appear vertically
    // FLIPPED versus what the same draw calls produce on X11's default framebuffer.
    // Tell the compositor the buffer carries a FLIPPED_180 transform (a vertical
    // flip) so it presents upright. This is a presentation-layer fix — it needs no
    // change to any app's projection/coordinate system. Surface state, set once
    // here; it persists across resizes and applies at the first present's commit.
    Wl.wl_surface_set_buffer_transform(*batch, *ww.surface, cast(s32) Wl.Wl_Output_Transform.FLIPPED_180);
    Wl.wayland_send(*batch);

    ww.wl_current = 0;
    ww.wl_slot_width  = cap_w;
    ww.wl_slot_height = cap_h;
    ww.wl_initted = true;
    wl_update_viewport_crop(ww);
    return true;
}

// Retire current slots (compositor may still hold an in-flight buffer) and
// reallocate all of them at (w, h), reusing the negotiated format/modifier.
// Sets wl_current=0 and wl_slot_width/height. Returns true on success; on failure
// disables the window (wl_initted=false) and returns false.
wl_realloc_slots :: (ww: *Wayland_Window, w: s32, h: s32) -> bool {
    if !wl_make_current()  return false;

    retire_batch: Wl.MessageBuilder;
    wl_retire_slots(*retire_batch, *ww.wl_retired, ww.wl_slots, wl_shared_egl);
    Wl.wayland_send(*retire_batch);

    backend := wl_choose_gl_backend();
    alloc_batch: Wl.MessageBuilder;
    for * slot, i: ww.wl_slots {
        if !wl_slot_init(slot, wl_shared_egl, *ww.wl_dmabuf_info.dmabuf, *alloc_batch,
                         ww.wl_format, ww.wl_modifier, w, h, backend) {
            log_error("Wayland_Support: slot % realloc failed (%x%) — window disabled", i, w, h);
            ww.wl_initted = false;
            return false;
        }
    }
    Wl.wayland_send(*alloc_batch);
    ww.wl_current = 0;
    ww.wl_slot_width  = w;
    ww.wl_slot_height = h;
    return true;
}

// Resize the window's render slots to the new LOGICAL size (new_w, new_h).
//
// With wp_viewporter (ww.wl_have_viewport): slot allocation is bucketed and
// grow-only — we reallocate only when the bucketed target capacity must grow past
// the current capacity, and otherwise just re-crop the existing oversized buffers
// to the new logical region via wp_viewport. Returns true only when slots were
// actually reallocated (caller rebinds the FBO); a crop-only update returns false.
//
// Without viewporter: falls back to the exact pre-bucketing behavior — capacity ==
// logical, realloc on any size change, no crop. Returns true if it reallocated,
// false on a no-op (size unchanged); on failure the window is disabled
// (wl_initted=false) and it returns false. (BACKEND_RESIZE body.)
// new_w/new_h are the new LOGICAL size; the pump (ww.width/height) is the source
// of truth for logical size and is expected to already equal them by the time
// Simp dispatches this (wl_update_viewport_crop reads logical from ww.width/height).
wl_window_resize_gl :: (ww: *Wayland_Window, new_w: s32, new_h: s32) -> bool {
    if !ww.wl_have_viewport {
        // No-viewporter fallback: buffer size == logical size; realloc on any change.
        if ww.wl_slot_width == new_w && ww.wl_slot_height == new_h  return false;
        return wl_realloc_slots(ww, new_w, new_h);
    }

    // Bucketed path: grow-only capacity, crop to the logical region.
    target_w, target_h := wl_target_capacity(new_w, new_h, ww.wl_slot_width, ww.wl_slot_height);

    realloc := false;
    if target_w > ww.wl_slot_width || target_h > ww.wl_slot_height {
        if !wl_realloc_slots(ww, target_w, target_h)  return false;
        realloc = true;
    }

    wl_update_viewport_crop(ww);  // logical may have changed even with no realloc
    return realloc;
}

// ──────────────────────────── Input (keyboard) ────────────────────────────
// The shared input globals — the Wayland analogue of X11's x_global_input_*.
// Acquisition is triggered by a consumer (Input's init, or hello_simp) via
// wl_acquire_input; the objects live HERE so the single pump can decode against
// them. The pump turns raw wl_keyboard events into stable Wl_Input_Events and
// appends them to provisional_input_events; consumers drain that buffer each
// frame, translate to their own model (Input -> events_this_frame), then call
// wl_clear_input_events.

Wl_Input_Event_Kind :: enum u8 {
    KEY;
    MODIFIERS;
    POINTER_ENTER;
    POINTER_MOTION;
    POINTER_BUTTON;
    POINTER_AXIS;
    TOUCH_DOWN;
    TOUCH_UP;
    TOUCH_MOTION;
    DRAG_DROP;
}

Wl_Key_Event :: struct {
    keycode: u32;   // evdev keycode (wl_keyboard.key)
    keysym:  u32;   // resolved through the keymap (xkb keysym == X11 keysym numbering)
    pressed: bool;  // true = press, false = release
    serial:  u32;
    time:    u32;
}

Wl_Modifiers_Event :: struct {
    mods_depressed: u32;
    mods_latched:   u32;
    mods_locked:    u32;
    group:          u32;
}

Wl_Pointer_Pos_Event :: struct {  // ENTER + MOTION: surface-local pointer position
    x: float;
    y: float;
}

Wl_Pointer_Btn_Event :: struct {
    button:  u32;   // Linux evdev button code (BTN_LEFT=0x110, BTN_RIGHT=0x111, BTN_MIDDLE=0x112, …)
    pressed: bool;
}

Wl_Pointer_Axis_Event :: struct {
    axis:  u32;     // Wl_Pointer_Axis: 0 = vertical scroll, 1 = horizontal scroll
    value: float;   // scroll amount (Wayland convention: positive = down/right)
}

Wl_Touch_Point_Event :: struct {
    id: s32;        // touch-point id (a finger) -> touch_index
    x:  float;      // surface-local position (0 on UP)
    y:  float;
}

Wl_Drag_Drop_Event :: struct {
    uri_list: string;  // raw text/uri-list transfer, heap-allocated by the pump; the consumer parses it (into Event.files) and frees it
    x:        float;   // surface-local drop position
    y:        float;
}

// A decoded, consumer-agnostic input event of our own making (the "stable event"
// the repackaging vision calls for): Wayland semantics (keysym + evdev codes),
// each consumer maps it to its own model.
Wl_Input_Event :: union kind: Wl_Input_Event_Kind {
    .KEY            ,, key:            Wl_Key_Event;
    .MODIFIERS      ,, modifiers:      Wl_Modifiers_Event;
    .POINTER_ENTER  ,, pointer_enter:  Wl_Pointer_Pos_Event;
    .POINTER_MOTION ,, pointer_motion: Wl_Pointer_Pos_Event;
    .POINTER_BUTTON ,, pointer_button: Wl_Pointer_Btn_Event;
    .POINTER_AXIS   ,, pointer_axis:   Wl_Pointer_Axis_Event;
    .TOUCH_DOWN     ,, touch_down:     Wl_Touch_Point_Event;
    .TOUCH_UP       ,, touch_up:       Wl_Touch_Point_Event;
    .TOUCH_MOTION   ,, touch_motion:   Wl_Touch_Point_Event;
    .DRAG_DROP      ,, drag_drop:      Wl_Drag_Drop_Event;
}

wl_keyboards:      [] Wl.Keyboard_Info;   // acquired keyboards; the pump matches object ids against these
wl_keymap:         Wl.Keymap;
wl_keymap_valid:   bool;
wl_input_acquired: bool;

// Current keyboard modifier state, tracked from wl_keyboard.modifiers. Used for
// shift-level keysym resolution (Shift -> level 1; Caps Lock inverts for letters).
wl_mods_depressed: u32;
wl_mods_latched:   u32;
wl_mods_locked:    u32;

// Key autorepeat. Wayland delivers NO repeat events — the client synthesizes
// them from wl_keyboard.repeat_info (rate = keys/sec, delay = ms before repeat).
// We remember the held repeatable key and the Input backend replays it each
// frame (wl_repeats_due). Defaults cover pre-v4 keyboards that never send
// repeat_info. rate == 0 means the user disabled repeat — honour it.
WL_REPEAT_MAX_PER_FRAME :: 6;   // cap a post-stall burst (e.g. after a long frame)
wl_repeat_rate:       s32 = 25;
wl_repeat_delay:      s32 = 600;
wl_repeat_key_valid:  bool;
wl_repeat_key:        Wl_Key_Event;
wl_repeat_press_time: float64;
wl_repeat_count:      int;

wl_pointers:         [] Wl.Pointer_Info;  // acquired pointers; the pump matches object ids against these
wl_touches:          [] Wl.Touch_Info;    // acquired touch devices (machine-dependent; usually none on desktop)
wl_mouse_x:          float;               // current surface-local pointer position (for get_mouse_pointer_position)
wl_mouse_y:          float;
wl_keyboard_focused: bool;                // wl_keyboard.enter/leave -> input_application_has_focus

// ─────────────────────────── Drag-and-drop ────────────────────────────────
// The destination half of wl_data_device DnD. We acquire a wl_data_device per
// seat (in wl_acquire_input, beside keyboards/pointers); the single pump decodes
// a drag session — data_offer → enter → motion* → drop. On drop we pull the
// text/uri-list transfer across an SCM_RIGHTS pipe fd and emit a DRAG_DROP
// Wl_Input_Event, which the Input backend turns into Event.DRAG_AND_DROP_FILES
// (the X11 parity path). Acceptance is gated on the app having opted in via
// X11.enable_drag_and_drop (WT.wayland_drag_and_drop_requested) — we acquire the
// device regardless, but decline drops until opt-in, matching the X11 backend
// where a window is a drop target only after that call.

WL_DND_MIME :: "text/uri-list";  // the only transfer type we negotiate (file drops)

wl_data_devices:        [] Wl.Data_Device_Info;    // one per seat; the pump matches object ids against these
wl_data_device_manager: Wl.Wl_Data_Device_Manager;
wl_dnd_version:         u32;                        // negotiated wl_data_device_manager version (finish() requires v3+)

// data_offers the compositor has introduced (data_offer event) but we have not
// yet consumed. A drag AND a clipboard selection each create their own offer, so
// we keep a small set and reap on leave/drop/selection — none leak.
Wl_Dnd_Offer :: struct {
    id:           u32;
    has_uri_list: bool;    // saw text/uri-list among this offer's advertised mime types (drag-and-drop)
    text_mime:    string;  // best clipboard text mime this offer advertises ("" = none); a static WL_CLIPBOARD_TEXT_MIMES entry
}
wl_dnd_offers: [..] Wl_Dnd_Offer;

// Active drag session (between enter and drop/leave). 0 = no drag in progress.
wl_dnd_active_offer: u32;
wl_dnd_enter_serial: u32;
wl_dnd_x: float;
wl_dnd_y: float;

// ─────────────────────────── Clipboard (selection) ────────────────────────
// Copy/paste over the same wl_data_device, sharing the offer machinery above.
// PASTE reads the current selection's wl_data_offer (kept alive, unlike a drag
// offer, which is consumed on drop). COPY creates a wl_data_source we own and
// serves its wl_data_source.send requests. When we own the selection we return
// our own buffer directly rather than receiving from our own offer (which would
// deadlock — serving the receive needs the pump we'd be blocking) — the same
// trick X11's Clipboard module uses via x_window_is_ours.

WL_CLIPBOARD_TEXT_MIMES :: string.[
    "text/plain;charset=utf-8",
    "text/plain",
    "UTF8_STRING",
    "STRING",
    "TEXT",
];

wl_clipboard_selection_offer: u32;     // current selection's wl_data_offer id, kept alive (0 = none)
wl_clipboard_source:          u32;     // our wl_data_source id when WE own the selection (0 = we don't)
wl_clipboard_source_text:     string;  // heap copy of what we put on the clipboard, served on .send
wl_last_input_serial:         u32;     // most recent key/button serial — set_selection needs one

// The pump fills this; consumers drain + clear it each frame. It naturally stays
// empty for render-only apps: Wayland only delivers key events to keyboards you
// have bound, and binding only happens in wl_acquire_input — so no acquisition
// means no events to buffer (no leak, no gate needed).
provisional_input_events: [..] Wl_Input_Event;

// Bind the seats' keyboards and parse the keymap. MUST be called before the
// render loop's first pump: get_seats_info / get_keyboards_info do their own sync
// roundtrips (via for_expansion), which would otherwise consume in-flight render
// events. Idempotent.
wl_acquire_input :: () {
    if wl_input_acquired  return;
    wl_input_acquired = true;

    seats := Wl.get_seats_info();
    wl_keyboards = Wl.get_keyboards_info(seats);
    wl_pointers  = Wl.get_pointers_info(seats);
    wl_touches   = Wl.get_touch_info(seats);
    if wl_keyboards.count > 0 {
        kb := wl_keyboards[0];
        keymap, ok := Wl.parse_keymap_fd(kb.keymap_fd, kb.keymap_size);
        if ok  { wl_keymap = keymap; wl_keymap_valid = true; }
        else     log("Wayland_Support: keymap parse failed; keysyms unavailable", flags=.WARNING);
        close(cast(s32) kb.keymap_fd);  // parse_keymap_fd mmaps a private copy; it does NOT own the fd
    }

    // Acquire the data device unconditionally (cheap) so it's ready before any
    // drag, regardless of whether enable_drag_and_drop ran first; the manager
    // version gates finish() (a v3 request) in the drop path. The same device
    // carries clipboard selection events.
    wl_data_devices, wl_data_device_manager = Wl.get_data_devices_info(seats);
    if wl_data_device_manager.id != 0 {
        g, ok := Wl.get_global("wl_data_device_manager");
        if ok  wl_dnd_version = ifx g.version < 3 then g.version else 3;
    }

    // Serving the clipboard (wl_data_source.send) writes to a pipe whose reader
    // may close early; without this, that write raises SIGPIPE and kills the
    // process. Ignore it process-wide — the write loop handles EPIPE instead.
    signal(SIGPIPE, SIG_IGN);

    log("Wayland_Support: acquired % keyboard(s), % pointer(s), % touch, % data device(s)",
        wl_keyboards.count, wl_pointers.count, wl_touches.count, wl_data_devices.count);
}

// Drop the events a consumer has finished processing (keeps array capacity).
wl_clear_input_events :: () {
    provisional_input_events.count = 0;
}

wl_key_trace_checked: bool;
wl_key_trace_enabled: bool;

wl_should_log_keys :: () -> bool {
    if !wl_key_trace_checked {
        p := getenv("JAI_WAYLAND_LOG_KEYS");
        if p {
            v := to_string(p);
            wl_key_trace_enabled = v.count > 0 && v[0] != #char "0";
        }
        wl_key_trace_checked = true;
    }
    return wl_key_trace_enabled;
}

// Decode one wl_keyboard event into a stable Wl_Input_Event (or update keymap
// state). Called by the pump for messages matching an acquired keyboard.
wl_handle_keyboard_event :: (kev: Wl.Wl_Keyboard_Event) {
    if kev.kind == {
        case .KEY;
            wl_last_input_serial = kev.key.serial;  // freshest serial for set_selection (clipboard copy)
            // Resolve the keysym at the modifier-aware shift level: Shift (held or
            // latched) selects level 1; Caps Lock inverts that for alphabetic keys.
            // Covers the common xkb ALPHABETIC / TWO_LEVEL / ONE_LEVEL key types;
            // AltGr / level-3 layouts are a future refinement.
            keysym: u32 = 0;
            base:   u32 = 0;
            level:  u32 = 0;
            shift := false;
            caps  := false;
            if wl_keymap_valid {
                shift      = ((wl_mods_depressed | wl_mods_latched) & 0x01) != 0;  // ShiftMask
                caps       = (wl_mods_locked & 0x02) != 0;                         // LockMask (Caps)
                base       = Wl.keymap_get_keysym(*wl_keymap, kev.key.key, 0);
                is_letter := base >= #char "a" && base <= #char "z";
                use_shift := shift != (caps && is_letter);                         // XOR: caps flips shift for letters
                level = cast(u32)(ifx use_shift then 1 else 0);
                keysym = Wl.keymap_get_keysym(*wl_keymap, kev.key.key, level);
                // Keys with only one level (modifiers, F-keys, …) have no level-1
                // keysym; if the shifted level is empty, fall back to level 0 so the
                // physical key still resolves. This is what made Shift fail to
                // register: when the modifiers event marking Shift active arrives
                // BEFORE the Shift key-press, we'd pick level 1 for Shift_L (which has
                // no level-1 keysym) -> 0 -> UNKNOWN instead of SHIFT.
                if keysym == 0 && level != 0  keysym = Wl.keymap_get_keysym(*wl_keymap, kev.key.key, 0);
            }
            key_event := Wl_Key_Event.{
                keycode = kev.key.key,
                keysym  = keysym,
                pressed = kev.key.state == cast(u32) Wl.Wl_Keyboard_Key_State.PRESSED,
                serial  = kev.key.serial,
                time    = kev.key.time,
            };
            if wl_should_log_keys() {
                log("WL_KEY raw key=% state=% keysym=0x% base=0x% level=% shift=% caps=% mods depressed=0x% latched=0x% locked=0x% serial=% time=%",
                    key_event.keycode,
                    ifx key_event.pressed then "pressed" else "released",
                    formatInt(key_event.keysym, base=16),
                    formatInt(base, base=16),
                    level,
                    shift,
                    caps,
                    formatInt(wl_mods_depressed, base=16),
                    formatInt(wl_mods_latched, base=16),
                    formatInt(wl_mods_locked, base=16),
                    key_event.serial,
                    key_event.time);
            }
            array_add(*provisional_input_events, .{ kind = .KEY, key = key_event });
            wl_update_repeat_state(key_event);
        case .MODIFIERS;
            // Track for shift-level keysym resolution (above) AND forward to consumers.
            wl_mods_depressed = kev.modifiers.mods_depressed;
            wl_mods_latched   = kev.modifiers.mods_latched;
            wl_mods_locked    = kev.modifiers.mods_locked;
            if wl_should_log_keys() {
                log("WL_MODIFIERS depressed=0x% latched=0x% locked=0x% group=%",
                    formatInt(wl_mods_depressed, base=16),
                    formatInt(wl_mods_latched, base=16),
                    formatInt(wl_mods_locked, base=16),
                    kev.modifiers.group);
            }
            array_add(*provisional_input_events, .{
                kind = .MODIFIERS,
                modifiers = .{
                    mods_depressed = kev.modifiers.mods_depressed,
                    mods_latched   = kev.modifiers.mods_latched,
                    mods_locked    = kev.modifiers.mods_locked,
                    group          = kev.modifiers.group,
                },
            });
        case .KEYMAP;
            // Layout change mid-session: re-parse, then release the fresh fd.
            keymap, ok := Wl.parse_keymap_fd(kev.keymap.fd, kev.keymap.size);
            if ok  { wl_keymap = keymap; wl_keymap_valid = true; }
            if wl_should_log_keys()  log("WL_KEYMAP fd=% size=% ok=%", kev.keymap.fd, kev.keymap.size, ok);
            close(cast(s32) kev.keymap.fd);
        case .ENTER;  wl_keyboard_focused = true;   // keyboard focus -> input_application_has_focus
        case .LEAVE;
            wl_keyboard_focused = false;
            wl_repeat_key_valid = false;            // stop repeating a held key when focus leaves
        case .REPEAT_INFO;
            wl_repeat_rate  = kev.repeat_info.rate;   // keys/sec (0 disables repeat)
            wl_repeat_delay = kev.repeat_info.delay;  // ms before repeat starts
        case;
            // (no other wl_keyboard events)
    }
}

// True for the standard modifier keysyms (Shift/Control/Caps/Meta/Alt/Super/Hyper,
// left+right) — these must NOT autorepeat and must not disturb the held key.
wl_keysym_is_modifier :: (keysym: u32) -> bool {
    return keysym >= 0xffe1 && keysym <= 0xffee;
}

// Track the currently-held repeatable key for autorepeat. A press of a non-modifier
// key becomes the repeat key (replacing any prior); releasing it stops repeat.
wl_update_repeat_state :: (key_event: Wl_Key_Event) {
    if key_event.pressed {
        if wl_keysym_is_modifier(key_event.keysym)  return;  // modifiers don't repeat / don't take over
        wl_repeat_key_valid  = true;
        wl_repeat_key        = key_event;
        wl_repeat_press_time = seconds_since_init();
        wl_repeat_count      = 0;
    } else if wl_repeat_key_valid && key_event.keycode == wl_repeat_key.keycode {
        wl_repeat_key_valid = false;
    }
}

// How many autorepeat events are due since the last frame (advancing the count),
// plus the held key to replay. The Input backend calls this once per frame and
// emits that many key events through its normal key path. Returns 0 before the
// initial delay elapses, while no key is held, or when repeat is disabled.
wl_repeats_due :: () -> count: int, key: Wl_Key_Event {
    if !wl_repeat_key_valid || wl_repeat_rate <= 0  return 0, wl_repeat_key;
    elapsed := seconds_since_init() - wl_repeat_press_time;
    delay_s := wl_repeat_delay / 1000.0;
    if elapsed < delay_s  return 0, wl_repeat_key;

    interval := 1.0 / wl_repeat_rate;
    target   := cast(int)((elapsed - delay_s) / interval) + 1;  // repeats that should have fired by now
    due      := target - wl_repeat_count;
    if due <= 0  return 0, wl_repeat_key;

    wl_repeat_count = target;
    if due > WL_REPEAT_MAX_PER_FRAME  due = WL_REPEAT_MAX_PER_FRAME;
    return due, wl_repeat_key;
}

// Decode one wl_pointer event into stable Wl_Input_Events (and track the current
// surface-local pointer position for get_mouse_pointer_position). Called by the
// pump for messages matching an acquired pointer.
wl_handle_pointer_event :: (pev: Wl.Wl_Pointer_Event) {
    if pev.kind == {
        case .ENTER;
            wl_mouse_x = cast(float) Wl.fixed_to_float(pev.enter.surface_x);
            wl_mouse_y = cast(float) Wl.fixed_to_float(pev.enter.surface_y);
            array_add(*provisional_input_events, .{ kind = .POINTER_ENTER, pointer_enter = .{ x = wl_mouse_x, y = wl_mouse_y } });
        case .MOTION;
            wl_mouse_x = cast(float) Wl.fixed_to_float(pev.motion.surface_x);
            wl_mouse_y = cast(float) Wl.fixed_to_float(pev.motion.surface_y);
            array_add(*provisional_input_events, .{ kind = .POINTER_MOTION, pointer_motion = .{ x = wl_mouse_x, y = wl_mouse_y } });
        case .BUTTON;
            wl_last_input_serial = pev.button.serial;  // freshest serial for set_selection (clipboard copy)
            array_add(*provisional_input_events, .{ kind = .POINTER_BUTTON, pointer_button = .{
                button  = pev.button.button,
                pressed = pev.button.state == cast(u32) Wl.Wl_Pointer_Button_State.PRESSED,
            }});
        case .AXIS;
            array_add(*provisional_input_events, .{ kind = .POINTER_AXIS, pointer_axis = .{
                axis  = pev.axis.axis,
                value = cast(float) Wl.fixed_to_float(pev.axis.value),
            }});
        case;
            // LEAVE / FRAME / AXIS_SOURCE/STOP/DISCRETE/VALUE120/RELATIVE_DIRECTION — ignored.
    }
}

// Decode one wl_touch event into stable Wl_Input_Events. Called by the pump for
// messages matching an acquired touch device. (Untested on this hardware — no
// touch device — but structurally mirrors the pointer path.)
wl_handle_touch_event :: (tev: Wl.Wl_Touch_Event) {
    if tev.kind == {
        case .DOWN;
            array_add(*provisional_input_events, .{ kind = .TOUCH_DOWN, touch_down = .{
                id = tev.down.id,
                x  = cast(float) Wl.fixed_to_float(tev.down.x),
                y  = cast(float) Wl.fixed_to_float(tev.down.y),
            }});
        case .UP;
            array_add(*provisional_input_events, .{ kind = .TOUCH_UP, touch_up = .{ id = tev.up.id } });
        case .MOTION;
            array_add(*provisional_input_events, .{ kind = .TOUCH_MOTION, touch_motion = .{
                id = tev.motion.id,
                x  = cast(float) Wl.fixed_to_float(tev.motion.x),
                y  = cast(float) Wl.fixed_to_float(tev.motion.y),
            }});
        case;
            // FRAME / CANCEL / SHAPE / ORIENTATION — ignored.
    }
}

// ─────────────────────── Drag-and-drop decode + transfer ──────────────────

// True if the app opted into DnD (X11.enable_drag_and_drop flips the flag). Gates
// drop ACCEPTANCE so behaviour matches the X11 backend's XdndAware requirement.
wl_dnd_enabled :: inline () -> bool {
    return WT.wayland_drag_and_drop_requested;
}

wl_dnd_find_offer :: (offer_id: u32) -> *Wl_Dnd_Offer {
    for * wl_dnd_offers  if it.id == offer_id  return it;
    return null;
}

wl_dnd_is_tracked_offer :: (offer_id: u32) -> bool {
    return wl_dnd_find_offer(offer_id) != null;
}

wl_dnd_forget_offer :: (offer_id: u32) {
    for wl_dnd_offers {
        if it.id == offer_id {
            array_unordered_remove_by_index(*wl_dnd_offers, it_index);
            return;
        }
    }
}

// Send wl_data_offer.destroy and stop tracking the offer.
wl_dnd_destroy_offer :: (offer_id: u32) {
    if offer_id == 0  return;
    offer := Wl.Wl_Data_Offer.{ id = offer_id };
    batch: Wl.MessageBuilder;
    Wl.wl_data_offer_destroy(*batch, *offer);
    Wl.wayland_send(*batch);
    wl_dnd_forget_offer(offer_id);
}

// Decode a wl_data_device event (drag-session lifecycle + clipboard selection).
wl_handle_data_device_event :: (ev: Wl.Wl_Data_Device_Event) {
    if ev.kind == {
        case .DATA_OFFER;
            // Compositor introduced a new (server-allocated) wl_data_offer; track
            // it. Its advertised mime types arrive next as wl_data_offer.offer.
            array_add(*wl_dnd_offers, .{ id = ev.data_offer.id.id });

        case .ENTER;
            // A drag entered our surface. Stash the serial (needed to accept) and
            // tell the source whether we'll take it.
            wl_dnd_active_offer = ev.enter.id.id;
            wl_dnd_enter_serial = ev.enter.serial;
            wl_dnd_x = cast(float) Wl.fixed_to_float(ev.enter.x);
            wl_dnd_y = cast(float) Wl.fixed_to_float(ev.enter.y);

            off := wl_dnd_find_offer(wl_dnd_active_offer);
            offer := Wl.Wl_Data_Offer.{ id = wl_dnd_active_offer };
            batch: Wl.MessageBuilder;
            if wl_dnd_enabled() && off != null && off.has_uri_list {
                Wl.wl_data_offer_accept(*batch, *offer, wl_dnd_enter_serial, WL_DND_MIME);
                // v3: declare a copy action so the source enables the drop.
                Wl.wl_data_offer_set_actions(*batch, *offer,
                    cast(u32) Wl.Wl_Data_Device_Manager_Dnd_Action.COPY,
                    cast(u32) Wl.Wl_Data_Device_Manager_Dnd_Action.COPY);
            } else {
                // Decline: NULL (empty) mime, so the source shows a "no drop" cursor.
                Wl.wl_data_offer_accept(*batch, *offer, wl_dnd_enter_serial, "");
            }
            Wl.wayland_send(*batch);

        case .MOTION;
            wl_dnd_x = cast(float) Wl.fixed_to_float(ev.motion.x);
            wl_dnd_y = cast(float) Wl.fixed_to_float(ev.motion.y);

        case .LEAVE;
            // Drag left without dropping — tear the active offer down.
            wl_dnd_destroy_offer(wl_dnd_active_offer);
            wl_dnd_active_offer = 0;

        case .DROP;
            wl_dnd_perform_drop();

        case .SELECTION;
            // Clipboard selection changed. Adopt the new offer (kept alive for
            // wl_clipboard_get_text — its text mimes were recorded as its offer
            // events arrived) and destroy the one it replaces. A NULL id means the
            // selection was cleared.
            new_offer := ifx ev.selection.id != null then ev.selection.id.id else 0;
            if wl_clipboard_selection_offer != 0 && wl_clipboard_selection_offer != new_offer {
                wl_dnd_destroy_offer(wl_clipboard_selection_offer);
            }
            wl_clipboard_selection_offer = new_offer;
    }
}

// Decode a wl_data_offer event (mime advertisement + action negotiation). The
// caller has already matched object_id to a tracked offer.
wl_handle_data_offer_event :: (ev: Wl.Wl_Data_Offer_Event, offer_id: u32) {
    if ev.kind == {
        case .OFFER;
            off := wl_dnd_find_offer(offer_id);
            if off == null  return;
            if ev.offer.mime_type == WL_DND_MIME  off.has_uri_list = true;
            // Record the best (highest-priority) clipboard text mime this offer
            // carries. Store the STATIC list entry, never ev.offer.mime_type — that
            // string points into the temp-allocated payload and dies on temp reset.
            rank := wl_clipboard_mime_rank(ev.offer.mime_type);
            if rank >= 0 {
                cur := ifx off.text_mime.count > 0 then wl_clipboard_mime_rank(off.text_mime) else WL_CLIPBOARD_TEXT_MIMES.count;
                if rank < cur  off.text_mime = WL_CLIPBOARD_TEXT_MIMES[rank];
            }
        case;
            // SOURCE_ACTIONS / ACTION — informational for our copy path.
    }
}

wl_clipboard_mime_rank :: (mime: string) -> int {
    for WL_CLIPBOARD_TEXT_MIMES  if it == mime  return it_index;
    return -1;  // not a clipboard text mime we handle
}

// Handle a completed drop: pull the text/uri-list across the pipe and hand it to
// consumers as a DRAG_DROP event. The offer is always torn down afterwards.
wl_dnd_perform_drop :: () {
    offer_id := wl_dnd_active_offer;
    wl_dnd_active_offer = 0;
    if offer_id == 0  return;

    off := wl_dnd_find_offer(offer_id);
    offer := Wl.Wl_Data_Offer.{ id = offer_id };

    if !(wl_dnd_enabled() && off != null && off.has_uri_list) {
        // We never accepted this offer — just discard it.
        wl_dnd_destroy_offer(offer_id);
        return;
    }

    fds: [2] s32;
    if pipe2(*fds, O_CLOEXEC) != 0 {
        log_error("Wayland_Support: pipe2 failed for DnD receive");
        wl_dnd_destroy_offer(offer_id);
        return;
    }
    read_fd  := fds[0];
    write_fd := fds[1];

    // Ask the source to write the uri-list into write_fd (passed via SCM_RIGHTS),
    // then close OUR copy so the read hits EOF once the source finishes + closes.
    rbatch: Wl.MessageBuilder;
    Wl.wl_data_offer_receive(*rbatch, *offer, WL_DND_MIME, cast(Wl.Fd) write_fd);
    Wl.wayland_send(*rbatch);
    close(write_fd);

    uri_list := wl_dnd_read_all(read_fd);
    close(read_fd);

    // v3+: finish() tells the compositor the DnD completed; then destroy the offer.
    fbatch: Wl.MessageBuilder;
    if wl_dnd_version >= 3  Wl.wl_data_offer_finish(*fbatch, *offer);
    Wl.wl_data_offer_destroy(*fbatch, *offer);
    Wl.wayland_send(*fbatch);
    wl_dnd_forget_offer(offer_id);

    if uri_list.count > 0 {
        array_add(*provisional_input_events, .{
            kind = .DRAG_DROP,
            drag_drop = .{ uri_list = uri_list, x = wl_dnd_x, y = wl_dnd_y },
        });
    } else {
        free(uri_list.data);  // nothing transferred
    }
}

// Read a pipe fd to EOF into a freshly heap-allocated buffer; returns it as a
// string VIEW over that buffer (the consumer frees .data). Blocks until the
// source finishes writing — the same model as X11's selection transfer.
wl_dnd_read_all :: (fd: s32) -> string {
    buf: [..] u8;
    CHUNK :: 4096;
    while true {
        old := buf.count;
        array_resize(*buf, old + CHUNK);
        n := read(fd, buf.data + old, cast(u64) CHUNK);
        if n < 0 {
            if (cast(s32) errno()) == EINTR { buf.count = old; continue; }
            buf.count = old;
            break;
        }
        buf.count = old + cast(int) n;
        if n == 0  break;  // EOF
    }
    result: string = ---;
    result.data  = buf.data;
    result.count = buf.count;
    return result;
}

// ──────────────────────────── Clipboard (copy/paste) ──────────────────────
// Backs the Wayland arm of the vendored Clipboard module's os_clipboard_get_text
// / os_clipboard_set_text.

// PASTE. Returns a heap-allocated copy of the clipboard's text ("" if empty / not
// text). Per the os_clipboard_get_text contract the caller frees it.
wl_clipboard_get_text :: () -> string {
    // If WE own the selection, hand back our own buffer — receiving from our own
    // offer would deadlock (serving the receive needs the pump we'd block in).
    // Mirrors X11's x_window_is_ours short-circuit.
    if wl_clipboard_source != 0  return copy_string(wl_clipboard_source_text);

    // Catch up on any pending selection event so we read the current clipboard.
    wl_pump(false);
    if wl_clipboard_selection_offer == 0  return "";
    off := wl_dnd_find_offer(wl_clipboard_selection_offer);
    if off == null || off.text_mime.count == 0  return "";

    offer := Wl.Wl_Data_Offer.{ id = wl_clipboard_selection_offer };
    fds: [2] s32;
    if pipe2(*fds, O_CLOEXEC) != 0  return "";
    read_fd  := fds[0];
    write_fd := fds[1];

    rbatch: Wl.MessageBuilder;
    Wl.wl_data_offer_receive(*rbatch, *offer, off.text_mime, cast(Wl.Fd) write_fd);
    Wl.wayland_send(*rbatch);
    close(write_fd);

    text := wl_dnd_read_all(read_fd);
    close(read_fd);
    return text;
}

// COPY. Take ownership of the clipboard selection with a wl_data_source offering
// `text` in the common text mime types. The compositor delivers the bytes to
// other clients on demand via wl_data_source.send (handled in the pump).
wl_clipboard_set_text :: (text: string) {
    if wl_data_device_manager.id == 0 || wl_data_devices.count == 0  return;

    wl_clipboard_release_source();                 // drop any previous source we owned
    wl_clipboard_source_text = copy_string(text);  // freed in release_source / on .cancelled

    src_id := Wl.allocate_id();
    batch: Wl.MessageBuilder;
    Wl.wl_data_device_manager_create_data_source(*batch, *wl_data_device_manager, src_id);
    source := Wl.Wl_Data_Source.{ id = src_id };
    for WL_CLIPBOARD_TEXT_MIMES  Wl.wl_data_source_offer(*batch, *source, it);
    Wl.wl_data_device_set_selection(*batch, *wl_data_devices[0].device, *source, wl_last_input_serial);
    Wl.wayland_send(*batch);

    wl_clipboard_source = src_id;
}

// Clear the clipboard selection we own (os_clipboard_empty's Wayland arm).
wl_clipboard_empty :: () {
    wl_clipboard_release_source();
}

// Destroy our data source (if any) and free its served text.
wl_clipboard_release_source :: () {
    if wl_clipboard_source != 0 {
        source := Wl.Wl_Data_Source.{ id = wl_clipboard_source };
        b: Wl.MessageBuilder;
        Wl.wl_data_source_destroy(*b, *source);
        Wl.wayland_send(*b);
        wl_clipboard_source = 0;
    }
    if wl_clipboard_source_text.data != null {
        free(wl_clipboard_source_text.data);
        wl_clipboard_source_text = "";
    }
}

// Decode a wl_data_source event (our own clipboard source). The caller has
// matched object_id to wl_clipboard_source.
wl_handle_data_source_event :: (ev: Wl.Wl_Data_Source_Event) {
    if ev.kind == {
        case .SEND;
            // A client is pasting our selection — write the bytes and close the fd.
            fd := cast(s32) ev.send.fd;
            wl_write_all(fd, wl_clipboard_source_text);
            close(fd);
        case .CANCELLED;
            // Another client took the selection (or our source was replaced).
            wl_clipboard_release_source();
        case;
            // TARGET / ACTION / DND_DROP_PERFORMED / DND_FINISHED — not for clipboard.
    }
}

// Write a whole string to a (blocking) fd, tolerating short writes + EINTR.
// SIGPIPE is ignored process-wide (wl_acquire_input), so a closed reader yields
// EPIPE here instead of killing us.
wl_write_all :: (fd: s32, s: string) {
    written := 0;
    while written < s.count {
        n := write(fd, s.data + written, cast(u64)(s.count - written));
        if n < 0 {
            if (cast(s32) errno()) == EINTR  continue;
            break;
        }
        if n == 0  break;
        written += cast(int) n;
    }
}

// ─────────────────────────── The single pump ──────────────────────────────

// wl_pump is THE single drain of the persistent session buffer, serving BOTH
// rendering (Simp) and input (Input) because the one compositor connection
// multiplexes everything. It routes each message to its owning record in
// wayland_global_windows: frame callback / xdg_*.configure / xdg_toplevel.close
// / wl_buffer.release. Input events (everything it does not recognize) are
// dropped FOR NOW — the Input slice deposits them into a shared queue here.
//
// blocking=true  — block (reading the socket as needed) until a window's pending
//                  frame callback fires. Vsync-equivalent pacing (swap_buffers).
// blocking=false — drain only what is already buffered and return. (Input poll.)
//
// MANUAL drain (NOT `for session()`): the blocking-until-frame-callback vs.
// non-blocking-drain control flow is exactly what the for_expansion can't
// express, so this replicates its ping/pong + wl_display.error handling. That
// duplication is accepted for this first draft.
//
// WIRE GOTCHA: WL_CALLBACK_DONE and WL_BUFFER_RELEASE are BOTH opcode 0 —
// different interfaces, same opcode byte. We disambiguate by object_id, matching
// the dynamic frame-callback id first, then xdg roles, then buffers.
//
// The persistent session.recv (session.jai) is what makes this correct across
// calls: a wl_buffer.release coalesced into the same socket read as the frame
// `done` is NOT discarded when the blocking wait stops — it stays buffered for
// the next pump call.
wl_pump :: (blocking: bool) {
    session := context.wayland_session;
    if !session  return;

    while true {
        if session.connection_lost  break;

        msg, size := Wl.receive_peek_message(*session.recv);
        if msg == null {
            // Nothing buffered. Non-blocking: drained everything — return.
            // Blocking: read the socket (the only blocking point) and re-peek.
            if !blocking  break;
            bts := Wl.wayland_receive(*session.conn, *session.recv);
            if bts <= 0 { session.connection_lost = true; break; }
            msg, size = Wl.receive_peek_message(*session.recv);
            if msg == null  continue;
        }

        header: Wl.WaylandMessageHeader;
        header.object_id, header.opcode, header.msg_size = Wl.unpack_header(msg);
        header.payload = msg + Wl.HEADER_SIZE;

        // done=true stops the blocking wait after this message is consumed.
        done := false;

        // defer-consume mirrors for_expansion: handlers read header.payload
        // first, THEN we advance and re-peek, so a `continue` can't skip consume.
        defer {
            Wl.receive_consume_message(*session.recv, header.msg_size);
            msg, size = Wl.receive_peek_message(*session.recv);
        }

        if header.object_id == 1 && header.opcode == Wl.WL_DISPLAY_ERROR {
            err_obj := Wl.read_u32(header.payload);
            err_code := Wl.read_u32(header.payload + 4);
            err_msg, _ := Wl.read_string(header.payload + 8);
            log("FATAL: wl_display.error object=% code=%: %", err_obj, err_code, err_msg, flags=.ERROR);
            session.connection_lost = true;
            done = true;
        } else if header.object_id == session.wm_base.id && header.opcode == Wl.XDG_WM_BASE_PING {
            serial := Wl.read_u32(header.payload);
            ping_batch: Wl.MessageBuilder;
            Wl.xdg_wm_base_pong(*ping_batch, *session.wm_base, serial);
            Wl.wayland_send(*session.conn, *ping_batch);
        } else {
            // Route to the owning window record. The opcode-0 collision zone
            // (callback.done / xdg_surface.configure / buffer.release) is
            // disambiguated by object_id, so these object-id-qualified branches
            // MUST precede the opcode-only buffer-release scan below.
            routed := false;
            for * ww: wayland_global_windows {
                if ww.wl_pending_frame_callback != 0 && header.object_id == ww.wl_pending_frame_callback && header.opcode == Wl.WL_CALLBACK_DONE {
                    // The frame we're pacing on fired. Flag it (wl_present_and_pace's
                    // vsync throttle loops on wl_frame_done) and stop the blocking
                    // wait. SWAP owns the id recycle (cache_free). A callback means
                    // the compositor is presenting this surface again, so clear the
                    // starvation flag (it may have been read during a sibling's wait).
                    ww.wl_frame_done = true;
                    ww.wl_pacing_starved = false;
                    done = true;
                    routed = true;
                    break;
                }
                if header.object_id == ww.xdg_surface.id && header.opcode == Wl.XDG_SURFACE_CONFIGURE {
                    // Ack the serial — the protocol REQUIRES every configure be acked.
                    serial := Wl.read_u32(header.payload);
                    ack_batch: Wl.MessageBuilder;
                    Wl.xdg_surface_ack_configure(*ack_batch, *ww.xdg_surface, serial);
                    Wl.wayland_send(*ack_batch);
                    routed = true;
                    break;
                }
                if header.object_id == ww.toplevel.id && header.opcode == Wl.XDG_TOPLEVEL_CONFIGURE {
                    // Carries the suggested size (0x0 means "you decide"). Update
                    // the registry (the size source of truth) and flag size_dirty so
                    // consumers re-sync: Simp's next update_window -> BACKEND_RESIZE
                    // reallocs the slots, and Input emits a Window_Resize_Record that
                    // get_window_resizes() returns (invaders/GetRect re-layout off it).
                    args: Wl.Xdg_Toplevel_Configure_Args;
                    Wl.unmarshal(*args, header.payload, *session.recv);
                    if wl_note_configure_size(ww, args.width, args.height)  done = true;
                    routed = true;
                    break;
                }
                if header.object_id == ww.toplevel.id && header.opcode == Wl.XDG_TOPLEVEL_CLOSE {
                    ww.wl_close_requested = true;
                    done = true;
                    routed = true;
                    break;
                }
            }

            // Opcode-0 catch: a slot/retired buffer's only event is release.
            if !routed && header.opcode == Wl.WL_BUFFER_RELEASE {
                for * ww: wayland_global_windows {
                    for * ww.wl_slots {
                        if it.buffer.id == header.object_id {
                            it.in_flight = false;
                            // Let wl_present_and_pace's throttle (a blocking wl_pump)
                            // stop as soon as an active slot frees. (Async present
                            // dropped the frame callback that used to set `done`.)
                            done = true;
                            routed = true;
                            break;
                        }
                    }
                    if routed  break;
                    release_batch: Wl.MessageBuilder;
                    if wl_release_retired_slot(*release_batch, *ww.wl_retired, header.object_id, wl_shared_egl) {
                        Wl.wayland_send(*release_batch);
                        routed = true;
                        break;
                    }
                }
            }

            // Still unrouted → try input. Keyboard messages (matched against the
            // acquired wl_keyboards) decode into stable Wl_Input_Events appended
            // to provisional_input_events, which consumers drain each frame.
            // Pointer/touch are later slices; anything still unrouted is dropped
            // (the defer above consumes it regardless).
            if !routed && wl_keyboards.count > 0 {
                kev, is_kb := Wl.get_keyboard_event(header, wl_keyboards, *session.recv);
                if is_kb {
                    wl_handle_keyboard_event(kev);
                    routed = true;
                }
            }
            if !routed && wl_pointers.count > 0 {
                pev, is_ptr := Wl.get_pointer_event(header, wl_pointers, *session.recv);
                if is_ptr {
                    wl_handle_pointer_event(pev);
                    routed = true;
                }
            }
            if !routed && wl_touches.count > 0 {
                tev, is_touch := Wl.get_touch_event(header, wl_touches, *session.recv);
                if is_touch {
                    wl_handle_touch_event(tev);
                    routed = true;
                }
            }

            // Drag-and-drop: wl_data_device events (drag-session lifecycle +
            // selection) match a device id; wl_data_offer events (mime
            // advertisement, opcode 0 — same byte as buffer.release, but on the
            // disjoint server-allocated offer-id range) match a tracked offer.
            if !routed && wl_data_devices.count > 0 {
                dd_ev, is_dd := Wl.get_data_device_event(header, wl_data_devices, *session.recv);
                if is_dd {
                    wl_handle_data_device_event(dd_ev);
                    routed = true;
                }
            }
            if !routed && wl_dnd_is_tracked_offer(header.object_id) {
                off_ev := Wl.get_data_offer_event(header, *session.recv);
                wl_handle_data_offer_event(off_ev, header.object_id);
                routed = true;
            }
            // Our own clipboard source: serve wl_data_source.send / .cancelled.
            if !routed && wl_clipboard_source != 0 && header.object_id == wl_clipboard_source {
                src_ev := Wl.get_data_source_event(header, *session.recv);
                wl_handle_data_source_event(src_ev);
                routed = true;
            }
        }

        if blocking && done  break;
    }
}
