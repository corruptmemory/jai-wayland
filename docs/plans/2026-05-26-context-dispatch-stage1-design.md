# Context-Based Backend Dispatch — Stage 1 (X11) Design

> **Status:** validated through conversation, ready to implement.
> Stage 1 of two stages. Stage 2 (Wayland) is downstream of this design.

## Goal

Establish the context-based dispatch architecture inside vendored Simp so the
same backend-agnostic Simp code can route operations to either an X11 or a
Wayland backend at runtime, chosen once at app startup. Stage 1 validates the
architecture by routing X11 through it; Stage 2 fills in the Wayland branch.

The end-state of Stage 1: invaders runs **identically** to how it runs today on
the upstream-integration branch — same behavior, same ldd cleanliness, same
play feel — but its execution path now goes through the dispatch scaffold.
That's the architecture-validation success criterion.

## Context

This is a direct continuation of the upstream-integration branch and the
answer to the architecture question captured in
`docs/plans/2026-05-26-wayland-backend-question.md`. That doc named three
layers (catalog, common rollup abstraction, GL-on-Wayland mechanism). This
design implements Layer 2 (the abstraction). Layer 3 (the actual Wayland GL
mechanism) is settled implicitly here too: `Wayland_Window_State` will carry
an EGL-on-GBM context, matching the existing `hello_gl.jai` pattern. No
libwayland-egl, no libwayland linkage.

The integration goal is "X11/Wayland just works" against the same vendored
upstream stack. Stage 1 + Stage 2 together complete that goal.

## Non-goals

- **Implementing the Wayland backend.** Stage 2 owns that. Stage 1's
  `simp_wayland_dispatch` is a stub that asserts.
- **Window_Creation polymorphism.** `create_window`, `toggle_fullscreen`,
  `get_dimensions`, `get_mouse_pointer_position` stay X11-specific in Stage 1.
  Their bifurcation comes in Stage 2 — either via a separate
  `#add_context wc_dispatch` or via direct tag dispatch off `Window_Type`. We
  defer that decision.
- **Input module polymorphism.** Vendoring stock `Input` and patching its
  Linux backend is now part of Stage 1 (see below — this changed after Task 1
  surfaced an Input-vs-tagged-union-Window_Type incompatibility). But
  Input *polymorphism* (a Wayland event-pump backend) remains Stage 2 work.
  Stage 1's Input vendor patches only the type compatibility — the X11
  event-pump body stays as upstream wrote it.
- **Touching upstream invaders source.** Ever. Same constraint as
  upstream-integration.
- **Changing the behavior of existing project examples** (`hello_gl`,
  `hello_x11_gl`, `headless_gl`, etc.). They remain unaffected.

## Mid-execution scope revision: Input must be vendored

The original design (above) said "Input module polymorphism is deferred to
Stage 2; stock Input works on X11 via path-order resolution." That deferral
assumed Window_Type's shape change in Task 1 wouldn't matter to Input. **It
does.** Upstream `~/jai/jai/modules/Input/x11.jai:813` does
`record.window = hwnd` — assigns a `u64` (`X11.Window`) to a `Window_Type`
field. When Window_Type was a u64 alias, this was a no-op assignment.
After Task 1 made Window_Type a tagged union, the assignment fails type-check
because Jai forbids `operator =` overloads.

The discovery came during Task 7's invaders build attempt. The cleanest
resolution is to vendor `Input/` into `modules/Input/` and patch its
`x11.jai` line 813 to construct a `Window_Type` value instead of assigning
the bare handle. This preserves the design intent of Window_Type as a
tagged union while keeping Input's X11 backend functional in Stage 1.

A second category of collateral fixes also surfaced during Task 7's attempt:
Jai 0.2.029 tagged-union literal syntax strictness (`X.{ op = .Y }` is no
longer valid; needs `X.{ op = .Y, y = .{} }`), `.x11` extractions wherever
`info.window` is consumed as a `u64` (in Simp's backend code), and
`operator ==` overloads on `Window_Type` for both same-type and cross-type
comparison against `X11.Window`. All of these are consequences of Task 1's
tagged-union conversion and need to be handled before invaders compiles.

The impl plan has been amended with two new tasks before the original Task 7:

- **New Task 6.5 — Harden Window_Type conversion.** Add `operator ==`
  overloads, fix Jai 0.2.029 tagged-union literal syntax in `Simp_Op_Args`
  constructions, add `.x11` extractions where `info.window` flows through
  to `X11.Window`-typed APIs, drop the explicit `-> void` on
  `Simp_Backend_Dispatch` (which mismatches Jai's implicit-no-return
  convention).

- **New Task 6.6 — Vendor Input module + patch x11.jai.** Copy
  `~/jai/jai/modules/Input/` verbatim into `modules/Input/`, then patch
  `x11.jai:813` (and any sibling sites) to handle Window_Type as a tagged
  union.

After 6.5 + 6.6 land, the original Task 7 (lazy init in create_window +
`parent = None` → `INVALID_WINDOW`) becomes tractable and the invaders
build can proceed.

## Approach

Use Jai's `#add_context` mechanism to declare a Simp-private dispatch field
that's read at every Simp backend op site. The field's value is set once at
app startup by `init_linux_window()`, which detects the runtime environment
and pushes the appropriate dispatcher into context. In Stage 1, that detection
unconditionally returns "X11" (the `running_wayland()` predicate is a stub
that returns `false`).

The dispatch is **typed inside Simp's module** (full type safety where it
matters) and **invisible to Window_Type** (which stays a pure tagged union of
backend identity + per-backend data). This sidesteps the layering and
circular-dependency problems we walked through in conversation.

We considered three alternative dispatch placements in conversation:

- **`*void` function pointer in `Window_Type`** — works, but type-erases at
  the boundary and creates multi-renderer collision risk.
- **Dispatch pointer in `Window_Info_Platform_Specific`** — clean layering,
  but requires patching `swap_buffers(window: Window_Type)`'s signature to
  reach the pointer.
- **Context dispatch (this design)** — wins on every axis: pure Window_Type,
  no signature patches, fully typed inside Simp, idiomatic Jai pattern
  (mirrors how the allocator and the project's existing `wayland_session`
  work).

## Section 1 — Context Dispatch Architecture

Each subsystem that needs polymorphic dispatch declares its own typed function
pointer in `context`. The convention this design establishes:

```jai
// Inside Simp's vendored module (modules/Simp/backend/dispatch.jai — new file):

Simp_Op_Tag :: enum u32 {
    BACKEND_INIT;
    BACKEND_SET_RENDER_TARGET;
    BACKEND_RESIZE_RENDER_TARGET;
    SWAP_BUFFERS;
}

Simp_Op_Args :: union op: Simp_Op_Tag {
    .BACKEND_INIT                   ,, init                  : Backend_Init_Args;
    .BACKEND_SET_RENDER_TARGET      ,, set_render_target     : Backend_Set_Render_Target_Args;
    .BACKEND_RESIZE_RENDER_TARGET   ,, resize_render_target  : Backend_Resize_Args;
    .SWAP_BUFFERS                   ,, swap_buffers          : Swap_Buffers_Args;
}

Simp_Backend_Dispatch :: #type (args: *Simp_Op_Args, info: *Window_Info) -> void;

#add_context simp_dispatch: Simp_Backend_Dispatch;
```

`Simp_Op_Args` is internal to Simp. `Window_Info` is already Simp's own type.
Neither escapes into Window_Type or any other module's surface area.

The per-op argument structs (`Backend_Init_Args`, etc.) are mostly empty in
Stage 1 — the relevant state lives inside `info` already. They're declared
properly now so Stage 2 doesn't need to retrofit them when Wayland needs
additional per-op state.

## Section 2 — Window_Type as Pure Tagged Union

Vendor `~/jai/jai/modules/Window_Type.jai`. Replace the Linux branch's current
`Window_Type :: X11.Window` with a tagged union:

```jai
// modules/Window_Type.jai (Linux branch)

#scope_module
X11     :: #import "X11";
Wayland :: #import "wayland";   // our existing wire-protocol module
#scope_export

Window_Tag :: enum u32 {
    X11;
    Wayland;
}

Wayland_Window_State :: struct {
    // Per-window Wayland state. Stage 2 populates this. For Stage 1
    // the type exists but is never instantiated.
    egl_context: EGL_Context;
    // surfaces, BO slots, etc. — fields are TBD by Stage 2's implementation.
}

EGL_Context :: struct {
    drm_fd: s32 = -1;
    gbm:    Gbm_Device;
    dpy:    EGLDisplay;
    ctx:    EGLContext;
}

Window_Type :: union wtype: Window_Tag {
    .X11     ,, x11     : X11.Window;
    .Wayland ,, wayland : Wayland_Window_State;
}

INVALID_WINDOW : Window_Type : .{ wtype = .X11, x11 = 0 };  // X11 Window 0 is None
```

Non-Linux branches (`#if OS == .WINDOWS` etc.) stay byte-for-byte identical to
upstream. Only the Linux branch becomes a tagged union.

`Window_Type` knows nothing about Simp, nothing about the dispatch, nothing
about which backend is "current." It's pure backend identity + per-backend
data. Anyone — Window_Creation, Simp, Input, future renderers — consumes it
according to their own conventions.

## Section 3 — The Simp Dispatchers (Visible Parallel Structure)

Two new files alongside the existing `modules/Simp/backend/gl.jai`:

```
modules/Simp/backend/
├── gl.jai                # existing — backend-AGNOSTIC GL state code stays here
├── gl_screenshot.jai     # existing — unchanged
├── none.jai              # existing — unchanged
├── dispatch.jai          # NEW — Simp_Op_Args + Simp_Backend_Dispatch + #add_context
├── x11_dispatch.jai      # NEW — simp_x11_dispatch :: (args, info) { switch on args.op... }
└── wayland_dispatch.jai  # NEW — simp_wayland_dispatch (Stage 1: stub that asserts)
```

Inside `gl.jai`, the existing `#if OS == .LINUX` branches of `backend_init`,
`backend_set_render_target`, `backend_resize_render_target`, and `swap_buffers`
get reshaped:

```jai
// Existing (Stage 0 state — what's there today on upstream-integration):
backend_set_render_target :: (info: *Window_Info) {
    if info.backend_initted_for_this_window {
        #if OS == .LINUX {
            success := glXMakeCurrent(x_global_display, info.specific.glx_window, the_gl_context);
            // ... existing GLX-specific logic ...
        }
        // ... other OS branches ...
    } else {
        backend_init(info);
        info.backend_initted_for_this_window = true;
    }
    glViewport(0, 0, xx info.window_width, xx info.window_height);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    #if !IS_GLES  glDrawBuffer(GL_BACK);
}

// Stage 1 (after refactor):
backend_set_render_target :: (info: *Window_Info) {
    if info.backend_initted_for_this_window {
        #if OS == .LINUX {
            args := Simp_Op_Args.{ op = .BACKEND_SET_RENDER_TARGET };
            context.simp_dispatch(*args, info);
        }
        // ... other OS branches unchanged ...
    } else {
        backend_init(info);
        info.backend_initted_for_this_window = true;
    }
    glViewport(0, 0, xx info.window_width, xx info.window_height);  // unchanged
    glBindFramebuffer(GL_FRAMEBUFFER, 0);                            // unchanged
    #if !IS_GLES  glDrawBuffer(GL_BACK);                             // unchanged
}
```

The GLX-specific code that USED to live inside `#if OS == .LINUX` relocates
**verbatim** into `simp_x11_dispatch` inside `x11_dispatch.jai`:

```jai
// modules/Simp/backend/x11_dispatch.jai

simp_x11_dispatch :: (args: *Simp_Op_Args, info: *Window_Info) {
    if args.op == {
        case .BACKEND_INIT;
            // (Existing X11 backend_init body — glx_create_context, etc.)
        case .BACKEND_SET_RENDER_TARGET;
            success := glXMakeCurrent(x_global_display, info.specific.glx_window, the_gl_context);
            // ...
        case .BACKEND_RESIZE_RENDER_TARGET;
            // GLX handles this implicitly; mostly a no-op
        case .SWAP_BUFFERS;
            glXSwapBuffers(x_global_display, info.specific.glx_window);
    }
}
```

The dispatcher body is **moved code, not new code**. That's important —
Stage 1's substantive change is a relocation, not a rewrite. The risk of
behavior drift is correspondingly low.

`wayland_dispatch.jai` in Stage 1:

```jai
// modules/Simp/backend/wayland_dispatch.jai

simp_wayland_dispatch :: (args: *Simp_Op_Args, info: *Window_Info) {
    assert(false, "Wayland dispatcher not yet implemented (Stage 2)");
}
```

The file exists in Stage 1 so the architectural skeleton is visible and
init_linux_window's `running_wayland() == true` branch is reachable as a
compile target. Its body is filled in Stage 2.

## Section 4 — The Init Ceremony

A new file `modules/Window_Creation/linux_init.jai` (or inline at top of
`linux.jai`):

```jai
running_wayland :: () -> bool {
    // Stage 1: unconditionally X11.
    return false;
    // Stage 2 replaces this body with real detection — typically:
    //   home := to_string(getenv("WAYLAND_DISPLAY"));
    //   return home.count > 0;
    // (Or XDG_SESSION_TYPE, or attempted Wayland connection, etc. —
    //  see the Wayland-backend question doc for options.)
}

init_linux_window :: () {
    if running_wayland() {
        context.simp_dispatch = simp_wayland_dispatch;
        // (Stage 2: also any other subsystem dispatchers — wc_dispatch
        //  if/when Window_Creation needs one, input_pump if/when we vendor Input.)
    } else {
        context.simp_dispatch = simp_x11_dispatch;
    }
}
```

`init_linux_window` is called **once** by the app at startup, **before**
`create_window` runs and before any Simp operation fires. For upstream
example targets that go through `build_and_run_upstream_example` (currently
just `invaders`), the helper itself can call `init_linux_window` after
compile/before spawning the binary — except that's compile-time, not runtime.
The right model: the application's main() does it, or a Window_Creation
helper exports a "call at app entry" function. Most likely we patch
Window_Creation's `create_window` to call `init_linux_window` lazily on first
invocation if context.simp_dispatch is null, so apps don't have to remember.

We don't have to commit to that mechanism in the design — the impl plan will
pin it down based on what works cleanly when wired up.

## Section 5 — Validation

Stage 1's success criterion is **observable equivalence** between Stage 0
(current `upstream-integration` HEAD) and Stage 1 (this work merged):

1. **Compile clean:** `./build.sh - invaders` exits 0; `build/invaders`
   exists.
2. **ldd-clean:** `ldd build/invaders` shows only `libc.so.6 + linux-vdso +
   ld-linux-x86-64.so.2`. No new libraries.
3. **Existing examples unaffected:** `./build.sh - hello_gl`,
   `- hello_x11_gl`, `- headless_gl`, `- x11_smoke`, `- headless_vulkan` —
   all build, all run, all stay ldd-clean.
4. **Test suites unchanged:** All 111 tests across 6 suites pass.
5. **Invaders plays:** Window opens, animation runs at ≥60 fps, keyboard
   input works, sound plays, exit clean. Identical play feel to current
   upstream-integration HEAD.

If 1-5 hold, Stage 1's architectural scaffold is validated and Stage 2
becomes "implement `simp_wayland_dispatch`'s body" — a contained,
well-shaped problem.

## File Inventory

**New:**
- `modules/Window_Type.jai` — vendored from upstream; Linux branch extended
  to tagged union. Other-OS branches verbatim.
- `modules/Simp/backend/dispatch.jai` — `Simp_Op_Tag`, `Simp_Op_Args`,
  `Simp_Backend_Dispatch`, `#add_context simp_dispatch`.
- `modules/Simp/backend/x11_dispatch.jai` — `simp_x11_dispatch` function,
  body relocated from existing `backend/gl.jai` X11 branches.
- `modules/Simp/backend/wayland_dispatch.jai` — `simp_wayland_dispatch` stub
  asserting "not yet implemented."
- `modules/Window_Creation/linux_init.jai` (or inline) — `init_linux_window`
  and `running_wayland` (latter returns `false` in Stage 1).

**Modified (in vendored upstream):**
- `modules/Simp/backend/gl.jai` — four `#if OS == .LINUX` branches inside
  `backend_init`, `backend_set_render_target`,
  `backend_resize_render_target`, `swap_buffers` get reshaped to
  `context.simp_dispatch(*args, info)` calls. The relocated GLX code lives
  in `x11_dispatch.jai`. Headers updated to "Modified" annotation per the
  vendoring convention.
- `modules/Simp/module.jai` — `#load "backend/dispatch.jai"`,
  `#load "backend/x11_dispatch.jai"`, `#load "backend/wayland_dispatch.jai"`
  added next to the existing `#load "backend/gl.jai"`. Header updated.

**Untouched:**
- `modules/Window_Creation/{module,windows,macos,android}.jai`
- `modules/Window_Creation/linux.jai` — Stage 2 territory.
- `modules/Simp/{bitmap,font,immediate,shader,texture,texture_format}.jai`
- `modules/Simp/backend/{gl_screenshot,none}.jai`
- `modules/GetRect/`, `modules/GetRect_LeftHanded/` — no GL/X11 touch.
- `modules/X11/`, `modules/GL/`, `modules/EGL/`, `modules/gbm/`, etc. —
  Stage 1 doesn't touch any of our runtime-loaded module bindings.
- `first.jai`, `build.sh` — build infrastructure unchanged.
- All examples in `examples/` — unchanged.

## Stage 2 Handoff

When Stage 1 lands, the remaining work to complete the integration goal:

1. **Implement `simp_wayland_dispatch`.** This is the bulk of Stage 2 — it's
   essentially "package `hello_gl.jai`'s setup + render-to-BO + present-via-
   dmabuf logic behind the four-op dispatch interface." The hardest sub-
   question: what semantics does the `SWAP_BUFFERS` op have on Wayland?
   Three candidates (block-on-frame-callback, non-blocking-with-rotation,
   hybrid). The design doc captures these; Stage 2 picks.
2. **Window_Creation polymorphism.** `create_window`, `toggle_fullscreen`,
   `get_dimensions`, `get_mouse_pointer_position`. Either via direct tag
   dispatch (small switch in each function) or via a separate
   `#add_context wc_dispatch`. Probably the former — Window_Creation's
   polymorphic surface is small.
3. **Input polymorphism.** Stage 1 vendored `Input/` for type compatibility
   only. Stage 2 adds a `wayland.jai` backend (and a `#add_context
   input_pump` or equivalent), routing through the same context-dispatch
   pattern Simp uses. The existing X11 event-pump in Stage 1's vendored
   Input stays as the X11 dispatcher; the Wayland version drains our
   wire-protocol message queue and feeds `Input.events_this_frame`.
4. **Flip `running_wayland()` to real detection.** Probably
   `to_string(getenv("WAYLAND_DISPLAY")).count > 0` is enough.

## Open Items (Stage 1 only)

These are small and will resolve naturally during impl planning:

- **Exact `Simp_Op_Args` variant arg structs.** Most are empty for Stage 1.
  The impl plan reads `none.jai` + the current `backend/gl.jai` Linux
  branches and pins them down.
- **Where `init_linux_window` is called from.** Two candidates: (a) lazy
  call from inside `create_window` if context dispatch is null; (b) explicit
  call required by the app at top of main(). Lean toward (a) because it
  preserves "upstream apps run unmodified" — invaders doesn't have to be
  patched to add an explicit init call. Trade-off: lazy initialization
  hides the wiring slightly. We pick during impl.
- **Whether to split `init_linux_window` into a new file or keep inline in
  `linux.jai`.** Mild lean toward new file (`linux_init.jai`) for visibility,
  matching the parallel-files philosophy for the Simp dispatchers.

## References

- `docs/plans/2026-05-26-wayland-backend-question.md` — open question this
  design closes out (Layer 2 of the three-layer framing).
- `docs/plans/2026-05-26-upstream-integration-design.md` — prior phase's
  design rationale; useful for analogy on the vendoring + patching shape.
- `docs/plans/2026-05-26-upstream-integration-impl.md` — prior phase's
  impl plan; useful for impl-plan shape and pacing.
- `~/jai/jai/modules/Window_Type.jai` — the file to vendor.
- `~/jai/jai/modules/Simp/backend/none.jai` — the answer key for Simp's
  full backend API surface.
- `modules/Simp/backend/gl.jai` — current state; the four `#if OS == .LINUX`
  branches are the patch sites.
- `examples/hello_gl.jai` — the proof-of-concept for Layer 3 Option B
  (DMA-BUF on Wayland); reference for Stage 2's `simp_wayland_dispatch`
  body.
