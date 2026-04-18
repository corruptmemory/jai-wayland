// EGL types + enum constants + function-pointer declarations.
// Ported from ~/jai/jai/modules/Android/EGL/bindings.jai, with these differences:
//   - no #foreign libegl hard link (we runtime-dlopen in loader.jai)
//   - only the subset we actually use for the dmabuf rendering path

// Opaque handle types.
EGLDisplay      :: *void;
EGLConfig       :: *void;
EGLContext      :: *void;
EGLSurface      :: *void;
EGLImage        :: *void;   // aka EGLImageKHR
EGLClientBuffer :: *void;

EGLBoolean :: u32;
EGLint     :: s32;
EGLenum    :: u32;
EGLAttrib  :: s64;          // platform-dependent; s64 on x86_64 Linux

EGL_FALSE :: 0;
EGL_TRUE  :: 1;
EGL_NO_DISPLAY :: cast(EGLDisplay) null;
EGL_NO_CONTEXT :: cast(EGLContext) null;
EGL_NO_SURFACE :: cast(EGLSurface) null;

// Platform constants (EGL 1.5 + EGL_KHR_platform_gbm).
EGL_PLATFORM_GBM_KHR         :: 0x31D7;
EGL_PLATFORM_SURFACELESS_MESA :: 0x31DD;

// Config attributes we use.
EGL_ALPHA_SIZE         :: 0x3021;
EGL_BLUE_SIZE          :: 0x3022;
EGL_GREEN_SIZE         :: 0x3023;
EGL_RED_SIZE           :: 0x3024;
EGL_DEPTH_SIZE         :: 0x3025;
EGL_SURFACE_TYPE       :: 0x3033;
EGL_NONE               :: 0x3038;
EGL_RENDERABLE_TYPE    :: 0x3040;
EGL_OPENGL_API         :: 0x30A2;
EGL_OPENGL_BIT         :: 0x0008;
EGL_PBUFFER_BIT        :: 0x0001;

// Context creation (EGL_KHR_create_context).
EGL_CONTEXT_MAJOR_VERSION_KHR           :: 0x3098;
EGL_CONTEXT_MINOR_VERSION_KHR           :: 0x30FB;
EGL_CONTEXT_OPENGL_PROFILE_MASK         :: 0x30FD;
EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT_KHR :: 0x00000001;

// eglQueryString names.
EGL_VENDOR     :: 0x3053;
EGL_VERSION    :: 0x3054;
EGL_EXTENSIONS :: 0x3055;

// EGL_KHR_image_base targets.
EGL_GL_TEXTURE_2D_KHR :: 0x30B1;

// Core function pointers — populated by init_egl() via dlsym.
eglGetPlatformDisplay: #type (platform: EGLenum, native_display: *void, attrib_list: *EGLAttrib) -> EGLDisplay #c_call;
eglInitialize:         #type (dpy: EGLDisplay, major: *EGLint, minor: *EGLint) -> EGLBoolean #c_call;
eglTerminate:          #type (dpy: EGLDisplay) -> EGLBoolean #c_call;
eglQueryString:        #type (dpy: EGLDisplay, name: EGLint) -> *u8 #c_call;
eglBindAPI:            #type (api: EGLenum) -> EGLBoolean #c_call;
eglChooseConfig:       #type (dpy: EGLDisplay, attrib_list: *EGLint, configs: *EGLConfig, config_size: EGLint, num_config: *EGLint) -> EGLBoolean #c_call;
eglCreateContext:      #type (dpy: EGLDisplay, config: EGLConfig, share_context: EGLContext, attrib_list: *EGLint) -> EGLContext #c_call;
eglDestroyContext:     #type (dpy: EGLDisplay, ctx: EGLContext) -> EGLBoolean #c_call;
eglMakeCurrent:        #type (dpy: EGLDisplay, draw: EGLSurface, read: EGLSurface, ctx: EGLContext) -> EGLBoolean #c_call;
eglGetError:           #type () -> EGLint #c_call;
eglGetProcAddress:     #type (procname: *u8) -> *void #c_call;

// Extension function pointers — populated by init_egl_extensions() via eglGetProcAddress,
// which must be called AFTER eglInitialize (extensions are resolved per display).
eglCreateImageKHR:             #type (dpy: EGLDisplay, ctx: EGLContext, target: EGLenum, buffer: EGLClientBuffer, attrib_list: *EGLint) -> EGLImage #c_call;
eglDestroyImageKHR:            #type (dpy: EGLDisplay, image: EGLImage) -> EGLBoolean #c_call;
eglExportDMABUFImageQueryMESA: #type (dpy: EGLDisplay, image: EGLImage, fourcc: *s32, num_planes: *s32, modifiers: *u64) -> EGLBoolean #c_call;
eglExportDMABUFImageMESA:      #type (dpy: EGLDisplay, image: EGLImage, fds: *s32, strides: *s32, offsets: *s32) -> EGLBoolean #c_call;
