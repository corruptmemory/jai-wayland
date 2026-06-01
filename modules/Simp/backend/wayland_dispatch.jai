// New file (not vendored — original to this project).
// Wayland backend ops for vendored Simp. Thin glue: each finds this window's
// shared record in WS.wayland_global_windows (keyed by wl_surface id) and calls
// the matching Wayland_Support op, then does Simp's own GL bookkeeping (FBO
// bind). ALL the EGL/GBM/wire work lives in Wayland_Support — Simp never touches
// EGL/Gbm/wayland directly here.
//
// Formerly the op-tagged simp_wayland_dispatch switch (context.simp_dispatch);
// now plain per-op functions called from gl.jai's display_manager branch.
//
// WS is the module-scope `#import "Wayland_Support"` (module.jai). GL entry
// points (glFinish, glBindFramebuffer, GL_FRAMEBUFFER) are bare (Simp imports GL
// anonymously). window_framebuffer lives in gl.jai (same module scope).

#scope_export

// Look up the shared record for this Window_Info's surface. The identity lives
// in info.window.wayland (Window_Type); the render state lives in the registry.
wl_window_for :: (info: *Window_Info) -> *WS.Wayland_Window {
    return WS.find_wayland_window(info.window.wayland.surface);
}

wl_backend_init :: (info: *Window_Info) {
    ww := wl_window_for(info);
    if !ww {
        // create_window_wayland registers the record before Simp ever sees the
        // window; a miss means the window was built off our create path.
        log_error("Simp Wayland: no Wayland_Window registered for surface %", info.window.wayland.surface);
        return;
    }
    // Read the size from the registry record, not info.window_width:
    // set_render_target calls backend_init BEFORE update_window populates
    // info.window_width. wl_window_init_gl reads ww.width/height (set at
    // create-time / updated by the pump on configure).
    if !WS.wl_window_init_gl(ww) {
        log_error("Simp Wayland: GL bring-up failed");
        return;
    }

    // Simp's GL backend uses `the_gl_context` as the process-wide "did we do
    // one-time GL object setup?" sentinel. X11 stores the single GLX context
    // there; Wayland stores the shared EGL context pointer there so shaders,
    // VAO/VBOs, and font textures are initialized exactly once and then reused
    // across multiple Wayland windows.
    if !the_gl_context  the_gl_context = xx WS.wl_shared_context();
}

wl_set_render_target :: (info: *Window_Info) {
    ww := wl_window_for(info);
    // Fail safe if backend_init bailed: gl.jai marks the window initted regardless
    // of outcome, so without this guard a failed init would make-current a
    // half-built context. ONLY make current here; the FBO bind is gl.jai's job via
    // window_framebuffer (mirrors how the X11 op only does glXMakeCurrent).
    if !ww || !ww.wl_initted  return;
    WS.wl_make_current();
}

wl_resize_render_target :: (info: *Window_Info) {
    ww := wl_window_for(info);
    if !ww || !ww.wl_initted  return;
    // update_window set info.window_{width,height} before dispatching. If the
    // slots actually reallocated, bind the new current slot's FBO so the next
    // clear/draw targets it (the old FBO was just retired); gl.jai's glViewport
    // follows this dispatch.
    if WS.wl_window_resize_gl(ww, info.window_width, info.window_height) && context.simp.current_window_info.window == info.window {
        glBindFramebuffer(GL_FRAMEBUFFER, window_framebuffer(info));
    }
}

wl_swap_buffers :: (info: *Window_Info) {
    ww := wl_window_for(info);
    // Fail safe if backend_init bailed: slots are uninitialized (wl_current -1),
    // so presenting would commit a null buffer. Skip rather than corrupt.
    if !ww || !ww.wl_initted  return;

    // Coarse GPU sync before handing the BO to the compositor — same as hello_gl.
    // Explicit fences are a future item (slot.acquire/release_fence_fd placeholders).
    glFinish();

    // Present the current slot. Asynchronous + vsync-paced: wl_present_and_pace
    // throttles on the PREVIOUS frame's callback (no per-frame block for a
    // CPU-bound app; capped to vsync for a fast one) and rotates ww.wl_current to
    // a free slot. See docs/plans/2026-05-31-wayland-async-present.md.
    WS.wl_present_and_pace(ww);

    // Leave the NEW current slot's FBO bound as the render target. On X11 the
    // back buffer is always framebuffer 0 so callers set the target once; on
    // Wayland the target rotates every frame, so this rebind is what keeps the
    // once-set-render-target pattern correct — the rotation is invisible to the app.
    glBindFramebuffer(GL_FRAMEBUFFER, window_framebuffer(info));
}
