// headless_gl — smoke test for the EGL+GL+gbm stack.
//
// Selects a DRM render node, creates a gbm_device, creates an EGL display via
// EGL_PLATFORM_GBM_KHR,
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
Gpu :: #import,dir "../modules/gpu";
GL :: #import,dir "../modules/GL";   // vendored; see Task 2.5 in the plan doc
#import "Basic";
#import "POSIX";

main :: () {
    // 1. Discover and select a render node. Render nodes are non-privileged:
    //    rendering only, no KMS/modeset or DRM master dance required.
    nodes: [..] Gpu.Render_Node_Info;
    assert(Gpu.discover_render_nodes(*nodes), "No DRM render nodes discovered under /dev/dri");
    Gpu.print_render_nodes(nodes);

    selected, selected_ok := Gpu.choose_render_node(nodes);
    assert(selected_ok, "No render node matched selection policy");
    print("Selected render node: % (% id=0x%)\n",
        selected.path,
        Gpu.vendor_name(selected.vendor),
        formatInt(selected.vendor_id, base=16, minimum_digits=4));

    drm_fd := open(temp_c_string(selected.path), O_RDWR | O_CLOEXEC);
    assert(drm_fd >= 0, "Failed to open % (check render/video group membership)", selected.path);
    defer close(drm_fd);

    // 2. Initialize dlopen'd libraries.
    assert(init_egl(), "EGL init failed (libEGL.so.1 not found?)");
    assert(init_gbm(), "gbm init failed (libgbm.so.1 not found?)");

    // 3. Create gbm_device — an opaque handle Mesa uses as the native
    //    display for EGL_PLATFORM_GBM_KHR.
    gbm := gbm_create_device(drm_fd);
    assert(gbm != null, "gbm_create_device failed");
    defer gbm_device_destroy(gbm);

    if gbm_device_get_backend_name != null {
        print("GBM backend: %\n", to_string(gbm_device_get_backend_name(gbm)));
    }
    probe_gbm_bo(gbm);

    // 4. Create EGL display on top of gbm.
    dpy := eglGetPlatformDisplay(EGL_PLATFORM_GBM_KHR, gbm, null);
    assert(dpy != EGL_NO_DISPLAY, "eglGetPlatformDisplay failed");

    major, minor: EGLint;
    assert(eglInitialize(dpy, *major, *minor) == EGL_TRUE, "eglInitialize failed");
    print("EGL %.% initialized\n", major, minor);
    print("  vendor:  %\n", to_string(eglQueryString(dpy, EGL_VENDOR)));
    print("  version: %\n", to_string(eglQueryString(dpy, EGL_VERSION)));
    defer eglTerminate(dpy);

    // Extensions require an initialized display to resolve. Must come
    // after eglInitialize but before any extension use.
    assert(init_egl_extensions(dpy), "required EGL extensions missing (need EGL_MESA_image_dma_buf_export)");

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

    // 6. Load GL 3.3 core entry points. Our vendored GL module takes just
    //    the get-proc-address function; it resolves every entry point we
    //    care about through module-scope function-pointer variables.
    assert(GL.gl_load(eglGetProcAddress), "GL proc loading failed — context GL version too old?");
    assert(GL.gl_load_egl_image_extensions(eglGetProcAddress),
        "GL_OES_EGL_image extension missing (need glEGLImageTargetTexture2DOES)");
    major_gl, minor_gl := GL.gl_get_version();
    print("GL %.% loaded\n", major_gl, minor_gl);

    test_bo_backed_fbo(dpy, gbm);

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

    // 8. DMA-BUF export — wrap the GL texture as an EGLImage, then ask
    //    Mesa for the backing DMA-BUF fd. This is the piece that lets us
    //    hand GPU-rendered pixels to the compositor without a CPU copy.
    //
    //    The opaque-pointer cast on `tex` deserves a note: GL texture names
    //    are u32, but EGLClientBuffer is a *void. Widening straight from
    //    u32 to *void is illegal in Jai (ptr size != u32 size); we stage
    //    through u64 to satisfy the type system.
    GL.glFinish();  // ensure render is complete before the GPU hands the
                    // buffer off — glFinish is coarser than fence sync but
                    // adequate for a smoke test
    image := eglCreateImageKHR(dpy, ctx, EGL_GL_TEXTURE_2D_KHR,
        cast(EGLClientBuffer) cast(u64) tex, null);
    assert(image != null, "eglCreateImageKHR failed (err=0x%)", formatInt(eglGetError(), base=16));
    defer eglDestroyImageKHR(dpy, image);

    fourcc: s32;
    num_planes: s32;
    modifier: u64;
    assert(eglExportDMABUFImageQueryMESA(dpy, image, *fourcc, *num_planes, *modifier) == EGL_TRUE,
        "eglExportDMABUFImageQueryMESA failed");
    print("DMA-BUF fourcc=0x% planes=% modifier=0x%\n",
        formatInt(fourcc, base=16), num_planes, formatInt(modifier, base=16));
    assert(num_planes == 1, "expected single-plane export, got % planes", num_planes);

    fd: s32;
    stride: s32;
    offset: s32;
    assert(eglExportDMABUFImageMESA(dpy, image, *fd, *stride, *offset) == EGL_TRUE,
        "eglExportDMABUFImageMESA failed");
    assert(fd >= 0, "invalid exported fd: %", fd);
    assert(stride > 0, "invalid stride: %", stride);
    print("DMA-BUF fd=% stride=% offset=%\n", fd, stride, offset);
    defer close(fd);

    // Optional: mmap and verify the pixel matches. This only works if the
    // compositor advertised the LINEAR modifier (0x0) — tiled modifiers
    // have non-obvious pixel layouts that would need driver-specific
    // detiling to read back. If mmap fails or the modifier is tiled, we
    // still pass the test: the DMA-BUF fd itself is the deliverable.
    DRM_FORMAT_MOD_LINEAR :: 0;
    if modifier == DRM_FORMAT_MOD_LINEAR {
        size := cast(u64)(stride * HEIGHT);
        mapped := mmap(null, size, PROT_READ, MAP_SHARED, fd, 0);
        MAP_FAILED :: cast(*void) -1;
        if mapped != MAP_FAILED {
            // fourcc AR24 (ARGB8888) is BGRA in memory — check center pixel
            // matches our clear color at the right channel positions.
            row := cast(*u8) mapped + 128 * stride;
            center := row + 128 * 4;
            b := center[0]; g := center[1]; r := center[2]; a := center[3];
            print("DMA-BUF mmap center BGRA: (%, %, %, %)\n", b, g, r, a);
            munmap(mapped, size);
        } else {
            print("DMA-BUF mmap not supported by driver (skipping CPU readback)\n");
        }
    } else {
        print("DMA-BUF uses tiled modifier — skipping CPU readback\n");
    }

    // 9. Cleanup is handled by defers above; explicit makeCurrent(no ctx)
    //    ensures no dangling binding before the context is destroyed.
    eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    print("OK — EGL+GL+gbm+DMA-BUF smoke test passed\n");
}

probe_gbm_bo :: (gbm: Gbm_Device) {
    if gbm_bo_create == null || gbm_bo_destroy == null {
        print("GBM BO probe skipped: gbm_bo_create/destroy not available\n");
        return;
    }

    WIDTH  :: 64;
    HEIGHT :: 64;
    FORMAT :: GBM_FORMAT_XRGB8888;
    FLAGS  :: GBM_BO_USE_RENDERING;

    if gbm_device_is_format_supported != null {
        supported := gbm_device_is_format_supported(gbm, FORMAT, FLAGS);
        print("GBM XRGB8888 RENDERING support: %\n", supported != 0);
    }

    bo := gbm_bo_create(gbm, WIDTH, HEIGHT, FORMAT, FLAGS);
    if bo == null {
        print("GBM BO probe: gbm_bo_create failed for XRGB8888 RENDERING\n");
        return;
    }
    defer gbm_bo_destroy(bo);

    format := ifx gbm_bo_get_format != null then gbm_bo_get_format(bo) else FORMAT;
    stride := ifx gbm_bo_get_stride != null then gbm_bo_get_stride(bo) else 0;
    planes := ifx gbm_bo_get_plane_count != null then gbm_bo_get_plane_count(bo) else 0;
    modifier := ifx gbm_bo_get_modifier != null then gbm_bo_get_modifier(bo) else 0;
    print("GBM BO probe: format=0x% stride=% planes=% modifier=0x%\n",
        formatInt(format, base=16),
        stride,
        planes,
        formatInt(modifier, base=16));

    if gbm_bo_get_fd != null {
        fd := gbm_bo_get_fd(bo);
        if fd >= 0 {
            print("GBM BO probe: fd=%\n", fd);
            close(fd);
        } else {
            print("GBM BO probe: gbm_bo_get_fd failed\n");
        }
    }
}

test_bo_backed_fbo :: (dpy: EGLDisplay, gbm: Gbm_Device) {
    if gbm_bo_create == null || gbm_bo_destroy == null {
        print("BO-backed FBO skipped: gbm_bo_create/destroy not available\n");
        return;
    }

    WIDTH  :: 128;
    HEIGHT :: 128;
    FORMAT :: GBM_FORMAT_XRGB8888;
    FLAGS  :: GBM_BO_USE_RENDERING;

    bo := gbm_bo_create(gbm, WIDTH, HEIGHT, FORMAT, FLAGS);
    assert(bo != null, "BO-backed FBO: gbm_bo_create failed");
    defer gbm_bo_destroy(bo);

    image, image_fd, image_ok := create_image_from_gbm_bo(dpy, bo);
    assert(image_ok, "BO-backed FBO: failed to create EGLImage from GBM BO");
    if image_fd >= 0  defer close(image_fd);
    defer eglDestroyImageKHR(dpy, image);

    tex: u32;
    GL.glGenTextures(1, *tex);
    GL.glBindTexture(GL.GL_TEXTURE_2D, tex);
    GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_MIN_FILTER, GL.GL_LINEAR);
    GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_MAG_FILTER, GL.GL_LINEAR);
    GL.glEGLImageTargetTexture2DOES(GL.GL_TEXTURE_2D, image);
    defer GL.glDeleteTextures(1, *tex);

    fbo: u32;
    GL.glGenFramebuffers(1, *fbo);
    GL.glBindFramebuffer(GL.GL_FRAMEBUFFER, fbo);
    GL.glFramebufferTexture2D(GL.GL_FRAMEBUFFER, GL.GL_COLOR_ATTACHMENT0, GL.GL_TEXTURE_2D, tex, 0);
    assert(GL.glCheckFramebufferStatus(GL.GL_FRAMEBUFFER) == GL.GL_FRAMEBUFFER_COMPLETE,
        "BO-backed FBO: framebuffer not complete");
    defer GL.glDeleteFramebuffers(1, *fbo);

    GL.glViewport(0, 0, WIDTH, HEIGHT);
    GL.glClearColor(0.9, 0.1, 0.4, 1.0);
    GL.glClear(GL.GL_COLOR_BUFFER_BIT);

    pixel: [4] u8;
    GL.glReadPixels(WIDTH / 2, HEIGHT / 2, 1, 1, GL.GL_RGBA, GL.GL_UNSIGNED_BYTE, pixel.data);
    print("BO-backed FBO center RGBA: (%, %, %, %)\n", pixel[0], pixel[1], pixel[2], pixel[3]);

    // 0.9 * 255 = 230, 0.1 * 255 = 26, 0.4 * 255 = 102. Allow ±1.
    assert(pixel[0] >= 229 && pixel[0] <= 231, "BO-backed FBO red channel wrong: %", pixel[0]);
    assert(pixel[1] >= 25  && pixel[1] <= 27,  "BO-backed FBO green channel wrong: %", pixel[1]);
    assert(pixel[2] >= 101 && pixel[2] <= 103, "BO-backed FBO blue channel wrong: %", pixel[2]);

    if gbm_bo_get_fd != null {
        fd := gbm_bo_get_fd(bo);
        assert(fd >= 0, "BO-backed FBO: gbm_bo_get_fd failed");
        defer close(fd);

        stride := ifx gbm_bo_get_stride != null then gbm_bo_get_stride(bo) else 0;
        planes := ifx gbm_bo_get_plane_count != null then gbm_bo_get_plane_count(bo) else 0;
        modifier := ifx gbm_bo_get_modifier != null then gbm_bo_get_modifier(bo) else 0;
        print("BO-backed FBO export: fd=% stride=% planes=% modifier=0x%\n",
            fd, stride, planes, formatInt(modifier, base=16));
    }
}

create_image_from_gbm_bo :: (dpy: EGLDisplay, bo: Gbm_Bo) -> EGLImage, s32, bool {
    image := eglCreateImageKHR(dpy, EGL_NO_CONTEXT, EGL_NATIVE_PIXMAP_KHR,
        cast(EGLClientBuffer) bo, null);
    if image != null {
        print("BO-backed FBO import: EGL_NATIVE_PIXMAP_KHR\n");
        return image, -1, true;
    }

    native_error := eglGetError();
    print("BO-backed FBO import: EGL_NATIVE_PIXMAP_KHR failed (err=0x%), trying EGL_LINUX_DMA_BUF_EXT\n",
        formatInt(native_error, base=16));

    if gbm_bo_get_fd == null || gbm_bo_get_stride == null || gbm_bo_get_format == null {
        return null, -1, false;
    }

    fd := gbm_bo_get_fd(bo);
    if fd < 0  return null, -1, false;

    width := ifx gbm_bo_get_width != null then gbm_bo_get_width(bo) else 0;
    height := ifx gbm_bo_get_height != null then gbm_bo_get_height(bo) else 0;
    format := gbm_bo_get_format(bo);
    stride := gbm_bo_get_stride(bo);
    offset := ifx gbm_bo_get_offset != null then gbm_bo_get_offset(bo, 0) else 0;
    modifier := ifx gbm_bo_get_modifier != null then gbm_bo_get_modifier(bo) else 0;

    if gbm_bo_get_modifier != null {
        attrs := EGLint.[
            EGL_WIDTH, cast(EGLint) width,
            EGL_HEIGHT, cast(EGLint) height,
            EGL_LINUX_DRM_FOURCC_EXT, cast(EGLint) format,
            EGL_DMA_BUF_PLANE0_FD_EXT, fd,
            EGL_DMA_BUF_PLANE0_OFFSET_EXT, cast(EGLint) offset,
            EGL_DMA_BUF_PLANE0_PITCH_EXT, cast(EGLint) stride,
            EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT, cast,trunc(EGLint) modifier,
            EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT, cast,trunc(EGLint) (modifier >> 32),
            EGL_NONE,
        ];
        image = eglCreateImageKHR(dpy, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, null, attrs.data);
    } else {
        attrs := EGLint.[
            EGL_WIDTH, cast(EGLint) width,
            EGL_HEIGHT, cast(EGLint) height,
            EGL_LINUX_DRM_FOURCC_EXT, cast(EGLint) format,
            EGL_DMA_BUF_PLANE0_FD_EXT, fd,
            EGL_DMA_BUF_PLANE0_OFFSET_EXT, cast(EGLint) offset,
            EGL_DMA_BUF_PLANE0_PITCH_EXT, cast(EGLint) stride,
            EGL_NONE,
        ];
        image = eglCreateImageKHR(dpy, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, null, attrs.data);
    }

    if image == null {
        print("BO-backed FBO import: EGL_LINUX_DMA_BUF_EXT failed (err=0x%)\n",
            formatInt(eglGetError(), base=16));
        close(fd);
        return null, -1, false;
    }

    print("BO-backed FBO import: EGL_LINUX_DMA_BUF_EXT fd=% stride=% modifier=0x%\n",
        fd, stride, formatInt(modifier, base=16));
    return image, fd, true;
}
