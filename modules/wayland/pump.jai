// Event-pump contract shared by the Simp render backend (which IMPLEMENTS the
// pump) and the Input backend (which CONSUMES input events). These types live in
// the wayland module — which both Simp and Input already import — so the two wire
// together through context hooks WITHOUT a static Simp<->Input dependency (the
// decoupling chosen in the Slice 3 design, docs/plans/2026-05-29-wayland-input-
// event-pump-design.md §2).
//
// Data flow: the app calls update_window_events (Input) then swap_buffers (Simp);
// both call context.wl_pump, which drains the persistent session buffer once and
// dispatches each message — render events (frame/release/configure/close) to
// Simp's slot state directly, input events to context.wl_input_sink (Input's).

// A backend-neutral input event the pump hands to the Input sink. Deliberately
// raw (evdev keycode, not a translated Key_Code) so the wayland module stays
// free of any dependency on Input's enums — the Input backend does the
// keysym->Key_Code mapping (Slice 3 Task 6).
Wl_Input_Event_Kind :: enum u32 {
    KEY;             // a key press/release
    POINTER_MOTION;  // pointer moved (surface-local x,y)
    POINTER_BUTTON;  // pointer button press/release
    POINTER_AXIS;    // scroll
    CLOSE;           // xdg_toplevel.close — the window was asked to close
}

Wl_Input_Event :: struct {
    kind:          Wl_Input_Event_Kind;
    evdev_keycode: u32;    // KEY: evdev keycode (xkb keycode - 8)
    pressed:       bool;   // KEY / POINTER_BUTTON: down (true) or up (false)
    x, y:          float;  // POINTER_MOTION: surface-local coordinates
    button:        u32;    // POINTER_BUTTON: linux input button code (BTN_*)
    axis:          u32;    // POINTER_AXIS: 0 = vertical, 1 = horizontal
    value:         float;  // POINTER_AXIS: scroll amount
}

// Implemented by Simp (extends its swap-path drain). blocking=true blocks until
// the frame callback fires (vsync pacing, used by swap_buffers); blocking=false
// drains only what is already buffered and returns (used by update_window_events).
Wl_Pump :: #type (blocking: bool);

// Implemented by the Input backend; the pump calls it for each input event.
Wl_Input_Sink :: #type (event: Wl_Input_Event);

#add_context wl_pump:       Wl_Pump;
#add_context wl_input_sink: Wl_Input_Sink;
