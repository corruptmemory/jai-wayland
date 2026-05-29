# Wayland Input + Event Pump (Slice 3) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (or subagent-driven-development) to implement task-by-task.
> Before writing/modifying ANY Jai code, invoke the `jai-language` skill (project CLAUDE.md mandate).

**Goal:** Working keyboard/pointer/close input on the Wayland Simp backend, so an app's standard `update_window_events()` + `events_this_frame` loop (invaders') works unchanged — via a persistent-buffer unified event pump.

**Architecture:** One persistent `ReceiveBuffer` on `WaylandSession`; the shared `for_expansion` drains it persistently (fixes review #2/#5). A unified pump in Simp (`wl_block_on_frame` → `wl_pump(blocking)`) drains once and dispatches frame/release/configure/close to Simp state and keyboard/pointer to Input via `#add_context wl_input_sink`; Simp registers `#add_context wl_pump`. A pending-queue surfaces swap-block input on the next `update_window_events`. Close emits both the Simp close flag and an Input `.QUIT`.

**Tech Stack:** Jai; our wire-protocol `wayland` module (`session.jai`, `input.jai`, `xkb.jai`); vendored `Input` + `Simp`. Design doc: `docs/plans/2026-05-29-wayland-input-event-pump-design.md`.

---

## Testing model (read first)

Same as Slices 1–2: **integration-validated, not unit-tested.**
- **Compile gates (headless, safe):** `./build.sh - compile_only <target>` (NEVER bare — it runs GUIs and hangs); `./build.sh - compile_test` (must stay 11/11); `ldd build/<target>` (libc/vdso/ld-linux only).
- **Functional gates (live Hyprland):** run the binary directly in background with a `JAI_WAYLAND_SIMP_FRAMES=N` cap, screenshot/observe with `grim` + Read, inspect stdout. For input, check `wtype` / `ydotool` availability for synthetic keystrokes; else verify manually + by log.
- **§1 carries special risk** (changes the shared session loop): Task 1 MUST re-verify every `for session()` consumer. Treat that as a gate, not a formality.
- Per task: implement → compile gate → (functional gate where relevant) → commit. Use @superpowers:verification-before-completion — paste real output.

**Branch:** `upstream-integration`. Frequent commits.

---

### Task 1: Persistent `ReceiveBuffer` on the session (the risky one)

**Files:** Modify `modules/wayland/session.jai` (`WaylandSession` struct + `for_expansion`).

**Step 1 — Add the field.** `WaylandSession` gains `recv: ReceiveBuffer;` and `connection_lost: bool;`.

**Step 2 — Rewrite `for_expansion`** to drain `*session.recv` persistently. Current code makes a fresh local `_recv` each call and `wayland_receive`s first. New shape: first drain any messages ALREADY buffered in `session.recv` (peek/consume loop), and only `wayland_receive` (which blocks) when the buffer is empty. On `wayland_receive` returning ≤0 or `wl_display.error`, set `session.connection_lost = true` before `break bts`. Keep the `recv := *session.recv` backtick binding name so existing bodies (`unmarshal(*args, it.payload, recv)`) still compile. Keep the ping/pong + `wl_display.error` handling. The KEY behavior change: messages peeked-but-the-loop-broke survive in `session.recv` for the next drain.

```jai
WaylandSession :: struct {
    pool: Pool;
    conn: Connection;
    registry: Wl_Registry;
    compositor: Wl_Compositor;
    wm_base: Xdg_Wm_Base;
    globals: [..] Global_Info;
    recv: ReceiveBuffer;       // NEW: persistent across for-session drains
    connection_lost: bool;     // NEW: set on socket close / wl_display.error
}

for_expansion :: (session: *WaylandSession, body: Code, flags: For_Flags) #expand {
    `recv := *session.recv;
    drain := true;
    while drain {
        // Process whatever is already buffered before blocking on the socket.
        msg, size := receive_peek_message(`recv);
        if msg == null {
            bts := wayland_receive(*session.conn, `recv);
            if bts <= 0 { session.connection_lost = true; break; }
            msg, size = receive_peek_message(`recv);
        }
        while msg != null {
            header: WaylandMessageHeader;
            header.object_id, header.opcode, header.msg_size = unpack_header(msg);
            header.payload = msg + HEADER_SIZE;
            defer { receive_consume_message(`recv, header.msg_size); msg, size = receive_peek_message(`recv); }
            if header.object_id == 1 && header.opcode == WL_DISPLAY_ERROR {
                /* ... existing log ... */ session.connection_lost = true; drain = false; break;
            } else if header.object_id == session.wm_base.id && header.opcode == XDG_WM_BASE_PING {
                /* ... existing pong ... */
            } else {
                `it := header; `it_index := 0;
                #insert(break=#code { drain = false; break; }) body;
            }
        }
    }
}
```
(Exact control-flow — verify the `break`/`#insert` wiring against the current file; the goal is: body `break` exits the whole drain, leftover buffered messages persist in `session.recv`.)

**Step 3 — Compile gate.** `./build.sh - compile_test` (PASS), `./build.sh - compile_only invaders` (clean).

**Step 4 — RE-VERIFY EVERY CONSUMER (the real gate).** Build + run each, confirm unchanged behavior:
- `./build.sh - hello_globals` (prints globals, exits)
- `./build.sh - hello_screens` (prints outputs, exits)
- `./build.sh - dump_keymap` (prints keymap, exits)
- `./build.sh - hello_window` (run bounded / observe + close)
- `hello_simp` (run bounded via grim — still renders/resizes/closes)
Paste each result. ANY behavior change = stop and reconcile before proceeding.

**Step 5 — Commit.** `git commit -m "refactor(wayland): persistent session ReceiveBuffer (fixes review #2/#5)"`

---

### Task 2: Context hooks + raw-event type

**Files:** Create `modules/Simp/backend/wayland_pump_types.jai` (or add to `dispatch.jai`); `#load` it from `modules/Simp/module.jai`.

Define the input-sink hook and a backend-neutral raw input event the pump hands to Input (so the wayland module/Simp don't depend on Input's `Event` type):

```jai
Wl_Input_Event_Kind :: enum u32 { KEY; POINTER_MOTION; POINTER_BUTTON; POINTER_AXIS; CLOSE; }
Wl_Input_Event :: struct {
    kind: Wl_Input_Event_Kind;
    // KEY:
    evdev_keycode: u32; pressed: bool;
    // POINTER_MOTION: x,y ; POINTER_BUTTON: button, pressed ; POINTER_AXIS: axis, value
    x, y: float; button: u32; axis: u32; value: float;
}
Wl_Input_Sink :: #type (event: Wl_Input_Event);
Wl_Pump      :: #type (blocking: bool);
#add_context wl_input_sink: Wl_Input_Sink;
#add_context wl_pump:       Wl_Pump;
```

**Gate:** `compile_only invaders` clean. **Commit.**

---

### Task 3: `wl_block_on_frame` → `wl_pump(blocking)`

**Files:** Modify `modules/Simp/backend/wayland_gl.jai`.

Generalize the drain: rename/extend `wl_block_on_frame` to `wl_pump(blocking: bool, frame_callback_id, slots, retired, egl, xdg_toplevel_id, xdg_surface_id, signals)`. Behavior:
- If `blocking`, loop until the frame callback (current behavior). If not blocking, drain only what's buffered (use a non-blocking receive or peek-until-empty) and return.
- Keep frame/release/configure-ack/close handling (close → `signals.close_requested` AND, if `context.wl_input_sink`, emit a `CLOSE` Wl_Input_Event).
- NEW: `wl_keyboard.*` / `wl_pointer.*` messages → build a `Wl_Input_Event` and call `context.wl_input_sink(ev)` (guard null). Use `modules/wayland/input.jai`'s event decoders where they fit; otherwise decode opcodes inline.

The non-blocking mode is the subtlety: the drain must process buffered messages without blocking on `wayland_receive`. Reuse the persistent buffer — peek/consume what's present; do NOT call the blocking receive when `!blocking`. (May need a `receive_peek`-only path; check `connection.jai`.)

**Gate:** `compile_only invaders` clean; `compile_test` 11/11. **Commit.**

---

### Task 4: Register `wl_pump`; route swap/set through it

**Files:** `modules/Simp/backend/wayland_dispatch.jai`; the registration site (`linux_init.jai` or `backend_init`).

- `SWAP_BUFFERS` calls `wl_pump(blocking=true, ...)` (was `wl_block_on_frame`).
- Register `context.wl_pump` = a closure/proc that calls `wl_pump` with the current window's ids — OR register a thin proc and have it look up the current window info. (Resolve the binding mechanism: the pump needs per-window ids; `context.wl_pump(blocking)` must find them. Likely via `state.current_window_info`.)

**Gate:** `compile_only invaders` clean. **Commit.**

---

### Task 5: Input Wayland backend

**Files:** Create `modules/Input/wayland.jai`; modify `modules/Input/module.jai` (`#load` it) and the Linux `update_window_events`.

- On first use, register `context.wl_input_sink` = a proc that translates `Wl_Input_Event` → `Input.Event` and appends to a module-level `pending: [..] Event` (+ pending button-state deltas). CLOSE → an `Event` with `type = .QUIT`.
- Wayland branch of `update_window_events`: if `running_wayland()` (or backend is Wayland), do: `array_reset(events_this_frame)` + button-state bookkeeping (mirror `update_x11_window_events`) → `context.wl_pump(false)` (drains, fires sink → pending) → move `pending` into `events_this_frame` + apply to `input_button_states`.
- Keysym→Key_Code: see Task 6.

**Gate:** `compile_only invaders` clean; `compile_test` 11/11. **Commit.**

---

### Task 6: Keysym → `Input.Key_Code` mapping

**Files:** `modules/Input/wayland.jai` (helper) — reuse `modules/wayland/xkb.jai`.

Parse the keyboard keymap once (the `wl_keyboard.keymap` fd, as `hello_window` does via `parse_keymap_fd`). `Wl_Input_Event.evdev_keycode` → keysym (`keymap_get_keysym`) → `Input.Key_Code`. Map the common set: A–Z, 0–9, arrows, SPACE, ENTER, ESCAPE, SHIFT/CTRL/ALT. Modifiers from `wl_keyboard.modifiers` → `Input.Modifier_Flags`.

**Gate:** `compile_only invaders` clean. **Commit.**

---

### Task 7: Extend `hello_simp` to show input

**Files:** `examples/hello_simp.jai`.

Add `update_window_events()` already in the loop (Slice 2). Now also iterate `Input.events_this_frame`: print KEYBOARD (key + pressed) and pointer events; on `.QUIT` (or `window_should_close`) exit. Keep the cycling quad.

**Gate:** `compile_only hello_simp` clean. **Commit.**

---

### Task 8: SLICE 3 FUNCTIONAL GATE

1. **Per-consumer re-verify** (repeat Task 1 Step 4 against final state).
2. **Input live:** run `hello_simp` on Hyprland; check `wtype`/`ydotool` for synthetic keys (`wtype "rgb"`, click) → confirm printed events; else manual. Super+Q → `.QUIT` → exits.
3. **Compile/ldd/test:** `compile_only hello_simp` + `invaders` clean; `ldd build/hello_simp` clean; `compile_test` 11/11.
4. Use @superpowers:verification-before-completion — paste real evidence.

Invaders-on-Wayland stays **Slice 4**.

---

## Sequencing notes

- **Task 1 is the high-risk gate** — the persistent buffer changes shared behavior. Do not proceed past its Step 4 re-verification with any unexplained regression.
- Tasks 2–6 are a compile unit conceptually (hooks → pump → register → Input backend → mapping); commit each but expect the first end-to-end *run* only after Task 7.
- `examples/hello_gl.jai` is never edited.
- The non-blocking drain (Task 3) and the `wl_pump` per-window-id binding (Task 4) are the two implementation unknowns — flag early if they need a design tweak.
