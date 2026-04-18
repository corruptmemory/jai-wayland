// headless_gl — smoke test for the EGL+GL+gbm stack.
//
// Opens /dev/dri/renderD128 (the generic render node, no display privileges),
// creates a gbm_device, creates an EGL display via EGL_PLATFORM_GBM_KHR,
// creates a GL 3.3 core context, loads GL entry points through
// eglGetProcAddress, allocates an offscreen FBO, glClears to a known color,
// and reads back the center pixel to verify it matches.
//
// If this works, the hardest part of the dmabuf rendering path is proven:
// everything from here on is wiring, not discovery.
//
// Task 4 will extend this file to exercise the DMA-BUF export path.

#import,dir "../modules/EGL";
#import,dir "../modules/gbm";
GL :: #import "GL";
#import "Basic";
#import "POSIX";

main :: () {
    // 1. Open render node. /dev/dri/renderD128 is the non-privileged render
    //    node: rendering only, no KMS/modeset. Everyone in the `video` group
    //    can open it; no TTY/DRM master dance required.
    drm_fd := open("/dev/dri/renderD128".data, O_RDWR | O_CLOEXEC);
    assert(drm_fd >= 0, "Failed to open /dev/dri/renderD128 (check 'video' group membership)");
    defer close(drm_fd);

    // 2. Initialize dlopen'd libraries.
    assert(init_egl(), "EGL init failed (libEGL.so.1 not found?)");
    assert(init_gbm(), "gbm init failed (libgbm.so.1 not found?)");

    // 3. Create gbm_device — an opaque handle Mesa uses as the native
    //    display for EGL_PLATFORM_GBM_KHR.
    gbm := gbm_create_device(drm_fd);
    assert(gbm != null, "gbm_create_device failed");
    defer gbm_device_destroy(gbm);

    // 4. Create EGL display on top of gbm.
    dpy := eglGetPlatformDisplay(EGL_PLATFORM_GBM_KHR, gbm, null);
    assert(dpy != EGL_NO_DISPLAY, "eglGetPlatformDisplay failed");

    major, minor: EGLint;
    assert(eglInitialize(dpy, *major, *minor) == EGL_TRUE, "eglInitialize failed");
    print("EGL %.% initialized\n", major, minor);
    print("  vendor:  %\n", to_string(eglQueryString(dpy, EGL_VENDOR)));
    print("  version: %\n", to_string(eglQueryString(dpy, EGL_VERSION)));
    defer eglTerminate(dpy);

    // 5. Bind OpenGL API (not GLES), choose a PBUFFER-compatible config,
    //    create a GL 3.3 core context. We never actually use the PBUFFER —
    //    we render to FBOs — but eglChooseConfig insists on some surface
    //    type being set.
    assert(eglBindAPI(EGL_OPENGL_API) == EGL_TRUE, "eglBindAPI(OPENGL) failed");

    // Mesa's gbm platform advertises WINDOW-surface-capable configs, not
    // PBUFFER. We never bind a surface (render to FBOs only) but must still
    // satisfy eglChooseConfig's surface-type filter.
    config_attrs := s32.[
        EGL_SURFACE_TYPE,    EGL_WINDOW_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
        EGL_RED_SIZE,   8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE,  8,
        EGL_ALPHA_SIZE, 8,
        EGL_NONE,
    ];
    config: EGLConfig;
    num_configs: EGLint;
    assert(eglChooseConfig(dpy, config_attrs.data, *config, 1, *num_configs) == EGL_TRUE && num_configs > 0,
        "eglChooseConfig failed");

    ctx_attrs := s32.[
        EGL_CONTEXT_MAJOR_VERSION_KHR, 3,
        EGL_CONTEXT_MINOR_VERSION_KHR, 3,
        EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT_KHR,
        EGL_NONE,
    ];
    ctx := eglCreateContext(dpy, config, EGL_NO_CONTEXT, ctx_attrs.data);
    assert(ctx != EGL_NO_CONTEXT, "eglCreateContext failed (err=0x%)", formatInt(eglGetError(), base=16));
    defer eglDestroyContext(dpy, ctx);

    // Surfaceless: no draw/read surface. All rendering goes to FBOs.
    assert(eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx) == EGL_TRUE,
        "eglMakeCurrent failed");

    // 6. Load GL 3.3 core entry points. We hand Jai's GL loader our
    //    dlsym'd eglGetProcAddress; it walks the GL_Procedures struct
    //    and populates every function pointer.
    GL.gl_load(*GL.gl, eglGetProcAddress);
    major_gl, minor_gl := GL.gl_get_version();
    print("GL %.% loaded\n", major_gl, minor_gl);

    // 7. Create a color texture + framebuffer object, glClear to a
    //    distinctive color, read back the center pixel.
    WIDTH  :: 256;
    HEIGHT :: 256;

    tex: u32;
    GL.glGenTextures(1, *tex);
    GL.glBindTexture(GL.GL_TEXTURE_2D, tex);
    GL.glTexImage2D(GL.GL_TEXTURE_2D, 0, GL.GL_RGBA8, WIDTH, HEIGHT, 0, GL.GL_RGBA, GL.GL_UNSIGNED_BYTE, null);
    GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_MIN_FILTER, GL.GL_LINEAR);
    GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_MAG_FILTER, GL.GL_LINEAR);
    defer GL.glDeleteTextures(1, *tex);

    fbo: u32;
    GL.glGenFramebuffers(1, *fbo);
    GL.glBindFramebuffer(GL.GL_FRAMEBUFFER, fbo);
    GL.glFramebufferTexture2D(GL.GL_FRAMEBUFFER, GL.GL_COLOR_ATTACHMENT0, GL.GL_TEXTURE_2D, tex, 0);
    assert(GL.glCheckFramebufferStatus(GL.GL_FRAMEBUFFER) == GL.GL_FRAMEBUFFER_COMPLETE,
        "FBO not complete");
    defer GL.glDeleteFramebuffers(1, *fbo);

    GL.glViewport(0, 0, WIDTH, HEIGHT);
    GL.glClearColor(0.2, 0.6, 0.8, 1.0);
    GL.glClear(GL.GL_COLOR_BUFFER_BIT);

    pixel: [4] u8;
    GL.glReadPixels(128, 128, 1, 1, GL.GL_RGBA, GL.GL_UNSIGNED_BYTE, pixel.data);
    print("Center pixel RGBA: (%, %, %, %)\n", pixel[0], pixel[1], pixel[2], pixel[3]);

    // 0.2 * 255 = 51, 0.6 * 255 = 153, 0.8 * 255 = 204. Allow ±1 for rounding.
    assert(pixel[0] >= 50  && pixel[0] <= 52,  "red channel wrong: %",   pixel[0]);
    assert(pixel[1] >= 152 && pixel[1] <= 154, "green channel wrong: %", pixel[1]);
    assert(pixel[2] >= 203 && pixel[2] <= 205, "blue channel wrong: %",  pixel[2]);

    // 8. Cleanup is handled by defers above; explicit makeCurrent(no ctx)
    //    ensures no dangling binding before the context is destroyed.
    eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    print("OK — EGL+GL+gbm smoke test passed\n");
}
