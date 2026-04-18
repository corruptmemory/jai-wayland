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
GL :: #import,dir "../modules/GL";

#import "Basic";
#import "Math";
#import "POSIX";

WIDTH  :: 640;
HEIGHT :: 480;

Gl_Slot :: struct {
    tex:       u32;
    fbo:       u32;
    image:     EGLImage;
    buffer:    Wl_Buffer;
    fd:        s32;
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

    // --- Triangle setup (shader, VAO, VBO) ---
    tri: Triangle;
    if !init_triangle(*tri) {
        print("Triangle setup failed\n");
        return;
    }

    // --- Pre-allocate two GL-backed buffer slots ---
    slots: [2] Gl_Slot;
    batch: MessageBuilder;
    for * slot, i: slots {
        if !init_slot(slot, egl, *dmabuf_info.dmabuf, *batch, format, modifier) {
            print("Failed to initialize slot %\n", i);
            return;
        }
    }
    wayland_send(*batch);

    // --- Paint slot 0 with the initial frame ---
    paint_gl_frame(*slots[0], tri, 0.0);

    // --- Create surface + xdg roles ---
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
    configure_serial: u32 = 0;
    for session() {
        if it.object_id == xdg_surface.id && it.opcode == XDG_SURFACE_CONFIGURE {
            configure_serial = read_u32(it.payload);
            break;
        }
    }
    if configure_serial == 0 {
        print("Did not receive xdg_surface.configure\n");
        return;
    }

    // --- Ack, attach slot 0, request first frame callback, commit ---
    frame_callback_id := allocate_id();
    xdg_surface_ack_configure(*batch, *xdg_surface, configure_serial);
    wl_surface_frame(*batch, *surface, frame_callback_id);
    wl_surface_attach(*batch, *surface, *slots[0].buffer, 0, 0);
    wl_surface_damage_buffer(*batch, *surface, 0, 0, WIDTH, HEIGHT);
    wl_surface_commit(*batch, *surface);
    wayland_send(*batch);
    slots[0].in_flight = true;
    frame_requested := true;

    print("hello_gl: animating. Close the window to exit.\n");

    // --- Main loop: frame-paced render-rotate ---
    //
    // `t` advances once per displayed frame. The clear color runs off
    // three phase-shifted sines for a rainbow cycle.
    //
    // The defer at the top of the body fires after every message: if
    // we're allowed to render (content wants repaint, compositor has
    // handed a frame back, a slot is free) we paint into the free slot
    // and re-arm the frame callback.
    dirty := true;
    t: float = 0.0;

    for session() {
        defer if dirty && !frame_requested {
            slot_idx := find_free_slot(slots);
            if slot_idx >= 0 {
                slot := *slots[slot_idx];
                paint_gl_frame(slot, tri, t);
                t += 0.02;   // ~0.2 rad/frame → ~2 sec per full rotation at 60Hz

                frame_callback_id = allocate_id();
                wl_surface_frame(*batch, *surface, frame_callback_id);
                wl_surface_attach(*batch, *surface, *slot.buffer, 0, 0);
                wl_surface_damage_buffer(*batch, *surface, 0, 0, WIDTH, HEIGHT);
                wl_surface_commit(*batch, *surface);
                wayland_send(*batch);

                slot.in_flight = true;
                frame_requested = true;
                dirty = false;
            }
        };

        // wl_buffer.release — mark slot available
        if it.opcode == WL_BUFFER_RELEASE {
            obj_id := it.object_id;
            for * slots  if it.buffer.id == obj_id {
                it.in_flight = false;
                break;
            }
            continue;
        }

        // wl_callback.done for the frame we most recently requested —
        // compositor has displayed the frame, we can pace the next.
        if it.object_id == frame_callback_id && it.opcode == WL_CALLBACK_DONE {
            frame_requested = false;
            dirty = true;    // continuous animation; Task 9 will flip this
                             // to input-driven
            continue;
        }

        if it.object_id == toplevel.id && it.opcode == XDG_TOPLEVEL_CLOSE {
            print("Close requested.\n");
            break;
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
    egl.drm_fd = open("/dev/dri/renderD128".data, O_RDWR | O_CLOEXEC);
    if egl.drm_fd < 0  return false;
    if !init_egl() || !init_gbm()  return false;

    egl.gbm = gbm_create_device(egl.drm_fd);
    if !egl.gbm  return false;

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
              batch: *MessageBuilder, format: u32, modifier: u64) -> bool
{
    GL.glGenTextures(1, *slot.tex);
    GL.glBindTexture(GL.GL_TEXTURE_2D, slot.tex);
    GL.glTexImage2D(GL.GL_TEXTURE_2D, 0, GL.GL_RGBA8, WIDTH, HEIGHT, 0,
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

    params := Zwp_Linux_Buffer_Params_V1.{ id = allocate_id() };
    zwp_linux_dmabuf_v1_create_params(batch, dmabuf, params.id);
    zwp_linux_buffer_params_v1_add(batch, *params,
        fd          = cast(Fd) fd,
        plane_idx   = 0,
        offset      = cast(u32) offset,
        stride      = cast(u32) stride,
        modifier_hi = cast(u32)(modifier >> 32),
        modifier_lo = cast(u32)(modifier & 0xFFFFFFFF));

    slot.buffer = Wl_Buffer.{ id = allocate_id() };
    zwp_linux_buffer_params_v1_create_immed(batch, *params,
        new_id = slot.buffer.id,
        width  = WIDTH,
        height = HEIGHT,
        format = format,
        flags  = 0);
    zwp_linux_buffer_params_v1_destroy(batch, *params);

    return true;
}

find_free_slot :: (slots: [] Gl_Slot) -> int {
    for slots  if !it.in_flight  return it_index;
    return -1;
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
    program:    u32;
    vao:        u32;
    vbo:        u32;
    u_angle:    GL.GLint;   // uniform location; may be -1 if optimized out
    r: float = 1.0;  g: float = 0.2; b: float = 0.2;   // vertex A color
    r2: float = 0.2; g2: float = 1.0; b2: float = 0.2; // vertex B color
    r3: float = 0.2; g3: float = 0.2; b3: float = 1.0; // vertex C color
}

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

    // Upload three vertices: equilateral triangle, R/G/B at each corner.
    // Jai expects the array literal's element type to match — float values
    // from constants need to be promoted explicitly.
    SQRT3_OVER_2 :: 0.8660254;
    verts := float.[
        //   x            y           r      g      b
             0.0,          0.7,       tri.r,  tri.g,  tri.b,
            -cast(float) SQRT3_OVER_2 * 0.7,  -0.35,  tri.r2, tri.g2, tri.b2,
             cast(float) SQRT3_OVER_2 * 0.7,  -0.35,  tri.r3, tri.g3, tri.b3,
    ];

    GL.glGenVertexArrays(1, *tri.vao);
    GL.glBindVertexArray(tri.vao);

    GL.glGenBuffers(1, *tri.vbo);
    GL.glBindBuffer(GL.GL_ARRAY_BUFFER, tri.vbo);
    GL.glBufferData(GL.GL_ARRAY_BUFFER, verts.count * size_of(float), verts.data, GL.GL_STATIC_DRAW);

    stride : GL.GLsizei = 5 * size_of(float);
    GL.glVertexAttribPointer(0, 2, GL.GL_FLOAT, GL.GL_FALSE, stride, cast(*void) 0);
    GL.glEnableVertexAttribArray(0);
    GL.glVertexAttribPointer(1, 3, GL.GL_FLOAT, GL.GL_FALSE, stride, cast(*void)(2 * size_of(float)));
    GL.glEnableVertexAttribArray(1);

    GL.glBindVertexArray(0);
    GL.glBindBuffer(GL.GL_ARRAY_BUFFER, 0);
    return true;
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
    GL.glViewport(0, 0, WIDTH, HEIGHT);
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
