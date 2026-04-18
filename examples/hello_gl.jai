// hello_gl — first GPU-rendered pixel on Wayland via dmabuf.
//
// Renders a solid-color frame into a GL texture, exports the texture's
// backing as a DMA-BUF fd, wraps that fd as a wl_buffer through
// zwp_linux_dmabuf_v1, and attaches it to an xdg_toplevel surface.
// No double-buffering, no frame pacing, no input — those come in
// Tasks 7-9. The goal here is "GL-rendered pixel appears on screen."

#import,dir "../modules/wayland";
#import,dir "../modules/EGL";
#import,dir "../modules/gbm";
GL :: #import,dir "../modules/GL";

#import "Basic";
#import "POSIX";

WIDTH  :: 640;
HEIGHT :: 480;

main :: () {
    if !init_wayland_session() {
        print("Failed to create Wayland session\n");
        return;
    }
    defer end_wayland_session();

    // --- Init EGL + GL stack (identical shape to headless_gl) ---
    drm_fd := open("/dev/dri/renderD128".data, O_RDWR | O_CLOEXEC);
    if drm_fd < 0 {
        print("Could not open /dev/dri/renderD128\n");
        return;
    }
    defer close(drm_fd);

    if !init_egl() || !init_gbm() {
        print("EGL/gbm init failed\n");
        return;
    }

    gbm := gbm_create_device(drm_fd);
    if !gbm {
        print("gbm_create_device failed\n");
        return;
    }
    defer gbm_device_destroy(gbm);

    dpy := eglGetPlatformDisplay(EGL_PLATFORM_GBM_KHR, gbm, null);
    if dpy == EGL_NO_DISPLAY {
        print("eglGetPlatformDisplay failed\n");
        return;
    }
    if eglInitialize(dpy, null, null) != EGL_TRUE {
        print("eglInitialize failed\n");
        return;
    }
    defer eglTerminate(dpy);

    if !init_egl_extensions(dpy) {
        print("EGL_MESA_image_dma_buf_export unavailable\n");
        return;
    }

    eglBindAPI(EGL_OPENGL_API);
    config_attrs := s32.[
        EGL_SURFACE_TYPE,    EGL_WINDOW_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_NONE,
    ];
    config: EGLConfig;
    num_configs: EGLint;
    if eglChooseConfig(dpy, config_attrs.data, *config, 1, *num_configs) != EGL_TRUE || num_configs == 0 {
        print("eglChooseConfig failed\n");
        return;
    }
    ctx_attrs := s32.[
        EGL_CONTEXT_MAJOR_VERSION_KHR, 3,
        EGL_CONTEXT_MINOR_VERSION_KHR, 3,
        EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT_KHR,
        EGL_NONE,
    ];
    ctx := eglCreateContext(dpy, config, EGL_NO_CONTEXT, ctx_attrs.data);
    if ctx == EGL_NO_CONTEXT {
        print("eglCreateContext failed (err=0x%)\n", formatInt(eglGetError(), base=16));
        return;
    }
    defer eglDestroyContext(dpy, ctx);

    eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx);
    if !GL.gl_load(eglGetProcAddress) {
        print("GL proc loading failed\n");
        return;
    }

    // --- Discover dmabuf and pick a format compatible with the export ---
    dmabuf_info, dmabuf_ok := get_dmabuf_info();
    if !dmabuf_ok {
        print("Compositor does not support zwp_linux_dmabuf_v1\n");
        return;
    }
    // Mesa exports GL_RGBA/GL_UNSIGNED_BYTE textures as ABGR8888 fourcc (bytes
    // R,G,B,A in memory). Request that as our preferred format; fall back to
    // ARGB/XRGB if the compositor somehow doesn't advertise ABGR (rare).
    format, modifier, have_format := pick_format(dmabuf_info, GBM_FORMAT_ABGR8888);
    if !have_format {
        format, modifier, have_format = pick_format(dmabuf_info, GBM_FORMAT_XBGR8888);
    }
    if !have_format {
        print("Compositor doesn't advertise ABGR8888 or XBGR8888\n");
        return;
    }
    print("Using format=0x% modifier=0x%\n",
        formatInt(format, base=16),
        formatInt(modifier, base=16));

    // --- Create the GL texture + FBO, paint once ---
    tex, fbo: u32;
    GL.glGenTextures(1, *tex);
    GL.glBindTexture(GL.GL_TEXTURE_2D, tex);
    GL.glTexImage2D(GL.GL_TEXTURE_2D, 0, GL.GL_RGBA8, WIDTH, HEIGHT, 0,
        GL.GL_RGBA, GL.GL_UNSIGNED_BYTE, null);
    GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_MIN_FILTER, GL.GL_LINEAR);
    GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_MAG_FILTER, GL.GL_LINEAR);

    GL.glGenFramebuffers(1, *fbo);
    GL.glBindFramebuffer(GL.GL_FRAMEBUFFER, fbo);
    GL.glFramebufferTexture2D(GL.GL_FRAMEBUFFER, GL.GL_COLOR_ATTACHMENT0,
        GL.GL_TEXTURE_2D, tex, 0);
    if GL.glCheckFramebufferStatus(GL.GL_FRAMEBUFFER) != GL.GL_FRAMEBUFFER_COMPLETE {
        print("FBO not complete\n");
        return;
    }

    GL.glViewport(0, 0, WIDTH, HEIGHT);
    GL.glClearColor(0.8, 0.3, 0.2, 1.0);   // distinctive orange-red
    GL.glClear(GL.GL_COLOR_BUFFER_BIT);
    GL.glFinish();   // ensure GPU finished rendering before we export

    // --- Export texture as DMA-BUF ---
    image := eglCreateImageKHR(dpy, ctx, EGL_GL_TEXTURE_2D_KHR,
        cast(EGLClientBuffer) cast(u64) tex, null);
    if !image {
        print("eglCreateImageKHR failed (err=0x%)\n", formatInt(eglGetError(), base=16));
        return;
    }
    defer eglDestroyImageKHR(dpy, image);

    fd, stride, offset: s32;
    if eglExportDMABUFImageMESA(dpy, image, *fd, *stride, *offset) != EGL_TRUE {
        print("eglExportDMABUFImageMESA failed\n");
        return;
    }
    print("Exported DMA-BUF: fd=% stride=% offset=%\n", fd, stride, offset);

    // --- Wrap the DMA-BUF as a wl_buffer via zwp_linux_dmabuf_v1 ---
    batch: MessageBuilder;
    params := Zwp_Linux_Buffer_Params_V1.{ id = allocate_id() };
    zwp_linux_dmabuf_v1_create_params(*batch, *dmabuf_info.dmabuf, params.id);

    zwp_linux_buffer_params_v1_add(*batch, *params,
        fd          = cast(Fd) fd,
        plane_idx   = 0,
        offset      = cast(u32) offset,
        stride      = cast(u32) stride,
        modifier_hi = cast(u32)(modifier >> 32),
        modifier_lo = cast(u32)(modifier & 0xFFFFFFFF));

    buffer := Wl_Buffer.{ id = allocate_id() };
    zwp_linux_buffer_params_v1_create_immed(*batch, *params,
        new_id = buffer.id,
        width  = WIDTH,
        height = HEIGHT,
        format = format,
        flags  = 0);

    // Params object is single-use; destroy it after create_immed so the
    // compositor can free its side. The wl_buffer outlives it.
    zwp_linux_buffer_params_v1_destroy(*batch, *params);

    // --- Create surface + xdg_surface + xdg_toplevel ---
    surface := Wl_Surface.{ id = allocate_id() };
    xdg_surface := Xdg_Surface.{ id = allocate_id() };
    toplevel := Xdg_Toplevel.{ id = allocate_id() };
    wl_compositor_create_surface(*batch, compositor(), surface.id);
    xdg_wm_base_get_xdg_surface(*batch, wm_base(), xdg_surface.id, *surface);
    xdg_surface_get_toplevel(*batch, *xdg_surface, toplevel.id);
    xdg_toplevel_set_title(*batch, *toplevel, "hello_gl");
    wl_surface_commit(*batch, *surface);
    wayland_send(*batch);

    // --- Wait for initial configure, then ack + attach + commit ---
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

    xdg_surface_ack_configure(*batch, *xdg_surface, configure_serial);
    wl_surface_attach(*batch, *surface, *buffer, 0, 0);
    wl_surface_damage_buffer(*batch, *surface, 0, 0, WIDTH, HEIGHT);
    wl_surface_commit(*batch, *surface);
    wayland_send(*batch);

    print("hello_gl: window should show a solid orange-red %x% area. Close to exit.\n", WIDTH, HEIGHT);

    // --- Minimal event loop: exit on toplevel.close ---
    for session() {
        if it.object_id == toplevel.id && it.opcode == XDG_TOPLEVEL_CLOSE {
            print("Close requested.\n");
            break;
        }
    }
}
