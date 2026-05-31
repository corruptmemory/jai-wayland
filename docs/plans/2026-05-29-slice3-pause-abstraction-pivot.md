# Slice 3 Paused — Pivot to a Wayland Abstraction Layer

> **Status:** Slice 3 (Wayland input + event pump) is PAUSED after Tasks 1–4.
> Tasks 5–8 are deferred — NOT abandoned, but blocked on a missing scaffold.
> Decision date: 2026-05-29.

## What happened

Stage 2 (the Wayland backend for vendored Simp) reached working render + resize +
window-close on a live compositor (Slices 1–2 + the Slice-3 entry), all ldd-clean,
all reviewed. Slice 3 then set out to add keyboard/pointer input by stitching Simp
and the Input module together through a unified event pump.

Tasks 1–4 landed and are green:
- **Task 1** — persistent session `ReceiveBuffer` (`for_expansion` drains
  `session.recv`; fixes the coalesced-`wl_buffer.release` loss + adds
  `connection_lost`). Reviewed.
- **Task 2 + revision** — the pump contract in `modules/wayland/pump.jai`
  (`wl_pump`, `wl_input_sink`, `wl_window_closed`, `Default_ReceiveBuffer`).
- **Tasks 3+4** — `wl_block_on_frame` unified into `wl_pump(blocking)`: one drain
  that dispatches render events to Simp's slot/window state and forwards raw
  non-render messages to `context.wl_input_sink`; registered as `context.wl_pump`;
  SWAP routes through it. Reviewed (a Critical opcode-0 dispatch-order regression
  was caught and fixed).

## The wall (why we're pausing)

We are building the event pump **bottom-up, coupled to Simp**, and reaching into
Input through ad-hoc context hooks. Every integration step has been a symptom of a
**missing abstraction**, not a local problem to patch:

- The input-sink contract changed twice (classified `Wl_Input_Event` → raw
  `(header, recv)`) because we had not settled an event model.
- Window-close needed an ad-hoc `wl_window_closed` context flag to cross the
  Simp↔Input boundary.
- Keyboard/pointer **acquisition** and **keymap** ownership tangled (who registers
  the objects of interest? where does the keymap live?).
- `wl_pump` re-derives its window from `current_window_info` — a single-window
  expedient, not a real model.
- The pump duplicates `for_expansion`'s ping/pong + `wl_display.error` handling
  because there is no shared "drain + route" primitive.

These all point at the same thing the **repackaging vision** named (see the
`wayland-module-repackaging-vision` memory and the Slice-3 design doc §2): the raw
`modules/wayland` module needs a **first abstraction** — a data structure you
register your **objects of interest** into, plus a **pump function** over the I/O
stream that emits **sane, stable events of our own making** (NOT libwayland's
callback-IoC model; we keep the loop). Simp and Input should both consume *that*,
rather than being hand-stitched to each other through context hooks.

We hit this wall because stitching Simp↔Input directly *is* the wrong layer. The
abstraction has to come first; then the consumers fall out cleanly.

## Decision

**Pause the Simp↔Input stitching (Slice 3 Tasks 5–8).** Next, design and build the
first abstraction layer on top of the raw wayland module — the registration struct
+ pump → stable-events shape. The concrete `wl_pump` / sink / persistent-buffer
work from Tasks 1–4 is the forcing function that revealed the shape; expect it to
be refactored *into* that abstraction (the persistent buffer and the single-drain
router are very likely keepers; the Simp-coupling and the ad-hoc hooks are not).

This is owned by the user, who will study the shape of what we've built and craft
the abstraction; this doc records the decision and the state to resume from.

## What is valid / preserved (nothing here is lost)

- `hello_simp` renders, resizes, and closes on Wayland (Slices 1–2 + close).
- The X11 path (invaders) is unaffected; `ldd` stays libc/vdso/ld-linux on both.
- The persistent `ReceiveBuffer` (Task 1) is a genuine, independent improvement.
- `wl_pump` is a working concrete pump — the best available reference for what the
  abstraction's pump must do (frame pacing, release, configure/ack, close, input
  fan-out, blocking vs non-blocking, connection loss).
- All 111 tests pass; everything is committed.

## To resume Slice 3 later

Once the abstraction exists, Tasks 5–8 (Input `wayland.jai` backend + keysym
mapping + hello_simp input + functional gate) become "consume the abstraction's
event stream," likely much smaller than the current plan assumes. The plan at
`docs/plans/2026-05-29-wayland-input-event-pump-impl.md` (Tasks 5–8) should be
revisited *after* the abstraction's event model is fixed — its current shape
predates the scaffold.

## References

- `wayland-module-repackaging-vision` (memory) — the target abstraction.
- `docs/plans/2026-05-29-wayland-input-event-pump-design.md` — Slice 3 design (§2
  is the seed of the abstraction).
- `modules/wayland/{session,pump,connection}.jai` — the persistent buffer + pump
  contract + the drain primitive to generalize.
- `modules/Simp/backend/wayland_gl.jai::wl_pump` — the concrete pump reference.
