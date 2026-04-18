# OpenGL Rendering Integration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.
> **Branch:** `rendering-gl` — user creates; execute this plan there.

> **Amendment (2026-04-18, after Task 3):** The original draft of this plan reused `~/jai/jai/modules/GL/` via `gl_load(*gl, eglGetProcAddress)`, on the assumption that routing calls through a function-pointer table would avoid hard-linkage. It does not: `glad_core.jai` declares `gl_lib :: #library,system "libGL"` and has unconditional `#foreign gl_lib` procedure declarations (glBegin/glEnd/glColor4f etc. at lines 1968+), which cause `libGL.so` to be linked regardless of whether the `gl_load` path is taken. Additionally, `GL.jai` does `#import "Window_Type"` which on Linux pulls in `X11`, hard-linking `libX11/libxcb/libXau/libXdmcp`. The first `ldd build/headless_gl` after Task 3 showed all of these linked in. This is a direct violation of the project thesis (a from-scratch Wayland client should not have X11 libraries linked in). Task 2.5 below was inserted to vendor `modules/GL/` under the same runtime-dlopen pattern as EGL and gbm, and Tasks 3+ have been updated to import it. The original "reuse Jai's GL module" bullet below is retained as historical context and struck through.

**Goal:** Add GPU-accelerated rendering to jai-wayland via OpenGL 3.3 core, without introducing `libwayland-client.so` as a dependency. Render to GL textures, export them as DMA-BUF fds, wrap those as `wl_buffer` objects via `zwp_linux_dmabuf_v1`, present via the existing Wayland event loop.

**Architecture (Path B — gbm + linux-dmabuf, no libwayland):**
- EGL context via `EGL_PLATFORM_GBM_KHR`, targeting `/dev/dri/renderD128` (the generic render node — no display privileges needed)
- GL rendering to offscreen FBOs backed by textures
- `EGL_KHR_image_base` + `EGL_MESA_image_dma_buf_export` to extract backing DMA-BUF fds from rendered textures
- `zwp_linux_dmabuf_v1.create_params` + `.add` + `.create_immed` to wrap DMA-BUF fds as Wayland `wl_buffer` objects
- Attach to `wl_surface` via existing `wl_surface_attach` / `damage_buffer` / `commit` path
- Pace via `wl_surface.frame` callbacks (compositor-aligned v-sync)
- Double-buffered with two texture+FBO+DMA-BUF slots, cycling on `wl_buffer.release` (same pattern as `hello_window.jai`)

**Tech stack:** Jai, OpenGL 3.3 core (vendored into `modules/GL/`), EGL 1.5 (vendored into `modules/EGL/`), libgbm (vendored into `modules/gbm/`), `zwp_linux_dmabuf_v1` protocol (already generated into `modules/wayland/linux_dmabuf_v1/`). All three library modules use the same runtime-dlopen pattern — no `#foreign` declarations, no build-time linkage.

**What we reuse from Jai's standard modules:**
- ~~`~/jai/jai/modules/GL/` — GL function table + `gl_load(*gl, GetProcAddress)` loader. We pass in `eglGetProcAddress`, everything else is free (glad_core.jai covers GL 3.3 core + ~15 common extensions).~~ *Superseded by amendment — Jai's GL module hard-links `libGL` via `#foreign gl_lib` and pulls in X11 via `Window_Type`. Vendored into `modules/GL/` instead; see Task 2.5.*
- `~/jai/jai/modules/Android/EGL/bindings.jai` — 265-line reference for EGL types and enum constants; we PORT (not import) into `modules/EGL/` because Android's uses `#foreign libegl` hard-link and we need runtime dlopen.
- Jai's GL module is still used as a *reference* for function signatures, constant values, and the `gl_load` walk-the-struct-by-type_info pattern — we port selectively, we don't import.

**What we reuse from the already-generated `modules/wayland/`:**
- `zwp_linux_dmabuf_v1.create_params()` — request, no args → new `zwp_linux_buffer_params_v1`
- `zwp_linux_buffer_params_v1.add(fd, plane_idx, offset, stride, mod_hi, mod_lo)` — add a DMA-BUF plane
- `zwp_linux_buffer_params_v1.create_immed(new_id, w, h, format, flags)` — synchronously create `wl_buffer`
- `zwp_linux_dmabuf_v1.format` / `.modifier` events — compositor advertises supported formats
- `zwp_linux_dmabuf_feedback_v1` — newer API for modifier negotiation; optional, defer to v2 of this work

**Build/test commands:**
- `./build.sh` — still builds the main validation tool
- `./build.sh - hello_gl` — new: the GL smoke test (added in Task 9)
- `./build.sh - hello_window` — the existing shm example; MUST continue to work unchanged at every checkpoint
- `./build.sh - compile_test` — verifies the generated module still compiles against new EGL/gbm modules
- No unit tests for this work — verification is headless GL smoke tests (Tasks 4-5), on-screen visual tests (Tasks 6-9)

**Key invariants preserved:**
- **No libwayland dependency** — the project thesis. All shared libraries loaded via `dlopen`; nothing appears under `ldd main`.
- **No inversion of control** — application still owns its event loop; `hello_gl.jai` follows the same `for session() { ... }` pattern as `hello_window.jai`.
- **Wire ordering** — `allocate_id()` immediately before each `zwp_linux_buffer_params_v1.create_immed`, same rule as always.

---

## Pre-flight: create the branch

Run (as user, manually):
```bash
git checkout -b rendering-gl
```
All tasks below execute on that branch.

---

### Task 1: Vendor EGL type definitions + runtime loader

Foundation: the minimal EGL surface for Path B. We need the types, the platform-display entry point, context creation, image/fence extension infrastructure, and `eglGetProcAddress` to feed into Jai's GL loader.

**Files:**
- Create: `modules/EGL/module.jai` (entry point: `#load "egl.jai"; #load "loader.jai";`)
- Create: `modules/EGL/egl.jai` (types + function-pointer declarations)
- Create: `modules/EGL/loader.jai` (dlopen, populate function pointers)

**Step 1: Scaffold `modules/EGL/egl.jai`**

Port types and constants from `~/jai/jai/modules/Android/EGL/bindings.jai`. Minimum surface:

```jai
// Opaque handle types
EGLDisplay       :: *void;
EGLConfig        :: *void;
EGLContext       :: *void;
EGLSurface       :: *void;
EGLImage         :: *void;   // aka EGLImageKHR
EGLClientBuffer  :: *void;
EGLNativeDisplayType :: *void;

EGLBoolean :: u32;
EGLint     :: s32;
EGLenum    :: u32;
EGLAttrib  :: s64;            // platform-dependent; s64 on x86_64 Linux

EGL_FALSE :: 0;
EGL_TRUE  :: 1;
EGL_NO_DISPLAY :: cast(EGLDisplay) 0;
EGL_NO_CONTEXT :: cast(EGLContext) 0;
EGL_NO_SURFACE :: cast(EGLSurface) 0;

// Platform constants (from Mesa / EGL 1.5 + extensions)
EGL_PLATFORM_GBM_KHR  :: 0x31D7;
EGL_PLATFORM_SURFACELESS_MESA :: 0x31DD;

// Config attributes we use
EGL_SURFACE_TYPE       :: 0x3033;
EGL_RENDERABLE_TYPE    :: 0x3040;
EGL_OPENGL_API         :: 0x30A2;
EGL_OPENGL_BIT         :: 0x0008;
EGL_PBUFFER_BIT        :: 0x0001;
EGL_RED_SIZE           :: 0x3024;
EGL_GREEN_SIZE         :: 0x3023;
EGL_BLUE_SIZE          :: 0x3022;
EGL_ALPHA_SIZE         :: 0x3021;
EGL_DEPTH_SIZE         :: 0x3025;
EGL_NONE               :: 0x3038;

// Context creation (via EGL_KHR_create_context)
EGL_CONTEXT_MAJOR_VERSION_KHR   :: 0x3098;
EGL_CONTEXT_MINOR_VERSION_KHR   :: 0x30FB;
EGL_CONTEXT_OPENGL_PROFILE_MASK :: 0x30FD;
EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT_KHR :: 0x00000001;

// EGL_EXT_platform_base
EGL_EXTENSIONS :: 0x3055;

// EGL_KHR_image_base / EGL_MESA_image_dma_buf_export
EGL_GL_TEXTURE_2D_KHR :: 0x30B1;

// Function pointers — loaded at runtime in loader.jai
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

// Extensions (loaded via eglGetProcAddress in Task 5)
eglCreateImageKHR:             #type (dpy: EGLDisplay, ctx: EGLContext, target: EGLenum, buffer: EGLClientBuffer, attrib_list: *EGLint) -> EGLImage #c_call;
eglDestroyImageKHR:            #type (dpy: EGLDisplay, image: EGLImage) -> EGLBoolean #c_call;
eglExportDMABUFImageQueryMESA: #type (dpy: EGLDisplay, image: EGLImage, fourcc: *s32, num_planes: *s32, modifiers: *u64) -> EGLBoolean #c_call;
eglExportDMABUFImageMESA:      #type (dpy: EGLDisplay, image: EGLImage, fds: *s32, strides: *s32, offsets: *s32) -> EGLBoolean #c_call;
```

**Step 2: Write `modules/EGL/loader.jai`**

Standard dlopen pattern — use the same shape as the project's existing runtime-loaded libs (if any; if not, this is the first). Minimal version:

```jai
#import "POSIX";

init_egl :: () -> bool {
    egl_lib := dlopen("libEGL.so.1", RTLD_LAZY);
    if !egl_lib  egl_lib = dlopen("libEGL.so", RTLD_LAZY);
    if !egl_lib  return false;

    // Core entry points — straight symbol lookup
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

    // Extensions get loaded after eglInitialize (when display is known)
    return eglGetPlatformDisplay != null;
}

init_egl_extensions :: (dpy: EGLDisplay) -> bool {
    eglCreateImageKHR             = xx eglGetProcAddress("eglCreateImageKHR");
    eglDestroyImageKHR            = xx eglGetProcAddress("eglDestroyImageKHR");
    eglExportDMABUFImageQueryMESA = xx eglGetProcAddress("eglExportDMABUFImageQueryMESA");
    eglExportDMABUFImageMESA      = xx eglGetProcAddress("eglExportDMABUFImageMESA");
    return eglCreateImageKHR != null && eglExportDMABUFImageMESA != null;
}
```

**Step 3: Build**

Run: `./build.sh`
Expected: compiles. No runtime uses yet; this task just verifies the bindings typecheck.

**Step 4: Commit**

```bash
git add modules/EGL/
git commit -m "feat: vendor EGL bindings with runtime dlopen"
```

---

### Task 2: Vendor libgbm bindings

Tiny module — gbm's public API is ~10 functions, all trivially typed. No Jai reference to port from.

**Files:**
- Create: `modules/gbm/module.jai`
- Create: `modules/gbm/gbm.jai`
- Create: `modules/gbm/loader.jai`

**Step 1: Write `modules/gbm/gbm.jai`**

```jai
Gbm_Device :: *void;
Gbm_Bo     :: *void;

// Usage flags
GBM_BO_USE_SCANOUT     :: 1 << 0;
GBM_BO_USE_CURSOR      :: 1 << 1;
GBM_BO_USE_RENDERING   :: 1 << 2;
GBM_BO_USE_WRITE       :: 1 << 3;
GBM_BO_USE_LINEAR      :: 1 << 4;

// Format: DRM fourcc codes — define the ones we use
gbm_fourcc :: (a: u8, b: u8, c: u8, d: u8) -> u32 #expand {
    return cast(u32) a | (cast(u32) b << 8) | (cast(u32) c << 16) | (cast(u32) d << 24);
}
GBM_FORMAT_XRGB8888 :: #run gbm_fourcc(#char "X", #char "R", #char "2", #char "4");
GBM_FORMAT_ARGB8888 :: #run gbm_fourcc(#char "A", #char "R", #char "2", #char "4");
GBM_FORMAT_ABGR8888 :: #run gbm_fourcc(#char "A", #char "B", #char "2", #char "4");

// Function pointers
gbm_create_device: #type (fd: s32) -> Gbm_Device #c_call;
gbm_device_destroy: #type (gbm: Gbm_Device) #c_call;
gbm_device_get_fd: #type (gbm: Gbm_Device) -> s32 #c_call;
// bo_create / bo_destroy not needed for our path (we render to GL textures, not gbm BOs directly)
// Keeping the module minimal — add more only when needed
```

**Step 2: Write `modules/gbm/loader.jai`**

```jai
#import "POSIX";

init_gbm :: () -> bool {
    gbm_lib := dlopen("libgbm.so.1", RTLD_LAZY);
    if !gbm_lib  gbm_lib = dlopen("libgbm.so", RTLD_LAZY);
    if !gbm_lib  return false;

    gbm_create_device  = xx dlsym(gbm_lib, "gbm_create_device");
    gbm_device_destroy = xx dlsym(gbm_lib, "gbm_device_destroy");
    gbm_device_get_fd  = xx dlsym(gbm_lib, "gbm_device_get_fd");
    return gbm_create_device != null;
}
```

**Step 3: Build + commit**

```bash
./build.sh  # expect clean compile
git add modules/gbm/
git commit -m "feat: vendor minimal libgbm bindings"
```

---

### Task 2.5: Vendor minimal GL bindings (inserted by amendment)

**Why this exists:** The original plan reused `~/jai/jai/modules/GL/` via `gl_load(*gl, eglGetProcAddress)`. That turned out to hard-link `libGL` (via `#foreign gl_lib` declarations in `glad_core.jai`) and `libX11/libxcb/libXau/libXdmcp` (via `#import "Window_Type"` in `GL.jai`). We vendor our own minimal GL module under the same runtime-dlopen pattern as EGL and gbm.

**Scope:** just the GL entry points this project uses — ~15 for Tasks 3–7 (texture + FBO + clear + readback + version query) and ~25 more for Task 8 (shader compile/link, VAO/VBO, uniforms, draw call). Task 8's additions can be added *when Task 8 lands* — this task only needs the Tasks 3–7 surface.

**Files:**
- Create: `modules/GL/module.jai` (`#load "gl.jai"; #load "loader.jai";`)
- Create: `modules/GL/gl.jai` — types, constants, function-pointer variable declarations
- Create: `modules/GL/loader.jai` — `gl_load(get_proc_address)` that populates all pointers via eglGetProcAddress, plus a `gl_get_version` helper

**Key pattern:**

```jai
// gl.jai
GLenum     :: u32;
GLboolean  :: u8;
GLbitfield :: u32;
GLint      :: s32;
GLuint     :: u32;
GLsizei    :: s32;
GLfloat    :: float32;
GLchar     :: u8;
GLintptr   :: s64;     // x86_64 Linux
GLsizeiptr :: s64;

// Only the constants we actually use — add more as Tasks 6/8 need them.
GL_FALSE :: 0;
GL_TRUE  :: 1;
GL_COLOR_BUFFER_BIT :: 0x00004000;
GL_TEXTURE_2D        :: 0x0DE1;
GL_RGBA              :: 0x1908;
GL_RGBA8             :: 0x8058;
GL_UNSIGNED_BYTE     :: 0x1401;
GL_LINEAR            :: 0x2601;
GL_TEXTURE_MIN_FILTER :: 0x2801;
GL_TEXTURE_MAG_FILTER :: 0x2800;
GL_FRAMEBUFFER          :: 0x8D40;
GL_COLOR_ATTACHMENT0    :: 0x8CE0;
GL_FRAMEBUFFER_COMPLETE :: 0x8CD5;
GL_MAJOR_VERSION :: 0x821B;
GL_MINOR_VERSION :: 0x821C;

// Function pointers populated by gl_load().
glGenTextures:       #type (n: GLsizei, textures: *GLuint) #c_call;
glBindTexture:       #type (target: GLenum, texture: GLuint) #c_call;
glTexImage2D:        #type (target: GLenum, level: GLint, internalformat: GLint, width: GLsizei, height: GLsizei, border: GLint, format: GLenum, type: GLenum, pixels: *void) #c_call;
glTexParameteri:     #type (target: GLenum, pname: GLenum, param: GLint) #c_call;
glDeleteTextures:    #type (n: GLsizei, textures: *GLuint) #c_call;
glGenFramebuffers:   #type (n: GLsizei, framebuffers: *GLuint) #c_call;
glBindFramebuffer:   #type (target: GLenum, framebuffer: GLuint) #c_call;
glFramebufferTexture2D:  #type (target: GLenum, attachment: GLenum, textarget: GLenum, texture: GLuint, level: GLint) #c_call;
glCheckFramebufferStatus:#type (target: GLenum) -> GLenum #c_call;
glDeleteFramebuffers:    #type (n: GLsizei, framebuffers: *GLuint) #c_call;
glViewport:          #type (x: GLint, y: GLint, width: GLsizei, height: GLsizei) #c_call;
glClearColor:        #type (r: GLfloat, g: GLfloat, b: GLfloat, a: GLfloat) #c_call;
glClear:             #type (mask: GLbitfield) #c_call;
glReadPixels:        #type (x: GLint, y: GLint, width: GLsizei, height: GLsizei, format: GLenum, type: GLenum, pixels: *void) #c_call;
glFinish:            #type () #c_call;
glGetIntegerv:       #type (pname: GLenum, data: *GLint) #c_call;
glGetString:         #type (name: GLenum) -> *u8 #c_call;
```

```jai
// loader.jai
GL_Get_Proc_Address :: #type (procname: *u8) -> *void #c_call;

gl_load :: (get_proc: GL_Get_Proc_Address) -> bool {
    // Each line: pointer = xx get_proc("name");
    // Return false if any required pointer is null.
    // ... (one line per function)
}

gl_get_version :: () -> major: s32, minor: s32 {
    major, minor: s32;
    glGetIntegerv(GL_MAJOR_VERSION, *major);
    glGetIntegerv(GL_MINOR_VERSION, *minor);
    return major, minor;
}
```

**Verification:**

1. `./build.sh` compiles — bindings typecheck, unused so no runtime exercise yet.
2. After redoing Task 3 (below) with this module:
   ```bash
   ldd build/headless_gl | grep -cE 'libGL|libX11|libxcb|libXau|libXdmcp'
   ```
   expect `0`. Only `libc.so.6` and whatever POSIX pulls in for `dlopen` should appear.

**Commit:**
```bash
git add modules/GL/ examples/headless_gl.jai
git commit -m "feat: vendor minimal GL bindings (plan amendment: no libGL/X11 linkage)"
```

---

### Task 3: Headless EGL+GL smoke test

**The critical early checkpoint.** Before touching Wayland, prove the full EGL+GL+gbm stack works: open render node, create gbm device, create EGL display, create GL 3.3 core context, `gl_load`, allocate FBO, `glClear` to a known color, read back the pixel. If this works, the rest of Phase 5 is plumbing. If it doesn't, stop and debug before going further.

**Files:**
- Create: `examples/headless_gl.jai` — standalone diagnostic, not shipped long-term but useful for regression testing and debugging

**Step 1: Write the smoke test**

```jai
#import,dir "../modules/EGL";
#import,dir "../modules/gbm";
GL :: #import,dir "../modules/GL";   // vendored; see Task 2.5
#import "Basic";
#import "POSIX";

main :: () {
    // 1. Open render node
    drm_fd := open("/dev/dri/renderD128".data, O_RDWR | O_CLOEXEC);
    assert(drm_fd >= 0, "Failed to open /dev/dri/renderD128");

    // 2. Initialize libraries
    assert(init_egl(),  "EGL init failed");
    assert(init_gbm(), "gbm init failed");

    // 3. Create gbm device
    gbm := gbm_create_device(drm_fd);
    assert(gbm != null, "gbm_create_device failed");

    // 4. Create EGL display via gbm platform
    dpy := eglGetPlatformDisplay(EGL_PLATFORM_GBM_KHR, gbm, null);
    assert(dpy != EGL_NO_DISPLAY, "eglGetPlatformDisplay failed");

    major, minor: EGLint;
    assert(eglInitialize(dpy, *major, *minor) == EGL_TRUE, "eglInitialize failed");
    print("EGL %.% initialized\n", major, minor);
    print("EGL vendor:     %\n", to_string(eglQueryString(dpy, 0x3053)));  // EGL_VENDOR
    print("EGL extensions: %\n", to_string(eglQueryString(dpy, EGL_EXTENSIONS)));

    // 5. Bind OpenGL API + choose config + create context
    assert(eglBindAPI(EGL_OPENGL_API) == EGL_TRUE);

    config_attrs := s32.[
        EGL_SURFACE_TYPE,    EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
        EGL_RED_SIZE,   8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE,  8,
        EGL_ALPHA_SIZE, 8,
        EGL_NONE,
    ];
    config: EGLConfig;
    n: EGLint;
    assert(eglChooseConfig(dpy, config_attrs.data, *config, 1, *n) == EGL_TRUE && n > 0);

    ctx_attrs := s32.[
        EGL_CONTEXT_MAJOR_VERSION_KHR, 3,
        EGL_CONTEXT_MINOR_VERSION_KHR, 3,
        EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT_KHR,
        EGL_NONE,
    ];
    ctx := eglCreateContext(dpy, config, EGL_NO_CONTEXT, ctx_attrs.data);
    assert(ctx != EGL_NO_CONTEXT, "eglCreateContext failed (err=0x%)", formatInt(eglGetError(), base=16));

    // Surfaceless: no draw/read surface
    assert(eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx) == EGL_TRUE);

    // 6. Load GL procedures + verify. Vendored GL module uses module-scope
    // function-pointer variables (no gl struct), so the load call is simpler
    // than Jai's stock module.
    assert(GL.gl_load(eglGetProcAddress), "GL proc loading failed");
    major_gl, minor_gl := GL.gl_get_version();
    print("GL %.% loaded\n", major_gl, minor_gl);

    // 7. Create FBO + color texture, glClear, readback
    tex: u32;
    GL.glGenTextures(1, *tex);
    GL.glBindTexture(GL.GL_TEXTURE_2D, tex);
    GL.glTexImage2D(GL.GL_TEXTURE_2D, 0, GL.GL_RGBA8, 256, 256, 0, GL.GL_RGBA, GL.GL_UNSIGNED_BYTE, null);
    GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_MIN_FILTER, GL.GL_LINEAR);
    GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_MAG_FILTER, GL.GL_LINEAR);

    fbo: u32;
    GL.glGenFramebuffers(1, *fbo);
    GL.glBindFramebuffer(GL.GL_FRAMEBUFFER, fbo);
    GL.glFramebufferTexture2D(GL.GL_FRAMEBUFFER, GL.GL_COLOR_ATTACHMENT0, GL.GL_TEXTURE_2D, tex, 0);
    assert(GL.glCheckFramebufferStatus(GL.GL_FRAMEBUFFER) == GL.GL_FRAMEBUFFER_COMPLETE);

    GL.glViewport(0, 0, 256, 256);
    GL.glClearColor(0.2, 0.6, 0.8, 1.0);    // distinctive color
    GL.glClear(GL.GL_COLOR_BUFFER_BIT);

    // Readback and verify
    pixel: [4] u8;
    GL.glReadPixels(128, 128, 1, 1, GL.GL_RGBA, GL.GL_UNSIGNED_BYTE, pixel.data);
    print("Center pixel RGBA: %, %, %, %\n", pixel[0], pixel[1], pixel[2], pixel[3]);
    assert(pixel[0] == 51 && pixel[1] == 153 && pixel[2] == 204, "pixel not what we cleared to");

    // 8. Cleanup
    GL.glDeleteFramebuffers(1, *fbo);
    GL.glDeleteTextures(1, *tex);
    eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroyContext(dpy, ctx);
    eglTerminate(dpy);
    gbm_device_destroy(gbm);
    close(drm_fd);
    print("OK — EGL+GL+gbm smoke test passed\n");
}
```

**Step 2: Add build target**

Modify `first.jai`: add `case "headless_gl";` alongside the other example cases.

**Step 3: Build + run**

Run: `./build.sh - headless_gl`
Expected:
- Clean compile
- Runtime prints EGL version, GL version, center pixel RGBA (approximately 51, 153, 204, 255)
- "OK" at the end

If this fails, **stop and debug**. Common causes:
- `/dev/dri/renderD128` not accessible (check permissions — needs `video` group membership)
- Mesa driver doesn't support `EGL_PLATFORM_GBM_KHR` (rare on AMD/Intel, happens on some nvidia configs)
- GL 3.3 core not available (very unlikely on modern Mesa)

**Step 4: Commit**

```bash
git add examples/headless_gl.jai first.jai
git commit -m "feat: headless EGL+GL+gbm smoke test"
```

---

### Task 4: DMA-BUF export pipeline

Verify we can export a GL-rendered texture as a DMA-BUF fd and read its pixels via mmap. This is the glue between "we have GL pixels" and "we have a handle we can share with the compositor."

**Files:**
- Modify: `examples/headless_gl.jai` — extend the smoke test

**Step 1: Load extension function pointers**

After `eglInitialize`, call:
```jai
assert(init_egl_extensions(dpy), "EGL_MESA_image_dma_buf_export not available");
```

**Step 2: After the glClear, export the texture as DMA-BUF**

Add after the readback assertion:

```jai
// Export texture as DMA-BUF
image := eglCreateImageKHR(dpy, ctx, EGL_GL_TEXTURE_2D_KHR, cast(EGLClientBuffer) cast(u64) tex, null);
assert(image != null, "eglCreateImageKHR failed (err=0x%)", formatInt(eglGetError(), base=16));

fourcc: s32;
num_planes: s32;
modifier: u64;
assert(eglExportDMABUFImageQueryMESA(dpy, image, *fourcc, *num_planes, *modifier) == EGL_TRUE);
print("DMA-BUF fourcc=0x%, planes=%, modifier=0x%\n",
    formatInt(fourcc, base=16), num_planes, formatInt(modifier, base=16));
assert(num_planes == 1, "expected single-plane export, got % planes", num_planes);

fd: s32;
stride: s32;
offset: s32;
assert(eglExportDMABUFImageMESA(dpy, image, *fd, *stride, *offset) == EGL_TRUE);
print("DMA-BUF fd=%, stride=%, offset=%\n", fd, stride, offset);
assert(fd >= 0 && stride > 0);

// Verify: mmap the DMA-BUF and check the center pixel matches what GL rendered
size := cast(s64)(stride * 256);
mapped := mmap(null, cast(u64) size, PROT_READ, MAP_SHARED, fd, 0);
if mapped != cast(*void) -1 {
    row := cast(*u8) mapped + 128 * stride;
    center := cast(*u32)(row + 128 * 4);
    print("Center pixel from DMA-BUF (hex): %\n", formatInt(<<center, base=16));
    munmap(mapped, cast(u64) size);
}
// Note: not all drivers allow CPU mmap of GPU-allocated DMA-BUFs;
// the LINEAR modifier (0x0) guarantees mmappable layout.

close(fd);
eglDestroyImageKHR(dpy, image);
```

**Step 3: Build + run**

Run: `./build.sh - headless_gl`
Expected additions:
- DMA-BUF fourcc prints (likely `0x34325241` = `AR24` = `DRM_FORMAT_ARGB8888`, or a variant)
- Single plane, reasonable stride (~1024 for 256×4bpp — or padded higher)
- If `modifier=0x0` (LINEAR), CPU readback should show the cleared color
- If modifier is tiled, readback may show garbage — that's fine at this stage, means the DMA-BUF exists but isn't linearly addressable

**Step 4: Commit**

```bash
git add examples/headless_gl.jai
git commit -m "feat: GL texture → DMA-BUF export via EGL_MESA"
```

---

### Task 5: Bind `zwp_linux_dmabuf_v1` + format/modifier discovery

Wire up the Wayland side. Extend the existing `WaylandSession` infrastructure to discover the linux-dmabuf global and enumerate what formats the compositor supports.

**Files:**
- Create: `modules/wayland/dmabuf.jai` — session-level helper, parallel to `output.jai` / `input.jai`

**Step 1: Write `modules/wayland/dmabuf.jai`**

```jai
#import "Basic";

Dmabuf_Info :: struct {
    dmabuf: Zwp_Linux_Dmabuf_V1;
    // Supported (format, modifier) pairs advertised by the compositor via .modifier events.
    // Format is a DRM fourcc; modifier is split into (modifier_hi, modifier_lo) on the wire.
    Format_Mod :: struct { format: u32; modifier: u64; }
    supported: [..] Format_Mod;
}

// Discover zwp_linux_dmabuf_v1 from the session's registry and enumerate supported format+modifier pairs.
// Returns info + true if the compositor supports linux-dmabuf v3+ (the version with modifier events).
get_dmabuf_info :: () -> Dmabuf_Info, bool {
    info: Dmabuf_Info;

    global := find_global("zwp_linux_dmabuf_v1");
    if !global  return info, false;

    info.dmabuf = Zwp_Linux_Dmabuf_V1.{ id = allocate_id() };

    batch: MessageBuilder;
    wl_registry_bind(*batch, registry(), *info.dmabuf);

    display := Wl_Display.{ id = 1 };
    sync_id := allocate_id();
    wl_display_sync(*batch, *display, sync_id);
    wayland_send(*batch);

    for session() {
        if it.object_id == sync_id  break;
        if it.object_id == info.dmabuf.id {
            event: Zwp_Linux_Dmabuf_V1_Event;
            unmarshal_event(*event, it.opcode, it.payload, recv);
            if event.kind == .MODIFIER {
                fm := array_add(*info.supported);
                fm.format = event.modifier.format;
                fm.modifier = (cast(u64) event.modifier.modifier_hi << 32) | cast(u64) event.modifier.modifier_lo;
            }
            // .FORMAT events are the legacy v1 signal; we prefer .MODIFIER from v3
        }
    }

    return info, true;
}

// Pick a (format, modifier) pair matching the requested format, preferring LINEAR if available.
DRM_FORMAT_MOD_LINEAR :: 0;
DRM_FORMAT_MOD_INVALID :: 0x00ffffffffffffff;

pick_format :: (info: Dmabuf_Info, preferred_fourcc: u32) -> format: u32, modifier: u64, found: bool {
    // First pass: LINEAR modifier for preferred format
    for info.supported {
        if it.format == preferred_fourcc && it.modifier == DRM_FORMAT_MOD_LINEAR {
            return it.format, it.modifier, true;
        }
    }
    // Second pass: any modifier for preferred format
    for info.supported {
        if it.format == preferred_fourcc  return it.format, it.modifier, true;
    }
    return 0, 0, false;
}
```

**Step 2: Wire up in a quick test**

Extend `examples/hello_globals.jai` (or add a new `examples/hello_dmabuf.jai` if you want to keep hello_globals minimal) to call `get_dmabuf_info()` and print what the compositor advertises. This validates the discovery path without needing full rendering yet.

**Step 3: Build + run** against a live Hyprland session:
```bash
./build.sh - hello_globals  # or hello_dmabuf
```
Expected: prints a list of (fourcc, modifier) pairs. You should see at least `ARGB8888`/`XRGB8888` with modifier `0x0` (LINEAR) and probably some tiled modifiers.

**Step 4: Commit**

```bash
git add modules/wayland/dmabuf.jai modules/wayland/module.jai first.jai examples/
git commit -m "feat: zwp_linux_dmabuf_v1 discovery (get_dmabuf_info)"
```

---

### Task 6: First on-screen pixel from GPU

Wire the DMA-BUF export → wl_buffer path, attach to a surface, commit. No frame pacing yet, no input — just "GL-rendered texture appears on screen." Once this works, the hard part is done.

**Files:**
- Create: `examples/hello_gl.jai` — initial skeleton (will grow in Tasks 7-9)

**Step 1: Minimal hello_gl.jai**

```jai
#import,dir "../modules/wayland";
#import,dir "../modules/EGL";
#import,dir "../modules/gbm";
GL :: #import,dir "../modules/GL";   // vendored; see Task 2.5
#import "Basic";
#import "POSIX";

main :: () {
    if !init_wayland_session() { print("no wayland\n"); return; }
    defer end_wayland_session();

    // --- Init EGL/GL stack ---
    drm_fd := open("/dev/dri/renderD128".data, O_RDWR | O_CLOEXEC);
    assert(drm_fd >= 0);
    assert(init_egl() && init_gbm());
    gbm := gbm_create_device(drm_fd);
    dpy := eglGetPlatformDisplay(EGL_PLATFORM_GBM_KHR, gbm, null);
    eglInitialize(dpy, null, null);
    assert(init_egl_extensions(dpy));
    eglBindAPI(EGL_OPENGL_API);
    // (config + context creation as in headless_gl.jai)
    // ...
    eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx);
    GL.gl_load(eglGetProcAddress);

    // --- Discover dmabuf ---
    dmabuf_info, ok := get_dmabuf_info();
    assert(ok, "compositor doesn't support zwp_linux_dmabuf_v1");
    format, modifier, found := pick_format(dmabuf_info, GBM_FORMAT_XRGB8888);
    assert(found, "compositor doesn't advertise XRGB8888");

    // --- Create GL texture + FBO + export as DMA-BUF + wrap as wl_buffer ---
    WIDTH  :: 640;
    HEIGHT :: 480;
    tex, fbo: u32;
    GL.glGenTextures(1, *tex);
    GL.glBindTexture(GL.GL_TEXTURE_2D, tex);
    GL.glTexImage2D(GL.GL_TEXTURE_2D, 0, GL.GL_RGBA8, WIDTH, HEIGHT, 0, GL.GL_RGBA, GL.GL_UNSIGNED_BYTE, null);
    GL.glGenFramebuffers(1, *fbo);
    GL.glBindFramebuffer(GL.GL_FRAMEBUFFER, fbo);
    GL.glFramebufferTexture2D(GL.GL_FRAMEBUFFER, GL.GL_COLOR_ATTACHMENT0, GL.GL_TEXTURE_2D, tex, 0);

    // Paint: clear to a distinct color
    GL.glViewport(0, 0, WIDTH, HEIGHT);
    GL.glClearColor(0.8, 0.3, 0.2, 1.0);
    GL.glClear(GL.GL_COLOR_BUFFER_BIT);
    GL.glFinish();  // ensure render complete before DMA-BUF export

    image := eglCreateImageKHR(dpy, ctx, EGL_GL_TEXTURE_2D_KHR, cast(EGLClientBuffer) cast(u64) tex, null);
    fd, stride, offset: s32;
    assert(eglExportDMABUFImageMESA(dpy, image, *fd, *stride, *offset) == EGL_TRUE);

    // Wrap as wl_buffer via zwp_linux_dmabuf_v1
    params := Zwp_Linux_Buffer_Params_V1.{ id = allocate_id() };
    batch: MessageBuilder;
    zwp_linux_dmabuf_v1_create_params(*batch, *dmabuf_info.dmabuf, params.id);
    zwp_linux_buffer_params_v1_add(*batch, *params,
        fd = cast(Fd) fd,
        plane_idx = 0,
        offset = cast(u32) offset,
        stride = cast(u32) stride,
        modifier_hi = cast(u32)(modifier >> 32),
        modifier_lo = cast(u32)(modifier & 0xFFFFFFFF));
    buffer := Wl_Buffer.{ id = allocate_id() };
    zwp_linux_buffer_params_v1_create_immed(*batch, *params, buffer.id,
        width = WIDTH, height = HEIGHT, format = format, flags = 0);

    // Create surface + attach + commit (same as hello_window minus the shm path)
    surface := Wl_Surface.{ id = allocate_id() };
    xdg_surface := Xdg_Surface.{ id = allocate_id() };
    toplevel := Xdg_Toplevel.{ id = allocate_id() };
    wl_compositor_create_surface(*batch, compositor(), surface.id);
    xdg_wm_base_get_xdg_surface(*batch, wm_base(), xdg_surface.id, *surface);
    xdg_surface_get_toplevel(*batch, *xdg_surface, toplevel.id);
    xdg_toplevel_set_title(*batch, *toplevel, "hello_gl");
    wl_surface_commit(*batch, *surface);
    wayland_send(*batch);

    // Wait for configure, then attach+commit the buffer
    configure_serial: u32 = 0;
    for session()  if it.object_id == xdg_surface.id && it.opcode == XDG_SURFACE_CONFIGURE {
        configure_serial = read_u32(it.payload);
        break;
    }
    xdg_surface_ack_configure(*batch, *xdg_surface, configure_serial);
    wl_surface_attach(*batch, *surface, *buffer, 0, 0);
    wl_surface_damage_buffer(*batch, *surface, 0, 0, WIDTH, HEIGHT);
    wl_surface_commit(*batch, *surface);
    wayland_send(*batch);

    print("hello_gl: window should now show solid color. Close to exit.\n");

    // Minimal event loop: just wait for close
    for session() {
        if it.object_id == toplevel.id && it.opcode == XDG_TOPLEVEL_CLOSE  break;
    }
}
```

**Step 2: Add build target in first.jai**

```jai
case "hello_gl";
    build_and_run_test("hello_gl", "hello_gl", "examples/hello_gl.jai", "build");
    set_build_options_dc(.{do_output=false});
```

**Step 3: Build + run**

Run: `./build.sh - hello_gl`
Expected: window appears, solid orange-red color (RGB 0.8, 0.3, 0.2). Close to exit.

**If the window shows garbage or black:**
- Check the DMA-BUF fourcc matches what we passed to `create_immed` — mismatch = wrong color channels
- Check the compositor actually supports our (format, modifier) pair from the discovery
- Try forcing `modifier = DRM_FORMAT_MOD_LINEAR` (0) — some tiled modifiers require additional metadata
- `glFinish()` before export is required (GPU might not be done rendering yet)

**Step 4: Commit**

```bash
git add examples/hello_gl.jai first.jai
git commit -m "feat: first GPU-rendered pixel on Wayland via dmabuf"
```

**Checkpoint: if this task works, stop and report to user for visual verification before proceeding to Task 7.** This is the "does the whole architecture work at all" milestone.

---

### Task 7: Frame callback pacing + double-buffered DMA-BUF slots

Apply the same slot-rotation pattern as `hello_window.jai`, but with GL textures + DMA-BUF + EGLImage instead of shm buffers. Add `wl_surface.frame` callbacks for v-sync-aligned pacing.

**Files:**
- Modify: `examples/hello_gl.jai`

**Design:**

Each slot holds: `Gl_Slot :: struct { tex: u32; fbo: u32; image: EGLImage; buffer: Wl_Buffer; in_flight: bool; }`.
Two slots total. Render into current slot's FBO, attach its wl_buffer, mark in-flight. On `wl_buffer.release`, clear in_flight. On `wl_surface.frame` callback, request another frame.

The animation driver: `dirty` flag + `frame_requested` flag. The compositor's frame callback clears `frame_requested`. When both are set, render and request the next frame.

**Step 1-N:** (omitted for brevity in this plan — follow the `hello_window.jai` double-buffer pattern, substituting GL paint for shm paint)

**Verification:**
- Smooth animation (spinning triangle or color-shifting clear)
- No tearing
- CPU usage low (we're rendering on frame callback, not tight-loop)

**Commit:**
```bash
git commit -m "feat: double-buffered dmabuf slots + wl_surface.frame pacing"
```

---

### Task 8: Spinning triangle

Replace the solid-color `glClear` with a minimal GL 3.3 core rendering path: VAO, VBO, shader program, uniform for rotation.

**Files:**
- Modify: `examples/hello_gl.jai`

**Shaders (inline `#string`):**

```jai
VS_SRC :: #string GLSL
#version 330 core
layout(location = 0) in vec2 pos;
layout(location = 1) in vec3 col;
uniform float angle;
out vec3 vcol;
void main() {
    float c = cos(angle), s = sin(angle);
    vec2 r = vec2(c*pos.x - s*pos.y, s*pos.x + c*pos.y);
    gl_Position = vec4(r, 0.0, 1.0);
    vcol = col;
}
GLSL

FS_SRC :: #string GLSL
#version 330 core
in vec3 vcol;
out vec4 fragColor;
void main() { fragColor = vec4(vcol, 1.0); }
GLSL
```

Standard shader compile + link + VAO/VBO setup boilerplate. 3 vertices for an equilateral triangle with R/G/B vertex colors.

**Test:** run `./build.sh - hello_gl` — expect a triangle rotating continuously, smooth motion.

**Commit:**
```bash
git commit -m "feat: rotating triangle in hello_gl"
```

---

### Task 9: Input handling (keyboard + pointer)

Port the keyboard + pointer routing from `hello_window.jai`. R/G/B keys cycle triangle color scheme. Click prints pointer coords. Q quits.

**Files:**
- Modify: `examples/hello_gl.jai`

**Step 1: Acquire seats/keyboards/pointers** (copy from `hello_window.jai`)

**Step 2: Parse keymap** (copy from `hello_window.jai`)

**Step 3: Handle keyboard + pointer events in the for session() loop** (copy pattern from `hello_window.jai`)

**Verification:**
- R/G/B cycles triangle colors
- Click prints coords
- Q quits cleanly
- All three happen while triangle continues rotating smoothly

**Commit:**
```bash
git commit -m "feat: hello_gl keyboard + pointer input"
```

---

### Task 10: Docs update

**Files:**
- Modify: `CLAUDE.md` — add `hello_gl.jai` entry, update status section to mark Phase 5 as in progress / done for GL
- Modify: `README.md` — update "Status" section to add Phase 5 GL completion; bump test/example counts
- Modify: `first.jai` — confirm `./build.sh - hello_gl` is registered

**Commit:**
```bash
git commit -m "docs: add Phase 5 GL rendering to project docs"
```

---

### Task 11: Merge back to master

When user is satisfied with visual verification:
```bash
git checkout master
git merge --ff-only rendering-gl   # or --no-ff if you prefer merge commits
```

---

## Checkpoint strategy

This plan has four natural checkpoint boundaries:
1. **After Task 3** (headless_gl smoke test works) — proves the EGL+GL+gbm stack
2. **After Task 6** (first on-screen pixel) — proves the DMA-BUF → Wayland plumbing
3. **After Task 7** (double-buffered + frame pacing) — proves the rendering loop architecture
4. **After Task 9** (full hello_gl with input) — the shippable milestone

At each checkpoint, **stop and report to user for visual verification** — this is novel territory with more moving parts than the double-buffering work, and the user's eye is the ground truth for "is this actually rendering correctly."

## Rollback plan

If Task 3 fails: the architecture may need revision. Consider Path C (EGL surfaceless instead of gbm) or accept Path A (libwayland cohabit). Worst case the `rendering-gl` branch is abandoned and only the EGL/gbm vendoring work is salvageable.

If Task 6 fails but Task 3 passed: the issue is specifically in the DMA-BUF → Wayland handoff. Debug the (format, modifier) pair, check compositor's supported_format list, try forcing LINEAR modifier, cross-reference zig-wayland or wayland-rs implementations in `vendor/reference/`.

If Task 7+ fails: the GL rendering path itself is suspect, but the Phase 5 architecture is proven. Can commit what works and iterate.

## Known unknowns

- **Whether Hyprland specifically supports all the Mesa extensions we're using.** Most compositors do; Hyprland is fairly standard. But this is the kind of thing that's obvious when you hit it and invisible until you do.
- **Whether `glFinish()` is sufficient synchronization before DMA-BUF export, or whether we need explicit fence syncs** (`EGL_KHR_fence_sync`). The "right" answer is fences, but `glFinish` is simpler and likely adequate for a first version.
- **Modifier handling edge cases.** The compositor might advertise tiled modifiers only; we might need tiled-format support eventually. First version should work with LINEAR.

## Post-execution checklist

- [ ] All 11 tasks committed on `rendering-gl` branch (10 original + Task 2.5 amendment)
- [ ] `./build.sh - hello_gl` renders a rotating triangle in a Wayland window
- [ ] `./build.sh - hello_window` still works (shm path not regressed)
- [ ] `./build.sh - compile_test` passes
- [ ] `ldd build/hello_gl | grep -c wayland` returns `0` — no libwayland-client linkage
- [ ] `ldd build/hello_gl | grep -cE 'libGL\|libEGL\|libgbm\|libX11\|libxcb'` returns `0` — all GPU-facing libraries loaded via `dlopen` (added after Task 2.5 amendment)
- [ ] Docs updated (CLAUDE.md, README.md)
- [ ] Merged back to master
