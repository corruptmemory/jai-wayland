# Wayland async present (non-blocking, vsync-paced) — design + impl + results

> **Status: DONE — signed off ("less jittery/chunky, looks good") and committed.**
> Perf + gross-render verified autonomously; tearing + drag feel verified by a
> human eyeball pass.
> Date: 2026-05-31. Built with Jai `beta 0.2.029`.
>
> **Follow-up (2026-06-01):** multi-window Simp under Hyprland exposed one more
> pacing edge case: configure/close can arrive while waiting on the previous
> frame callback, and Hyprland may not deliver that callback until the client
> handles the configure. `wl_present_and_pace` now yields back to the app when
> configure/close is observed, so resize records, animation, color cycling, and
> compositor close continue flowing.
>
> **Follow-up 2 (2026-06-01):** the "Occlusion" open item below is now FIXED.
> Grouped Simp windows under Hyprland (only one tab visible) starved — a hidden
> window gets no frame callbacks, so the unbounded pacing wait blocked the
> single-threaded render loop and froze the *visible* window too (it advanced one
> frame per tab toggle). The wait is now bounded (`PRESENT_PACE_TIMEOUT_MS` =
> 50 ms) with a per-window `wl_pacing_starved` flag: a starved window is skipped
> so a visible sibling keeps full vsync pacing, while an all-occluded app keeps
> the timeout so the loop idles instead of busy-spinning the GPU on invisible
> frames.
>
> **Follow-up 3 (2026-06-02):** Simp Wayland present is now selectable with
> `JAI_WAYLAND_PRESENT_MODE=fifo|mailbox|immediate`. `fifo` keeps the bounded
> previous-frame-callback throttle described here. `mailbox` and `immediate`
> skip the callback wait, commit only when a spare BO slot exists, and drop
> rendered frames when the queue is full so the app loop is not callback-paced.
> `immediate` additionally requests `tearing-control-v1` async presentation when
> advertised. Because these low-latency paths no longer have FIFO's blocking
> frame-callback receive, swap and input must call `wl_pump_timed(0)` rather than
> only `wl_pump(false)`, or pings, input, and buffer releases can sit unread on
> the socket. The same follow-up tracks allocated slot size separately from the
> current requested size and coalesces Wayland resize records to avoid repeated
> BO reallocations during compositor resize bursts.

## Motivation

Per-frame swap profiling (`getrect_example` @ 2552×1387, both backends) showed the
Wayland present path costs ~4 ms/frame — `glFinish` 0.68 ms + a **synchronous block
on the frame callback 3.3 ms** — while X11/GLX present returns in ~0.2 ms
(driver-managed, triple-buffered). The ~28.5 ms GetRect/Simp CPU is the shared
ceiling (both ~30–34 fps); the ~4 ms + the vsync-coupling jitter is the *entire*
Wayland-vs-X11 "smoothness" gap a user perceives.

This change removes the per-frame block, keeping vsync-correct pacing and no
tearing. `glFinish` is **kept** (0.68 ms, correctness); `glFinish`→fence is a
separate future item (Next Steps #1).

## The key idea: throttle on the PREVIOUS frame's callback

The old `wl_present_and_pace` requested a `wl_surface.frame` callback, committed,
then **blocked on THIS frame's callback** — waiting up to a full vsync for the
compositor to present what we just sent (~3.3 ms even for a slow app).

The fix blocks on the **PREVIOUS** frame's callback, *before* committing the next:
- **CPU-bound app** (GetRect ~28.5 ms/frame > 13.3 ms vsync): the prior callback
  already fired during this frame's render → **no wait, no latency**.
- **Fast app** (faster than vsync): blocks until the compositor consumed the prior
  frame → **capped to vsync, no uncapped GPU burn**.

This is exactly GLX's triple-buffered swap: non-blocking when slower than vsync,
throttling when faster.

### ⚠️ First attempt was wrong — pace on the callback, not the buffer release
The first cut *dropped* the frame callback and paced on `wl_buffer.release`. GetRect
(CPU-bound) looked fine, but **`hello_simp` ran at ~9000 fps** — uncapped. Buffer
releases arrive on *supersession* (the next commit), not at vsync, so they don't
throttle a fast app. The second-example test caught it. Lesson: the frame callback
*is* the vsync signal; the bug was blocking on the wrong (current) one, not the
callback's existence.

## The change (`modules/Wayland_Support.jai`)
1. **`wl_present_and_pace`**: block on the previous frame's callback (`wl_frame_done`)
   *before* committing; then request a new callback, commit, and rotate to a free
   slot (non-blocking drain + a blocking fallback if every slot is still in flight).
2. **`Wayland_Window.wl_frame_done: bool`** — set by the pump when the pending
   callback's `wl_callback.done` arrives; the throttle loops on it.
3. **`wl_buffer.release` sets `done=true`** in the pump (active-slot branch) so the
   slot-availability fallback's blocking `wl_pump(true)` can stop on a freed slot.
4. **`SIMP_WL_SLOT_COUNT` 2 → 3** — with vsync pacing the N-2 slot is already
   released, so the rotate always finds a free slot without blocking (2 slots could
   leave the just-committed + still-held buffers with no free third).

### Why it is tear-safe
A slot is reused only after its `wl_buffer.release`, so we never overwrite an
in-flight buffer. `glFinish` guarantees the GPU finished before commit. The
compositor presents committed buffers at vsync. The block was *pacing*, not
correctness.

## Measured results (getrect_example + hello_simp @ 2552×1387, native Wayland)
| App | present | frame | fps | note |
|-----|--------:|------:|----:|------|
| GetRect before | 3268–3639 µs | 33.3 ms | ~30 | synchronous block |
| **GetRect after** | **~20 µs** | **30.3 ms** | **~32** | no per-frame latency (X11 ≈ 34) |
| hello_simp (1st attempt) | ~20 µs | 0.11 ms | **~9000** | BROKEN — uncapped |
| **hello_simp after** | **13032 µs** (1 vsync) | 13.3 ms | **~75** | correctly vsync-capped |

GetRect's 3.3 ms present block is gone (now ~matching X11's ~34 fps; the residual
~2 fps is `glFinish` 0.7 ms + slightly higher `cpu/other`). hello_simp is correctly
capped to vsync instead of burning the GPU. Does **not** touch the 28.5 ms GetRect
ceiling — this closes the Wayland-vs-X11 gap, it does not make GetRect "smooth."

## Risks / open items
- **Occlusion** — **FIXED 2026-06-01** (see "Follow-up 2" at top). Originally: if
  the compositor stops sending the frame callback (occluded surface), the throttle
  blocks until it resumes. Grouped Simp windows under Hyprland hit exactly this.
  The pacing wait is now bounded at `PRESENT_PACE_TIMEOUT_MS` (50 ms); on timeout
  the window is flagged `wl_pacing_starved` and skipped so a visible sibling keeps
  full vsync pacing, while an all-occluded app keeps the full timeout so the loop
  idles instead of busy-spinning.
- **Subtle tearing + drag feel** — NOT verifiable autonomously. **Needs human
  eyes before commit.** (Gross render verified clean via grim for both examples;
  perf verified; no crash/hang over multi-second runs.)
- Idle/GPU-idle-when-static is unchanged for these always-redraw demos; a future
  idle-aware layer skips rendering at the app level, independent of this.

## Verification protocol (status)
- [x] swap-perf: present 4 ms → ~0.02 ms (GetRect); hello_simp vsync-capped.
- [x] grim: both examples render clean, no gross corruption/tearing.
- [x] multi-second runs: no crash/hang.
- [x] **human: subtle tearing + drag feel/jitter** — signed off ("less jittery/chunky, looks good").
