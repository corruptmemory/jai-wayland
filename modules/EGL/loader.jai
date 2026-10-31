// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jim Powers

// Runtime loader: dlopen libEGL.so.1 and resolve function pointers.
// init_egl()            — core entry points (safe to call before eglInitialize)
// init_egl_extensions() — extension entry points (requires an initialized display)
// init_egl_fence_extensions() — native fence sync entry points, when the display has them

#import "Basic";
#import "POSIX";

init_egl :: () -> bool {
    egl_lib := dlopen("libEGL.so.1", RTLD_LAZY);
    if !egl_lib  egl_lib = dlopen("libEGL.so", RTLD_LAZY);
    if !egl_lib  return false;

    eglGetPlatformDisplay = xx dlsym(egl_lib, "eglGetPlatformDisplay");
    eglInitialize         = xx dlsym(egl_lib, "eglInitialize");
    eglTerminate          = xx dlsym(egl_lib, "eglTerminate");
    eglQueryString        = xx dlsym(egl_lib, "eglQueryString");
    eglBindAPI            = xx dlsym(egl_lib, "eglBindAPI");
    eglChooseConfig       = xx dlsym(egl_lib, "eglChooseConfig");
    eglCreateContext      = xx dlsym(egl_lib, "eglCreateContext");
    eglDestroyContext     = xx dlsym(egl_lib, "eglDestroyContext");
    eglMakeCurrent        = xx dlsym(egl_lib, "eglMakeCurrent");
    eglGetError           = xx dlsym(egl_lib, "eglGetError");
    eglGetProcAddress     = xx dlsym(egl_lib, "eglGetProcAddress");

    return eglGetPlatformDisplay != null && eglGetProcAddress != null;
}

init_egl_extensions :: (dpy: EGLDisplay) -> bool {
    eglCreateImageKHR             = xx eglGetProcAddress("eglCreateImageKHR");
    eglDestroyImageKHR            = xx eglGetProcAddress("eglDestroyImageKHR");
    eglExportDMABUFImageQueryMESA = xx eglGetProcAddress("eglExportDMABUFImageQueryMESA");
    eglExportDMABUFImageMESA      = xx eglGetProcAddress("eglExportDMABUFImageMESA");
    return eglCreateImageKHR != null && eglExportDMABUFImageMESA != null;
}

// True when `dpy` lists EGL_ANDROID_native_fence_sync (which requires EGL_KHR_fence_sync)
// and its three entry points load. Leaves them null otherwise, so callers fall back
// to glFinish. Requires an initialized display: extensions are per display.
init_egl_fence_extensions :: (dpy: EGLDisplay) -> bool {
    eglCreateSyncKHR           = null;
    eglDestroySyncKHR          = null;
    eglDupNativeFenceFDANDROID = null;

    extensions := eglQueryString(dpy, EGL_EXTENSIONS);
    if extensions == null  return false;
    if !egl_extension_listed(to_string(extensions), "EGL_ANDROID_native_fence_sync")  return false;

    create  := cast(type_of(eglCreateSyncKHR))           eglGetProcAddress("eglCreateSyncKHR");
    destroy := cast(type_of(eglDestroySyncKHR))          eglGetProcAddress("eglDestroySyncKHR");
    dup     := cast(type_of(eglDupNativeFenceFDANDROID)) eglGetProcAddress("eglDupNativeFenceFDANDROID");
    if create == null || destroy == null || dup == null  return false;

    eglCreateSyncKHR           = create;
    eglDestroySyncKHR          = destroy;
    eglDupNativeFenceFDANDROID = dup;
    return true;
}

// Whole-word match in a space-separated extension list.
egl_extension_listed :: (list: string, name: string) -> bool {
    rest := list;
    while rest.count > 0 {
        end := 0;
        while end < rest.count && rest[end] != #char " "  end += 1;
        word := string.{ count = end, data = rest.data };
        if word == name  return true;
        if end >= rest.count  break;
        rest.data  += end + 1;
        rest.count -= end + 1;
    }
    return false;
}
