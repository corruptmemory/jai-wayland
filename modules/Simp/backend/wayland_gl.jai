// New file (not vendored — original to this project).
//
// Ported from examples/hello_gl.jai (the Option-B reference proven on Mesa
// AMD/Intel and NVIDIA). This is a PORT, not a rewrite: the known-good EGL-on-
// GBM + DMA-BUF machinery is lifted out of hello_gl's example locals and
// re-homed into structs the Wayland dispatcher reaches via *Window_Info.
// hello_gl.jai itself stays frozen as the reference (design doc §4).
//
// Symbol-naming notes (these matter — this file loads into the Simp module
// scope, which already `#import "GL"` and `#import "X11"` anonymously):
//   * GL entry points / constants (glGenTextures, GL_TEXTURE_2D, GLint, ...)
//     are referenced BARE — they're already in the module scope via GL.
//   * wayland / EGL / gbm / gpu are NOT imported by Simp, so we pull them in
//     under NAMED imports (Wl / EGL / Gbm / Gpu) to avoid polluting or
//     colliding with the Simp module namespace. All their symbols are
//     qualified at the call site.
//
// Modules log, they don't print: hello_gl uses print() (it's an example);
// every diagnostic here uses log()/log_error() per the modules convention.
//
// See docs/plans/2026-05-29-wayland-backend-design.md (§1 state-ownership,
// §4 shared helper) and the impl plan Task 4.

#scope_module

// `wayland` is NAME-based (not #import,dir) on purpose: Window_Creation ALSO
// imports wayland, and the two modules must share ONE instance — wayland
// declares `#add_context wayland_session`, so two instances give context.
// wayland_session conflicting types. Jai dedups modules by import SPELLING:
// name-based `#import "wayland"` dedups across modules (location-independent),
// but `#import,dir "../../wayland"` here could never string-match Window_
// Creation's `#import,dir "../wayland"`. Name-based resolves via the build's
// import_path (modules/ first — see first.jai). EGL/Gbm/Gpu stay dir-based:
// only Simp imports them, so no cross-module dedup is needed.
Wl  :: #import "wayland";
EGL :: #import,dir "../../EGL";
Gbm :: #import,dir "../../gbm";
Gpu :: #import,dir "../../gpu";

// POSIX is used bare here (open/close/O_RDWR/O_CLOEXEC for the dmabuf/keymap
// fds). No Simp file imports it directly — today it arrives only transitively
// through the Linux branch's anonymous X11 import. Import it explicitly so this
// file's dependency surface is self-evident and survives a future refactor of
// that transitive path. (Basic — log/to_string/temp_c_string — is ambient
// throughout Simp; same-module imports dedup, so this adds no collision risk.)
#import "POSIX";

// Double-buffered, matching hello_gl. The compositor scans out slot N while we
// render slot N+1; wl_buffer.release marks a slot free again.
SIMP_WL_SLOT_COUNT :: 2;

// Ported verbatim from hello_gl.jai:31-51 (Gl_Slot), renamed Wl_Gl_Slot.
// One slot holds a GL texture + FBO + EGLImage + (optional) GBM BO + the
// exported DMA-BUF fd wrapped as a wl_buffer.
Wl_Gl_Slot :: struct {
    tex:       u32;
    fbo:       u32;
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

// Ported from hello_gl.jai:363 (EGL_Context), renamed Wl_Egl_State.
// The per-window EGL display/context + GBM device + drm fd. Lives in
// Window_Info.specific, mirroring how glx_window lives there for X11.
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
// Ported from hello_gl.jai:357-361 (choose_gl_backend).
wl_choose_gl_backend :: () -> Wl_Gl_Backend {
    if Gbm.gbm_bo_create != null && Gbm.gbm_bo_destroy != null && glEGLImageTargetTexture2DOES != null
        return .GBM_BO;
    return .MESA_TEXTURE_EXPORT;
}

// Ported from hello_gl.jai:370-424 (init_gl_stack). Writes into the passed
// struct instead of a local. Same render-node selection (modules/gpu) + EGL/
// GBM/GL loaders.
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

// Ported from hello_gl.jai:426-431 (destroy_gl_stack).
wl_egl_destroy :: (egl: *Wl_Egl_State) {
    if egl.ctx  EGL.eglDestroyContext(egl.dpy, egl.ctx);
    if egl.dpy != EGL.EGL_NO_DISPLAY  EGL.eglTerminate(egl.dpy);
    if egl.gbm  Gbm.gbm_device_destroy(egl.gbm);
    if egl.drm_fd >= 0  close(egl.drm_fd);
}

// --- Format / modifier selection (ported from hello_gl.jai:433-504) ---

// Ported from hello_gl.jai:433-464 (choose_dmabuf_format). Prefers per-surface
// dmabuf feedback (filtered through GBM device capability) when available,
// falling back to the global format list.
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

// Ported from hello_gl.jai:466-478 (pick_format_from_feedback_for_gbm).
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

// Ported from hello_gl.jai:480-493 (pick_global_format_for_gbm).
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

// Ported from hello_gl.jai:495-504 (pick_global_format_for_gbm_pass).
wl_pick_global_format_for_gbm_pass :: (gbm: Gbm.Gbm_Device, supported: [] Wl.Format_Modifier, preferred_fourcc: u32, flags: u32, wanted_modifier: u64, require_modifier: bool) -> format: u32, modifier: u64, found: bool {
    for fm: supported {
        if fm.format != preferred_fourcc  continue;
        if require_modifier && fm.modifier != wanted_modifier  continue;
        if !Gpu.supports_bo_format_modifier(gbm, fm.format, fm.modifier, flags)  continue;
        return fm.format, fm.modifier, true;
    }

    return 0, 0, false;
}

// --- Slot allocation (ported from hello_gl.jai:506-619) ---

// Allocate a GL texture + FBO, export as DMA-BUF, wrap as wl_buffer.
// The wl_buffer + params messages get queued into `batch`; the caller sends
// when ready (so multiple slots can batch into a single send).
// Ported from hello_gl.jai:509-533 (init_slot).
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

// Ported from hello_gl.jai:535-585 (init_slot_bo).
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

// Ported from hello_gl.jai:587-619 (init_slot_mesa).
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

// Ported from hello_gl.jai:621-641 (queue_dmabuf_buffer). Builds the
// zwp_linux_dmabuf_v1 params and creates the wl_buffer into `buffer`. The
// messages are queued into `batch`; the caller sends.
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

// --- Slot teardown / retire (ported from hello_gl.jai:643-685) ---

// Ported from hello_gl.jai:643-652 (destroy_slot).
wl_slot_destroy :: (slot: *Wl_Gl_Slot, egl: Wl_Egl_State) {
    if slot.fbo != 0  glDeleteFramebuffers(1, *slot.fbo);
    if slot.tex != 0  glDeleteTextures(1, *slot.tex);
    if slot.image != null  EGL.eglDestroyImageKHR(egl.dpy, slot.image);
    if slot.bo != null  Gbm.gbm_bo_destroy(slot.bo);
    if slot.fd >= 0  close(slot.fd);
    if slot.image_fd >= 0  close(slot.image_fd);
    if slot.acquire_fence_fd >= 0  close(slot.acquire_fence_fd);
    if slot.release_fence_fd >= 0  close(slot.release_fence_fd);
}

// Ported from hello_gl.jai:654-667 (retire_slots). In-flight slots whose
// compositor-held buffer hasn't been released yet are moved to `retired` and
// destroyed later on their wl_buffer.release; the rest are torn down now.
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

// Ported from hello_gl.jai:669-680 (release_retired_slot). Matches a
// wl_buffer.release object_id against the retired list and tears down the slot.
// Returns true (and queues a wl_buffer.destroy into `batch`) if matched.
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

// Ported from hello_gl.jai:682-685 (find_free_slot).
wl_find_free_slot :: (slots: [] Wl_Gl_Slot) -> int {
    for slots  if !it.in_flight  return it_index;
    return -1;
}

// --- Frame-callback drain (extracted from hello_gl's render loop) ---

// Block draining the session until the frame callback we requested fires,
// while routing wl_buffer.release events back to their owning slots. This is
// the synchronous core of SWAP_BUFFERS (design §3): vsync-equivalent pacing.
//
// Extracted from hello_gl.jai's main render loop (the wl_callback.done /
// wl_buffer.release routing at lines 248-272). The dispatcher (Task 5) requests
// the frame callback + commit and then calls this to wait for the callback.
//
// WIRE GOTCHA: WL_CALLBACK_DONE and WL_BUFFER_RELEASE are BOTH opcode 0 —
// different interfaces, same opcode byte. We MUST disambiguate by object_id
// before treating an opcode-0 message as either one. Callback check is first
// because its id set is the most dynamic (allocated fresh every frame).
//
// `retired` carries slots from a prior resize whose buffers are still held by
// the compositor; their release events are matched here too. May be empty.
//
// CALLER CONTRACT (Task 5 dispatcher): this helper does NOT recycle the frame
// callback id. The reference recycled it inline (hello_gl.jai:249,
// cache_free(*frame_cache, ...)); that ownership now belongs to the caller,
// since the Id_Cache lives in the dispatcher. After this returns, the caller
// MUST cache_free the frame_callback_id, or it will leak a new id every frame.
//
// KNOWN LIMITATION — MUST be fixed in the Slice-3 event pump before invaders
// (Slice 4) leans on a long-running loop. On the frame-callback `done` we `break`
// out of `for session()`, whose ReceiveBuffer is LOCAL (session.jai:24) and
// discarded on exit. A wl_buffer.release the compositor coalesced into the SAME
// socket read as the `done` is therefore read from the socket but never consumed,
// and Wayland does not re-send it — so that slot stays in_flight PERMANENTLY (not
// just one frame). With 2 slots, one stuck slot makes wl_find_free_slot return -1,
// wl_current stops advancing, and the next frame re-commits a buffer the
// compositor may still be scanning out → tearing/corruption. It did not surface on
// the Hyprland smoke tests (that compositor didn't coalesce this way), but it is
// order-dependent. The correct fix is a persistent, session-level ReceiveBuffer so
// leftover messages survive across drains — exactly the pump Slice 3 builds.
//
// Event signals the swap-path drain collects while blocked. The dispatcher acts
// on them after wl_block_on_frame returns (set the close flag; apply a new size).
// Consolidates what would otherwise be a growing list of out-params and is the
// seed of the Slice-3 event pump.
Wl_Frame_Signals :: struct {
    close_requested: bool;   // xdg_toplevel.close seen
    have_new_size:   bool;   // an xdg_toplevel.configure carried a usable (>0) size
    new_width:       s32;
    new_height:      s32;
}

// Collects close / resize signals while waiting for the frame callback, and acks
// every xdg_surface.configure inline (required by the protocol). Pass 0 for an id
// to disable that detection. Caller acts on `signals` after return.
wl_block_on_frame :: (frame_callback_id: u32, slots: [] Wl_Gl_Slot,
                      retired: *[..] Wl_Gl_Slot, egl: Wl_Egl_State,
                      xdg_toplevel_id: u32, xdg_surface_id: u32,
                      signals: *Wl_Frame_Signals) {
    // `for :Wl.for_expansion` names the iterator explicitly: the WaylandSession
    // for_expansion lives in the `Wl` module and is NOT merged into Simp's scope
    // by our named import, so a bare `for Wl.session()` can't find the overload
    // (it falls through to Hash_Table's). hello_gl gets away with a bare `for`
    // because it imports wayland anonymously. See modules/wayland/session.jai.
    for :Wl.for_expansion Wl.session() {
        // wl_callback.done for the frame we most recently requested — done.
        if it.object_id == frame_callback_id && it.opcode == Wl.WL_CALLBACK_DONE {
            break;
        }

        if xdg_toplevel_id != 0 && it.object_id == xdg_toplevel_id {
            // xdg_toplevel.close — compositor/user asked the window to close.
            // Record it and stop waiting; the app checks window_should_close.
            if it.opcode == Wl.XDG_TOPLEVEL_CLOSE {
                signals.close_requested = true;
                break;
            }
            // xdg_toplevel.configure — carries the suggested size (0x0 means
            // "you decide" — ignore those). Keep waiting for the frame callback;
            // the resize is applied by the app's next update_window.
            if it.opcode == Wl.XDG_TOPLEVEL_CONFIGURE {
                args: Wl.Xdg_Toplevel_Configure_Args;
                Wl.unmarshal(*args, it.payload, recv);
                if args.width > 0 && args.height > 0 {
                    signals.have_new_size = true;
                    signals.new_width  = args.width;
                    signals.new_height = args.height;
                }
                continue;
            }
        }

        // xdg_surface.configure — ack the serial (the protocol REQUIRES every
        // configure be acked, resize or not). The size from xdg_toplevel.configure
        // above is applied separately by the caller.
        if xdg_surface_id != 0 && it.object_id == xdg_surface_id && it.opcode == Wl.XDG_SURFACE_CONFIGURE {
            serial := Wl.read_u32(it.payload);
            ack_batch: Wl.MessageBuilder;
            xs := Wl.Xdg_Surface.{ id = xdg_surface_id };
            Wl.xdg_surface_ack_configure(*ack_batch, *xs, serial);
            Wl.wayland_send(*ack_batch);
            continue;
        }

        // wl_buffer.release — mark the owning slot available. Requires the
        // object_id to match a known slot buffer (see wire gotcha above).
        if it.opcode == Wl.WL_BUFFER_RELEASE {
            matched := false;
            obj_id := it.object_id;
            for * slots  if it.buffer.id == obj_id {
                it.in_flight = false;
                matched = true;
                break;
            }
            if matched  continue;

            release_batch: Wl.MessageBuilder;
            if wl_release_retired_slot(*release_batch, retired, obj_id, egl) {
                Wl.wayland_send(*release_batch);
                continue;
            }
            // otherwise fall through — not our release event, some other
            // opcode-0 event on an object we don't own.
        }
    }
}
