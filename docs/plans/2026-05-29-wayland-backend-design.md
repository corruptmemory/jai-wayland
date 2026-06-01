# Wayland Backend for Vendored Simp — Stage 2 Design

> **Status:** validated through conversation, ready to implement.
> **Current implementation note (2026-06-01):** the final backend keeps the same
> broad shape but uses a shared `Wayland_Support` EGL/GBM/GL context for all
> Simp Wayland windows. Per-window state is limited to surface roles, BO slots,
> dmabuf choices, frame pacing, resize, and close state in
> `wayland_global_windows`; `Window_Type.wayland` remains only a copy-safe
> wl_surface identity handle.
> Supersedes `docs/plans/2026-05-26-wayland-backend-question.md` (the Layer-3
> "open question" doc), whose central uncertainty no longer exists.
> Continues `docs/plans/2026-05-26-context-dispatch-stage1-design.md` (Stage 1,
> the context-dispatch scaffold, already shipped on `upstream-integration`).

## Goal

Implement `simp_wayland_dispatch` and the surrounding per-window state so the
vendored Simp + Window_Creation + Input stack runs on a Wayland session, using
the DMA-BUF presentation path already proven by `examples/hello_gl.jai`. No
libwayland linkage, no `libwayland-egl`; `ldd` stays clean (libc + vdso +
ld-linux only) on both the X11 and Wayland binaries.

The end-state: on a Wayland session, `invaders` plays identically to how it
plays on X11 today — same vendored stack, same API surface, backend chosen once
at startup by `running_wayland()`.

## Why this supersedes the "open question" doc

`2026-05-26-wayland-backend-question.md` treated **Layer 3 — "how does GL work
on Wayland under our no-libwayland thesis?"** as the load-bearing open question,
and weighed four options (A: link libwayland; B: DMA-BUF render path; C:
reimplement `libwayland-egl`; D: dlopen `libwayland-egl` as a staging step).
That doc was written **before `hello_gl.jai` existed as a complete, validated
artifact**.

It does now. `hello_gl.jai` is Option B, running end-to-end on Mesa (AMD/Intel)
**and** NVIDIA. The visible unknown is retired. Therefore:

- **Option A — link libwayland.** Dead. Violates the thesis.
- **Option C — reimplement `libwayland-egl`.** Dead. Months of work to rebuild
  what we routed around.
- **Option D — dlopen `libwayland-egl` "as a staging step."** Dead, and this is
  the important one. D's entire justification was "unblock fast iteration while
  we validate the API shape." `hello_gl` already validated the API shape. D
  would add libwayland to the process to reach a destination we already stand
  at — pure thesis-dilution with no remaining upside.
- **Option B — DMA-BUF.** The path. Already proven.

The "70% of the work remains" framing in the question doc was inflated by
counting the now-solved GL mechanism as an unknown. What actually remains is a
handful of **contained integration problems**, re-ranked below.

The question doc is retained (with a SUPERSEDED banner) for provenance: it
records *why* A/C/D are rejected, which is worth not re-litigating.

## The real problem (and the phantom it was hiding behind)

The question doc named "the swap model" as the hard part of Option B. It is not.
The real architectural problem is **render-target ownership**, and it was hiding
under the swap question.

`modules/Simp/backend/gl.jai:955-956`, in *backend-agnostic* code that runs
after the per-backend dispatch returns:

```jai
glViewport(0, 0, xx info.window_width, xx info.window_height);
glBindFramebuffer(GL_FRAMEBUFFER, 0);
```

On X11/GLX, **framebuffer 0 *is* the window's back buffer** — what
`glXSwapBuffers` presents. Simp's whole model assumes "render to FBO 0, the
windowing system presents FBO 0." On Wayland-via-DMA-BUF that assumption is
false: there is no window-system default framebuffer. FBO 0 is an orphan with no
compositor-visible storage. Render to 0, export a BO, and you export blank
pixels.

So the crux of Stage 2: **on Wayland, "the window's framebuffer" must *be* a
BO-backed FBO.** Simp already has the machinery — `backend_set_render_target
(texture: *Texture)` at `gl.jai:976` binds a texture-backed FBO via
`main_fbo_handle`. The Wayland window path is the same trick, pointed at a
BO-backed texture, with the result exported rather than blitted.

Once render-target ownership is solved, `SWAP_BUFFERS` is easy downstream work:
it is `hello_gl`'s present loop turned inside-out to fit inside one synchronous
Simp call.

## Non-goals

- **Touching upstream `invaders` source.** Ever. Same constraint as Stage 1.
- **Refactoring `hello_gl.jai`.** It stays frozen as the reference
  implementation. Its known-good EGL/slot/export logic is *ported into* a Simp
  helper, not moved out of the example. A later "hello_gl consumes the shared
  helper" cleanup is explicitly out of scope (post-invaders, if ever).
- **Explicit fence sync.** `SWAP_BUFFERS` uses `glFinish()` like `hello_gl`.
  `EGL_KHR_fence_sync` + `wp_linux_drm_syncobj_v1` remain a separate future item;
  `Gl_Slot.{acquire,release}_fence_fd` placeholder fields are already in place.
- **Non-blocking / hybrid swap models.** `SWAP_BUFFERS` is block-on-frame-
  callback only (see §3). The other two candidates are GPU-idle optimizations
  for the future UI layer, not a game. YAGNI until a real consumer needs them.
- **Fractional scaling, multi-output, server-allocated IDs.** Unchanged from the
  project's existing backlog; not part of this stage.

## Approach

### §1 — State-ownership model (mirror the X11 split)

Wayland per-window state splits along the **exact seam X11 already uses**. No
new pattern is introduced.

| State | X11 today | Wayland | Created by |
|-------|-----------|---------|------------|
| Window identity | `Window_Type.x11` (`X11.Window`) | `Window_Type.wayland` (`Wayland_Window_State`) | `Window_Creation.create_window` |
| GL backend state | `Window_Info.specific.glx_window` | `Window_Info.specific` (Linux) | `Simp.backend_init` (dispatcher) |

`Wayland_Window_State` (today an empty placeholder in `modules/Window_Type.jai`)
gets the window-identity fields: the `wl_surface` / `xdg_surface` /
`xdg_toplevel` object IDs. It is the Wayland analogue of `X11.Window`.

The Linux `Window_Info_Platform_Specific` (today `{ glx_window: GLXWindow; }`
in `gl.jai`) gains the GL backend state: EGL display/context, GBM device, the
BO-backed slot array, and the current-slot index. This is the Wayland analogue
of `glx_window`, and sits exactly where the upstream `NOTE(Charles)` at
`gl.jai:187` already mused EGL state "could maybe go."

The dispatcher receives `*Window_Info`, so it reaches both: window surfaces via
`info.window.wayland`, GL state via `info.specific`. invaders never touches
either — the polymorphism is fully contained below the Simp API surface, which
is what makes "invaders just works" true at Slice 4.

The slot record reuses `hello_gl`'s `Gl_Slot` shape (tex/fbo/image/bo/buffer +
fd/stride/offset/modifier/format + width/height + bo_backed/in_flight +
fence-fd placeholders). It moves into the shared helper (§4).

### §2 — Render-target ownership (the one backend-agnostic edit)

Generalize the hardcoded bind at `gl.jai:956`:

```jai
glBindFramebuffer(GL_FRAMEBUFFER, window_framebuffer(info));
```

`window_framebuffer(info: *Window_Info) -> GLuint` is a tiny backend-agnostic
helper that switches on `info.window.wtype`:

- `.X11` → returns `0` (the GLX drawable — *unchanged* behavior).
- `.Wayland` → returns the current slot's FBO handle from `info.specific`.

X11 falls out as the degenerate case (handle 0) rather than being special-cased.
This is the **only** edit to backend-agnostic code beyond Stage 1's existing
`context.simp_dispatch` calls. The companion `glViewport` at line 955 stays
backend-agnostic and unchanged.

### §3 — `SWAP_BUFFERS` semantics: block-on-frame-callback

Inside the single synchronous `swap_buffers` call invaders believes is a
blocking swap, the Wayland dispatcher's `SWAP_BUFFERS` op does:

1. `glFinish()` — coarse GPU sync (same as `hello_gl`; fences are a future item).
2. Export the current slot's BO → attach its `wl_buffer` → `wl_surface.commit`.
3. Request a `wl_surface.frame` callback; **block draining the session** until
   it fires. This provides vsync-equivalent pacing — semantically the same as
   `glXSwapBuffers` under vsync.
4. Rotate `current_slot` to the next free slot. Slot freeing is driven by
   `wl_buffer.release` events handled while draining. §2's `window_framebuffer`
   then returns the next slot's FBO for the following frame.

`BACKEND_INIT` (Wayland) creates the EGL/GBM context and the slot array (sized
to the initial window dimensions) into `info.specific`, mirroring how the X11
dispatcher's `BACKEND_INIT` creates the GLX context. `BACKEND_SET_RENDER_TARGET`
(Wayland) makes the EGL context current; the FBO bind itself happens via §2's
`window_framebuffer` in the backend-agnostic tail of `backend_set_render_target`.

### §4 — Shared GL helper (`modules/Simp/backend/wayland_gl.jai`)

`hello_gl.jai`'s known-good machinery — `Gl_Slot`, EGL/GBM stack init, BO
allocation + EGLImage import (`EGL_NATIVE_PIXMAP_KHR` → `EGL_LINUX_DMA_BUF_EXT`
fallback), FBO setup, dmabuf format/modifier selection, `wl_buffer` creation
from a BO, slot retire/realloc — is **ported** (not moved) into a new
`modules/Simp/backend/wayland_gl.jai`, consumed by `wayland_dispatch.jai`.

`hello_gl.jai` is untouched: it remains the reference. Divergence risk is
accepted for this stage as the price of keeping a working artifact stable. (A
future cleanup could invert this so `hello_gl` consumes the helper; out of
scope here.)

These modules already provide the underlying loaders the helper needs:
`modules/gpu/{device,dmabuf_bo}.jai`, `modules/{EGL,gbm,GL}/`, and the wayland
module's `dmabuf.jai`.

### §5 — Detection (`running_wayland`)

Replace the Stage 1 `return false;` stub with real detection:

```jai
running_wayland :: () -> bool {
    return to_string(getenv("WAYLAND_DISPLAY")).count > 0;
}
```

Two lines, correct, and `hello_simp` then "just works" on a Wayland session with
no force-hack. **Caveat:** `./build.sh - invaders` on a Wayland session will hit
the (still-incomplete) Wayland dispatcher during Slices 1–3. This is desirable —
fail loud — because invaders is only *validated* at Slice 4.

## Phasing

Slice-first: attack the real unknowns in isolation before integration. This is
the same risk ordering `hello_gl` used to de-risk the GL mechanism originally.

| Slice | Goal | Proves |
|-------|------|--------|
| **1** | `examples/hello_simp.jai` triangle presents on Wayland | §1 state split, §2 render-target, §3 swap — the real unknowns |
| **2** | Compositor-driven resize | `BACKEND_RESIZE_RENDER_TARGET` → slot realloc (hello_gl's retire-and-realloc) |
| **3** | Input pump | wire events (`get_keyboard_event`/`get_pointer_event`) → `Input.events_this_frame`; detection already live from §5 |
| **4** | `invaders` on Wayland | integration confirmation — *not* the proving ground |

`hello_simp.jai` (~60–80 lines) calls Simp's own API exactly as invaders does,
minus game logic: `create_window` → loop { `clear_render_target` → one
immediate-mode triangle → `swap_buffers` }. It is the minimal surface that
exercises §1+§2+§3 end-to-end. No input, no resize.

## Validation

**Slice 1 (the gate):**
1. `./build.sh - hello_simp` exits 0 on a Wayland session; a triangle renders
   and animates at frame-callback pace.
2. `ldd build/hello_simp` shows only libc + vdso + ld-linux. No libwayland, no
   libwayland-egl.
3. `running_wayland()` returns true under Hyprland; the X11 path is unaffected
   when `WAYLAND_DISPLAY` is unset.

**Slices 2–4 (cumulative, must not regress Slice 1):**
4. Resize: dragging the window reallocates slots without artifacts or leaks.
5. Input: keyboard/pointer events reach the app through `Input`.
6. `invaders` plays on Wayland — window opens, animation ≥60fps, input works,
   sound plays, clean exit — and **still plays identically on X11**
   (`WAYLAND_DISPLAY` unset).
7. All existing examples unaffected: `hello_gl`, `hello_x11_gl`, `headless_gl`,
   `x11_smoke`, `headless_vulkan` build, run, stay ldd-clean.
8. All 111 tests across 6 suites still pass.

## File Inventory

**New:**
- `modules/Simp/backend/wayland_gl.jai` — ported `hello_gl` GL/slot/export
  machinery; the shared helper consumed by the Wayland dispatcher.
- `examples/hello_simp.jai` — Slice 1 proving vehicle.

**Modified (vendored upstream):**
- `modules/Simp/backend/wayland_dispatch.jai` — replace the asserting stub with
  the real four-op implementation (`BACKEND_INIT`, `BACKEND_SET_RENDER_TARGET`,
  `BACKEND_RESIZE_RENDER_TARGET`, `SWAP_BUFFERS`) over `wayland_gl.jai`.
- `modules/Simp/backend/gl.jai` — §2: `glBindFramebuffer(GL_FRAMEBUFFER, 0)` at
  line 956 → `glBindFramebuffer(GL_FRAMEBUFFER, window_framebuffer(info))`; add
  the `window_framebuffer` helper; extend the Linux `Window_Info_Platform_
  Specific` with the Wayland GL-state fields.
- `modules/Window_Type.jai` — populate `Wayland_Window_State` with surface IDs;
  revisit the `.Wayland` arm of `operator ==` (currently `return true` on the
  empty struct).
- `modules/Window_Creation/linux.jai` (+ `linux_init.jai`) — §5 real
  `running_wayland`; Wayland arm of `create_window` (and, in later slices,
  `get_dimensions` / `toggle_fullscreen` / `get_mouse_pointer_position`) creating
  the `wl_surface`/`xdg_surface`/`xdg_toplevel` and storing them in
  `Window_Type.wayland`.
- `modules/Simp/module.jai` — `#load "backend/wayland_gl.jai"`.
- `build.sh`, `first.jai` — add the `hello_simp` example target.
- `docs/plans/2026-05-26-wayland-backend-question.md` — SUPERSEDED banner.

**Untouched:**
- `examples/hello_gl.jai` — frozen reference (see Non-goals).
- `modules/Simp/backend/x11_dispatch.jai` — Stage 1's X11 dispatcher stands.
- All `modules/wayland/`, `modules/{EGL,gbm,GL,gpu,X11,Vulkan}/` bindings.
- Upstream `invaders` source.

## Stage handoff / future items

- Explicit fence sync replacing `glFinish()` (placeholder fields ready).
- Non-blocking / hybrid swap models, once the UI layer needs GPU-idle behavior.
- Optional later refactor: `hello_gl` consumes `wayland_gl.jai` to retire the
  divergence accepted in §4.

## References

- `docs/plans/2026-05-26-context-dispatch-stage1-design.md` — the dispatch
  scaffold this builds on; its handoff section seeded this stage.
- `docs/plans/2026-05-26-wayland-backend-question.md` — superseded; provenance
  for the A/C/D rejection.
- `examples/hello_gl.jai` — the Option B proof; source of the ported machinery.
- `modules/Simp/backend/gl.jai:187,955-956,976` — the render-target-ownership
  evidence and the patch sites.
- `modules/gpu/dmabuf_bo.jai`, `modules/wayland/dmabuf.jai` — BO allocation +
  dmabuf negotiation the helper relies on.
