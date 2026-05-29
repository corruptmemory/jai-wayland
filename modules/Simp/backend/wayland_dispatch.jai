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

            // Allocate the double-buffered slots at the current window size. Buffer-
            // creation messages batch into one send (multiple slots share a batch).
            backend := wl_choose_gl_backend();
            batch: Wl.MessageBuilder;
            for * slot, i: s.wl_slots {
                if !wl_slot_init(slot, s.wl_egl, *s.wl_dmabuf_info.dmabuf, *batch,
                                 s.wl_format, s.wl_modifier, info.window_width, info.window_height, backend) {
                    log_error("Simp Wayland: failed to initialize slot %", i);
                    return;
                }
            }
            Wl.wayland_send(*batch);

            s.wl_current = 0;
            s.wl_initted = true;

        case .BACKEND_SET_RENDER_TARGET;
            // ONLY make the EGL context current. The FBO bind happens in gl.jai via
            // window_framebuffer(info); do NOT bind here. (Mirrors how the X11
            // dispatcher only does glXMakeCurrent and lets gl.jai bind framebuffer 0.)
            if EGL.eglMakeCurrent(s.wl_egl.dpy, EGL.EGL_NO_SURFACE, EGL.EGL_NO_SURFACE, s.wl_egl.ctx) != EGL.EGL_TRUE {
                log_error("Simp Wayland: eglMakeCurrent failed in set_render_target");
            }

        case .BACKEND_RESIZE_RENDER_TARGET;
            // DEFERRED TO SLICE 2 (Task 10). Resize on Wayland is not a no-op like
            // GLX: the BO-backed slots are sized to the surface, so a resize must
            // retire the in-flight slots (wl_retire_slots → wl_retired, torn down on
            // their wl_buffer.release) and reallocate fresh slots at the new size
            // (wl_slot_init with s.wl_dmabuf_info/wl_format/wl_modifier). Left empty
            // intentionally for Slice 1 — the backend-agnostic glViewport stays in
            // gl.jai. See docs/plans/2026-05-29-wayland-backend-design.md.

        case .SWAP_BUFFERS;
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
            // back to their owning slots. wl_retired carries slots from a prior resize
            // whose buffers the compositor still holds (empty in Slice 1).
            wl_block_on_frame(frame_callback_id, s.wl_slots, *s.wl_retired, s.wl_egl);

            // CALLER CONTRACT (wl_block_on_frame doc comment): the helper does NOT
            // recycle the frame-callback id. Recycle it here, or we leak a new id
            // every frame.
            Wl.cache_free(*s.wl_frame_cache, frame_callback_id);

            // Rotate to a non-in-flight slot for the next frame's render. If both are
            // in flight (no release arrived during the block), keep the current slot;
            // the next swap will re-block on its callback.
            nxt := wl_find_free_slot(s.wl_slots);
            if nxt >= 0  s.wl_current = cast(s32) nxt;
    }
}
