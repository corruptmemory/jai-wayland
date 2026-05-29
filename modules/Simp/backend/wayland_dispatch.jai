// New file (not vendored — original to this project).
// Wayland dispatcher. Stage 2 Slice 1 implementation: EGL-on-GBM + DMA-BUF
// presentation (the same architecture hello_gl.jai uses), built on the helpers
// in backend/wayland_gl.jai. Presents via the block-on-frame-callback model
// (design §3): each SWAP_BUFFERS attaches the current slot, requests a frame
// callback, commits, then blocks draining the session until that callback
// fires — vsync-equivalent pacing without an out-of-band event loop.
//
// See docs/plans/2026-05-26-context-dispatch-stage1-design.md,
//     docs/plans/2026-05-29-wayland-backend-design.md (§1, §3, §4),
// and the impl plan Task 5.
//
// Symbol-naming: this file loads into the Simp module scope alongside
// wayland_gl.jai. The Wl_Gl_Slot / Wl_Egl_State / SIMP_WL_SLOT_COUNT types and
// the wl_* helpers are referenced BARE (same module scope). GL entry points
// (glFinish, ...) are bare too (Simp `#import "GL"` anonymously). The `Wl` and
// `EGL` NAMED imports come from wayland_gl.jai at #scope_module level — they are
// already module-visible here, so re-importing them in this file is a
// redeclaration error. We deliberately do NOT re-import; we just use Wl./EGL.
//
// Modules log, they don't print — every diagnostic here uses log()/log_error().

#scope_export

simp_wayland_dispatch :: (args: *Simp_Op_Args, info: *Window_Info) {
    s := *info.specific;
    if args.op == {
        case .BACKEND_INIT;
            // Bring up the EGL-on-GBM stack (render-node selection + EGL display/
            // context + GL loaders). wl_egl_init eglMakeCurrent's the context on
            // success, so the GL calls in slot init below have a current context.
            if !wl_egl_init(*s.wl_egl) {
                log_error("Simp Wayland: EGL/GBM init failed");
                return;
            }

            // Discover the compositor's dmabuf formats and pick one usable by our
            // GBM device (per-surface feedback when available, else the global
            // list). The bound zwp_linux_dmabuf_v1 lives in wl_dmabuf_info; we keep
            // it (plus the chosen format/modifier) so slot (re)allocation — here
            // and in the Slice-2 resize path — can reach it.
            dmabuf_info, dmabuf_ok := Wl.get_dmabuf_info();
            if !dmabuf_ok {
                log_error("Simp Wayland: compositor does not advertise zwp_linux_dmabuf_v1");
                return;
            }
            // Borrows get_dmabuf_info's `supported` dynamic-array storage (copied
            // by header — backing is shared, not owned). Fine while nothing frees
            // it; the Slice-2 resize reuse must not double-free it.
            s.wl_dmabuf_info = dmabuf_info;

            surface := Wl.Wl_Surface.{ id = info.window.wayland.surface };
            format, modifier, have_format := wl_choose_dmabuf_format(s.wl_egl.gbm, s.wl_dmabuf_info, *surface);
            if !have_format {
                log_error("Simp Wayland: no GBM-usable ABGR/XBGR 8888 dmabuf format advertised");
                return;
            }
            s.wl_format   = format;
            s.wl_modifier = modifier;
            log("Simp Wayland: using format=0x% modifier=0x%",
                formatInt(format, base=16), formatInt(modifier, base=16));

            // Allocate the double-buffered slots at the configured window size.
            // IMPORTANT: read the size from info.window.wayland, NOT
            // info.window_width — set_render_target calls backend_init BEFORE
            // update_window populates info.window_width, so it is still 0 here. The
            // .wayland fields carry the size captured at create_window_wayland's
            // first configure. (Buffer-creation messages batch into one send.)
            init_w := info.window.wayland.width;
            init_h := info.window.wayland.height;
            backend := wl_choose_gl_backend();
            batch: Wl.MessageBuilder;
            for * slot, i: s.wl_slots {
                if !wl_slot_init(slot, s.wl_egl, *s.wl_dmabuf_info.dmabuf, *batch,
                                 s.wl_format, s.wl_modifier, init_w, init_h, backend) {
                    log_error("Simp Wayland: failed to initialize slot %", i);
                    // NOTE: an earlier slot's batched create messages are abandoned
                    // unsent here, yet allocate_id() already advanced the session's
                    // next_id for them — leaving a hole in the contiguous client-ID
                    // stream. Tolerable only because this leaves wl_initted false, so
                    // SWAP/SET_RENDER_TARGET no-op (guards below) and the window is
                    // dead. If slot init ever becomes recoverable, this must roll
                    // next_id back or the session is unusable.
                    return;
                }
            }
            Wl.wayland_send(*batch);

            s.wl_current = 0;
            s.wl_initted = true;

        case .BACKEND_SET_RENDER_TARGET;
            // Fail safe if BACKEND_INIT bailed: gl.jai marks the window initted
            // regardless of dispatch outcome, so without this guard a failed init
            // would make-current a half-built context. wl_initted is the reader
            // that makes the flag meaningful.
            if !s.wl_initted  return;
            // ONLY make the EGL context current. The FBO bind happens in gl.jai via
            // window_framebuffer(info); do NOT bind here. (Mirrors how the X11
            // dispatcher only does glXMakeCurrent and lets gl.jai bind framebuffer 0.)
            if EGL.eglMakeCurrent(s.wl_egl.dpy, EGL.EGL_NO_SURFACE, EGL.EGL_NO_SURFACE, s.wl_egl.ctx) != EGL.EGL_TRUE {
                log_error("Simp Wayland: eglMakeCurrent failed in set_render_target");
            }

        case .BACKEND_RESIZE_RENDER_TARGET;
            if !s.wl_initted  return;
            new_w := info.window_width;   // update_window set these before dispatching
            new_h := info.window_height;
            // No-op if the slots already match — guards against spurious configures.
            if s.wl_slots[0].width == new_w && s.wl_slots[0].height == new_h  return;

            // Retire current slots (the compositor may still hold an in-flight
            // buffer; those go to wl_retired and are torn down on their
            // wl_buffer.release inside wl_block_on_frame), then reallocate fresh
            // slots at the new size, reusing the negotiated format/modifier.
            retire_batch: Wl.MessageBuilder;
            wl_retire_slots(*retire_batch, *s.wl_retired, s.wl_slots, s.wl_egl);
            Wl.wayland_send(*retire_batch);

            backend := wl_choose_gl_backend();
            alloc_batch: Wl.MessageBuilder;
            for * slot, i: s.wl_slots {
                if !wl_slot_init(slot, s.wl_egl, *s.wl_dmabuf_info.dmabuf, *alloc_batch,
                                 s.wl_format, s.wl_modifier, new_w, new_h, backend) {
                    // Realloc failed mid-loop: old slots are already retired and some
                    // new-slot create messages sit unsent in alloc_batch while
                    // allocate_id() advanced next_id (the contiguous-ID hazard, same as
                    // BACKEND_INIT). Mark the window dead so SWAP / SET_RENDER_TARGET
                    // no-op via their wl_initted guards rather than attaching a
                    // half-built / null buffer to the live surface. Recovery would
                    // require rolling next_id back.
                    log_error("Simp Wayland: resize slot % realloc failed (%x%) — window disabled", i, new_w, new_h);
                    s.wl_initted = false;
                    return;
                }
            }
            Wl.wayland_send(*alloc_batch);
            s.wl_current = 0;
            // Bind the new current slot's FBO so the next clear/draw target it (the
            // old FBO was just retired). gl.jai's glViewport follows this dispatch.
            glBindFramebuffer(GL_FRAMEBUFFER, window_framebuffer(info));

        case .SWAP_BUFFERS;
            // Fail safe if BACKEND_INIT bailed: the slots are uninitialized
            // (wl_current still -1, slot.buffer.id 0), so attaching would commit a
            // null buffer. Skip rather than corrupt the surface.
            if !s.wl_initted  return;
            slot := *s.wl_slots[s.wl_current];

            // Coarse GPU sync before handing the BO to the compositor — same as
            // hello_gl. Explicit fences (EGL_KHR_fence_sync + wp_linux_drm_syncobj_v1)
            // are a future item; slot.acquire_fence_fd/release_fence_fd are placeholders.
            glFinish();

            // Present sequence ported from hello_gl.jai's render loop (the steady-state
            // present at lines 228-233): allocate a fresh frame-callback id, request
            // wl_surface.frame, attach the slot's wl_buffer, damage the full surface,
            // commit, and send. The frame-callback id comes from the per-window
            // Id_Cache so it recycles (first alloc sequential, later allocs reuse a
            // dead entry) — see the cache_free below.
            surface := Wl.Wl_Surface.{ id = info.window.wayland.surface };
            batch: Wl.MessageBuilder;
            frame_callback_id := Wl.cache_alloc(*s.wl_frame_cache);
            Wl.wl_surface_frame(*batch, *surface, frame_callback_id);
            Wl.wl_surface_attach(*batch, *surface, *slot.buffer, 0, 0);
            Wl.wl_surface_damage_buffer(*batch, *surface, 0, 0, slot.width, slot.height);
            Wl.wl_surface_commit(*batch, *surface);
            Wl.wayland_send(*batch);
            slot.in_flight = true;

            // Block until this frame callback fires, routing wl_buffer.release events
            // back to their owning slots and collecting close/resize signals. The
            // drain also acks any xdg_surface.configure. wl_retired carries slots
            // from a prior resize whose buffers the compositor still holds.
            signals: Wl_Frame_Signals;
            wl_block_on_frame(frame_callback_id, s.wl_slots, *s.wl_retired, s.wl_egl,
                              info.window.wayland.xdg_toplevel, info.window.wayland.xdg_surface,
                              *signals);
            if signals.close_requested  s.wl_close_requested = true;
            // Record a configured size change on Simp's Window_Type copy — the
            // source get_render_dimensions reads for Wayland. The actual slot
            // realloc happens via the app's next update_window -> backend_resize ->
            // BACKEND_RESIZE_RENDER_TARGET, so the X11 update_window pattern works
            // unchanged on Wayland too.
            if signals.have_new_size {
                info.window.wayland.width  = signals.new_width;
                info.window.wayland.height = signals.new_height;
            }

            // CALLER CONTRACT (wl_block_on_frame doc comment): the helper does NOT
            // recycle the frame-callback id. Recycle it here, or we leak a new id
            // every frame.
            Wl.cache_free(*s.wl_frame_cache, frame_callback_id);

            // Rotate to a non-in-flight slot for the next frame's render. If both are
            // in flight (no release arrived during the block), keep the current slot;
            // the next swap will re-block on its callback.
            nxt := wl_find_free_slot(s.wl_slots);
            if nxt >= 0  s.wl_current = cast(s32) nxt;

            // Leave the NEW current slot's FBO bound as the render target. On X11
            // the window's back buffer is always framebuffer 0, so callers set the
            // render target ONCE (invaders does); on Wayland the target rotates
            // every frame, so without this rebind the next frame would render into
            // the slot we just presented. This is what makes the once-set-render-
            // target pattern correct on Wayland — the rotation is invisible to the
            // app, exactly as the X11 back-buffer swap is.
            glBindFramebuffer(GL_FRAMEBUFFER, window_framebuffer(info));
    }
}
