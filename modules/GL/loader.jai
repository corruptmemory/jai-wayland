// Runtime GL loader. Unlike EGL and gbm, we don't dlopen libGL directly —
// the caller hands us a get-proc-address function (typically eglGetProcAddress)
// and we resolve everything through that. This is the standard modern pattern:
// the EGL/WGL/GLX layer knows how to return GL entry points appropriate to the
// currently-bound context.
//
// Mechanically: for each function-pointer variable declared in gl.jai, we call
// get_proc_address with the procedure name and assign the result. A single
// pass; the core subset must be resolvable once the context is current.

GL_Get_Proc_Address :: #type (procname: *u8) -> *void #c_call;

// Returns true if all required GL entry points resolved. A single null is a
// hard error: it means the caller's get-proc-address doesn't know about a
// core-profile function we depend on, which is a bug (either our name is
// wrong or the context isn't GL 3.3+).
gl_load :: (get_proc: GL_Get_Proc_Address) -> bool {
    if !get_proc  return false;

    ok := true;
    resolve :: (get_proc: GL_Get_Proc_Address, name: *u8, ok: *bool) -> *void #expand {
        addr := get_proc(name);
        if !addr  ok.* = false;
        return addr;
    }

    // Viewport / clear / read / status
    glViewport    = xx resolve(get_proc, "glViewport", *ok);
    glClearColor  = xx resolve(get_proc, "glClearColor", *ok);
    glClear       = xx resolve(get_proc, "glClear", *ok);
    glReadPixels  = xx resolve(get_proc, "glReadPixels", *ok);
    glReadBuffer  = xx resolve(get_proc, "glReadBuffer", *ok);
    glDrawBuffer  = xx resolve(get_proc, "glDrawBuffer", *ok);
    glFinish      = xx resolve(get_proc, "glFinish", *ok);
    glFlush       = xx resolve(get_proc, "glFlush", *ok);
    glGetError    = xx resolve(get_proc, "glGetError", *ok);
    glGetIntegerv = xx resolve(get_proc, "glGetIntegerv", *ok);
    glGetString   = xx resolve(get_proc, "glGetString", *ok);

    // State enable/disable, blend, scissor, pixel store
    glEnable      = xx resolve(get_proc, "glEnable", *ok);
    glDisable     = xx resolve(get_proc, "glDisable", *ok);
    glBlendFunc   = xx resolve(get_proc, "glBlendFunc", *ok);
    glScissor     = xx resolve(get_proc, "glScissor", *ok);
    glPixelStorei = xx resolve(get_proc, "glPixelStorei", *ok);

    // Textures
    glGenTextures    = xx resolve(get_proc, "glGenTextures", *ok);
    glDeleteTextures = xx resolve(get_proc, "glDeleteTextures", *ok);
    glBindTexture    = xx resolve(get_proc, "glBindTexture", *ok);
    glActiveTexture  = xx resolve(get_proc, "glActiveTexture", *ok);
    glTexImage2D     = xx resolve(get_proc, "glTexImage2D", *ok);
    glTexParameteri  = xx resolve(get_proc, "glTexParameteri", *ok);
    glTexParameterf  = xx resolve(get_proc, "glTexParameterf", *ok);

    // Framebuffer objects
    glGenFramebuffers        = xx resolve(get_proc, "glGenFramebuffers", *ok);
    glDeleteFramebuffers     = xx resolve(get_proc, "glDeleteFramebuffers", *ok);
    glBindFramebuffer        = xx resolve(get_proc, "glBindFramebuffer", *ok);
    glFramebufferTexture2D   = xx resolve(get_proc, "glFramebufferTexture2D", *ok);
    glCheckFramebufferStatus = xx resolve(get_proc, "glCheckFramebufferStatus", *ok);

    // Shaders / programs (not strictly required for Task 3, but they're core 3.3
    // so any context we care about will have them — resolve eagerly so Task 8
    // doesn't need its own pass)
    glCreateShader       = xx resolve(get_proc, "glCreateShader", *ok);
    glDeleteShader       = xx resolve(get_proc, "glDeleteShader", *ok);
    glShaderSource       = xx resolve(get_proc, "glShaderSource", *ok);
    glCompileShader      = xx resolve(get_proc, "glCompileShader", *ok);
    glGetShaderiv        = xx resolve(get_proc, "glGetShaderiv", *ok);
    glGetShaderInfoLog   = xx resolve(get_proc, "glGetShaderInfoLog", *ok);
    glCreateProgram      = xx resolve(get_proc, "glCreateProgram", *ok);
    glDeleteProgram      = xx resolve(get_proc, "glDeleteProgram", *ok);
    glAttachShader       = xx resolve(get_proc, "glAttachShader", *ok);
    glLinkProgram        = xx resolve(get_proc, "glLinkProgram", *ok);
    glGetProgramiv       = xx resolve(get_proc, "glGetProgramiv", *ok);
    glGetProgramInfoLog  = xx resolve(get_proc, "glGetProgramInfoLog", *ok);
    glUseProgram         = xx resolve(get_proc, "glUseProgram", *ok);
    glGetUniformLocation = xx resolve(get_proc, "glGetUniformLocation", *ok);
    glGetAttribLocation  = xx resolve(get_proc, "glGetAttribLocation", *ok);
    glUniform1f          = xx resolve(get_proc, "glUniform1f", *ok);
    glUniform1i          = xx resolve(get_proc, "glUniform1i", *ok);
    glUniformMatrix4fv   = xx resolve(get_proc, "glUniformMatrix4fv", *ok);

    // Buffer objects
    glGenBuffers     = xx resolve(get_proc, "glGenBuffers", *ok);
    glDeleteBuffers  = xx resolve(get_proc, "glDeleteBuffers", *ok);
    glBindBuffer     = xx resolve(get_proc, "glBindBuffer", *ok);
    glBufferData     = xx resolve(get_proc, "glBufferData", *ok);
    glMapBuffer      = xx resolve(get_proc, "glMapBuffer", *ok);
    glMapBufferRange = xx resolve(get_proc, "glMapBufferRange", *ok);
    glUnmapBuffer    = xx resolve(get_proc, "glUnmapBuffer", *ok);

    // Vertex array objects
    glGenVertexArrays          = xx resolve(get_proc, "glGenVertexArrays", *ok);
    glDeleteVertexArrays       = xx resolve(get_proc, "glDeleteVertexArrays", *ok);
    glBindVertexArray          = xx resolve(get_proc, "glBindVertexArray", *ok);
    glVertexAttribPointer      = xx resolve(get_proc, "glVertexAttribPointer", *ok);
    glEnableVertexAttribArray  = xx resolve(get_proc, "glEnableVertexAttribArray", *ok);
    glDisableVertexAttribArray = xx resolve(get_proc, "glDisableVertexAttribArray", *ok);

    // Framebuffer blit
    glBlitFramebuffer = xx resolve(get_proc, "glBlitFramebuffer", *ok);

    // Fence sync
    glFenceSync      = xx resolve(get_proc, "glFenceSync", *ok);
    glClientWaitSync = xx resolve(get_proc, "glClientWaitSync", *ok);

    // Draw
    glDrawArrays = xx resolve(get_proc, "glDrawArrays", *ok);

    return ok;
}

gl_load_egl_image_extensions :: (get_proc: GL_Get_Proc_Address) -> bool {
    if !get_proc  return false;

    glEGLImageTargetTexture2DOES = xx get_proc("glEGLImageTargetTexture2DOES");
    return glEGLImageTargetTexture2DOES != null;
}

// Convenience — assumes a GL 3.0+ context. Uses glGetIntegerv which is more
// reliable than parsing glGetString(GL_VERSION).
gl_get_version :: () -> major: s32, minor: s32 {
    major, minor: s32;
    glGetIntegerv(GL_MAJOR_VERSION, *major);
    glGetIntegerv(GL_MINOR_VERSION, *minor);
    return major, minor;
}

// Error dumper — used by upstream Simp backend at various points to flush
// pending GL errors with a tag. Drains glGetError until empty and logs each
// hex code. Cheap enough to leave on; if we want a release-build no-op later
// we can wrap this in a #if. Returns true if any errors were drained.
DumpGLErrors :: (tag: string, loc := #caller_location) -> bool {
    had_error := false;
    while true {
        error := glGetError();
        if error == GL_NO_ERROR break;
        had_error = true;
        log("[%] %:%: GL error 0x%\n", tag, loc.fully_pathed_filename, loc.line_number,
            formatInt(error, base = 16, minimum_digits = 4));
    }
    return had_error;
}

// No-op debug-output enabler. Upstream calls this from Simp's backend_init to
// install glDebugMessageCallback; we don't bind that proc set yet (KHR_debug
// is an optional extension) and the Simp callers expect a benign default.
// Once glDebugMessageCallback is wired into gl_load, replace this body.
gl_enable_debug_output :: (break_on_error: bool = false) {
    // intentionally empty
}

