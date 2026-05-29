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

// Implemented by Simp (extends its swap-path drain). blocking=true blocks until
// the frame callback fires (vsync pacing, used by swap_buffers); blocking=false
// drains only what is already buffered and returns (used by update_window_events).
Wl_Pump :: #type (blocking: bool);

// Implemented by the Input backend. The pump calls it for every message it does
// NOT recognize as one of its own render events (frame callback / wl_buffer.release
// / xdg_*.configure / xdg_toplevel.close). The sink inspects the RAW message via
// (header, recv) — reusing the wayland module's own decoders (get_keyboard_event /
// get_pointer_event) — classifies and translates input itself, and returns whether
// it consumed the message. This keeps ALL input ownership (seat/keyboard/pointer
// acquisition, keymap parsing, keysym -> Key_Code mapping) inside Input, and the
// pump free of any input-decode logic. Render events never reach the sink.
// recv is the CONCRETE Default_ReceiveBuffer (not the bare polymorphic
// ReceiveBuffer) — a context-field function-pointer type cannot mention a
// polymorphic type. session.recv instantiates to exactly this type.
// Fire-and-forget (no return): the pump consumes the message unconditionally
// (its defer), and only forwards a message here AFTER ruling out its own render
// objects — so the sink can't "decline" a message back to the pump.
Wl_Input_Sink :: #type (header: WaylandMessageHeader, recv: *Default_ReceiveBuffer);

// Set true by the pump on xdg_toplevel.close. A decoupled close signal: the pump
// (Simp) also sets its own per-window close flag, but Input reads THIS to emit a
// .QUIT event without needing the toplevel's object id or a Simp import. Terminal
// (never reset) — single-window scope, which is all Slice 3 / invaders need.
#add_context wl_window_closed: bool;

#add_context wl_pump:       Wl_Pump;
#add_context wl_input_sink: Wl_Input_Sink;
