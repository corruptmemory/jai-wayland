# Wayland Backend (Stage 2) Implementation Plan

> **Current implementation note (2026-06-01):** the final shipped backend moved
> this plan's early per-window EGL sketch out of `Window_Info.specific`.
> `Wayland_Support` now owns one shared EGL/GBM/GL context for all Simp Wayland
> windows, while `Wayland_Window` owns per-window surface roles, BO slots,
> dmabuf format/modifier, frame pacing, resize, and close state. Multi-window
> startup also routes configure/close events for already-registered windows
> while a new window waits for its first configure.

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.
> Before writing or modifying ANY Jai code, invoke the `jai-language` skill (project CLAUDE.md mandate).

**Goal:** Make the vendored Simp + Window_Creation stack present on a Wayland session via the proven DMA-BUF path, so `invaders` plays on Wayland identically to X11 — ldd-clean throughout.

**Architecture:** Implement `simp_wayland_dispatch` over a ported `wayland_gl.jai` helper. Per-window state splits exactly as X11's does: window identity (surfaces) in `Window_Type.wayland`, GL backend state (EGL/GBM/slots) in `Window_Info.specific`. The single backend-agnostic change is generalizing the hardcoded `glBindFramebuffer(…, 0)` to `window_framebuffer(info)`. `SWAP_BUFFERS` is block-on-frame-callback.

**Tech Stack:** Jai; runtime-loaded EGL/GBM/GL (`modules/{EGL,gbm,GL,gpu}`); our wire-protocol `wayland` module; `zwp_linux_dmabuf_v1`. Reference implementation: `examples/hello_gl.jai`.

**Design doc:** `docs/plans/2026-05-29-wayland-backend-design.md`.

---

## Testing model (read first)

This stage is **integration-validated, not unit-tested**, and the plan is honest about that:

- The 111-test suite (`./build.sh - test`, `- compile_test`, etc.) is the **regression gate** — it must stay green after every task that touches shared module code. It does *not* cover Simp rendering (Simp is vendored upstream and exercises a live compositor + GPU).
- The **functional gate is `./build.sh - hello_simp`**: build → ldd-clean check → run → *observe a triangle*. A wrong `window_framebuffer` returns 0 on Wayland → blank window → immediate, unambiguous failure. This is the "test" for the rendering path.
- Where a pure check is cheap (`window_framebuffer` tag logic), the plan adds an assertion. Where it would require standing up a Simp-importing display-backed test harness, the plan relies on the functional gate instead — building that harness is not worth its cost here.
- **Per task:** implement → build the relevant target → confirm expected output → commit. Use @superpowers:verification-before-completion before claiming any task done: paste the actual build/run output, don't assert success.

**Compile gate command (important):** `build.sh` builds *and runs* every target, and `invaders` (the only Simp-compiling target) is a GUI game with no frame cap. Use the **`compile_only`** flag for all "does it compile?" gates — it builds the workspace and skips the run:
```
./build.sh - compile_only invaders     # headless compile check of the whole Simp module
ldd build/invaders                       # inspects the binary; no run needed, always safe
```
Jai type-checks every `#load`ed file in a module regardless of which OS branch executes, so `compile_only invaders` is a *real* gate on `wayland_gl.jai` + `wayland_dispatch.jai` even while the X11 path is what would run.

**Two gate classes:**
- **Compile / ldd / regression-suite gates** — headless, safe to run autonomously: `./build.sh - compile_only <target>`, `ldd build/<target>`, `./build.sh - test`/`- compile_test`.
- **Functional / observation gates** — require the live Hyprland session and a human watching (triangle appears? invaders plays? resize artifacts?). These are **checkpoints batched for when the user is present** — do not block autonomous progress on them, but do not claim them passed without the user's confirmation.

**Branch:** work continues on `upstream-integration` (where the design doc was committed). Frequent commits per task.

---

# SLICE 1 — `hello_simp` triangle on Wayland (the gate)

Proves §1 state split, §2 render-target ownership, §3 block-on-frame-callback. No input, no resize.

---

### Task 1: Add Wayland GL-state fields to the Linux `Window_Info_Platform_Specific`

**Files:**
- Modify: `modules/Simp/backend/gl.jai:1094-1100` (the `#if OS == .LINUX` struct block)

**Step 1 — Extend the struct.** Add the Wayland backend state next to `glx_window`. The slot array reuses the helper type defined in Task 4 (forward-referenced; this task only declares fields whose types resolve once `wayland_gl.jai` is loaded — so do this task and Task 4 in the same compile cycle, or stub `Wl_Gl_Slot`/`Wl_Egl_State` first).

```jai
#if OS == .LINUX {
    Backend_Platform_Specific :: struct {
    }

    Window_Info_Platform_Specific :: struct {
        glx_window: GLXWindow;          // X11 path (unchanged)

        // Wayland path. Populated by simp_wayland_dispatch's BACKEND_INIT.
        // Mirrors how glx_window is Simp's per-window X11 backend handle.
        wl_egl:        Wl_Egl_State;    // EGL display/context + GBM device + drm fd
        wl_slots:      [SIMP_WL_SLOT_COUNT] Wl_Gl_Slot;
        wl_current:    s32 = -1;        // index of the slot currently being rendered
        wl_initted:    bool;
    }
}
```

`SIMP_WL_SLOT_COUNT`, `Wl_Egl_State`, `Wl_Gl_Slot` are defined in Task 4's `wayland_gl.jai`.

**Step 2 — Build to confirm it compiles after Task 4 lands.** (This task cannot independently compile; it pairs with Task 4. Sequence: write Task 4's types first, then this.)

**Step 3 — Commit** (combined with Task 4).

---

### Task 2: Populate `Wayland_Window_State` with surface identity

**Files:**
- Modify: `modules/Window_Type.jai:32-58`

**Step 1 — Give the placeholder real fields.**

```jai
Wayland_Window_State :: struct {
    surface:      u32;        // wl_surface id
    xdg_surface:  u32;        // xdg_surface id
    xdg_toplevel: u32;        // xdg_toplevel id
    width:        s32;        // last configured size
    height:       s32;
    configured:   bool;       // has the first xdg configure arrived?
}
```

**Step 2 — Fix the `.Wayland` arm of `operator ==`** (currently `return true` on the empty struct):

```jai
operator == :: (a: Window_Type, b: Window_Type) -> bool {
    if a.wtype != b.wtype  return false;
    if a.wtype == {
        case .X11;     return a.x11 == b.x11;
        case .Wayland; return a.wayland.surface == b.wayland.surface;
    }
    return false;
}
```

**Step 3 — Regression gate.**
Run: `./build.sh - compile_test`
Expected: PASS (all 11 compilation smoke tests) — confirms the generated module + types still compile with the changed `Window_Type`.

**Step 4 — Build invaders to confirm X11 path is unbroken** (the Wayland fields are inert on X11):
Run: `./build.sh - invaders` then `ldd build/invaders`
Expected: exit 0; ldd shows only libc/vdso/ld-linux.

**Step 5 — Commit.**
```bash
git add modules/Window_Type.jai
git commit -m "feat(Window_Type): give Wayland_Window_State surface identity fields"
```

---

### Task 3: `window_framebuffer(info)` + generalize the FBO bind (§2)

**Files:**
- Modify: `modules/Simp/backend/gl.jai:955-956` and add helper nearby

**Step 1 — Add the helper** (backend-agnostic; lives in `gl.jai`):

```jai
// The handle Simp binds as "the window's framebuffer". On X11/GLX this is the
// GLX drawable (framebuffer 0). On Wayland there is no window-system default
// framebuffer — we render into the current BO-backed slot's FBO and export it.
// X11 is the degenerate case (0), not a special case.
window_framebuffer :: (info: *Window_Info) -> GLuint {
    #if OS == .LINUX {
        if info.window.wtype == .Wayland {
            if info.specific.wl_current >= 0
                return info.specific.wl_slots[info.specific.wl_current].fbo;
            return 0;  // pre-first-slot; harmless
        }
    }
    return 0;
}
```

**Step 2 — Patch the hardcoded bind** at `gl.jai:956`:
```jai
    glViewport(0, 0, xx info.window_width, xx info.window_height);
    glBindFramebuffer(GL_FRAMEBUFFER, window_framebuffer(info));   // was: , 0
```

**Step 3 — Regression + X11 functional gate.** X11 must be byte-for-byte unaffected (helper returns 0 for the X11 tag).
Run: `./build.sh - invaders`; launch it (X11 session or `WAYLAND_DISPLAY=` unset); confirm it still plays.
Expected: identical behavior to before.

**Step 4 — Commit.**
```bash
git add modules/Simp/backend/gl.jai
git commit -m "feat(Simp): generalize window FBO bind via window_framebuffer(info)"
```

---

### Task 4: Port hello_gl's GL machinery into `modules/Simp/backend/wayland_gl.jai`

This is the bulk. It is a **port**, not a rewrite: lift the known-good logic from `hello_gl.jai`, re-homing locals into struct fields the dispatcher can reach. `hello_gl.jai` is **not** modified.

**Files:**
- Create: `modules/Simp/backend/wayland_gl.jai`
- Modify: `modules/Simp/module.jai` (add `#load "backend/wayland_gl.jai";` next to the other backend loads)

**Step 1 — Define the state types** (referenced by Task 1). Port `Gl_Slot` from `examples/hello_gl.jai:31-51` verbatim, renamed `Wl_Gl_Slot`; port the EGL/GBM context from `EGL_Context` (`hello_gl.jai:363`) renamed `Wl_Egl_State` (add `drm_fd`, `gbm`, `dpy`, `ctx`).

```jai
// Ported from examples/hello_gl.jai (the Option-B reference). Re-homed from
// example locals into structs reachable via Window_Info.specific.
SIMP_WL_SLOT_COUNT :: 2;   // double-buffered, matching hello_gl

Wl_Gl_Slot :: struct {
    // ... port hello_gl.jai:31-51 Gl_Slot fields verbatim ...
}

Wl_Egl_State :: struct {
    // ... port hello_gl.jai EGL_Context fields (drm_fd, gbm, dpy, ctx) ...
}
```

**Step 2 — Port the EGL/GBM init.** Adapt `init_gl_stack` (`hello_gl.jai:370-425`) into `wl_egl_init(egl: *Wl_Egl_State) -> bool`. Same body; writes into the passed struct instead of a local. Uses `modules/gpu` render-node selection and `init_egl`/`init_gbm`/`init_gl` loaders exactly as hello_gl does.

**Step 3 — Port slot allocation.** Adapt `init_slot` / `init_slot_bo` / `init_slot_mesa` (`hello_gl.jai:509-620`) into `wl_slot_init(egl, slot, width, height, fmt)`. Same format/modifier selection (`choose_dmabuf_format` + feedback path, `hello_gl.jai:433-508`) — port those helpers too, or call into a shared form.

**Step 4 — Port wl_buffer creation.** Adapt `queue_dmabuf_buffer` (`hello_gl.jai:621-642`) into `wl_slot_make_buffer(slot, surface_id, dmabuf_global)` — builds the `zwp_linux_dmabuf_v1` params and creates the `wl_buffer`.

**Step 5 — Port slot teardown + retire.** Adapt `destroy_slot` / `retire_slots` / `release_retired_slot` / `find_free_slot` (`hello_gl.jai:643-685`).

**Step 6 — Frame-callback drain helper.** Extract hello_gl's render-loop event handling (the part that pumps `for session()`, routes `wl_callback.done` and `wl_buffer.release` by `(object_id, opcode)` — see the wire-protocol gotcha in CLAUDE.md) into `wl_block_on_frame(egl, slots, surface_id) ` used by `SWAP_BUFFERS`.

**Step 7 — Build the regression suite to confirm the module loads & types resolve.**
Run: `./build.sh - compile_test`
Expected: PASS. (Also pairs with Task 1 — the `Window_Info_Platform_Specific` fields now resolve.)

**Step 8 — Commit** (Tasks 1 + 4 together, since they’re a compile unit).
```bash
git add modules/Simp/backend/wayland_gl.jai modules/Simp/backend/gl.jai modules/Simp/module.jai
git commit -m "feat(Simp): port hello_gl GL/slot/export machinery into wayland_gl.jai"
```

---

### Task 5: Implement the four-op `simp_wayland_dispatch`

**Files:**
- Modify: `modules/Simp/backend/wayland_dispatch.jai` (replace the asserting stub)

**Step 1 — Replace the stub** with the real dispatcher over `wayland_gl.jai`:

```jai
simp_wayland_dispatch :: (args: *Simp_Op_Args, info: *Window_Info) {
    s := *info.specific;
    if args.op == {
        case .BACKEND_INIT;
            wl_egl_init(*s.wl_egl);
            fmt := /* chosen dmabuf format/modifier */;
            for 0..SIMP_WL_SLOT_COUNT-1
                wl_slot_init(*s.wl_egl, *s.wl_slots[it], info.window_width, info.window_height, fmt);
            s.wl_current = 0;
            s.wl_initted = true;
            // make context current:
            eglMakeCurrent(s.wl_egl.dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, s.wl_egl.ctx);

        case .BACKEND_SET_RENDER_TARGET;
            // Make the EGL context current. The FBO bind itself happens in
            // gl.jai's backend-agnostic tail via window_framebuffer(info).
            eglMakeCurrent(s.wl_egl.dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, s.wl_egl.ctx);

        case .BACKEND_RESIZE_RENDER_TARGET;
            // Slice 2 fills this in (retire + realloc slots at new size).

        case .SWAP_BUFFERS;
            slot := *s.wl_slots[s.wl_current];
            glFinish();
            wl_slot_make_buffer(slot, info.window.wayland.surface, /* dmabuf global */);
            // attach + commit + request frame callback:
            // wl_surface_attach, wl_surface_damage_buffer, wl_surface_frame,
            // wl_surface_commit  (port from hello_gl's present path)
            wl_block_on_frame(*s.wl_egl, s.wl_slots, info.window.wayland.surface);
            next := wl_find_free_slot(s.wl_slots);   // driven by wl_buffer.release
            if next >= 0  s.wl_current = next;
    }
}
```

(Exact attach/commit calls: port from hello_gl's present sequence. The dmabuf global + session come from `context.wayland_session`.)

**Step 2 — Build.**
Run: `./build.sh - compile_test`
Expected: PASS (dispatcher compiles against the helper + ops).

**Step 3 — Commit.**
```bash
git add modules/Simp/backend/wayland_dispatch.jai
git commit -m "feat(Simp): implement simp_wayland_dispatch (init/set-target/swap)"
```

---

### Task 6: Wayland arm of `create_window`

**Files:**
- Modify: `modules/Window_Creation/linux.jai:102-198`

**Step 1 — Branch after the dispatch-init line.** Add immediately after `linux.jai:103`:

```jai
create_window :: (width: int, height: int, window_name: string, ...) -> Window_Type {
    if !context.simp_dispatch  init_linux_window();
    #if OS == .LINUX {
        if running_wayland()  return create_window_wayland(width, height, window_name);
    }
    // ... existing X11 body unchanged ...
}
```

**Step 2 — Implement `create_window_wayland`** (new proc in `linux.jai`): ensure `init_wayland_session()`; allocate + create `wl_surface`, `xdg_surface`, `xdg_toplevel` (port from `hello_gl.jai:99-110`); set title; commit; pump until first `xdg_toplevel.configure` to capture initial size (port from `hello_gl.jai:111-120`); return `.{ wtype = .Wayland, wayland = .{ surface=…, xdg_surface=…, xdg_toplevel=…, width=…, height=…, configured=true } }`.

**Step 3 — Build.**
Run: `./build.sh - compile_test` then `./build.sh - invaders` (X11 still compiles).
Expected: PASS; invaders builds.

**Step 4 — Commit.**
```bash
git add modules/Window_Creation/linux.jai
git commit -m "feat(Window_Creation): Wayland arm of create_window"
```

---

### Task 7: Real `running_wayland()` (§5)

**Files:**
- Modify: `modules/Window_Creation/linux_init.jai:12-18`

**Step 1 — Replace the `return false;` stub:**
```jai
running_wayland :: () -> bool {
    return to_string(getenv("WAYLAND_DISPLAY")).count > 0;
}
```
(`getenv` via `#import "POSIX"`; `to_string` handles the null case → count 0.)

**Step 2 — Commit.**
```bash
git add modules/Window_Creation/linux_init.jai
git commit -m "feat(Window_Creation): real running_wayland() via WAYLAND_DISPLAY"
```

---

### Task 8: `examples/hello_simp.jai` + build target

**Files:**
- Create: `examples/hello_simp.jai`
- Modify: `first.jai` (add the example target), `build.sh` (doc the target if it enumerates them)

**Step 1 — Write the minimal Simp harness** (~60–80 lines): `Simp.set_render_target` on a `create_window` result, loop { `Simp.clear_render_target(...)` → draw one immediate-mode triangle via `Simp.immediate_*` → `Simp.swap_buffers(window)` }. Honor `JAI_WAYLAND_SIMP_FRAMES=N` for bounded runs (mirror hello_gl's frame-cap env handling).

**Step 2 — Wire the target into `first.jai`** following the existing example-target pattern (search `first.jai` for `hello_gl` and replicate).

**Step 3 — Commit (pre-run wiring).**
```bash
git add examples/hello_simp.jai first.jai build.sh
git commit -m "feat(examples): hello_simp — minimal Simp-on-Wayland harness"
```

---

### Task 9: SLICE 1 VALIDATION GATE

**Step 1 — Build:** `./build.sh - hello_simp` → expect exit 0, `build/hello_simp` exists.

**Step 2 — ldd-clean:** `ldd build/hello_simp` → expect only `libc.so.6`, `linux-vdso`, `ld-linux-x86-64`. **No `libwayland*`, no `libEGL`, no `libgbm`.** If any appear, a static link leaked — stop and fix.

**Step 3 — Functional:** run on the Hyprland (Wayland) session → **observe a rendered, animating triangle**. Use `JAI_WAYLAND_SIMP_FRAMES=120` for a bounded run.

**Step 4 — X11 non-regression:** `WAYLAND_DISPLAY= ./build/hello_simp` (or on an X11 session) → triangle renders via the X11/GLX path (proves the branch + `window_framebuffer` degenerate case).

**Step 5 — Regression suite:** `./build.sh - test`, `- compile_test` (and the rest) → all 111 pass.

Use @superpowers:verification-before-completion: paste actual ldd + run output before declaring Slice 1 done. **Slice 1 passing is the project's de-risking milestone** — the real unknowns are now retired.

---

# SLICE 2 — Compositor-driven resize

### Task 10: Implement `BACKEND_RESIZE_RENDER_TARGET` (Wayland)

**Files:** `modules/Simp/backend/wayland_dispatch.jai`, `wayland_gl.jai`

**Step 1** — On resize: retire in-flight slots (`wl_slot`-level retire/realloc ported from `hello_gl.jai:654-668`), reallocate `wl_slots` at the new `info.window_width/height`, reset `wl_current`. The `Backend_Resize_Render_Target_Args` already carries `new_width/new_height`.
**Step 2** — Route the `xdg_toplevel.configure` → `xdg_surface.configure` ack and Simp's `resize_render_target` call (the Wayland event loop must feed new sizes; in `hello_simp`, handle configure like hello_gl does).
**Step 3** — Build + run `hello_simp`, drag-resize the window, confirm no artifacts/leaks.
**Step 4** — Commit.

---

# SLICE 3 — Input pump

### Task 11: Wayland → `Input.events_this_frame` pump

**Files:** vendored `modules/Input/` (add `wayland.jai`), a `#add_context input_pump` or direct tag-dispatch in `Input`'s per-frame `update_window_events`.

**Step 1** — Translate our wire events into Input events: use `get_keyboard_event` / `get_pointer_event` (`modules/wayland/input.jai`) + the xkb keymap (`parse_keymap_fd`) for keysyms; populate `Input.events_this_frame` / `input_button_states` mirroring what the X11 `x11.jai` pump produces.
**Step 2** — Decide the dispatch shape (mirror Simp's `#add_context` pattern for symmetry).
**Step 3** — Extend `hello_simp` (or a new `hello_simp_input`) to print key/click events; verify on Hyprland.
**Step 4** — Commit.

---

# SLICE 4 — invaders on Wayland (integration confirmation)

### Task 12: Validate invaders end-to-end on Wayland

**Step 1** — `./build.sh - invaders` on the Wayland session.
**Step 2** — `ldd build/invaders` → ldd-clean (no libwayland).
**Step 3** — Play: window opens, animation ≥60fps, keyboard moves/fires, sound plays, clean exit.
**Step 4** — X11 non-regression: `WAYLAND_DISPLAY=` → invaders still plays via X11.
**Step 5** — Full regression suite green (111 tests).
**Step 6** — Update CLAUDE.md "Backend dispatch infrastructure" + "Next Steps #4" to mark Stage 2 complete; commit. Consider `git` milestone commit mirroring Stage 1's `milestone:` style.

Use @superpowers:verification-before-completion at Step 3/5 — paste real output.

---

## Sequencing notes

- **Tasks 1 + 4 are a single compile unit** (struct fields reference helper types). Land them together.
- Tasks 2, 3, 6, 7, 8 each compile independently and commit separately.
- Do not start Slice 2 until Slice 1's gate (Task 9) is green with pasted evidence.
- `hello_gl.jai` is never edited. If you find yourself editing it, stop — re-read the design doc §4.
