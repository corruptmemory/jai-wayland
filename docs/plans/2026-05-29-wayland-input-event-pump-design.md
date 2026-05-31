# Wayland Input + Event Pump (Slice 3) Design

> **Status:** validated through brainstorming, ready to implement.
> Slice 3 of the Stage 2 Wayland backend. Builds on Slices 1–2
> (`docs/plans/2026-05-29-wayland-backend-design.md`). Also closes two
> code-review findings from the Slices 1–3 review (#2 lost-coalesced-release,
> #5 no-disconnect-signal) by replacing the per-call event drain with a
> persistent-buffer pump.

## Goal

Give the vendored Simp + Input stack working keyboard/pointer input and
window-close on Wayland, so an app's standard `update_window_events()` /
`events_this_frame` loop (what invaders uses) works unchanged on a Wayland
session. The defining constraint is unchanged: no libwayland linkage; ldd stays
libc/vdso/ld-linux only.

End state: `hello_simp` (extended to print key/click/quit events) responds to
keyboard and pointer on Wayland; the architecture is ready for invaders
(Slice 4) to run unmodified.

## The problem this solves

On Wayland, two subsystems want to drain the one compositor socket each frame:
Simp's `swap_buffers` (frame callback for vsync pacing, `wl_buffer.release` for
slots, `xdg_*.configure` for resize, `xdg_toplevel.close`) and Input's
`update_window_events` (keyboard/pointer, close → `.QUIT`). They cannot both
blindly drain: the shared `for_expansion` **consumes every message it peeks**
(its `defer receive_consume_message` runs even for ignored messages), so two
separate `for session()` loops would consume and discard each other's events.

Therefore the render path needs **one unified drain** that dispatches every
message to the correct sink in a single pass — not "two consumers sharing a
buffer," but "one router, multiple sinks."

## Decisions (from brainstorming)

1. **Unify on a persistent buffer.** The `ReceiveBuffer` moves into
   `WaylandSession`; the shared `for_expansion` drains it persistently. Chosen
   over a separate render-path-only pump to avoid duplicating the ping/pong +
   `wl_display.error` handling. Cost (accepted): every `for session()` consumer
   must be re-verified, because leftover messages now survive across drains.
2. **Unified pump lives in Simp; input via a context hook.** Simp owns the
   slot/frame/resize/close state, so the pump extends Simp's `wl_block_on_frame`.
   Keyboard/pointer are delivered to Input through a `#add_context` hook rather
   than a static `Input → Simp` import — strictly cleaner, same runtime coupling,
   and it matches the existing `#add_context simp_dispatch` idiom.
3. **Pending-queue for input** to dodge the reset-timing trap (see §3).
4. **Close emits both** the Simp close flag (for `window_should_close`) and an
   Input `.QUIT` event (so invaders quits).

## Architecture

### §1 — Persistent buffer

`WaylandSession` gains `recv: ReceiveBuffer`. `for_expansion` (session.jai)
drains `*session.recv` instead of a fresh local: on entry it processes any
messages already buffered from a prior drain *before* the next blocking
`wayland_receive`, so messages still un-peeked when a loop `break`s are not lost
(the #2 fix). A socket-closed / `wl_display.error` return becomes observable to
callers (the #5 fix — exact surfacing decided in impl).

**Re-verification (required):** `hello_window`, `hello_globals`, `hello_screens`,
`dump_keymap`, the discovery routines (`output.jai`, `input.jai`, `registry.jai`),
and `create_window_wayland` each run a `for session()` loop. Each must be
re-run/re-reasoned to confirm the persistent buffer (leftover messages surviving
across loops) does not change their behavior. Most break on a sync/configure and
leave nothing meaningful behind, but this is the load-bearing risk of decision 1.

### §2 — Unified pump in Simp

`wl_block_on_frame` becomes `wl_pump(blocking: bool, ...)`. One drain pass
dispatches each message:

- `wl_callback.done` (frame callback) → end the blocking wait.
- `wl_buffer.release` → mark the owning slot (or retired slot) free.
- `xdg_toplevel.configure` → record new size; `xdg_surface.configure` → ack.
- `xdg_toplevel.close` → Simp close flag **and** emit an Input `.QUIT` (§3).
- `wl_keyboard.*` / `wl_pointer.*` → `context.wl_input_sink(...)` (Input's hook).

Registration mirrors `simp_dispatch`: Simp sets `#add_context wl_pump` (so Input
calls `context.wl_pump(false)` without importing Simp) and Input sets
`#add_context wl_input_sink`.

**Pacing (unchanged):** `swap_buffers` calls `wl_pump(blocking=true)` — blocks on
the frame callback (vsync). `update_window_events` (Wayland) calls
`wl_pump(blocking=false)` — drains what's buffered and returns.

### §3 — Input delivery + the reset-timing trap

`swap_buffers`' blocking drain can deposit input *after* the app has already
processed `events_this_frame` this frame. If that input went straight into
`events_this_frame`, the next `update_window_events` reset (which clears the
prior frame's events, as on X11) would wipe it. So:

- `wl_input_sink` appends translated events to a **pending** list (and updates a
  pending button-state delta).
- `update_window_events` (Wayland): reset `events_this_frame` → `wl_pump(false)`
  (more pending) → flush pending into `events_this_frame` + apply to
  `input_button_states` (mirroring the X11 backend's bookkeeping).

Net: input caught during the swap-block surfaces on the next frame instead of
being lost. Close → a `.QUIT` event is appended to pending the same way, so
invaders' `if event.type == .QUIT` path fires.

### §4 — Keysym / pointer mapping

Reuse `modules/wayland/xkb.jai` (already used by `hello_window`): the keyboard's
keymap fd is parsed once; `wl_keyboard.key` evdev keycode → keysym →
`Input.Key_Code`. Map the common set — letters, digits, arrows, space, enter,
escape, modifiers — extensible; YAGNI beyond that. `wl_pointer` motion/button →
`Input` mouse position + button states. `wl_keyboard.modifiers` →
`Input.Modifier_Flags`.

The translation reuses `modules/wayland/input.jai`'s `get_keyboard_event` /
`get_pointer_event` where they fit; the pump routes the raw events to the sink,
the Input Wayland backend does the keysym→Key_Code mapping.

### §5 — Validation

1. **Per-consumer re-verify** (§1): build + run each existing example/discovery
   path; confirm unchanged behavior (ldd-clean, no regressions).
2. **hello_simp extended** to print key / click / quit events; verify on live
   Hyprland — synthetic input via `wtype`/`ydotool` if available, else manual.
   Super+Q still closes (now also via the `.QUIT` path).
3. **Compile gates:** `compile_only hello_simp` + `compile_only invaders` clean;
   `compile_test` 11/11; `ldd` clean.
4. Invaders-on-Wayland remains **Slice 4** (the integration payoff).

## File Inventory

**Modified (vendored upstream):**
- `modules/wayland/session.jai` — `WaylandSession.recv`; `for_expansion` drains
  the persistent buffer; disconnect surfacing.
- `modules/Simp/backend/wayland_gl.jai` — `wl_block_on_frame` → `wl_pump`
  (keyboard/pointer routing to `wl_input_sink`; `.QUIT`/close).
- `modules/Simp/backend/wayland_dispatch.jai` — SWAP/SET call `wl_pump`.
- `modules/Simp/backend/dispatch.jai` (or nearby) — `#add_context wl_pump`,
  `#add_context wl_input_sink`; Simp registers `wl_pump`.
- `modules/Input/` — new `wayland.jai` backend: registers `wl_input_sink`,
  keysym→Key_Code + pointer mapping, the pending-queue, and the Wayland branch of
  `update_window_events`. `module.jai` loads it.
- `examples/hello_simp.jai` — print key/click/quit events.

**Untouched:**
- `examples/hello_gl.jai` (frozen reference), the X11 dispatcher/path, the
  GL/EGL/gbm bindings, upstream invaders source.

## Open items (resolve during impl)

- Exact disconnect-signal surfacing (#5) — a `connection_lost` flag on the
  session vs a return value.
- Whether `wl_pump`'s blocking form also needs a timeout backstop.
- Precise `Input.Key_Code` table coverage.

## References

- `docs/plans/2026-05-29-wayland-backend-design.md` — Slices 1–2 + the
  slice-first framing.
- The Slices 1–3 code review (this session) — findings #2 (lost coalesced
  release) and #5 (no disconnect signal), closed by §1.
- `modules/Input/x11.jai` — the X11 pump (`update_window_events` /
  `update_x11_window_events`) to mirror for structure + button-state bookkeeping.
- `modules/wayland/{input,xkb}.jai` — seat/keyboard/pointer discovery + keymap
  parsing to reuse.
- `examples/hello_window.jai` — existing keysym handling reference.
