# Wayland Low-Latency Resize Pacing Experiment

Date: 2026-06-02
Branch: `pacing-experiments`

## Context

`JAI_WAYLAND_PRESENT_MODE=mailbox|immediate` intentionally removes the
`wl_surface.frame` callback gate from Simp's Wayland present path. That lets a
CPU-cheap application draw as fast as buffer-release backpressure allows, and
`immediate` additionally asks `tearing-control-v1` for async presentation when
the compositor advertises it.

During interactive compositor resize under Hyprland, that same low-latency path
can turn a dense configure stream into a hot loop:

1. Pump configure.
2. Emit `Window_Resize_Record`.
3. Re-layout app state.
4. Recreate BO/EGL/GL/wl_buffer slots for the new size.
5. Render and present immediately.
6. Repeat.

The first attempted mitigation coalesced/delayed app-visible resize application.
It reduced BO reallocation frequency, but made resize visibly jumpier and did
not materially reduce the observed single-core CPU load. That direction is
parked.

## Current Experiment

Keep resize application immediate, but add a tiny sleep only while low-latency
present sees a recent configure stream:

- `wl_note_configure_size` centralizes `xdg_toplevel.configure` size handling,
  gated tracing, `size_dirty`, and the latest configure timestamp.
- `wl_present_low_latency` calls `wl_maybe_pace_active_resize` after a commit or
  dropped frame.
- The active resize window is `WL_ACTIVE_RESIZE_WINDOW_MS` (currently 120 ms).
- The sleep is `WL_ACTIVE_RESIZE_PACE_MS` (currently 4 ms).
- FIFO mode is unchanged.
- Mailbox/immediate still skip frame-callback pacing and still keep one spare
  BO slot rather than blocking on callbacks.

This is deliberately small: it does not hide compositor resize from the app, and
it does not change GPU resource lifetime rules.

## Trace Knobs

Set `JAI_WAYLAND_TRACE_RESIZE=1` to log:

- `TRACE configure`
- `TRACE configure_ignore`
- `TRACE input_resize_record`
- `TRACE resize_gl_call`
- `TRACE resize_gl_noop`
- `TRACE resize_pace`

Example:

```bash
JAI_WAYLAND_PRESENT_MODE=immediate JAI_WAYLAND_TRACE_RESIZE=1 ./build/getrect_example
```

## Validation So Far

Compiled:

```bash
./build.sh - compile_only getrect_example compile_only getrect_lh_example compile_only skeletal_animation compile_only simp_multiple_windows compile_only simp_example compile_only simp_render_to_texture
```

`skeletal_animation` still emits only the upstream `Hash_Table.init`
deprecation warning.

Live check:

```bash
JAI_WAYLAND_PRESENT_MODE=immediate ./build/getrect_example
```

Subjective result after the current experiment: resize felt less chunky than the
coalesced-resize attempt. This is not final performance work; keep the branch
open for further pacing/profiling.

## Open Questions

- Tune or remove the 4 ms sleep after more data.
- Decide whether active-resize pacing should be per-window only, global, or
  dependent on present mode.
- Measure BO/EGL/GL/wl_buffer recreation separately from app-side CPU work.
- Explore bucketed GPU slot capacity instead of reallocating on every resize:
  keep per-window logical size separate from each slot's allocation capacity,
  allocate BO/EGLImage/GL texture/FBO/wl_buffer slots in growth buckets
  (possibly output-sized or next-power-ish buckets), and only recreate slots when
  the new logical size exceeds capacity. Render only the logical rectangle with
  `glViewport`/`glScissor`. Do not rely on `wl_surface.damage_buffer` as a crop;
  damage only describes changed pixels. Oversized buffers need `wp_viewporter`
  source/destination state, otherwise the compositor will treat the attached
  buffer size as the surface size.
- If bucketed slots work, consider delayed shrink-after-quiescence rather than
  shrinking on every smaller configure. That preserves reuse during drag-resize
  while bounding worst-case memory after the window settles.
- Profile GetRect/Simp CPU work independently of Wayland present pacing.
- Revisit explicit sync/fence work; this experiment does not replace it.
