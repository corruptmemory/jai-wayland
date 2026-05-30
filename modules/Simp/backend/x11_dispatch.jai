// New file (not vendored — original to this project).
// X11/GLX backend ops for vendored Simp. Bodies relocated verbatim from
// modules/Simp/backend/gl.jai's #if OS == .LINUX branches. Formerly the
// op-tagged simp_x11_dispatch switch (context.simp_dispatch); now plain per-op
// functions called directly from gl.jai's display_manager branch.
//
// info.window is a tagged Window_Type; .x11 is unwrapped where the value flows
// into GLX/XLib APIs that want a raw X11.Window.

#scope_export

// Relocated from backend_init's #if OS == .LINUX branches: create the GLX
// context (first time), make the dumb wrapper window, and make-current. The
// backend-agnostic GL setup (gl_load, glGen*, backend_init_shaders, …) stays
// in gl.jai around the call.
x11_backend_init :: (info: *Window_Info) {
    do_first_time_init := false;
    if !the_gl_context {
        do_first_time_init = true;
        // info.window is a tagged Window_Type now (X11 | Wayland); the X11 path
        // only ever sees the X11 variant, so unwrap .x11 for the GLX/XLib calls.
        the_gl_context, the_gl_fbc, info.msaa = glx_create_context(info.window.x11, MINIMUM_GL_MAJOR_VERSION, MINIMUM_GL_MINOR_VERSION);
    }

    // Must happen before glGen*, because we make current.
    glx_window := glXCreateWindow(x_global_display, the_gl_fbc, info.window.x11, null);
    info.specific.glx_window = glx_window;

    if do_first_time_init {
        // @Cleanup: Windows and Android make current during egl/wgl_create_context, Linux and mac don't. Which is correct?
        glXMakeCurrent(x_global_display, glx_window, the_gl_context);
    }
}

// Relocated from backend_set_render_target's #if OS == .LINUX branch. The caller
// (gl.jai) has already verified info.backend_initted_for_this_window; the
// post-call glViewport / glBindFramebuffer / glDrawBuffer stays in gl.jai.
x11_set_render_target :: (info: *Window_Info) {
    display := x_global_display;
    XLockDisplay(display);
    success := glXMakeCurrent(display, info.specific.glx_window, the_gl_context);
    if !success  log_error("glxMakeCurrent failed! (glx_window %, context %)\n", info.specific.glx_window, the_gl_context);
    XUnlockDisplay(display);
}

// X11/GLX has no resize op — the drawable resizes implicitly with the X11
// window, so backend_resize_render_target's Linux branch has nothing to call on
// the X11 side. (No x11_resize_render_target function exists by design.)

// Relocated from swap_buffers's #if OS == .LINUX branch. gl.jai handles
// CheckInit / immediate_flush and the find_window_info lookup; here we keep the
// X11-specific null-check before issuing glXSwapBuffers.
x11_swap_buffers :: (info: *Window_Info) {
    if !info.specific.glx_window {
        log_error("Simp: Attempt to swap_buffers on a previously unseen window!\n");
        return;
    }

    glXSwapBuffers(x_global_display, info.specific.glx_window);
}
