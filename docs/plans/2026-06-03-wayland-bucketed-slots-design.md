# Wayland Bucketed GPU Slot Capacity — design

Date: 2026-06-03
Branch: `pacing-experiments`
Status: **Design approved.** Implementation plan to follow.

## Motivation

Compositor-driven resize currently reallocates the entire per-window slot stack
on every `xdg_toplevel.configure` size change. `wl_window_resize_gl` retires all
`SIMP_WL_SLOT_COUNT` (3) slots and rebuilds each one — GBM BO → EGLImage → GL
texture → FBO → depth renderbuffer → exported DMA-BUF → `wl_buffer` — at exactly
the new logical size. During an interactive drag-resize under Hyprland that is a
storm of allocations (one full stack per configure, and configures stream).

The abandoned active-resize-sleep experiment (removed 2026-06-03 with the
`mailbox`/`immediate` present modes; see
`docs/plans/2026-05-31-wayland-async-present.md`, Follow-up 4) only throttled the
*frequency* of that storm. This is the real fix: stop reallocating on every
resize. Resize churn is independent of present mode — it happens in FIFO too — so
this work stands on its own.

## Core idea

Decouple each window's **logical size** from each slot's **allocation capacity**:

- **Logical size** — what Simp renders, and what the compositor must treat as the
  surface size. Already tracked as `ww.width` / `ww.height` (the pump maintains it
  on configure).
- **Capacity** — the BO / EGLImage / GL texture / FBO / depth-rbo / `wl_buffer`
  allocation size. Repurpose the existing `ww.wl_slot_width` / `wl_slot_height`
  fields to mean capacity (they already track allocation size; the meaning becomes
  "bucketed" rather than "exactly logical").

Capacity = logical rounded up per dimension to `BUCKET_STEP`, capped at the
window's output resolution, **grow-only**. We reallocate slots only when logical
exceeds the current capacity. An oversized buffer is cropped down to the logical
region for presentation with `wp_viewport`.

## Decisions (resolved during brainstorming)

1. **Bucket sizing:** round each dimension up to the next `BUCKET_STEP` (256 px,
   a tunable compile-time constant), capped at the window's output resolution.
   Memory stays within ~one step of the actual size; a full drag-resize crosses
   only a handful of step boundaries, cutting reallocations ~10–50×.
2. **Shrink:** grow-only / high-water-mark. Shrinking the window never
   reallocates. A window dragged large then small keeps the large slots until it
   closes (bounded by output size). No time-based "settled?" heuristic.
3. **Viewporter absent:** graceful fallback to today's behavior. If `wp_viewporter`
   is advertised, use bucketed slots + viewport crop; if not, `capacity == logical`
   and we realloc every resize exactly as now. No regression; bucketing is a
   runtime-detected optimization (matches the project's dmabuf-feedback /
   native-pixmap / GBM-vs-Mesa capability-fallback pattern).
4. **Acceptance bar:** full — all four Simp examples, a realloc-count check, and
   grim correctness (see Testing).

## New state

Per-window (`Wayland_Window`):
- `wl_viewport: Wl.Wp_Viewport`
- `wl_have_viewport: bool`

`ww.wl_slot_width` / `wl_slot_height` keep their type but now mean **capacity**;
`ww.width` / `height` remain the **logical** source of truth.

Module-global (`Wayland_Support`):
- `wl_viewporter: Wl.Wp_Viewporter`
- `wl_have_viewporter: bool`

The viewporter is bound once when first needed (the same shape as the removed
tearing-control manager binding — but this one earns its keep).

## Control flow

### Init — `wl_window_init_gl`
- If `wp_viewporter` is advertised, bind it (once, module-global) and create a
  `wp_viewport` for this surface (`wl_have_viewport = true`).
- Allocate slots at `capacity = bucket(logical)` (capped at output), not at
  `logical`.
- Set the viewport source rect (crop to the logical region) + destination (logical
  size) for the initial size.

### Resize — `wl_window_resize_gl(ww, logical_w, logical_h)`
1. `new_cap = max(current_cap, min(bucket(logical), output))` per dimension
   (grow-only, capped at output).
2. If `new_cap` exceeds the current capacity in either dimension → realloc all
   slots at `new_cap` via the existing retire+realloc path, set `wl_current = 0`,
   return `true` (the caller, `wl_resize_render_target`, rebinds the new FBO).
3. Else (logical fits the current capacity) → **no realloc**, slots untouched,
   return `false`.
4. **In both cases** (when viewporter is available): update the `wp_viewport`
   source rect + destination for the new logical size. This is double-buffered
   surface state, so it lands on the next `wl_surface.commit` from the present
   path — like `set_buffer_transform`, set once per logical-size change, not
   per frame.

Simp already calls `glViewport(0, 0, logical_w, logical_h)` itself after the
resize dispatch (keyed off `info.window_{width,height}` in `gl.jai`), so it keeps
rendering the logical sub-rect of an oversized FBO with **no Simp patch**. On a
no-realloc resize, `wl_current` and the bound FBO are unchanged, which is correct
— only the viewport crop changes.

### Present — `wl_present_and_pace`
- Unchanged except `wl_surface.damage_buffer` uses the logical rect rather than the
  full slot size.
- Viewport state was already set at resize; it persists across presents.

## The one real risk: `FLIPPED_180` × viewport crop

Simp renders into the GL **bottom-left** of the capacity-sized FBO
(`glViewport(0,0,logical_w,logical_h)`, GL origin bottom-left). The buffer carries
`set_buffer_transform(FLIPPED_180)` (so the bottom-up GL FBO presents upright
against the top-down DMA-BUF scanout).

`wp_viewport.set_source(x, y, w, h)` coordinates are in **post-transform** surface
space. Under `FLIPPED_180` the GL-bottom-left content lands at the **opposite**
corner of the transformed buffer, so the source origin is expected to be
approximately `(cap_w − logical_w, cap_h − logical_h)`, size = logical, with
`set_destination(logical_w, logical_h)` (1:1, no scaling).

This composition is the single highest-risk detail. It will be **confirmed
empirically with grim at non-step sizes** (e.g. 1000×700, 1500×900) — where the
content sits at a non-trivial offset within the buffer — before the work is
declared done. wlroots defines the transform+crop composition; the uncertainty is
only getting the offset convention exactly right.

## Edge cases

- **Clears / edge bleed:** `glClear` ignores the viewport and clears the whole
  capacity buffer — harmless, the margin is never sampled. At 1:1
  source==destination with an integer-aligned crop there is no interpolation
  across the logical boundary, so **no `glScissor` is needed** (optional hardening
  only).
- **Depth renderbuffer:** sized to capacity like the color attachment; Simp's
  viewport confines depth-tested draws to the logical region (skeletal_animation
  validates).
- **Multi-window:** each window owns its own `wp_viewport` + capacity; the shared
  EGL context is untouched (simp_multiple_windows validates).
- **Realloc path (bucket crossing up):** unchanged — the existing retire/release
  path handles in-flight buffers when a realloc does happen.
- **No-viewporter fallback:** `capacity == logical`, realloc every resize (today's
  exact behavior), no `wp_viewport` object, no crop, full-buffer damage. One branch
  at init + the resize decision.

## Tunable

- `BUCKET_STEP :: 256` — compile-time constant, documented as tunable.

## Testing / acceptance

- **Churn count:** a temporary realloc counter in the realloc branch. Drag-resize
  `getrect_example` within a bucket → counter stays 0; crossing a step → +1.
  Removed before the final commit (no lingering debug knob — consistent with the
  trace-knob removal).
- **grim** at several sizes including non-step (1000×700, 1500×900) → upright, no
  crop/corruption — `getrect_example` and `simp_multiple_windows`.
- **skeletal_animation** (3D/depth) + **invaders** (2D) render correctly via grim.
- All Simp examples compile clean.

## Out of scope

- Shrink-after-quiescence (rejected — grow-only is simpler and the cap is output
  size).
- Any change to present pacing (FIFO is the policy; see
  `docs/plans/2026-05-31-wayland-async-present.md`).
- `glScissor` margin confinement (optional hardening, only if grim shows an edge
  artifact at 1:1 crop, which is not expected).
