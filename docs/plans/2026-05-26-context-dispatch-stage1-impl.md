# Context-Based Backend Dispatch — Stage 1 (X11) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Wire context-based dispatch into vendored Simp so the X11 GL backend goes through `context.simp_dispatch` instead of inline `#if OS == .LINUX` branches. invaders runs identically afterward. Stage 2 will fill in the Wayland branch behind the same interface.

**Architecture:** New file `modules/Window_Type.jai` (vendored from upstream; Linux branch becomes a tagged union of X11 + Wayland variants). New files `modules/Simp/backend/{dispatch,x11_dispatch,wayland_dispatch}.jai`. The X11 GLX logic currently inside `gl.jai`'s `#if OS == .LINUX` branches relocates verbatim into `simp_x11_dispatch`. `gl.jai`'s Linux branches become `context.simp_dispatch(*args, info)` calls. A new `init_linux_window()` in vendored Window_Creation pushes the dispatcher into context; it's called lazily on first `create_window` invocation.

**Tech Stack:** Jai (`~/jai/jai/bin/jai-linux`), bash, git. No new external dependencies.

**Design reference:** `docs/plans/2026-05-26-context-dispatch-stage1-design.md`

**Branch:** continuing on `upstream-integration` (the integration goal is X11/Wayland working seamlessly — Stage 1 is part of that goal).

**Required skill before writing Jai code:** `jai-language` (per project CLAUDE.md).

---

## Validation Checkpoints (Stage 1 success criteria, from design doc)

These are the gates. The branch is done when all five pass:

| # | Signal |
|---|---|
| 1 | `./build.sh - invaders` exits 0; `build/invaders` exists |
| 2 | `ldd build/invaders` shows only libc + linux-vdso + ld-linux-x86-64 — no new libraries |
| 3 | Existing examples build: `./build.sh - hello_gl`, `- hello_x11_gl`, `- headless_gl`, `- x11_smoke`, `- headless_vulkan` — all OK, ldd clean |
| 4 | All 111 tests pass: `./build.sh - test gen_test wire_test marshal_test unmarshal_test compile_test` |
| 5 | invaders plays identically: window opens, animation at 60+ fps, keyboard works, sound plays, clean exit |

---

## Phase 1 — Vendor `Window_Type` and Establish the Tagged Union

### Task 1: Vendor `Window_Type.jai` with extended Linux branch

**Files:**
- Create: `modules/Window_Type.jai` (vendored from upstream, Linux branch modified)

**Step 1: Read the upstream file**

```bash
cat ~/jai/jai/modules/Window_Type.jai
```

Note its structure. It's small — single file with per-OS conditional definitions of `Window_Type`. The Linux branch currently looks like `Window_Type :: X11.Window;` or similar.

**Step 2: Determine line-ending convention**

```bash
file ~/jai/jai/modules/Window_Type.jai
grep -c $'\r' ~/jai/jai/modules/Window_Type.jai
```

If CRLF, preserve that when writing. The vendoring convention from the upstream-integration branch is to match upstream's line endings exactly.

**Step 3: Create the vendored file**

`modules/Window_Type.jai` content (adapted from upstream — non-Linux branches stay byte-identical; Linux branch is the new content):

```jai
// Vendored from ~/jai/jai/modules/Window_Type.jai.
// Modified: Linux branch extended from `Window_Type :: X11.Window` to a
//           tagged union covering both X11 and Wayland backends, to
//           support runtime backend selection. See
//           docs/plans/2026-05-26-context-dispatch-stage1-design.md.

#if OS == .WINDOWS {
    // (verbatim from upstream Windows branch)
} else #if OS == .LINUX {
    #scope_module
    X11 :: #import "X11";
    #scope_export

    Window_Tag :: enum u32 {
        X11;
        Wayland;
    }

    // Stage 1 placeholder. Stage 2 populates this with EGL_Context +
    // wl_surface/xdg_surface refs + BO slot state. The struct exists
    // now so the tagged union compiles; it is never instantiated in
    // Stage 1 (running_wayland() always returns false).
    Wayland_Window_State :: struct {
    }

    Window_Type :: union wtype: Window_Tag {
        .X11     ,, x11     : X11.Window;
        .Wayland ,, wayland : Wayland_Window_State;
    }

    INVALID_WINDOW : Window_Type : .{ wtype = .X11, x11 = 0 };
    // X11 Window 0 is None — valid sentinel for X11. Stage 2 may want
    // to revisit if Wayland needs a different sentinel for its variant.
} else #if OS == .MACOS {
    // (verbatim from upstream MacOS branch)
} else #if OS == .ANDROID {
    // (verbatim from upstream Android branch)
} else {
    // (verbatim catch-all from upstream, if any)
}
```

**Important:** preserve the upstream file's content for non-Linux branches. Read upstream first, copy non-Linux text verbatim, only edit the Linux branch.

**Step 4: Verify upstream callers of `Window_Type` still resolve correctly**

```bash
grep -rn 'Window_Type\b' ~/jai/jai/modules/ | head -20
```

Note callers (Window_Creation, Input, Simp). They use `Window_Type` as a value type — passing it around, comparing for equality, storing it. Our tagged-union shape changes its layout but Jai's `union` syntax means `wt.x11` accessor still works for X11 windows. Callers that only ever produce / consume X11 windows continue to work.

**Step 5: Build a sanity-check example that doesn't touch Window_Type**

```bash
./build.sh - test
```

Expected: 22 XML tests pass. If `first.jai` parses OK and project compiles, our new `modules/Window_Type.jai` doesn't break the project-internal modules (which don't import Window_Type).

**Step 6: Commit**

```bash
git add modules/Window_Type.jai
git commit -m "$(cat <<'EOF'
vendor: Window_Type.jai with Linux branch extended to tagged union

Linux Window_Type becomes a tagged union (Window_Tag :: X11 | Wayland)
carrying X11.Window for X11 and a Wayland_Window_State placeholder for
Wayland. Stage 1 only ever uses the X11 variant; the Wayland variant
exists structurally so the tagged union compiles and Stage 2 can fill
it in without restructuring.

Non-Linux branches (Windows / MacOS / Android) stay verbatim from
upstream.

See docs/plans/2026-05-26-context-dispatch-stage1-design.md.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Phase 2 — Simp Dispatch Infrastructure

### Task 2: Create `modules/Simp/backend/dispatch.jai`

**Files:**
- Create: `modules/Simp/backend/dispatch.jai`
- Modify: `modules/Simp/module.jai` (add `#load "backend/dispatch.jai";` next to existing backend loads; bump the "Modified" header)

**Step 1: Inspect the existing `module.jai` to find the right place to add the `#load`**

```bash
grep -n '#load "backend/' modules/Simp/module.jai
```

Note where the existing `#load "backend/gl.jai";` (and `gl_screenshot`, `none`) sit. We add `dispatch.jai` BEFORE `gl.jai` because `gl.jai`'s Linux branches will reference `Simp_Op_Args` and `context.simp_dispatch`.

**Step 2: Create `modules/Simp/backend/dispatch.jai`**

```jai
// New file (not vendored — original to this project).
// Subsystem dispatch types and #add_context field for the vendored Simp
// backend. See docs/plans/2026-05-26-context-dispatch-stage1-design.md.

Simp_Op_Tag :: enum u32 {
    BACKEND_INIT;
    BACKEND_SET_RENDER_TARGET;
    BACKEND_RESIZE_RENDER_TARGET;
    SWAP_BUFFERS;
}

Backend_Init_Args                 :: struct { }
Backend_Set_Render_Target_Args    :: struct { }
Backend_Resize_Render_Target_Args :: struct {
    new_width:  s32;
    new_height: s32;
}
Swap_Buffers_Args :: struct {
    vsync: bool = true;
}

Simp_Op_Args :: union op: Simp_Op_Tag {
    .BACKEND_INIT                 ,, init                  : Backend_Init_Args;
    .BACKEND_SET_RENDER_TARGET    ,, set_render_target     : Backend_Set_Render_Target_Args;
    .BACKEND_RESIZE_RENDER_TARGET ,, resize_render_target  : Backend_Resize_Render_Target_Args;
    .SWAP_BUFFERS                 ,, swap_buffers          : Swap_Buffers_Args;
}

Simp_Backend_Dispatch :: #type (args: *Simp_Op_Args, info: *Window_Info) -> void;

#add_context simp_dispatch: Simp_Backend_Dispatch;
```

**Important:** the per-op arg structs are mostly empty in Stage 1. The data needed for each op already lives in `info`. The structs exist so Stage 2's Wayland dispatcher can add fields without restructuring.

**Step 3: Add the `#load` to `modules/Simp/module.jai`**

Use Edit to insert `    #load "backend/dispatch.jai";` BEFORE the existing `#load "backend/gl.jai";` line. Also update the file's "Modified" header annotation if it's currently saying "Verbatim copy" — bump it to mention the dispatch infrastructure additions.

Actually, since `modules/Simp/module.jai` has not been patched yet in the upstream-integration branch, its header still says "Verbatim copy." This task changes that. Update the header:

```jai
// Vendored from ~/jai/jai/modules/Simp/module.jai.
// Modified: added #load directives for backend/dispatch.jai,
//           backend/x11_dispatch.jai, backend/wayland_dispatch.jai
//           (the context-based dispatch infrastructure).
//           See docs/plans/2026-05-26-context-dispatch-stage1-design.md.
```

(For Stage 1 this commit only adds the dispatch.jai #load; the other two come in subsequent commits. Phrase the header to anticipate them.)

**Step 4: Compile sanity check**

```bash
./build.sh - test
```

Expected: tests pass. If dispatch.jai has a syntax error or the #load is misplaced, the build dies before tests run.

**Step 5: Commit**

```bash
git add modules/Simp/backend/dispatch.jai modules/Simp/module.jai
git commit -m "$(cat <<'EOF'
feat(Simp): add context dispatch infrastructure

modules/Simp/backend/dispatch.jai defines Simp_Op_Tag, Simp_Op_Args
(tagged union of per-op arg structs), Simp_Backend_Dispatch (the
function-pointer type), and #add_context simp_dispatch.

This is the type infrastructure that x11_dispatch.jai (Task 3),
wayland_dispatch.jai (Task 4), and gl.jai's refactored Linux branches
(Task 5) will all reference.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Phase 3 — X11 Dispatcher (Relocate Existing Code)

### Task 3: Create `modules/Simp/backend/x11_dispatch.jai`

**Files:**
- Create: `modules/Simp/backend/x11_dispatch.jai`
- Modify: `modules/Simp/module.jai` (add `#load "backend/x11_dispatch.jai";` after the dispatch.jai load)

**Step 1: Read the existing X11 GLX code in `gl.jai`**

```bash
grep -n '#if OS == .LINUX' modules/Simp/backend/gl.jai
```

For each match, read enough context to understand what the Linux branch is doing. Specifically, find these four functions:

- `backend_init` (where GLX context is created with `glx_create_context`)
- `backend_set_render_target` (where `glXMakeCurrent` is called)
- `backend_resize_render_target` (may be empty/no-op on X11)
- `swap_buffers` (where `glXSwapBuffers` is called)

Read each function's Linux branch body. These bodies will be RELOCATED, not modified. The new file's contents are exactly these bodies, restructured into a single switch.

**Step 2: Create `modules/Simp/backend/x11_dispatch.jai`**

```jai
// New file (not vendored — original to this project).
// X11/GLX dispatcher for vendored Simp. Body relocated verbatim from
// modules/Simp/backend/gl.jai's #if OS == .LINUX branches.
// See docs/plans/2026-05-26-context-dispatch-stage1-design.md.

simp_x11_dispatch :: (args: *Simp_Op_Args, info: *Window_Info) {
    if args.op == {
        case .BACKEND_INIT;
            // (Relocated from backend_init's #if OS == .LINUX branch.)
            // The existing body created the GLX context via glx_create_context
            // and set up the_gl_context, the_gl_fbc, info.msaa.
            //
            // PASTE the existing body here, verbatim.

        case .BACKEND_SET_RENDER_TARGET;
            // (Relocated from backend_set_render_target's #if OS == .LINUX branch.)
            //
            // PASTE the existing body here, verbatim. Likely:
            //   glx_window := glXCreateWindow(x_global_display, the_gl_fbc, info.window, null);
            //   info.specific.glx_window = glx_window;
            //   ... etc.

        case .BACKEND_RESIZE_RENDER_TARGET;
            // (Relocated from backend_resize_render_target's #if OS == .LINUX branch.)
            // Likely empty / no-op on X11 since GLX handles it.

        case .SWAP_BUFFERS;
            // (Relocated from swap_buffers's #if OS == .LINUX branch.)
            //
            // glXSwapBuffers(x_global_display, info.specific.glx_window);
    }
}
```

When relocating: copy the existing body **verbatim** including comments, asserts, etc. Don't refactor inside the move. This is a code-relocation task, not a code-improvement task.

**Important caveat:** if the existing `backend_init` body has `do_first_time_init` logic, that machinery may need to be split between `gl.jai` (the part that's backend-agnostic — `gl_load(glXGetProcAddress)`, `glGenVertexArrays`, etc.) and `x11_dispatch.jai` (the GLX-specific part — `glx_create_context`, `glXMakeCurrent` on first init). Read the existing function carefully before splitting. The backend-agnostic GL initialization stays in gl.jai; only the X11/GLX-specific bits move to x11_dispatch.

**Step 3: Add `#load` to module.jai**

Insert `    #load "backend/x11_dispatch.jai";` after the dispatch.jai #load.

**Step 4: Compile sanity check**

```bash
./build.sh - test
```

Expected: tests pass. **Don't yet try to build invaders or hello_x11_gl** — those depend on the gl.jai changes that come in Task 5. Right now `simp_x11_dispatch` exists but nobody calls it; that's fine, the project compiles.

**Step 5: Commit**

```bash
git add modules/Simp/backend/x11_dispatch.jai modules/Simp/module.jai
git commit -m "$(cat <<'EOF'
feat(Simp): X11/GLX dispatcher (body relocated from gl.jai)

modules/Simp/backend/x11_dispatch.jai houses simp_x11_dispatch, the
X11/GLX backend dispatcher. The body is RELOCATED VERBATIM from the
#if OS == .LINUX branches that currently live inside gl.jai's
backend_init / backend_set_render_target / backend_resize_render_target /
swap_buffers functions.

This commit doesn't yet wire those gl.jai sites to call through context
to here — that's Task 5. Right now simp_x11_dispatch exists but is
unreferenced; the project still compiles.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Phase 4 — Wayland Stub

### Task 4: Create `modules/Simp/backend/wayland_dispatch.jai` (Stage 1 stub)

**Files:**
- Create: `modules/Simp/backend/wayland_dispatch.jai`
- Modify: `modules/Simp/module.jai` (add `#load "backend/wayland_dispatch.jai";` after x11_dispatch.jai)

**Step 1: Create the stub file**

```jai
// New file (not vendored — original to this project).
// Wayland dispatcher placeholder. Stage 1 stub; Stage 2 implementation
// will fill in the body with EGL-on-GBM + DMA-BUF presentation (the
// same architecture hello_gl.jai uses).
// See docs/plans/2026-05-26-context-dispatch-stage1-design.md and
// docs/plans/2026-05-26-wayland-backend-question.md (Option B).

simp_wayland_dispatch :: (args: *Simp_Op_Args, info: *Window_Info) {
    assert(false, "Wayland backend dispatcher not yet implemented (Stage 2). running_wayland() should currently return false; if you hit this, init_linux_window picked the wrong path.");
}
```

**Step 2: Add `#load` to module.jai**

Insert `    #load "backend/wayland_dispatch.jai";` after the x11_dispatch.jai #load.

**Step 3: Compile sanity check**

```bash
./build.sh - test
```

Expected: tests pass.

**Step 4: Commit**

```bash
git add modules/Simp/backend/wayland_dispatch.jai modules/Simp/module.jai
git commit -m "$(cat <<'EOF'
feat(Simp): Wayland dispatcher placeholder (Stage 2 will implement)

modules/Simp/backend/wayland_dispatch.jai is a stub that asserts. Stage
1 only routes through it when running_wayland() returns true, which
running_wayland() never does in Stage 1 — so the assertion is
unreachable.

The file exists in Stage 1 so the architectural skeleton is visible
(parallel x11_dispatch.jai / wayland_dispatch.jai) and the
init_linux_window's `if running_wayland()` branch is reachable as a
compile target.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Phase 5 — Splice Dispatch Calls in `gl.jai`

### Task 5: Refactor `gl.jai`'s four `#if OS == .LINUX` branches

**Files:**
- Modify: `modules/Simp/backend/gl.jai` (four functions)

**Step 1: Identify the exact lines**

```bash
grep -n '#if OS == .LINUX' modules/Simp/backend/gl.jai
```

Expected: four matches inside `backend_init`, `backend_set_render_target`, `backend_resize_render_target`, `swap_buffers`. Note the line numbers.

**Step 2: For each match, refactor the Linux branch**

The pattern is: replace the body of `#if OS == .LINUX { ... }` with a `context.simp_dispatch(*args, info)` call, leaving the body that's truly backend-agnostic (e.g., `gl_load`, `glViewport`, FBO setup if it's in `backend_init`) in place outside the conditional.

**For `backend_set_render_target(info)`** — the existing pattern is something like:

```jai
#if OS == .LINUX {
    success := glXMakeCurrent(...);
    // ... GLX-specific make-current logic ...
}
```

Becomes:

```jai
#if OS == .LINUX {
    args := Simp_Op_Args.{ op = .BACKEND_SET_RENDER_TARGET };
    context.simp_dispatch(*args, info);
}
```

**For `swap_buffers(window, vsync)`** — note this function takes `Window_Type` directly, not `*Window_Info`. The Linux branch may need to construct a temporary Window_Info or reach for window state another way. Read the existing body. If swap_buffers currently does `glXSwapBuffers(x_global_display, info.specific.glx_window)`, it must be deriving `info` from `window` somehow — possibly via a lookup table or a passed-in arg. Match whatever pattern exists.

If swap_buffers really doesn't have an `info` available, the dispatch needs to look up the window's Window_Info by Window_Type — that's an implementation detail to resolve here. One option: change Window_Info to be reachable from Window_Type (it's not currently), OR have swap_buffers maintain a side-table, OR have the dispatcher work without info (use globals directly).

(Pragmatically: stock Simp's swap_buffers probably uses module-level globals like `x_global_display` and `the_gl_context`. The dispatcher can do the same — pass a stub `info`-equivalent or just nil if unused. Read the existing swap_buffers carefully.)

**For `backend_init(info)`** — relocate ONLY the X11/GLX-specific bits to the dispatcher. The `gl_load(glXGetProcAddress)` call IS GLX-specific (relies on glXGetProcAddress); it moves into the dispatcher. Things like `glGenVertexArrays(1, *opengl_is_stupid_vao)` are backend-agnostic GL ops; they stay in gl.jai outside the dispatch.

Read the existing `backend_init` Linux branch carefully and decide what's GLX-specific (move) vs. what's backend-agnostic GL setup (stay). When in doubt: if the call references `glX*` or `x_global_display`, it's GLX-specific and moves.

**For `backend_resize_render_target(info)`** — if the existing Linux branch is empty or trivial, the refactor may produce an empty dispatcher case. That's fine.

**Step 3: Verify the relocation lines up**

After the refactor:
- gl.jai's four Linux branches are each ~3 lines (build args struct, call dispatch).
- x11_dispatch.jai's four switch cases contain the relocated bodies.
- No GLX-specific symbol appears in gl.jai outside an `#if` guard.

```bash
grep -n 'glX\|x_global_display\|the_gl_context\|the_gl_fbc' modules/Simp/backend/gl.jai
```

Should produce few or no matches in the Linux branches now. (Some may remain — e.g., type declarations or the_gl_context as a shared variable — that's fine.)

**Step 4: Build invaders to validate**

```bash
./build.sh - invaders 2>&1 | tail -20
```

**This is the critical moment.** Expected outcomes:

- If the relocation is correct: invaders compiles. Almost certainly fails at runtime because we haven't yet called `init_linux_window()` to push the dispatch into context — so `context.simp_dispatch` is null and calling it segfaults. That's Task 7.
- If there are compile errors: most likely an unreferenced symbol that should have moved with the relocation, or a symbol declared in x11_dispatch.jai but used in gl.jai (or vice versa). Triage by reading the error and adjusting the split.

For this task, "compiles cleanly" is the success criterion. Runtime failure is expected and acceptable until Task 7.

**Step 5: Update gl.jai's "Modified" header**

Bump the header annotation to reflect this commit's change. Something like:

```jai
// Vendored from ~/jai/jai/modules/Simp/backend/gl.jai.
// Modified: (a) gl_load(*gl) signature swapped to gl_load(glXGetProcAddress) — commit 7a9d296.
//           (b) Four #if OS == .LINUX branches in backend_init/backend_set_render_target/
//               backend_resize_render_target/swap_buffers replaced with context.simp_dispatch
//               calls. The X11/GLX-specific logic relocated verbatim to
//               modules/Simp/backend/x11_dispatch.jai. See
//               docs/plans/2026-05-26-context-dispatch-stage1-design.md.
```

**Step 6: Commit**

```bash
git add modules/Simp/backend/gl.jai
git commit -m "$(cat <<'EOF'
feat(Simp): route Linux branches through context.simp_dispatch

The four #if OS == .LINUX branches inside gl.jai's backend_init,
backend_set_render_target, backend_resize_render_target, and
swap_buffers now construct a Simp_Op_Args and call
context.simp_dispatch(*args, info). The existing GLX-specific logic
relocated to modules/Simp/backend/x11_dispatch.jai in commit <prev>.

invaders compiles after this commit but will SIGSEGV at runtime until
init_linux_window() is wired up (next commit) to push
simp_x11_dispatch into context. Expected — the architectural scaffold
needs both halves.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Phase 6 — Init Ceremony

### Task 6: Create `modules/Window_Creation/linux_init.jai`

**Files:**
- Create: `modules/Window_Creation/linux_init.jai`
- Modify: `modules/Window_Creation/module.jai` (add `#load "linux_init.jai";` to the Linux branch)

**Step 1: Inspect module.jai to find the Linux branch**

```bash
cat modules/Window_Creation/module.jai
```

Locate the `#if OS == .LINUX` branch and where `#load "linux.jai";` is. We add `#load "linux_init.jai";` immediately after it (so linux.jai's symbols are visible to linux_init.jai if needed).

**Step 2: Create `modules/Window_Creation/linux_init.jai`**

```jai
// New file (not vendored — original to this project).
// Subsystem init ceremony for the Linux backend. Detects the runtime
// environment (Wayland vs X11) and pushes the appropriate dispatchers
// into context. Called lazily on first create_window invocation.
// See docs/plans/2026-05-26-context-dispatch-stage1-design.md.

#import "Simp";  // for simp_x11_dispatch / simp_wayland_dispatch

running_wayland :: () -> bool {
    // Stage 1: unconditionally X11.
    // Stage 2 replaces this body with real detection — typically:
    //   wayland_display := to_string(getenv("WAYLAND_DISPLAY"));
    //   return wayland_display.count > 0;
    return false;
}

init_linux_window :: () {
    if running_wayland() {
        context.simp_dispatch = simp_wayland_dispatch;
    } else {
        context.simp_dispatch = simp_x11_dispatch;
    }
    // Stage 2 will also push wc_dispatch and possibly input_pump here.
}
```

**Important:** `#import "Simp"` from within Window_Creation may create an import cycle (if Simp imports Window_Creation transitively). If it does, alternatives:

- Move `init_linux_window` into Simp itself (it's mostly about pushing Simp's dispatcher).
- Or use forward declarations and let the linker resolve.

Try the straightforward import first; resolve the cycle if it surfaces.

**Step 3: Add `#load` to module.jai's Linux branch**

Use Edit to insert `    #load "linux_init.jai";` immediately after `#load "linux.jai";` inside the `#if OS == .LINUX` block. Update the "Modified" header to reflect this change.

**Step 4: Compile sanity check**

```bash
./build.sh - test
```

Expected: tests pass.

**Step 5: Commit**

```bash
git add modules/Window_Creation/linux_init.jai modules/Window_Creation/module.jai
git commit -m "$(cat <<'EOF'
feat(Window_Creation): add init_linux_window ceremony (Stage 1 X11-only)

modules/Window_Creation/linux_init.jai introduces init_linux_window()
and running_wayland(). Stage 1's running_wayland() returns false
unconditionally; Stage 2 replaces with real WAYLAND_DISPLAY detection.

init_linux_window pushes simp_x11_dispatch into context.simp_dispatch.
Wired into create_window in the next commit.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Phase 6.5 — Mid-Execution Scope Expansion (Discovered During Task 7's First Attempt)

The first attempt at Task 7 surfaced an architectural gap that the design
plan didn't anticipate: Task 1's tagged-union `Window_Type` is structurally
incompatible with upstream's stock `Input` module, which writes
`record.window = hwnd` (assigning `X11.Window` u64 to a `Window_Type` field).
Jai forbids `operator =` overloads, so this can only be fixed by vendoring
and patching upstream Input.

Two new tasks (6A and 6B) handle the discovered work. They must complete
before the original Task 7 can succeed.

### Task 6A: Harden Window_Type tagged-union conversion across consumers

**Files:**
- Modify: `modules/Window_Type.jai` (add `operator ==` overloads)
- Modify: `modules/Simp/backend/dispatch.jai` (drop explicit `-> void` on `Simp_Backend_Dispatch`)
- Modify: `modules/Simp/backend/gl.jai` (tagged-union literal syntax for Jai 0.2.029)
- Modify: `modules/Simp/backend/x11_dispatch.jai` (`info.window.x11` extractions)
- Modify: `modules/Simp/module.jai` (`info.window.x11` extraction in `get_render_dimensions`'s Linux branch)

**Step 1: Add `operator ==` overloads to Window_Type**

Tagged unions in Jai don't get implicit equality. Upstream code does both
same-type comparison (`it.window == window` in Simp) and cross-type
comparison (`it.window == hwnd` in Input, where `hwnd: X11.Window`). Both
need overloads.

In `modules/Window_Type.jai` inside the Linux branch, add after the
`Window_Type :: union ...` declaration:

```jai
operator == :: (a: Window_Type, b: Window_Type) -> bool {
    if a.wtype != b.wtype  return false;
    if a.wtype == {
        case .X11;     return a.x11 == b.x11;
        case .Wayland; return true;  // Wayland_Window_State is empty in Stage 1
    }
    return false;
}

operator == :: (a: Window_Type, b: X11.Window) -> bool {
    return a.wtype == .X11 && a.x11 == b;
}
```

**Step 2: Fix `Simp_Backend_Dispatch` return-type annotation**

In `modules/Simp/backend/dispatch.jai`, the current declaration is:
```jai
Simp_Backend_Dispatch :: #type (args: *Simp_Op_Args, info: *Window_Info) -> void;
```

The functions `simp_x11_dispatch` and `simp_wayland_dispatch` declared in
Tasks 3 and 4 use Jai's implicit-no-return convention (no `-> void`).
The explicit `-> void` here mismatches them, breaking assignment of the
function pointers to `context.simp_dispatch` in `init_linux_window`. Drop it:

```jai
Simp_Backend_Dispatch :: #type (args: *Simp_Op_Args, info: *Window_Info);
```

**Step 3: Fix Jai 0.2.029 tagged-union literal syntax in gl.jai**

Jai 0.2.029 requires tagged-union struct literals to have either 0 or 2
field assignments — never 1 (no implicit defaulting of the variant field).
`Simp_Op_Args.{ op = .BACKEND_INIT }` is no longer valid; must become
`Simp_Op_Args.{ op = .BACKEND_INIT, init = .{} }`.

In `modules/Simp/backend/gl.jai`, locate each Simp_Op_Args construction
(Task 5 added them) and update:

```jai
// Before:
args := Simp_Op_Args.{ op = .BACKEND_INIT };
// After:
args := Simp_Op_Args.{ op = .BACKEND_INIT, init = .{} };

// Before:
args := Simp_Op_Args.{ op = .BACKEND_SET_RENDER_TARGET };
// After:
args := Simp_Op_Args.{ op = .BACKEND_SET_RENDER_TARGET, set_render_target = .{} };

// The .SWAP_BUFFERS construction already has two fields (op + swap_buffers)
// and may be fine as-is. Verify.
```

**Step 4: `.x11` extractions where `info.window` flows to `X11.Window`-typed APIs**

In `modules/Simp/backend/x11_dispatch.jai`, several call sites pass
`info.window` to GLX/XLib functions that expect `X11.Window` (u64).
With Window_Type now a tagged union, these need `.x11` extraction:

```jai
// Before (BACKEND_INIT case):
glx_window := glXCreateWindow(x_global_display, the_gl_fbc, info.window, null);
// After:
glx_window := glXCreateWindow(x_global_display, the_gl_fbc, info.window.x11, null);
```

Audit `x11_dispatch.jai` for any other `info.window` usage and apply
the same fix.

Also in `modules/Simp/module.jai`'s `get_render_dimensions` function,
the Linux branch passes `window` directly to `XGetGeometry`. That `window`
is the `Window_Type` parameter — needs `.x11`:

```jai
// Before:
XGetGeometry(x_global_display, window, ..., *width, *height, ...);
// After:
XGetGeometry(x_global_display, window.x11, ..., *width, *height, ...);
```

**Step 5: Build sanity check**

```bash
./build.sh - test
```

Expected: all tests pass. The collateral fixes should produce no behavioral
change — they're entirely about making the post-Task-1 code well-typed
against the tagged-union Window_Type.

```bash
./build.sh - hello_x11_gl 2>&1 | tail -3
```

Expected: compile clean. (Will auto-run — see the prelude in the impl plan
about minimizing visible runs. Use `JAI_WAYLAND_X11_GL_FRAMES=10` if you
want it to exit fast.)

**Step 6: Commit**

```bash
git add modules/Window_Type.jai modules/Simp/backend/dispatch.jai modules/Simp/backend/gl.jai modules/Simp/backend/x11_dispatch.jai modules/Simp/module.jai
git commit -m "$(cat <<'EOF'
patch: harden tagged-union Window_Type across Simp consumers

Task 1 made Window_Type a tagged union but didn't anticipate the
ripple effects on consumers that read/write/compare Window_Type as
if it were the upstream u64 alias. This commit applies the collateral
fixes:

- modules/Window_Type.jai: operator == overloads (same-type and
  cross-type against X11.Window) for the equality checks Simp and
  Input use.
- modules/Simp/backend/dispatch.jai: drop explicit `-> void` on
  Simp_Backend_Dispatch, which mismatched simp_x11_dispatch's and
  simp_wayland_dispatch's implicit-no-return signatures.
- modules/Simp/backend/gl.jai: Jai 0.2.029 tagged-union literal
  syntax — `Simp_Op_Args.{ op = .X }` is invalid; needs
  `Simp_Op_Args.{ op = .X, x = .{} }`. Applied to BACKEND_INIT and
  BACKEND_SET_RENDER_TARGET construction sites.
- modules/Simp/backend/x11_dispatch.jai: `.x11` extractions where
  info.window is consumed as X11.Window by GLX/XLib APIs.
- modules/Simp/module.jai: same `.x11` extraction in
  get_render_dimensions's Linux branch.

These changes preserve all observable behavior; they only make the
post-Task-1 code well-typed against the new tagged-union Window_Type.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6B: Vendor `Input/` module + patch x11.jai for tagged-union Window_Type

**Files:**
- Create: `modules/Input/module.jai` (vendored from upstream verbatim)
- Create: `modules/Input/x11.jai` (vendored + patched at line 813)
- Create: any other `Input/*.jai` files present upstream — copy verbatim

**Step 1: List upstream Input files**

```bash
ls ~/jai/jai/modules/Input/
```

Expected: `module.jai` + per-OS files (`x11.jai`, `windows.jai`, `macos.jai`, `android.jai`). Maybe others. We vendor whatever's there.

**Step 2: Vendor all files verbatim with the standard provenance header**

For each `.jai` file:

```jai
// Vendored from ~/jai/jai/modules/Input/<filename>.jai.
// Verbatim copy.
```

EXCEPT for `x11.jai`, which gets a "Modified" header (see Step 3).

Apply the per-file CRLF detection convention established in upstream-integration's
Task 3.

**Step 3: Patch `x11.jai`**

In `~/jai/jai/modules/Input/x11.jai`, locate the offending site (around
line 813 per Task 7's first attempt). The current code:

```jai
record: Window_Resize_Record;
record.window = hwnd;
```

(or similar — `hwnd` is `X11.Window` u64; `record.window` is `Window_Type`.)

Patch to construct a Window_Type value:

```jai
record: Window_Resize_Record;
record.window = .{ wtype = .X11, x11 = hwnd };
```

Audit for any other `Window_Type` assignments that need the same treatment.
Search for `record.window =`, `.window =`, or similar patterns within Input.

Update the file's provenance header to "Modified" with a description.

**Step 4: Sanity build**

```bash
./build.sh - test
./build.sh - hello_x11_gl 2>&1 | tail -3   # may compile examples that pull Input
```

Expected: build passes. invaders still won't compile yet (Task 7's lazy-init
+ `None` fix isn't done), but the Input vendoring should not regress anything.

**Step 5: Commit**

```bash
git add modules/Input/
git commit -m "$(cat <<'EOF'
vendor: Input/ module + patch x11.jai for tagged-union Window_Type

Input is vendored into modules/Input/ to allow patching its x11
backend's `record.window = hwnd` assignment, which assumed Window_Type
was a u64 alias. After Stage 1 Task 1 made Window_Type a tagged union,
this assignment fails type-check. The patch constructs a Window_Type
value explicitly:

  record.window = .{ wtype = .X11, x11 = hwnd };

All other Input files (module.jai, per-OS variants) are verbatim
copies. Only x11.jai is patched.

This vendoring was originally planned for Stage 2 but was promoted to
Stage 1 once the type-incompatibility was discovered during Task 7's
first attempt. See docs/plans/2026-05-26-context-dispatch-stage1-design.md.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Lazy-init `create_window` to call `init_linux_window`

**Files:**
- Modify: `modules/Window_Creation/linux.jai` (insert call at top of `create_window`'s body)

**Step 1: Locate `create_window` in `linux.jai`**

```bash
grep -n 'create_window\b' modules/Window_Creation/linux.jai
```

Find the definition (`create_window :: (...) -> Window {`).

Also find any usages of `None` as a `Window_Type` value (currently in upstream the signature is `parent: Window_Type = None` and inside the body `if parent == None then parent = root;`). With Window_Type now a tagged union, `None` (X11's `s64` constant = 0) is not a valid Window_Type literal. These need updating.

**Step 2: Fix `parent: Window_Type = None`**

Change the parameter default:
```jai
// Before:
parent: Window_Type = None
// After:
parent: Window_Type = INVALID_WINDOW
```

`INVALID_WINDOW` is `.{ wtype = .X11, x11 = 0 }` (defined in Window_Type.jai per Task 1) — semantically identical to the old `None`.

Inside the body, locate `if parent == None then parent = root;`. Update either:
- Via the operator == overload (Task 6A): `if parent == INVALID_WINDOW { parent = .{ wtype = .X11, x11 = root }; }`
- OR by extracting `.x11` explicitly: `if parent.x11 == 0 { parent = .{ wtype = .X11, x11 = root }; }`

Both work. The first reads more naturally; the second is more defensive against future Window_Type shape changes.

Also: any other `parent` usage inside the body that passes it to X11 APIs (e.g., `XCreateColormap(d, parent, ...)`) needs `.x11` extraction since `parent` is now a Window_Type:
```jai
// Before:
cmap := XCreateColormap(d, parent, vi.visual, AllocNone);
// After:
cmap := XCreateColormap(d, parent.x11, vi.visual, AllocNone);
```

Audit the function body for all `parent` references and apply consistently.

**Step 3: Insert the lazy-init at the top of the body**

Use Edit. The body currently starts with something like:

```jai
create_window :: (width: int, height: int, window_name: string, ...) -> Window {
    if !x_global_display
        init_global_display();
    // ...
}
```

Insert immediately at the top of the body, BEFORE the existing first line:

```jai
create_window :: (width: int, height: int, window_name: string, ...) -> Window {
    if !context.simp_dispatch  init_linux_window();
    if !x_global_display
        init_global_display();
    // ...
}
```

This makes `create_window` idempotent on dispatch init: first call invokes init_linux_window which sets the dispatch; subsequent calls find the dispatch already set and skip. Apps don't need to remember to call init_linux_window explicitly.

**Step 4: Update the linux_init.jai cycle comment (Task 6 code-review follow-up)**

Task 6's code review flagged that `modules/Window_Creation/linux_init.jai`'s `#import "Simp"` deserves a comment explaining the known-but-benign import cycle. Update the import comment:

```jai
#import "Simp";  // for simp_x11_dispatch / simp_wayland_dispatch.
                 // Note: Simp also imports Window_Creation, but Jai resolves
                 // the cycle cleanly because neither side needs the other
                 // at file/load scope.
```

**Step 5: Update linux.jai's "Modified" header**

`modules/Window_Creation/linux.jai` is currently verbatim from upstream (no patches in upstream-integration). This commit makes it patched. Update the header:

```jai
// Vendored from ~/jai/jai/modules/Window_Creation/linux.jai.
// Modified: (a) create_window calls init_linux_window() at its top to
//               lazy-initialize context-based backend dispatch.
//           (b) parent parameter default changed from None (X11 s64)
//               to INVALID_WINDOW (Window_Type tagged-union sentinel).
//               In-body parent usages updated accordingly with .x11
//               extractions or tagged-union comparison.
//           See docs/plans/2026-05-26-context-dispatch-stage1-design.md.
```

**Step 6: Build invaders and verify it runs**

```bash
./build.sh - invaders 2>&1 | tail -30
```

**This is the architecture validation moment.** Expected: invaders compiles AND runs identically to how it does today.

If compile fails: the dispatch wiring has a flaw. Most likely a type or scope error in the new files. Triage.

If runtime fails: most likely the relocation in Task 3 lost something. Triage by comparing the X11 GLX behavior before/after. `gdb build/invaders` (with CWD set to upstream invaders) will pinpoint the crash.

**Step 7: Also verify existing examples still work**

```bash
./build.sh - hello_x11_gl 2>&1 | tail -5
JAI_WAYLAND_X11_GL_FRAMES=60 ./build.sh - hello_x11_gl
ldd build/hello_x11_gl | grep -vE 'libc\.so\.6|linux-vdso|ld-linux'   # expect empty
```

`hello_x11_gl` doesn't go through Simp at all; it uses our X11 module directly. So it should be unaffected. But verify, to catch any accidental regression.

```bash
./build.sh - hello_gl 2>&1 | tail -5
ldd build/hello_gl | grep -vE 'libc\.so\.6|linux-vdso|ld-linux'   # expect empty
```

`hello_gl` uses our X11 module directly too, not Simp. Also should be unaffected.

**Step 8: Commit**

```bash
git add modules/Window_Creation/linux.jai modules/Window_Creation/linux_init.jai
git commit -m "$(cat <<'EOF'
patch(Window_Creation): lazy-init dispatch + fix parent=None for tagged Window_Type

create_window now calls init_linux_window() at its top if
context.simp_dispatch hasn't been pushed yet. Idempotent — second call
to create_window finds the dispatch set and skips re-init. Apps don't
need to call init_linux_window explicitly.

Also fixes the parent parameter default from None (X11 s64 0) to
INVALID_WINDOW (Window_Type tagged-union sentinel — same semantic
meaning, type-compatible after Task 1's conversion). In-body parent
usages updated with .x11 extractions where they flow to X11 APIs.

Also adds a comment to linux_init.jai noting the Simp <-> Window_Creation
import cycle is intentional and benign (Task 6 code review follow-up).

invaders should now compile AND run identically to its pre-Stage-1
behavior — same ldd cleanliness, same play feel — but its execution
path goes through context.simp_dispatch instead of inline
#if OS == .LINUX branches in Simp. Validates Stage 1's architecture.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

### Task 7 scope-expansion note

In addition to Steps 2-5 above, the commit (`e78d3f3`) included three
additional changes inside `linux.jai`, all required to keep invaders
compiling under the tagged-union `Window_Type`:

1. `create_window` return type changed from `Window` (raw X11.Window u64)
   to `Window_Type`. Aligns with Windows/macOS backends, where `HWND ≡
   Window_Type` and `*NSWindow ≡ Window_Type` on their respective
   platforms. Required so that callers like invaders can feed the
   returned value directly into `Simp.set_render_target`, which after
   Task 1 takes `Window_Type`.
2. `get_dimensions(win)` signature changed to take `Window_Type` and
   unwrap `.x11` internally before handing off to `XGetWindowAttributes`.
   Invaders' call site passes the `Window_Type` returned from
   `create_window`.
3. Re-declared `operator ==` overloads at `Window_Creation`'s module
   scope, because Jai's namespaced import (`WT :: #import "Window_Type"`)
   doesn't propagate operator overloads to importers of
   `Window_Creation`. Without these the `it.window == window`
   comparison inside invaders failed to resolve.

The Task 9 docs-commit follow-up (this commit) replaced point 3 with a
single-line `operator == :: WT.operator==;` re-export inside
`Window_Creation/module.jai`. Re-exporting the operator value reference
from the WT namespace is sufficient — the duplicate `operator ==`
definitions in `linux.jai` were removed. `Window_Type` and
`INVALID_WINDOW` are also re-exported from `module.jai` alongside the
operator, so importers of `Window_Creation` get all three (type,
sentinel, comparison) without needing to `#import "Window_Type"`
themselves.

---

## Phase 7 — Validation

### Task 8: Run all five Stage 1 success criteria

**Step 1: Run the full test suite**

```bash
./build.sh - test gen_test wire_test marshal_test unmarshal_test compile_test 2>&1 | tail -10
```

Expected: all 111 tests pass.

**Step 2: Verify all existing examples build**

```bash
./build.sh - hello_gl       2>&1 | tail -3
./build.sh - hello_x11_gl   2>&1 | tail -3
./build.sh - headless_gl    2>&1 | tail -3
./build.sh - x11_smoke      2>&1 | tail -3
./build.sh - headless_vulkan 2>&1 | tail -3
./build.sh - headless_vulkan_dmabuf 2>&1 | tail -3
./build.sh - hello_vulkan_dmabuf 2>&1 | tail -3
```

Each should compile cleanly. Some will auto-run; runtime success isn't required here (just compile + start).

**Step 3: Verify ldd-clean for ALL binaries**

```bash
for bin in build/*; do
    if [ -x "$bin" ] && [ ! -d "$bin" ]; then
        echo "--- $bin ---"
        ldd "$bin" | grep -vE 'libc\.so\.6|linux-vdso|ld-linux' || echo "  (clean)"
    fi
done
```

Every binary should print "(clean)". If any shows a library, the new code accidentally pulled it in.

**Step 4: Manual invaders playtest**

```bash
./build.sh - invaders
```

Play for at least 30 seconds. Verify:
- Window opens (titled "Invaders" at correct resolution)
- Animation runs smoothly (~60 fps)
- Keyboard moves the ship and fires
- Sound plays (shooting, alien deaths)
- Esc / close exits cleanly

If any of these regress vs. the pre-Stage-1 behavior, debug — Stage 1 was supposed to be observably identical to pre-Stage-1.

**Step 5: Commit a validation marker (optional)**

If you want a clean "Stage 1 validated" point in git history, an empty commit:

```bash
git commit --allow-empty -m "milestone: Stage 1 validated — invaders plays through context dispatch

All five success criteria passed:
1. ./build.sh - invaders compiles, build/invaders exists.
2. ldd build/invaders clean (libc + vdso + ld-linux only).
3. All existing examples build cleanly; ldd clean for all.
4. All 111 tests pass across 6 suites.
5. invaders playable end-to-end: window, animation, keyboard, sound, clean exit.

The X11 backend now routes through context.simp_dispatch; the
architecture is validated. Stage 2 fills in simp_wayland_dispatch.
"
```

(Empty commit is optional. Tag-based marking also works: `git tag stage1-validated`.)

---

## Phase 8 — Documentation

### Task 9: Update CLAUDE.md, AGENTS.md, README.md

**Files:**
- Modify: `CLAUDE.md` (Architecture section, Next Steps)
- Modify: `AGENTS.md` (Architecture, Current Roadmap)
- Modify: `README.md` (Known gaps)

**Step 1: CLAUDE.md updates**

In the "Upstream vendored modules" paragraph (around line 95), add a sentence about Stage 1's dispatch infrastructure and the parallel x11_dispatch / wayland_dispatch files. Bump the "Three minimal patch sites" count if Stage 1 adds new patch sites in vendored Window_Creation (linux.jai gets a lazy-init insertion).

In Next Steps item 4 (the Phase 6 / vendored Window_Creation item), update the framing:

Before:
> Wayland backend dispatch within Window_Creation is the remaining ~70% of the work and the design question is open — see `docs/plans/2026-05-26-wayland-backend-question.md`.

After (rough):
> Phase 6 Stage 1 complete: context-based backend dispatch wired through vendored Simp; X11 route validated by invaders running identically. Stage 2 (Wayland dispatcher implementation) is the remaining ~50% of the work — see `docs/plans/2026-05-26-context-dispatch-stage1-design.md` for the architecture and the design question doc for Layer 3 trade-offs.

**Step 2: AGENTS.md updates**

In the Architecture section, add a bullet about the dispatch infrastructure:

```
- `modules/Simp/backend/{dispatch,x11_dispatch,wayland_dispatch}.jai` —
  context-based dispatch scaffold. Simp's Linux branches dispatch
  through `context.simp_dispatch`. The X11 dispatcher is the relocated
  GLX code; the Wayland dispatcher is a Stage 2 placeholder.
```

In Current Roadmap, update the vendored-Window_Creation bullet to reflect Stage 1 done.

**Step 3: README.md updates**

In Known gaps (next phases), update the bullet for vendored upstream window/graphics stack to reflect Stage 1 done.

**Step 4: Commit**

```bash
git add CLAUDE.md AGENTS.md README.md
git commit -m "$(cat <<'EOF'
docs: Stage 1 context dispatch landed (X11 routes through context)

CLAUDE.md / AGENTS.md / README.md updated to reflect:
- Stage 1 complete: context.simp_dispatch wired, X11 routes through it.
- New files: modules/Simp/backend/{dispatch,x11_dispatch,wayland_dispatch}.jai
  and modules/Window_Creation/linux_init.jai.
- New patches: modules/Simp/backend/gl.jai's 4 Linux branches route
  through context; modules/Window_Creation/linux.jai's create_window
  lazy-inits the dispatch.
- Stage 2 (Wayland dispatcher implementation) is the remaining work
  to complete the X11/Wayland "just works" integration goal.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Phase 9 — Push (Optional, on User Confirmation)

### Task 10: Push the branch

**Step 1: Run final validation one more time**

```bash
./build.sh - test gen_test wire_test marshal_test unmarshal_test compile_test
./build.sh - invaders   # manual playtest
ldd build/invaders | grep -vE 'libc\.so\.6|linux-vdso|ld-linux'   # expect empty
```

**Step 2: Push** (only if user explicitly approves)

```bash
git push origin upstream-integration
```

The branch already tracks `origin/upstream-integration`. This is a fast-forward push of the Stage 1 commits onto the existing branch.

**Step 3: Stop and check in with user.**

Stage 1 complete; Stage 2 is a separate brainstorming + design + impl effort. Don't merge, don't open a PR unless asked.

---

## Notes and Hard-Won Wisdom

- **Stage 1 is a refactor, not a rewrite.** The new code is all skeleton (dispatch types, file structure). The substantive change is relocating existing GLX code from `gl.jai`'s `#if OS == .LINUX` branches into `simp_x11_dispatch`'s switch cases. **Resist the urge to "clean up" the relocated code** — pure relocation makes behavior drift easy to spot if invaders regresses.

- **The chicken-and-egg between gl.jai and x11_dispatch.jai.** They share module-scope variables (`the_gl_context`, `the_gl_fbc`, etc.). Both files are `#load`'d into Simp, so they share the same scope. No `#scope_file` directives in either; default scope is the right choice.

- **Compile each phase separately.** Don't try to do all 9 tasks then build. Each task commit should leave the project compiling. The exception is Task 5 (gl.jai refactor) — invaders will SIGSEGV at runtime after this commit until Task 7 lands. That's expected.

- **`init_linux_window`'s `#import "Simp"` may cause a cycle.** If it does (Simp imports Window_Creation transitively), the fix is to move `init_linux_window` into Simp itself, or use a less direct dispatcher-setter (e.g., a registration function Simp exports that Window_Creation calls without importing Simp's whole surface). Try the straightforward approach first.

- **The `Wayland_Window_State :: struct {}` empty placeholder is deliberate.** Don't preemptively populate it with EGL_Context fields — that pulls EGL/gbm imports into Window_Type just for a variant that's never instantiated in Stage 1. Stage 2 populates it.

- **`Window_Type` is a stdlib module.** When we vendor it under `modules/Window_Type.jai`, the path-order trick (from the upstream-integration branch) ensures our version wins. Verify after vendoring that no stdlib module ends up using stock Window_Type by accident.

- **Test the existing X11 examples (hello_x11_gl, x11_smoke) explicitly.** They use our X11 module directly without going through Simp. They shouldn't regress, but they're the canary for "did we break the X11 module itself somehow."

---

## Execution Handoff

Plan complete and saved to `docs/plans/2026-05-26-context-dispatch-stage1-impl.md`. Two execution options:

**1. Subagent-Driven (this session)** — Fresh subagent per task, two-stage review (spec compliance then code quality) between tasks. Same workflow as the upstream-integration branch. ~30 subagent dispatches for 10 tasks.

**2. Parallel Session (separate)** — Open a new session with the `superpowers:executing-plans` skill on this plan. Stage 1 runs in a separate conversation.

Which approach?
