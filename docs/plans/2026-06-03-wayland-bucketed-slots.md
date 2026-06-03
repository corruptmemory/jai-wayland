# Wayland Bucketed GPU Slot Capacity Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Stop reallocating the per-window BO/EGLImage/GL-texture/FBO/depth/wl_buffer slot stack on every compositor resize by decoupling logical window size from a bucketed allocation capacity, cropping the oversized buffer to the logical region with `wp_viewport`.

**Architecture:** Each `Wayland_Window` keeps a logical size (`ww.width/height`, maintained by the pump) and an allocation capacity (`ww.wl_slot_width/height`, repurposed). Capacity = logical rounded up to `BUCKET_STEP` (256), capped at output resolution, grow-only. Reallocate only when logical exceeds capacity; otherwise just re-crop with `wp_viewport`. If `wp_viewporter` is absent, fall back to today's realloc-per-resize (capacity == logical).

**Tech Stack:** Jai (`beta 0.2.029`), the vendored `Wayland_Support` module, generated `wp_viewporter`/`wp_viewport` bindings, EGL/GBM/GL via runtime dlopen, grim for visual verification.

**Design doc:** `docs/plans/2026-06-03-wayland-bucketed-slots-design.md`

**Skills:** Use `jai-language` before editing any Jai. Visual checks use grim (see the "Visual verification via grim" memory).

---

## Verification model (read first)

- **Per-task gate:** `./build.sh` (main build) and/or `./build.sh - compile_only <examples>` must compile clean (only the known upstream `Hash_Table.init` deprecation warning in skeletal_animation is allowed).
- **Final gate:** grim correctness on all four Simp examples + a temporary realloc-count check (Task 5).
- **Live-session caution:** Tasks 4–5 launch real GUI windows and use `hyprctl` to size them. These affect the user's live Hyprland session (a window appears, focus may move). **Tell the user before running them.**
- **Running a GUI example for grim:** `./build.sh - <target>` compiles *and runs* (hangs the build call). To get a runnable binary without auto-run, prefer `./build.sh - compile_only <target>` and confirm it emits `build/<target>`; if compile_only does not emit a runnable binary, run the real target under `timeout` once to leave `build/<target>` (assets are staged by `first.jai`), then launch `./build/<target>` directly in the background.

---

## Task 1: Bucket constants + capacity helpers

**Files:**
- Modify: `modules/Wayland_Support.jai` (add near `SIMP_WL_SLOT_COUNT`, ~line 100)

**Step 1: Verify the output-info API names**

Run: `grep -nE "Screen_Info|Mode_Info|get_screens_info|current_mode" modules/wayland/output.jai | head`
Confirm: `get_screens_info()` returns `[] Screen_Info`; `Screen_Info` has `current_mode: Mode_Info`; `Mode_Info` has `width`/`height` (note their integer type, expected `s32`). Adjust the helper below if names/types differ.

**Step 2: Add the constants and helpers**

Add just below the `SIMP_WL_SLOT_COUNT :: 3;` block:

```jai
// Slot allocation capacity is bucketed: the logical size rounded up to
// BUCKET_STEP, capped at output resolution, grow-only. This decouples the
// logical window size (what Simp renders / what the compositor sees via
// wp_viewport) from the BO/FBO/wl_buffer allocation size, so interactive resize
// stops reallocating the whole slot stack on every configure.
// See docs/plans/2026-06-03-wayland-bucketed-slots-design.md.
BUCKET_STEP :: 256;

wl_round_up_to_step :: (v: s32, step: s32) -> s32 {
    if v <= 0  return step;
    return ((v + step - 1) / step) * step;
}

// Largest output dimensions, discovered once and cached. The capacity cap: a
// normal window cannot exceed its monitor, so this keeps a maximized window's
// buffer from rounding past the screen. Falls back to a generous 8K if output
// discovery yields nothing.
wl_output_cap_initialized: bool;
wl_output_cap_w: s32 = 7680;
wl_output_cap_h: s32 = 4320;

wl_output_cap :: () -> (w: s32, h: s32) {
    if wl_output_cap_initialized  return wl_output_cap_w, wl_output_cap_h;
    wl_output_cap_initialized = true;

    screens := Wl.get_screens_info();
    max_w: s32 = 0;
    max_h: s32 = 0;
    for screens {
        if it.current_mode.width  > max_w  max_w = it.current_mode.width;
        if it.current_mode.height > max_h  max_h = it.current_mode.height;
    }
    if max_w > 0 && max_h > 0 {
        wl_output_cap_w = max_w;
        wl_output_cap_h = max_h;
    }
    return wl_output_cap_w, wl_output_cap_h;
}

// Grow-only bucketed capacity for a logical size: round up to BUCKET_STEP, cap at
// output resolution, never below the current capacity, and never below the
// logical size itself (logical can exceed the output cap on odd configs).
wl_target_capacity :: (logical_w: s32, logical_h: s32, cur_cap_w: s32, cur_cap_h: s32) -> (w: s32, h: s32) {
    cap_w, cap_h := wl_output_cap();
    want_w := min(wl_round_up_to_step(logical_w, BUCKET_STEP), cap_w);
    want_h := min(wl_round_up_to_step(logical_h, BUCKET_STEP), cap_h);
    out_w := max(max(want_w, cur_cap_w), logical_w);
    out_h := max(max(want_h, cur_cap_h), logical_h);
    return out_w, out_h;
}
```

**Step 3: Compile**

Run: `./build.sh`
Expected: builds clean (`Stats for Workspace 3 ("main")`, no errors). The helpers are unused so far — that's fine.

**Step 4: Commit**

```bash
git add modules/Wayland_Support.jai
git commit -m "feat(wayland): add bucketed slot capacity helpers"
```

---

## Task 2: wp_viewporter binding + per-window viewport plumbing

**Files:**
- Modify: `modules/Wayland_Support.jai` (viewporter globals near the old present-helpers location ~line 240; per-window fields in `Wayland_Window`; a Fixed helper)

**Step 1: Confirm the bind + Fixed primitives exist**

Run: `grep -nE "get_global ::|wl_registry_bind ::|Fixed ::|raw" modules/wayland/*.jai | head`
Confirm `Wl.get_global`, `Wl.wl_registry_bind`, and `Wl.Fixed` (with field `raw: s32`) exist. (The removed tearing-control code used `get_global` + `wl_registry_bind`, so they exist.) If there is already a `Fixed`-from-int helper, use it instead of the local one below.

**Step 2: Add viewporter globals + helpers**

Add a new section (e.g. just before `// ─── Format / modifier selection ───`):

```jai
// ─────────────────────── Viewporter (bucketed crop) ───────────────────────
// wp_viewporter lets us present only the logical sub-rect of an oversized
// (bucketed) buffer, so the slot allocation size can exceed the surface size.
// Bound once; absent on a compositor that does not advertise it (we then fall
// back to realloc-per-resize). See the design doc.

wl_viewporter: Wl.Wp_Viewporter;
wl_have_viewporter: bool;
wl_viewporter_initialized: bool;

wl_fixed_from_int :: (v: s32) -> Wl.Fixed {
    return .{ raw = v << 8 };
}

wl_ensure_viewporter :: () {
    if wl_viewporter_initialized  return;
    wl_viewporter_initialized = true;

    _, ok := Wl.get_global("wp_viewporter");
    if !ok  return;

    wl_viewporter = .{ id = Wl.allocate_id() };
    batch: Wl.MessageBuilder;
    if !Wl.wl_registry_bind(*batch, Wl.registry(), *wl_viewporter) {
        wl_viewporter = .{};
        return;
    }
    if !Wl.wayland_send(*batch) {
        wl_viewporter = .{};
        return;
    }
    wl_have_viewporter = true;
    log("Wayland_Support: wp_viewporter available; using bucketed slot capacity");
}

// Create a wp_viewport for this surface (once). No-op if viewporter is absent.
wl_window_init_viewport :: (ww: *Wayland_Window) {
    wl_ensure_viewporter();
    if !wl_have_viewporter  return;

    ww.wl_viewport = .{ id = Wl.allocate_id() };
    batch: Wl.MessageBuilder;
    Wl.wp_viewporter_get_viewport(*batch, *wl_viewporter, ww.wl_viewport.id, *ww.surface);
    if Wl.wayland_send(*batch)  ww.wl_have_viewport = true;
    else                        ww.wl_viewport = .{};
}

// Crop the (possibly oversized) buffer down to the logical region and set the
// surface (logical) size. Source coords are post-transform: under FLIPPED_180 the
// GL-bottom-left content lands at the opposite corner, so the source origin is
// (cap - logical). The (src_x, src_y) offset is CONFIRMED WITH GRIM in Task 4.
wl_update_viewport_crop :: (ww: *Wayland_Window) {
    if !ww.wl_have_viewport  return;

    cap_w := ww.wl_slot_width;
    cap_h := ww.wl_slot_height;
    log_w := ww.width;
    log_h := ww.height;
    if log_w <= 0 || log_h <= 0 || cap_w <= 0 || cap_h <= 0  return;

    src_x := cap_w - log_w;   // Task 4 confirms/adjusts this offset.
    src_y := cap_h - log_h;

    batch: Wl.MessageBuilder;
    Wl.wp_viewport_set_source(*batch, *ww.wl_viewport,
        wl_fixed_from_int(src_x), wl_fixed_from_int(src_y),
        wl_fixed_from_int(log_w), wl_fixed_from_int(log_h));
    Wl.wp_viewport_set_destination(*batch, *ww.wl_viewport, log_w, log_h);
    Wl.wayland_send(*batch);
}
```

**Step 3: Add per-window fields**

In `Wayland_Window` (near the dmabuf/format fields), add:

```jai
    // wp_viewport crops the bucketed buffer to the logical surface size.
    wl_viewport:      Wl.Wp_Viewport;
    wl_have_viewport: bool;
```

**Step 4: Compile**

Run: `./build.sh`
Expected: clean. (Still unused — wiring is Task 3.)

**Step 5: Commit**

```bash
git add modules/Wayland_Support.jai
git commit -m "feat(wayland): add wp_viewporter binding and per-window viewport"
```

---

## Task 3: Wire bucketing into init + resize

**Files:**
- Modify: `modules/Wayland_Support.jai` (`wl_window_init_gl` slot-alloc tail; `wl_window_resize_gl`; factor out `wl_realloc_slots`)

**Step 1: Factor the retire+realloc body into a helper**

Add near `wl_window_resize_gl`:

```jai
// Retire current slots (compositor may still hold an in-flight buffer) and
// reallocate all of them at (w, h), reusing the negotiated format/modifier.
// Sets wl_current=0 and wl_slot_width/height. Returns true on success; on failure
// disables the window (wl_initted=false) and returns false.
wl_realloc_slots :: (ww: *Wayland_Window, w: s32, h: s32) -> bool {
    if !wl_make_current()  return false;

    retire_batch: Wl.MessageBuilder;
    wl_retire_slots(*retire_batch, *ww.wl_retired, ww.wl_slots, wl_shared_egl);
    Wl.wayland_send(*retire_batch);

    backend := wl_choose_gl_backend();
    alloc_batch: Wl.MessageBuilder;
    for * slot, i: ww.wl_slots {
        if !wl_slot_init(slot, wl_shared_egl, *ww.wl_dmabuf_info.dmabuf, *alloc_batch,
                         ww.wl_format, ww.wl_modifier, w, h, backend) {
            log_error("Wayland_Support: slot % realloc failed (%x%) — window disabled", i, w, h);
            ww.wl_initted = false;
            return false;
        }
    }
    Wl.wayland_send(*alloc_batch);
    ww.wl_current = 0;
    ww.wl_slot_width  = w;
    ww.wl_slot_height = h;
    return true;
}
```

**Step 2: Rewrite `wl_window_resize_gl`**

Replace the current body with:

```jai
wl_window_resize_gl :: (ww: *Wayland_Window, new_w: s32, new_h: s32) -> bool {
    if !ww.wl_have_viewport {
        // No-viewporter fallback: buffer size == logical size; realloc on any change.
        if ww.wl_slot_width == new_w && ww.wl_slot_height == new_h  return false;
        return wl_realloc_slots(ww, new_w, new_h);
    }

    // Bucketed path: grow-only capacity, crop to the logical region.
    target_w, target_h := wl_target_capacity(new_w, new_h, ww.wl_slot_width, ww.wl_slot_height);

    realloc := false;
    if target_w > ww.wl_slot_width || target_h > ww.wl_slot_height {
        if !wl_realloc_slots(ww, target_w, target_h)  return false;
        realloc = true;
    }

    wl_update_viewport_crop(ww);  // logical may have changed even with no realloc
    return realloc;
}
```

**Step 3: Wire init**

In `wl_window_init_gl`, find the slot-allocation tail (the `for * slot, i: ww.wl_slots { wl_slot_init(... ww.width, ww.height ...) }` loop and the `ww.wl_slot_width = ww.width; ww.wl_slot_height = ww.height;` assignment). Replace so it:
1. Calls `wl_window_init_viewport(ww)` (sets `ww.wl_have_viewport`).
2. Computes the initial capacity: `cap_w, cap_h := ifx ww.wl_have_viewport then wl_target_capacity(ww.width, ww.height, 0, 0) else (ww.width, ww.height);` — note Jai multi-return into a tuple via two vars; if the `ifx`-tuple form is awkward, branch with an `if`.
3. Allocates the slots at `cap_w, cap_h` (pass these into `wl_slot_init` instead of `ww.width/ww.height`).
4. Sets `ww.wl_slot_width = cap_w; ww.wl_slot_height = cap_h;`.
5. Keeps the existing `set_buffer_transform(FLIPPED_180)`, `wl_current = 0`, `wl_initted = true`.
6. After `wl_initted = true`, calls `wl_update_viewport_crop(ww)`.

Concretely, the capacity computation (avoid the awkward `ifx` tuple):

```jai
    cap_w := ww.width;
    cap_h := ww.height;
    wl_window_init_viewport(ww);
    if ww.wl_have_viewport  cap_w, cap_h = wl_target_capacity(ww.width, ww.height, 0, 0);
```

and the post-init crop:

```jai
    ww.wl_initted = true;
    wl_update_viewport_crop(ww);
    return true;
```

**Step 4: Compile-gate all Simp examples**

Run: `./build.sh - compile_only hello_simp compile_only simp_multiple_windows compile_only getrect_example compile_only skeletal_animation compile_only invaders`
Expected: 5 `Stats for Workspace` lines, exit 0, only the skeletal_animation `Hash_Table.init` deprecation warning.

**Step 5: Commit**

```bash
git add modules/Wayland_Support.jai
git commit -m "feat(wayland): bucketed slot capacity in init + resize"
```

---

## Task 4: Calibrate the FLIPPED_180 crop offset with grim

**Goal:** Confirm the `wl_update_viewport_crop` source offset presents the logical content upright and uncropped. **Tell the user first — this launches a GUI window.**

**Step 1: Build a runnable getrect binary**

Run: `./build.sh - compile_only getrect_example` and confirm `build/getrect_example` exists (`ls -l build/getrect_example`).
If compile_only does not emit a runnable binary, run `timeout 6 ./build.sh - getrect_example` once (it stages assets + leaves the binary), ignoring that it self-terminates.

**Step 2: Float + size the window to a NON-step size, then grim**

A non-step size (not a multiple of 256) forces a non-zero crop offset, which is what exposes a wrong offset.

```bash
./build/getrect_example & APP=$!
sleep 2
hyprctl dispatch togglefloating
hyprctl dispatch resizeactive exact 1500 900
sleep 1
grim -g "$(hyprctl activewindow -j | jq -r '"\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"')" /tmp/bucket_getrect_1500x900.png
kill $APP
```

**Step 3: Read the screenshot and judge**

Read `/tmp/bucket_getrect_1500x900.png`. Check:
- UI is **upright** (title bar at top, not flipped).
- The full GetRect UI is visible and fills the window (no black/garbage margin band, no half-cropped widgets).
- No portion of an adjacent stale frame shows at an edge.

**Step 4: If wrong, try the alternative offsets**

The composition of `FLIPPED_180` + viewport source has four candidate origins. In `wl_update_viewport_crop`, try in order until grim is correct, re-running Steps 1–3:
- `src_x = cap_w - log_w; src_y = cap_h - log_h;` (initial guess)
- `src_x = 0;               src_y = cap_h - log_h;`
- `src_x = cap_w - log_w;   src_y = 0;`
- `src_x = 0;               src_y = 0;`

(If none are right, the issue may be that `set_source` should be applied *before* `set_buffer_transform` semantics expect — re-read `modules/wayland/viewporter/wp_viewport.jai` doc comments and the wp_viewporter spec for the transform/source ordering.)

**Step 5: Commit the confirmed offset**

```bash
git add modules/Wayland_Support.jai
git commit -m "fix(wayland): confirm viewport crop offset for FLIPPED_180 buffers"
```

---

## Task 5: Full validation (churn count + grim) and instrumentation removal

**Tell the user first — launches GUI windows and drives hyprctl.**

**Step 1: Add a temporary realloc counter**

In `wl_realloc_slots`, just after `if !wl_make_current() return false;`, add:

```jai
    wl_realloc_count += 1;
    log("Wayland_Support: REALLOC #% -> %x% (logical %x%)", wl_realloc_count, w, h, ww.width, ww.height);
```

and a module global near the other counters:

```jai
wl_realloc_count: u64;  // TEMPORARY — bucketed-slots validation, removed before final commit
```

Build: `./build.sh - compile_only getrect_example` (confirm clean) and produce `build/getrect_example` as in Task 4.

**Step 2: Verify zero in-bucket reallocations**

```bash
./build/getrect_example 2>/tmp/bucket_log.txt & APP=$!
sleep 2
hyprctl dispatch togglefloating
# Resize within one 256 bucket (e.g. 1300..1450 wide, 800..900 tall): expect NO new REALLOC lines.
for s in "1300 820" "1350 850" "1400 870" "1450 890"; do hyprctl dispatch resizeactive exact $s; sleep 0.4; done
echo "--- in-bucket resizes done; REALLOC lines so far: ---"; grep -c REALLOC /tmp/bucket_log.txt
# Now cross several buckets upward: expect a FEW REALLOC lines, not one per step.
for s in "1600 1000" "1900 1100" "2200 1300"; do hyprctl dispatch resizeactive exact $s; sleep 0.4; done
kill $APP
echo "--- total REALLOC lines: ---"; grep REALLOC /tmp/bucket_log.txt
```
Expected: the in-bucket resizes add **0** REALLOC lines after the initial allocation; crossing buckets adds only a handful (not one per `resizeactive`).

**Step 3: grim correctness — getrect + multi_window at non-step sizes**

For `getrect_example` (reuse Task 4 result) and `simp_multiple_windows`:
- Build/run, float, `resizeactive exact 1500 900` and `exact 1100 700`, grim each, Read.
- Confirm upright, full UI, no crop/garbage. For multi_window, confirm **both** windows render (animation/color visible).

**Step 4: grim correctness — 3D/depth and 2D**

- `skeletal_animation`: build/run, grim. Read — the skinned mesh is depth-correct (no z-fighting/see-through), GetRect UI overlaid correctly.
- `invaders`: build/run, grim. Read — sprites render, no corruption.

**Step 5: Remove the instrumentation**

Delete the `wl_realloc_count` global and the two lines added in Step 1.

Run: `./build.sh - compile_only hello_simp compile_only simp_multiple_windows compile_only getrect_example compile_only skeletal_animation compile_only invaders`
Expected: clean, exit 0.

**Step 6: Commit**

```bash
git add modules/Wayland_Support.jai
git commit -m "test(wayland): validate bucketed slots (zero in-bucket realloc, grim correct)"
```

---

## Task 6: Documentation

**Files:**
- Modify: `CLAUDE.md`, `AGENTS.md`, `README.md`, `docs/plans/2026-06-03-wayland-bucketed-slots-design.md`

**Step 1: Update the live docs**

- `CLAUDE.md` Next Steps #2 ("Bucketed GPU slot capacity (active)"): change to **DONE**, summarizing the result (logical/capacity split, `BUCKET_STEP` 256 grow-only capped at output, `wp_viewport` crop, graceful realloc fallback when viewporter absent). Update the `Wayland_Support.jai` backend-layer paragraph to mention bucketed slots + `wp_viewport`.
- `AGENTS.md`: update the bucketed-slots bullet from "active direction" to done; note the `wp_viewporter` fallback and `BUCKET_STEP` tunable.
- `README.md`: change the "Bucketed GPU slot capacity" known-gap bullet to a completed-feature bullet.
- Design doc: set Status to "Implemented YYYY-MM-DD" and record the confirmed crop offset from Task 4.

**Step 2: Verify no stale "active/next" wording remains**

Run: `grep -niE "bucketed|active-resize|next.*resize" CLAUDE.md AGENTS.md README.md`
Confirm the surviving mentions describe a done feature, not pending work.

**Step 3: Commit**

```bash
git add CLAUDE.md AGENTS.md README.md docs/plans/2026-06-03-wayland-bucketed-slots-design.md
git commit -m "docs: bucketed GPU slot capacity is implemented"
```

---

## Done criteria

- [ ] All Simp examples compile clean (only the upstream `Hash_Table.init` warning).
- [ ] In-bucket resize of `getrect_example` triggers **zero** slot reallocations; crossing buckets triggers only a handful.
- [ ] grim confirms `getrect_example` + `simp_multiple_windows` render upright/uncropped at non-step sizes; `skeletal_animation` (3D/depth) + `invaders` (2D) correct.
- [ ] Temporary realloc instrumentation removed.
- [ ] `ldd build/getrect_example` still shows no windowing/GPU libs (sanity — viewporter is dlopen'd wire protocol, not a link dep; quick check).
- [ ] Docs updated.
