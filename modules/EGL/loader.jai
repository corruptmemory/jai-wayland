// Runtime loader: dlopen libEGL.so.1 and resolve function pointers.
// init_egl()            — core entry points (safe to call before eglInitialize)
// init_egl_extensions() — extension entry points (requires an initialized display)

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
