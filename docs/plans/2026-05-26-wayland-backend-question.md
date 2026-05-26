# Wayland Backend for Vendored Window_Creation — Open Design Question

> **Status:** OPEN. Pending digestion. This is NOT a decided design — it is the
> articulation of an architectural question that needs more thought before a
> design plan can be written.

## Context

The `upstream-integration` branch (commits `041f094..7336e6f`) successfully
makes upstream Jai's `invaders` example playable on the **X11 backend** against
our vendored `Window_Creation` / `Simp` / `GetRect` / `GetRect_LeftHanded`
modules. Validation passed all four checkpoints: compile, ldd-clean, launch,
playable. `ldd build/invaders` shows only `libc + linux-vdso + ld-linux`.

The next sub-phase is supplying a **Wayland backend** so the same vendored
stack can run on a Wayland session. The eventual end-state: at app startup,
detect the session type (Wayland or X11), branch into the appropriate
initialization, and present a unified `Window_Creation` API to the application
above.

This question is harder than the X11 path was. The X11 path mostly worked by
swapping our runtime-loaded X11 module in via module path order — the upstream
`Window_Creation/linux.jai` code was unmodified and just needed our X11 to be
self-initializing. **Wayland will require a substantive new code path** because
upstream Jai has no Wayland support at all, AND there is a deep technical
problem with how GL works on Wayland under our "no libwayland linkage" thesis.

## The Three Layers

### Layer 1 — Catalog the bifurcation points

Where in vendored upstream code will we need to inject a Wayland-vs-X11
runtime branch?

- **`modules/Window_Creation/linux.jai`** — `create_window`,
  `toggle_fullscreen`, `get_dimensions`, `get_mouse_pointer_position`.
  Currently all XLib + GLX. Each becomes a dispatcher with X11/Wayland arms.
- **`modules/Window_Creation/module.jai`** — exports `Window_Type`, currently
  `X11.Window` (a u64). Needs to become tagged or polymorphic.
- **`modules/Simp/backend/gl.jai::backend_init`** — calls `glx_create_context`,
  `glXMakeCurrent`, later `glXSwapBuffers`. Wayland equivalent uses EGL with a
  different context creation flow and a fundamentally different swap model.
- **Stock Jai `Input` module** (`~/jai/jai/modules/Input/x11.jai`) — translates
  `XEvent` → abstract Input events. We don't currently vendor Input. To get
  Wayland input feeding the Input module's API, we either vendor Input and add
  a `wayland.jai`, OR bridge from our wire-protocol input events to Input's
  queue from outside the module.
- **`modules/Simp/font.jai`** — likely abstraction-transparent (uses GL via
  Simp's path), but verify.

### Layer 2 — The common abstraction ("rollup")

A shared API surface that both backends implement:

```
create_window(w, h, name, ...) -> Window_Handle
make_context_current(window) -> bool
swap_buffers(window)
get_dimensions(window) -> x, y, w, h
poll_events() -> void   // populates Input module's queue
destroy_window(window)
```

`Window_Handle` carries enough state to discriminate at runtime. Two options:

- **Tagged union** — `Window_Handle :: union { x11: X11_Window_Data; wl: Wayland_Window_Data; }`. More Jai-idiomatic, no untyped pointers.
- **Opaque `*void` + side-channel** — `current_backend: enum { X11; WAYLAND }`
  set at startup. Simpler internally; risks misuse.

Recommendation lean: tagged union.

### Layer 3 — How does GL actually work on Wayland under our thesis?

**This is the hard problem.** It changes the shape of Layer 2.

The standard way to do GL on Wayland is:

```
1. Create wl_surface
2. wl_egl_window_create(wl_surface, w, h)   →  opaque native handle
3. eglCreateWindowSurface(dpy, config, native_handle, ...)
4. eglSwapBuffers()                          —  swaps + commits internally
```

`wl_egl_window` is provided by `libwayland-egl.so`, which depends on
`libwayland-client.so`. **We don't link libwayland-client** — we speak the wire
protocol ourselves. `libwayland-egl` expects to interact with real libwayland
proxy structs, not bare wire IDs. It cannot interoperate with our object IDs.

This is the **same fundamental incompatibility** we hit with
`VK_KHR_wayland_surface` (documented in CLAUDE.md / AGENTS.md as a permanent
design constraint, and the reason `hello_vulkan_dmabuf` uses the DMA-BUF export
path instead of Vulkan WSI).

#### Option A — Vendor `libwayland-client` + `libwayland-egl`

Add real libwayland to the dependency graph. Drop-in for everything.

- **Pros:** smallest API gap; existing upstream GL idioms work unchanged.
- **Cons:** breaks the project's defining thesis. `ldd` no longer clean.
  Defeats the reason `jai-wayland` exists.
- **Verdict:** rejected unless there's no other choice. Listed for
  completeness.

#### Option B — DMA-BUF render path (the `hello_gl.jai` approach)

Use the path we already proved works: render to a GBM BO → import as EGLImage
→ bind to FBO → render → export fd/stride/modifier → present via
`zwp_linux_dmabuf_v1`. Frame-pumped via `wl_surface.frame` callbacks. Buffer
management via `wl_buffer.release` events.

- **Pros:** preserves the thesis. We already know it works (hello_gl is the
  proof). Wayland binary stays ldd-clean.
- **Cons:** API shape diverges from X11's. There is **no `glXSwapBuffers`
  equivalent** — the swap model is frame-pumped, not blocking. Simp's
  `backend_init` + swap logic needs a substantial Wayland-specific rewrite,
  not just a dispatch branch. Invaders' inner loop is structured around
  blocking swap; reshaping it without modifying upstream invaders source is
  non-trivial.
- **Verdict:** most thesis-consistent. Highest engineering effort.

#### Option C — Implement libwayland-egl ourselves on top of our wire IDs

Build a tiny in-tree shim that fakes the proxy struct layout libwayland-egl
expects.

- **Pros:** preserves thesis perfectly; abstraction stays clean and looks just
  like X11's.
- **Cons:** libwayland-client has internal data structures that
  libwayland-egl introspects. We'd need to reproduce them exactly across
  libwayland versions. Heroic engineering. Months of work plus ongoing
  maintenance burden. High risk of subtle breakage when libwayland-egl
  versions change.
- **Verdict:** academically interesting; probably not worth it.

#### Option D — Selective libwayland-egl via dlopen ("controlled compromise")

Dlopen `libwayland-client.so` + `libwayland-egl.so` at runtime via the existing
`init_*()` pattern, but only use a narrow shim surface. The Wayland binary
gets libwayland in its runtime dlopen set; the X11 binary stays pure.

- **Pros:** unlocks standard GL-on-Wayland (Option A capability) while
  preserving "no link-time" thesis. ldd-clean still technically holds
  (libwayland is dlopen'd, not link-dependency'd). Lets Simp's GL backend
  dispatch cleanly without a full rewrite.
- **Cons:** runtime-dlopened libwayland still pulls libwayland code into the
  process. The thesis is *diluted* — "we don't link libwayland" becomes "we
  don't link libwayland at build time but we runtime-load it for the GL
  surface path." Some philosophical purists will object. Also: a
  dlopen'd libwayland-client will create its own internal proxy state, which
  could collide with the project's own wire-protocol state if not carefully
  isolated.
- **Verdict:** pragmatic middle ground. Might be acceptable as a **staging
  step** toward Option B.

## What I'd Suggest as the Phasing

Before cataloging Layer 1's bifurcation points, before designing Layer 2's
abstraction, **decide Layer 3.** Once Layer 3 is settled, the abstraction
shape falls out naturally:

- **If Option B (DMA-BUF):** Layer 2's abstraction has to expose a more
  imperative frame-pumped API; Simp's `glXSwapBuffers` model has to bend.
  Invaders' inner loop changes shape.
- **If Option A or D (libwayland-egl via link or dlopen):** Layer 2 looks just
  like the X11 path. Cost is in the thesis (A) or in the dilution of it (D).
- **If Option C (proxy shim):** Layer 2 stays clean but the project takes on
  months of work.

A reasonable hybrid: **Option D as a staging step → Option B as the eventual
end state.** Option D unblocks fast iteration on the abstraction design with
working invaders-on-Wayland. Option B replaces the libwayland-egl dependency
once we've validated the API shape end-to-end. The X11 binary stays pure
throughout; only the Wayland binary touches libwayland during the staging
period.

## Open Clarifying Questions

These need answers before a design plan can be written:

1. **Thesis strictness.** Must the Wayland binary be ldd-clean (only
   libc/vdso/ld-linux) like the X11 path? Or is "X11 ldd-clean, Wayland uses
   dlopen'd libwayland-egl pragmatically" acceptable as a staging compromise?
   This single answer eliminates 2 of the 4 Layer-3 options.

2. **Scope of "vendored Window_Creation."** Is invaders the only target for
   this phase, or are we designing for the broader use case (skeletal-animation,
   future apps)? Wider scope means the abstraction needs more API surface;
   narrower scope means we can shortcut things.

3. **Simp patching tolerance.** Is it acceptable to patch upstream Simp more
   invasively than the upstream-integration branch did? The gl_load swap +
   lazy-init wiring we already shipped are small. Wayland will require
   `backend_init` to dispatch X11/Wayland code paths — significantly more
   invasive. Or we wrap Simp's backend in a higher-level shim and don't touch
   Simp itself, accepting some duplication.

4. **Input module strategy.** Three options:
   - **(i)** Vendor stock `Input` module + add a `wayland.jai` to it.
   - **(ii)** Don't vendor Input — write an external bridge that pokes events
     into Input's queue from outside.
   - **(iii)** Bypass Input entirely for Wayland; have apps drain Wayland
     events directly via `for session()`. (Breaks the unified API goal.)

5. **Session-type detection mechanism.** Options:
   - `WAYLAND_DISPLAY` env var present → Wayland; else X11.
   - `XDG_SESSION_TYPE` env var (`wayland` / `x11`).
   - Try Wayland first, fall back to X11 on connection failure.
   - CLI flag override.

6. **Compositor coverage.** Validate against which compositors? Hyprland
   (already working for jai-wayland's own examples) is the obvious primary.
   Sway? GNOME / Mutter? KDE / KWin? Each has quirks. The project's existing
   tests are against Hyprland.

## Recommended Reading Before Deciding

- `docs/plans/2026-05-26-upstream-integration-design.md` — design rationale
  for the X11 path; useful for analogy.
- `docs/plans/2026-05-26-upstream-integration-impl.md` — what the X11 path
  actually cost in implementation labor; useful for estimating Wayland's cost.
- `examples/hello_gl.jai` — the existing DMA-BUF Wayland GL implementation;
  the proof of concept for Option B.
- `examples/hello_vulkan_dmabuf.jai` — same DMA-BUF pattern for Vulkan;
  parallel story to what Wayland-GL via Option B would look like.
- `modules/wayland/dmabuf.jai` — the `zwp_linux_dmabuf_v1` discovery + feedback
  API; needed by Option B's wl_buffer creation.
- The "GL policy layer" + "GPU bindings" sections in CLAUDE.md — how our
  runtime-loaded GL/EGL/gbm modules already compose.

## Status & Next Action

**Status:** Open. The X11 path is shipped (~30% of the eventual goal);
Wayland-backend dispatch is the remaining ~70%.

**Next action:** decide Layer 3 (the GL-on-Wayland mechanism). All other
design choices are downstream of that. Once decided, this doc becomes the
basis of a proper `2026-MM-DD-wayland-backend-design.md` and a paired
`-impl.md` following the project's established design + implementation plan
pattern.
