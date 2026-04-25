// hello_gl — GPU-rendered Wayland window, double-buffered via dmabuf,
// paced by wl_surface.frame callbacks.
//
// Two slots each hold a GL texture + FBO + EGLImage + DMA-BUF fd + wl_buffer.
// The render loop rotates between slots: while the compositor is scanning
// out slot N, we render slot N+1. wl_buffer.release marks a slot available.
// wl_callback.done marks a frame displayed, freeing us to render the next.
//
// Task 8 renders a rotating RGB triangle: vertex + fragment shader,
// VAO+VBO, single uniform for rotation angle. Task 9 adds input.

#import,dir "../modules/wayland";
#import,dir "../modules/EGL";
#import,dir "../modules/gbm";
Gpu :: #import,dir "../modules/gpu";
GL :: #import,dir "../modules/GL";

#import "Basic";
#import "Math";
#import "POSIX";

DEFAULT_WIDTH  :: 640;
DEFAULT_HEIGHT :: 480;

Gl_Slot :: struct {
    tex:       u32;
    fbo:       u32;
    image:     EGLImage;
    bo:        Gbm_Bo;
    buffer:    Wl_Buffer;
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
}

main :: () {
    if !init_wayland_session() {
        print("Failed to create Wayland session\n");
        return;
    }
    defer end_wayland_session();

    // --- EGL + GL stack ---
    egl: EGL_Context;
    if !init_gl_stack(*egl) {
        print("Could not initialize EGL/GL\n");
        return;
    }
    defer destroy_gl_stack(*egl);

    // --- dmabuf discovery + format pick ---
    dmabuf_info, dmabuf_ok := get_dmabuf_info();
    if !dmabuf_ok {
        print("Compositor does not support zwp_linux_dmabuf_v1\n");
        return;
    }

    format, modifier, have_format := pick_format(dmabuf_info, GBM_FORMAT_ABGR8888);
    if !have_format {
        format, modifier, have_format = pick_format(dmabuf_info, GBM_FORMAT_XBGR8888);
    }
    if !have_format {
        print("Compositor doesn't advertise an ABGR/XBGR 8888 format\n");
        return;
    }
    print("Using format=0x% modifier=0x%\n",
        formatInt(format, base=16),
        formatInt(modifier, base=16));

    // --- Input: seats, keyboards, pointers, keymap ---
    seats     := get_seats_info();
    keyboards := get_keyboards_info(seats);
    pointers  := get_pointers_info(seats);
    keymap: Keymap;
    if keyboards.count > 0 {
        ok: bool;
        keymap, ok = parse_keymap_fd(keyboards[0].keymap_fd, keyboards[0].keymap_size);
        if !ok  print("Warning: failed to parse keymap — r/g/b/q keys inactive\n");
    }
    print("Input: % seat(s), % keyboard(s), % pointer(s)\n",
        seats.count, keyboards.count, pointers.count);
    if keyboards.count > 0  print("  Keys:  r/g/b = color scheme, q = quit\n");
    if pointers.count > 0   print("  Click: prints pointer coords, cycles scheme\n");

    // --- Triangle setup (shader, VAO, VBO) ---
    tri: Triangle;
    if !init_triangle(*tri) {
        print("Triangle setup failed\n");
        return;
    }

    // --- Create surface + xdg roles ---
    batch: MessageBuilder;
    surface := Wl_Surface.{ id = allocate_id() };
    xdg_surface := Xdg_Surface.{ id = allocate_id() };
    toplevel := Xdg_Toplevel.{ id = allocate_id() };
    wl_compositor_create_surface(*batch, compositor(), surface.id);
    xdg_wm_base_get_xdg_surface(*batch, wm_base(), xdg_surface.id, *surface);
    xdg_surface_get_toplevel(*batch, *xdg_surface, toplevel.id);
    xdg_toplevel_set_title(*batch, *toplevel, "hello_gl");
    wl_surface_commit(*batch, *surface);
    wayland_send(*batch);

    // --- Wait for initial configure ---
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

    // --- Pre-allocate two GL-backed buffer slots at compositor size ---
    slots: [2] Gl_Slot;
    for * slot, i: slots {
        if !init_slot(slot, egl, *dmabuf_info.dmabuf, *batch, format, modifier, win_width, win_height) {
            print("Failed to initialize slot %\n", i);
            return;
        }
    }
    defer for * slots  destroy_slot(it, egl);
    wayland_send(*batch);

    // --- Paint slot 0 with the initial frame ---
    paint_gl_frame(*slots[0], tri, 0.0);

    // --- Ack, attach slot 0, request first frame callback, commit ---
    frame_callback_id := allocate_id();
    xdg_surface_ack_configure(*batch, *xdg_surface, configure_serial);
    wl_surface_frame(*batch, *surface, frame_callback_id);
    wl_surface_attach(*batch, *surface, *slots[0].buffer, 0, 0);
    wl_surface_damage_buffer(*batch, *surface, 0, 0, slots[0].width, slots[0].height);
    wl_surface_commit(*batch, *surface);
    wayland_send(*batch);
    slots[0].in_flight = true;
    frame_requested := true;

    print("hello_gl: animating. Close the window or press q to exit.\n");

    // --- Main loop: frame-paced render-rotate, input-reactive ---
    //
    // `t` advances once per displayed frame — rotates the triangle.
    // r/g/b keys flip COLOR_SCHEMES entries; pointer click prints
    // (x, y) and cycles to the next scheme.
    dirty := true;
    rotation_start := monotonic_seconds();
    pointer_x: float64 = 0;
    pointer_y: float64 = 0;
    pending_width:  s32 = 0;
    pending_height: s32 = 0;
    resize_width:   s32 = 0;
    resize_height:  s32 = 0;
    resize_serial:  u32 = 0;
    resize_pending := false;
    retired_slots: [..] Gl_Slot;
    defer for * retired_slots  destroy_slot(it, egl);

    for session() {
        defer {
            if resize_pending && !frame_requested {
                retire_slots(*batch, *retired_slots, slots, egl);

                for * slot, i: slots {
                    if !init_slot(slot, egl, *dmabuf_info.dmabuf, *batch, format, modifier, resize_width, resize_height, log_success = false) {
                        assert(false, "Failed to initialize resized slot %", i);
                    }
                }

                win_width = resize_width;
                win_height = resize_height;

                paint_gl_frame(*slots[0], tri, rotation_angle(rotation_start));
                frame_callback_id = allocate_id();
                xdg_surface_ack_configure(*batch, *xdg_surface, resize_serial);
                wl_surface_frame(*batch, *surface, frame_callback_id);
                wl_surface_attach(*batch, *surface, *slots[0].buffer, 0, 0);
                wl_surface_damage_buffer(*batch, *surface, 0, 0, slots[0].width, slots[0].height);
                wl_surface_commit(*batch, *surface);
                wayland_send(*batch);

                slots[0].in_flight = true;
                frame_requested = true;
                dirty = false;
                resize_pending = false;
            } else if dirty && !frame_requested && !resize_pending {
                slot_idx := find_free_slot(slots);
                if slot_idx >= 0 {
                    slot := *slots[slot_idx];
                    paint_gl_frame(slot, tri, rotation_angle(rotation_start));

                    frame_callback_id = allocate_id();
                    wl_surface_frame(*batch, *surface, frame_callback_id);
                    wl_surface_attach(*batch, *surface, *slot.buffer, 0, 0);
                    wl_surface_damage_buffer(*batch, *surface, 0, 0, slot.width, slot.height);
                    wl_surface_commit(*batch, *surface);
                    wayland_send(*batch);

                    slot.in_flight = true;
                    frame_requested = true;
                    dirty = false;
                }
            }
        };

        // wl_callback.done for the frame we most recently requested.
        // NOTE: WL_CALLBACK_DONE and WL_BUFFER_RELEASE are both opcode 0 —
        // different interfaces, same opcode byte on the wire. We MUST
        // disambiguate by object_id before treating an opcode-0 message
        // as one or the other. Callback check first because its id set
        // is the most dynamic (allocated fresh every frame).
        if it.object_id == frame_callback_id && it.opcode == WL_CALLBACK_DONE {
            frame_requested = false;
            dirty = true;    // continuous animation
            continue;
        }

        // wl_buffer.release — mark slot available. Requires the object_id
        // to actually match a known slot buffer (see note above).
        if it.opcode == WL_BUFFER_RELEASE {
            matched := false;
            obj_id := it.object_id;
            for * slots  if it.buffer.id == obj_id {
                it.in_flight = false;
                matched = true;
                break;
            }
            if matched  continue;
            if release_retired_slot(*batch, *retired_slots, obj_id, egl) {
                wayland_send(*batch);
                continue;
            }
            // otherwise fall through — this wasn't our release event,
            // it's some other opcode-0 event on an object we don't own.
        }

        if it.object_id == toplevel.id {
            if it.opcode == XDG_TOPLEVEL_CONFIGURE {
                args: Xdg_Toplevel_Configure_Args;
                unmarshal(*args, it.payload, recv);
                if args.width > 0 && args.height > 0 {
                    pending_width = args.width;
                    pending_height = args.height;
                }
                continue;
            } else if it.opcode == XDG_TOPLEVEL_CLOSE {
                print("Close requested.\n");
                break;
            }
        }

        if it.object_id == xdg_surface.id && it.opcode == XDG_SURFACE_CONFIGURE {
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

        // Keyboard: q quits, r/g/b flip the vertex color scheme.
        kb_event, is_kb := get_keyboard_event(it, keyboards, recv);
        if is_kb {
            if kb_event.kind == .KEY && kb_event.key.state == cast(u32) Wl_Keyboard_Key_State.PRESSED {
                keysym := keymap_get_keysym(*keymap, kb_event.key.key);
                if keysym == {
                  case #char "q";
                    print("Quit requested.\n");
                    break;
                  case #char "r"; apply_color_scheme(*tri, 1);
                  case #char "g"; apply_color_scheme(*tri, 2);
                  case #char "b"; apply_color_scheme(*tri, 3);
                }
            }
            continue;
        }

        // Pointer: track motion; click prints coords + cycles scheme.
        ptr_event, is_ptr := get_pointer_event(it, pointers, recv);
        if is_ptr {
            if ptr_event.kind == {
              case .ENTER;
                pointer_x = fixed_to_float(ptr_event.enter.surface_x);
                pointer_y = fixed_to_float(ptr_event.enter.surface_y);
              case .MOTION;
                pointer_x = fixed_to_float(ptr_event.motion.surface_x);
                pointer_y = fixed_to_float(ptr_event.motion.surface_y);
              case .BUTTON;
                if ptr_event.button.state == cast(u32) Wl_Pointer_Button_State.PRESSED {
                    print("Click at (%, %)\n", pointer_x, pointer_y);
                    apply_color_scheme(*tri, (tri.scheme + 1) % SCHEME_COUNT);
                }
            }
            continue;
        }

    }
}

// --- Helpers ---

EGL_Context :: struct {
    drm_fd: s32 = -1;
    gbm:    Gbm_Device;
    dpy:    EGLDisplay;
    ctx:    EGLContext;
}

init_gl_stack :: (egl: *EGL_Context) -> bool {
    nodes: [..] Gpu.Render_Node_Info;
    if !Gpu.discover_render_nodes(*nodes)  return false;
    Gpu.print_render_nodes(nodes);

    selected, selected_ok := Gpu.choose_render_node(nodes);
    if !selected_ok  return false;
    print("Selected render node: % (% id=0x%)\n",
        selected.path,
        Gpu.vendor_name(selected.vendor),
        formatInt(selected.vendor_id, base=16, minimum_digits=4));

    egl.drm_fd = open(temp_c_string(selected.path), O_RDWR | O_CLOEXEC);
    if egl.drm_fd < 0  return false;
    if !init_egl() || !init_gbm()  return false;

    egl.gbm = gbm_create_device(egl.drm_fd);
    if !egl.gbm  return false;
    if gbm_device_get_backend_name != null {
        print("GBM backend: %\n", to_string(gbm_device_get_backend_name(egl.gbm)));
    }

    egl.dpy = eglGetPlatformDisplay(EGL_PLATFORM_GBM_KHR, egl.gbm, null);
    if egl.dpy == EGL_NO_DISPLAY  return false;

    if eglInitialize(egl.dpy, null, null) != EGL_TRUE  return false;
    if !init_egl_extensions(egl.dpy)  return false;

    eglBindAPI(EGL_OPENGL_API);
    config_attrs := s32.[
        EGL_SURFACE_TYPE,    EGL_WINDOW_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_NONE,
    ];
    cfg: EGLConfig;
    n: EGLint;
    if eglChooseConfig(egl.dpy, config_attrs.data, *cfg, 1, *n) != EGL_TRUE || n == 0  return false;

    ctx_attrs := s32.[
        EGL_CONTEXT_MAJOR_VERSION_KHR, 3,
        EGL_CONTEXT_MINOR_VERSION_KHR, 3,
        EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT_KHR,
        EGL_NONE,
    ];
    egl.ctx = eglCreateContext(egl.dpy, cfg, EGL_NO_CONTEXT, ctx_attrs.data);
    if egl.ctx == EGL_NO_CONTEXT  return false;

    if eglMakeCurrent(egl.dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, egl.ctx) != EGL_TRUE  return false;
    if !GL.gl_load(eglGetProcAddress)  return false;
    if !GL.gl_load_egl_image_extensions(eglGetProcAddress) {
        print("Warning: GL_OES_EGL_image missing; BO-backed slots disabled\n");
    }
    return true;
}

destroy_gl_stack :: (egl: *EGL_Context) {
    if egl.ctx  eglDestroyContext(egl.dpy, egl.ctx);
    if egl.dpy != EGL_NO_DISPLAY  eglTerminate(egl.dpy);
    if egl.gbm  gbm_device_destroy(egl.gbm);
    if egl.drm_fd >= 0  close(egl.drm_fd);
}

// Allocate a GL texture + FBO, export as DMA-BUF, wrap as wl_buffer.
// The wl_buffer and params messages get queued into `batch`; the caller
// sends when ready (we batch all slots into a single send).
init_slot :: (slot: *Gl_Slot, egl: EGL_Context, dmabuf: *Zwp_Linux_Dmabuf_V1,
              batch: *MessageBuilder, format: u32, modifier: u64, width: s32, height: s32,
              log_success := true) -> bool
{
    slot_path_ptr := getenv("JAI_WAYLAND_GL_SLOT_PATH");
    if slot_path_ptr != null && to_string(slot_path_ptr) == "mesa" {
        print("Using Mesa texture-export slot path due to JAI_WAYLAND_GL_SLOT_PATH=mesa\n");
        return init_slot_mesa(slot, egl, dmabuf, batch, format, modifier, width, height);
    }

    if init_slot_bo(slot, egl, dmabuf, batch, format, modifier, width, height) {
        if log_success {
            print("Initialized BO-backed slot buffer=% format=0x% modifier=0x%\n",
                slot.buffer.id,
                formatInt(slot.format, base=16),
                formatInt(slot.modifier, base=16));
        }
        return true;
    }

    destroy_slot(slot, egl);
    slot.* = .{};
    print("BO-backed slot initialization failed; falling back to Mesa texture export\n");
    return init_slot_mesa(slot, egl, dmabuf, batch, format, modifier, width, height);
}

init_slot_bo :: (slot: *Gl_Slot, egl: EGL_Context, dmabuf: *Zwp_Linux_Dmabuf_V1,
                 batch: *MessageBuilder, format: u32, modifier: u64, width: s32, height: s32) -> bool
{
    if gbm_bo_create == null || gbm_bo_destroy == null  return false;
    if GL.glEGLImageTargetTexture2DOES == null  return false;

    flags := cast(u32) GBM_BO_USE_RENDERING;
    if gbm_device_is_format_supported != null {
        if gbm_device_is_format_supported(egl.gbm, format, flags) == 0  return false;
    }

    slot.bo = Gpu.create_bo_with_modifier(egl.gbm, width, height, format, modifier, flags);
    if slot.bo == null  return false;

    image_ok: bool;
    slot.image, slot.image_fd, image_ok = Gpu.create_image_from_gbm_bo(egl.dpy, slot.bo, width, height);
    if !image_ok  return false;

    GL.glGenTextures(1, *slot.tex);
    GL.glBindTexture(GL.GL_TEXTURE_2D, slot.tex);
    GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_MIN_FILTER, GL.GL_LINEAR);
    GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_MAG_FILTER, GL.GL_LINEAR);
    GL.glEGLImageTargetTexture2DOES(GL.GL_TEXTURE_2D, slot.image);

    GL.glGenFramebuffers(1, *slot.fbo);
    GL.glBindFramebuffer(GL.GL_FRAMEBUFFER, slot.fbo);
    GL.glFramebufferTexture2D(GL.GL_FRAMEBUFFER, GL.GL_COLOR_ATTACHMENT0,
        GL.GL_TEXTURE_2D, slot.tex, 0);
    if GL.glCheckFramebufferStatus(GL.GL_FRAMEBUFFER) != GL.GL_FRAMEBUFFER_COMPLETE  return false;

    if gbm_bo_get_fd == null || gbm_bo_get_stride == null  return false;
    fd := gbm_bo_get_fd(slot.bo);
    if fd < 0  return false;

    slot.fd = fd;
    slot.stride = gbm_bo_get_stride(slot.bo);
    slot.offset = ifx gbm_bo_get_offset != null then gbm_bo_get_offset(slot.bo, 0) else 0;
    planes := ifx gbm_bo_get_plane_count != null then gbm_bo_get_plane_count(slot.bo) else 1;
    if planes != 1  return false;

    slot.format = format;
    slot.modifier = modifier;
    slot.width = width;
    slot.height = height;
    slot.bo_backed = true;
    queue_dmabuf_buffer(batch, dmabuf, *slot.buffer, slot.fd, slot.offset, slot.stride, format, modifier, width, height);
    return true;
}

init_slot_mesa :: (slot: *Gl_Slot, egl: EGL_Context, dmabuf: *Zwp_Linux_Dmabuf_V1,
                  batch: *MessageBuilder, format: u32, modifier: u64, width: s32, height: s32) -> bool
{
    GL.glGenTextures(1, *slot.tex);
    GL.glBindTexture(GL.GL_TEXTURE_2D, slot.tex);
    GL.glTexImage2D(GL.GL_TEXTURE_2D, 0, GL.GL_RGBA8, width, height, 0,
        GL.GL_RGBA, GL.GL_UNSIGNED_BYTE, null);
    GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_MIN_FILTER, GL.GL_LINEAR);
    GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_MAG_FILTER, GL.GL_LINEAR);

    GL.glGenFramebuffers(1, *slot.fbo);
    GL.glBindFramebuffer(GL.GL_FRAMEBUFFER, slot.fbo);
    GL.glFramebufferTexture2D(GL.GL_FRAMEBUFFER, GL.GL_COLOR_ATTACHMENT0,
        GL.GL_TEXTURE_2D, slot.tex, 0);
    if GL.glCheckFramebufferStatus(GL.GL_FRAMEBUFFER) != GL.GL_FRAMEBUFFER_COMPLETE  return false;

    slot.image = eglCreateImageKHR(egl.dpy, egl.ctx, EGL_GL_TEXTURE_2D_KHR,
        cast(EGLClientBuffer) cast(u64) slot.tex, null);
    if !slot.image  return false;

    fd, stride, offset: s32;
    if eglExportDMABUFImageMESA(egl.dpy, slot.image, *fd, *stride, *offset) != EGL_TRUE  return false;
    slot.fd = fd;
    slot.stride = cast(u32) stride;
    slot.offset = cast(u32) offset;
    slot.format = format;
    slot.modifier = modifier;
    slot.width = width;
    slot.height = height;

    queue_dmabuf_buffer(batch, dmabuf, *slot.buffer, fd, cast(u32) offset, cast(u32) stride, format, modifier, width, height);
    return true;
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

destroy_slot :: (slot: *Gl_Slot, egl: EGL_Context) {
    if slot.fbo != 0  GL.glDeleteFramebuffers(1, *slot.fbo);
    if slot.tex != 0  GL.glDeleteTextures(1, *slot.tex);
    if slot.image != null  eglDestroyImageKHR(egl.dpy, slot.image);
    if slot.bo != null  gbm_bo_destroy(slot.bo);
    if slot.fd >= 0  close(slot.fd);
    if slot.image_fd >= 0  close(slot.image_fd);
}

retire_slots :: (batch: *MessageBuilder, retired: *[..] Gl_Slot, slots: [] Gl_Slot, egl: EGL_Context) {
    for * slot: slots {
        if slot.buffer.id == 0  continue;

        if slot.in_flight {
            array_add(retired, slot.*);
        } else {
            wl_buffer_destroy(batch, *slot.buffer);
            destroy_slot(slot, egl);
        }

        slot.* = .{};
    }
}

release_retired_slot :: (batch: *MessageBuilder, retired: *[..] Gl_Slot, object_id: u32, egl: EGL_Context) -> bool {
    for * slot, i: retired.* {
        if slot.buffer.id == object_id {
            wl_buffer_destroy(batch, *slot.buffer);
            destroy_slot(slot, egl);
            array_unordered_remove_by_index(retired, i);
            return true;
        }
    }

    return false;
}

find_free_slot :: (slots: [] Gl_Slot) -> int {
    for slots  if !it.in_flight  return it_index;
    return -1;
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

// --- Triangle rendering (Task 8) ---
//
// Minimal GL 3.3 core setup: one vertex shader, one fragment shader, one
// program, one VAO, one VBO. The VBO holds three vertices, each (x, y, r,
// g, b) as float32. The vertex shader rotates by a uniform angle. The
// fragment shader just passes through the interpolated per-vertex color.

VS_SRC :: #string GLSL
#version 330 core
layout(location = 0) in vec2 a_pos;
layout(location = 1) in vec3 a_col;
uniform float u_angle;
out vec3 v_col;
void main() {
    float c = cos(u_angle);
    float s = sin(u_angle);
    vec2 r = vec2(c * a_pos.x - s * a_pos.y,
                  s * a_pos.x + c * a_pos.y);
    gl_Position = vec4(r, 0.0, 1.0);
    v_col = a_col;
}
GLSL

FS_SRC :: #string GLSL
#version 330 core
in vec3 v_col;
out vec4 frag;
void main() {
    frag = vec4(v_col, 1.0);
}
GLSL

Triangle :: struct {
    program: u32;
    vao:     u32;
    vbo:     u32;
    u_angle: GL.GLint;   // uniform location; may be -1 if optimized out
    scheme:  int = 0;    // index into COLOR_SCHEMES
}

// Four color schemes — default, then r/g/b highlight the respective vertex.
// Each scheme is three (r, g, b) triples, one per vertex.
COLOR_SCHEMES :: float.[
    // default — saturated RGB at the three corners
    1.0, 0.2, 0.2,    0.2, 1.0, 0.2,    0.2, 0.2, 1.0,
    // r — warm reds/oranges
    1.0, 0.3, 0.1,    0.9, 0.6, 0.2,    0.8, 0.2, 0.2,
    // g — greens / teals
    0.1, 1.0, 0.4,    0.2, 0.8, 0.6,    0.4, 1.0, 0.7,
    // b — blues / purples
    0.3, 0.4, 1.0,    0.6, 0.3, 0.9,    0.2, 0.2, 0.8,
];
SCHEME_COUNT    :: 4;
VERTICES_PER_TRI :: 3;
FLOATS_PER_SCHEME :: VERTICES_PER_TRI * 3;

init_triangle :: (tri: *Triangle) -> bool {
    vs, vs_ok := compile_shader(GL.GL_VERTEX_SHADER, VS_SRC);
    if !vs_ok  return false;
    defer GL.glDeleteShader(vs);

    fs, fs_ok := compile_shader(GL.GL_FRAGMENT_SHADER, FS_SRC);
    if !fs_ok  return false;
    defer GL.glDeleteShader(fs);

    tri.program = GL.glCreateProgram();
    GL.glAttachShader(tri.program, vs);
    GL.glAttachShader(tri.program, fs);
    GL.glLinkProgram(tri.program);

    linked: GL.GLint;
    GL.glGetProgramiv(tri.program, GL.GL_LINK_STATUS, *linked);
    if linked != GL.GL_TRUE {
        log_len: GL.GLint;
        GL.glGetProgramiv(tri.program, GL.GL_INFO_LOG_LENGTH, *log_len);
        log_buf: [1024] u8;
        GL.glGetProgramInfoLog(tri.program, log_buf.count, null, log_buf.data);
        print("Program link failed: %\n", cast(string) log_buf);
        return false;
    }

    tri.u_angle = GL.glGetUniformLocation(tri.program, "u_angle".data);

    GL.glGenVertexArrays(1, *tri.vao);
    GL.glBindVertexArray(tri.vao);

    GL.glGenBuffers(1, *tri.vbo);
    GL.glBindBuffer(GL.GL_ARRAY_BUFFER, tri.vbo);

    // Upload initial vertex data with scheme 0. Colors get rewritten in place
    // on scheme change (see apply_color_scheme).
    upload_triangle_verts(tri, 0);

    stride : GL.GLsizei = 5 * size_of(float);
    GL.glVertexAttribPointer(0, 2, GL.GL_FLOAT, GL.GL_FALSE, stride, cast(*void) 0);
    GL.glEnableVertexAttribArray(0);
    GL.glVertexAttribPointer(1, 3, GL.GL_FLOAT, GL.GL_FALSE, stride, cast(*void)(2 * size_of(float)));
    GL.glEnableVertexAttribArray(1);

    GL.glBindVertexArray(0);
    GL.glBindBuffer(GL.GL_ARRAY_BUFFER, 0);
    return true;
}

// Pack (x, y, r, g, b) × 3 vertices using the given scheme, upload as VBO data.
upload_triangle_verts :: (tri: Triangle, scheme: int) {
    SQRT3_OVER_2 : float : 0.8660254;
    cols := COLOR_SCHEMES.data + scheme * FLOATS_PER_SCHEME;
    verts := float.[
        //   x                           y        r           g           b
             0.0,                        0.7,     cols[0],    cols[1],    cols[2],
            -SQRT3_OVER_2 * 0.7,        -0.35,    cols[3],    cols[4],    cols[5],
             SQRT3_OVER_2 * 0.7,        -0.35,    cols[6],    cols[7],    cols[8],
    ];
    GL.glBindBuffer(GL.GL_ARRAY_BUFFER, tri.vbo);
    GL.glBufferData(GL.GL_ARRAY_BUFFER, verts.count * size_of(float), verts.data, GL.GL_STATIC_DRAW);
}

apply_color_scheme :: (tri: *Triangle, scheme: int) {
    tri.scheme = scheme;
    upload_triangle_verts(tri, scheme);
}

compile_shader :: (kind: GL.GLenum, src: string) -> sh: u32, ok: bool {
    sh := GL.glCreateShader(kind);
    src_data := src.data;
    src_len  : GL.GLint = cast(GL.GLint) src.count;
    GL.glShaderSource(sh, 1, *src_data, *src_len);
    GL.glCompileShader(sh);

    status: GL.GLint;
    GL.glGetShaderiv(sh, GL.GL_COMPILE_STATUS, *status);
    if status != GL.GL_TRUE {
        log_buf: [1024] u8;
        GL.glGetShaderInfoLog(sh, log_buf.count, null, log_buf.data);
        print("Shader compile failed: %\n", cast(string) log_buf);
        GL.glDeleteShader(sh);
        return 0, false;
    }
    return sh, true;
}

paint_gl_frame :: (slot: *Gl_Slot, tri: Triangle, t: float) {
    GL.glBindFramebuffer(GL.GL_FRAMEBUFFER, slot.fbo);
    GL.glViewport(0, 0, slot.width, slot.height);
    GL.glClearColor(0.05, 0.05, 0.08, 1.0);   // dark background
    GL.glClear(GL.GL_COLOR_BUFFER_BIT);

    GL.glUseProgram(tri.program);
    GL.glUniform1f(tri.u_angle, t);
    GL.glBindVertexArray(tri.vao);
    GL.glDrawArrays(GL.GL_TRIANGLES, 0, 3);
    GL.glBindVertexArray(0);
    GL.glUseProgram(0);

    // Ensure GPU finished rendering before the compositor imports the
    // DMA-BUF. Fences would be finer-grained; glFinish is adequate here.
    GL.glFinish();
}
