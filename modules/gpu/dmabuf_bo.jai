// Shared GBM BO allocation and EGLImage import helpers.

#import "Basic";
#import "POSIX";
#import,dir "../EGL";
#import,dir "../gbm";

DRM_FORMAT_MOD_INVALID : u64 : 0x00ffffffffffffff;

supports_bo_format_modifier :: (gbm: Gbm_Device, format: u32, modifier: u64, flags: u32) -> bool {
    if !ensure_gbm_bo_runtime()  return false;

    if gbm_device_is_format_supported != null {
        if gbm_device_is_format_supported(gbm, format, flags) == 0  return false;
    }

    if modifier == DRM_FORMAT_MOD_INVALID  return true;

    if gbm_device_get_format_modifier_plane_count != null {
        return gbm_device_get_format_modifier_plane_count(gbm, format, modifier) > 0;
    }

    return true;
}

create_bo_with_modifier :: (gbm: Gbm_Device, width: s32, height: s32, format: u32, modifier: u64, flags: u32) -> Gbm_Bo {
    if !ensure_gbm_bo_runtime()  return null;

    if modifier == DRM_FORMAT_MOD_INVALID {
        return gbm_bo_create(gbm, cast(u32) width, cast(u32) height, format, flags);
    }

    modifiers := u64.[ modifier ];
    if gbm_bo_create_with_modifiers2 != null {
        return gbm_bo_create_with_modifiers2(gbm, cast(u32) width, cast(u32) height, format, modifiers.data, modifiers.count, flags);
    }
    if gbm_bo_create_with_modifiers != null {
        return gbm_bo_create_with_modifiers(gbm, cast(u32) width, cast(u32) height, format, modifiers.data, modifiers.count);
    }

    return gbm_bo_create(gbm, cast(u32) width, cast(u32) height, format, flags);
}

create_image_from_gbm_bo :: (dpy: EGLDisplay, bo: Gbm_Bo, fallback_width: s32, fallback_height: s32, verbose := false) -> EGLImage, s32, bool {
    if !ensure_egl_image_runtime(dpy)  return null, -1, false;
    if !ensure_gbm_bo_runtime()        return null, -1, false;

    image := eglCreateImageKHR(dpy, EGL_NO_CONTEXT, EGL_NATIVE_PIXMAP_KHR,
        cast(EGLClientBuffer) bo, null);
    if image != null {
        if verbose  log("BO EGLImage import: EGL_NATIVE_PIXMAP_KHR");
        return image, -1, true;
    }

    native_error := eglGetError();
    if verbose {
        log("BO EGLImage import: EGL_NATIVE_PIXMAP_KHR failed (err=0x%), trying EGL_LINUX_DMA_BUF_EXT",
            formatInt(native_error, base=16));
    }

    if gbm_bo_get_fd == null || gbm_bo_get_stride == null || gbm_bo_get_format == null {
        return null, -1, false;
    }

    fd := gbm_bo_get_fd(bo);
    if fd < 0  return null, -1, false;

    width := ifx gbm_bo_get_width != null then cast(s32) gbm_bo_get_width(bo) else fallback_width;
    height := ifx gbm_bo_get_height != null then cast(s32) gbm_bo_get_height(bo) else fallback_height;
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
        if verbose {
            log("BO EGLImage import: EGL_LINUX_DMA_BUF_EXT failed (err=0x%)",
                formatInt(eglGetError(), base=16));
        }
        close(fd);
        return null, -1, false;
    }

    if verbose {
        log("BO EGLImage import: EGL_LINUX_DMA_BUF_EXT fd=% stride=% modifier=0x%",
            fd, stride, formatInt(modifier, base=16));
    }
    return image, fd, true;
}

ensure_gbm_bo_runtime :: () -> bool {
    if gbm_bo_create == null {
        if !init_gbm()  return false;
    }

    return gbm_bo_create != null && gbm_bo_destroy != null;
}

ensure_egl_image_runtime :: (dpy: EGLDisplay) -> bool {
    if eglGetProcAddress == null {
        if !init_egl()  return false;
    }
    if eglCreateImageKHR == null {
        if !init_egl_extensions(dpy)  return false;
    }

    return eglCreateImageKHR != null;
}
