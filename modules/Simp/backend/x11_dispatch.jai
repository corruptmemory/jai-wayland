// New file (not vendored — original to this project).
// X11/GLX dispatcher for vendored Simp. Body relocated verbatim from
// modules/Simp/backend/gl.jai's #if OS == .LINUX branches.
// See docs/plans/2026-05-26-context-dispatch-stage1-design.md.

#scope_export

simp_x11_dispatch :: (args: *Simp_Op_Args, info: *Window_Info) {
    if args.op == {
        case .BACKEND_INIT;
            // Relocated from backend_init's #if OS == .LINUX branches in
            // gl.jai. The original function has three separate Linux blocks:
            //   1. inside `else { do_first_time_init = true; ... }` — creates
            //      the GLX context.
            //   2. an unconditional block — creates the glx_window wrapper.
            //   3. inside `if do_first_time_init { ... }` — glXMakeCurrent.
            // The backend-agnostic GL setup that surrounds these blocks
            // (gl_load, glGenVertexArrays, backend_init_shaders, etc.) stays
            // in gl.jai.
            do_first_time_init := false;
            if !the_gl_context {
                do_first_time_init = true;
                the_gl_context, the_gl_fbc, info.msaa = glx_create_context(info.window, MINIMUM_GL_MAJOR_VERSION, MINIMUM_GL_MINOR_VERSION);
            }

            // Make dumb wrapper window.
            // Must happen before glGen*, because we make current.
            glx_window := glXCreateWindow(x_global_display, the_gl_fbc, info.window, null);
            info.specific.glx_window = glx_window;

            if do_first_time_init {
                // @Cleanup: Windows and Android make current during egl/wgl_create_context, Linux and mac don't. Which is correct?
                glXMakeCurrent(x_global_display, glx_window, the_gl_context);
            }

        case .BACKEND_SET_RENDER_TARGET;
            // Relocated from backend_set_render_target's #if OS == .LINUX
            // branch. The caller (gl.jai) has already verified
            // info.backend_initted_for_this_window before dispatching; the
            // post-call glViewport / glBindFramebuffer / glDrawBuffer stays
            // in gl.jai (backend-agnostic).
            display := x_global_display;
            XLockDisplay(display);
            success := glXMakeCurrent(display, info.specific.glx_window, the_gl_context);
            if !success log_error("glxMakeCurrent failed! (glx_window %, context%)\n", info.specific.glx_window, the_gl_context);
            XUnlockDisplay(display);

        case .BACKEND_RESIZE_RENDER_TARGET;
            // Relocated from backend_resize_render_target's #if OS == .LINUX
            // branch. There is no Linux-specific code in upstream's
            // backend_resize_render_target — only MACOS has a branch
            // (NSOpenGLContext.update). GLX handles resize implicitly via
            // the X11 window, so this is a no-op on X11. The
            // backend-agnostic glViewport stays in gl.jai.

        case .SWAP_BUFFERS;
            // Relocated from swap_buffers's #if OS == .LINUX branch. The
            // caller (gl.jai) handles the CheckInit / immediate_flush and
            // the per-platform `info` lookup; here we just keep the
            // X11-specific null-check on info.specific.glx_window before
            // issuing glXSwapBuffers.
            if !info.specific.glx_window {
                log_error("Simp: Attempt to swap_buffers on a previously unseen window!\n");
                return;
            }

            glXSwapBuffers(x_global_display, info.specific.glx_window);
    }
}
