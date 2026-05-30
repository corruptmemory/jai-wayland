// New file (not in upstream Input). The Wayland input backend for the Input
// module: drains Wayland_Support's decoded Wl_Input_Events (produced by the
// single shared pump) into Input's events_this_frame / input_button_states — the
// same per-frame model the X11 backend (x11.jai) fills. Loaded alongside x11.jai
// on Linux; update_window_events (x11.jai) branches here when running_wayland().
//
// Reuses get_key_code (x11.jai): xkb keysyms share X11 keysym numbering, so the
// same keysym -> Key_Code table applies. WS is the module-private import declared
// in module.jai. Event / events_this_frame / input_button_states / Key_Code /
// input_per_frame_event_and_flag_update are all Input module scope.

// Current modifier state, tracked from Wl_Input_Event.MODIFIERS and stamped onto
// each KEY event — Wayland delivers modifier state out-of-band, unlike X11's
// per-event xkey.state. The xkb modifier-mask bit positions match X11's modifier
// masks for the standard modifiers (Shift=0x01, Control=0x04, Mod1/Alt=0x08,
// Mod4/Super=0x40), so we test the same bits. (Non-default keymaps that remap
// modifier indices are a future refinement.)
wl_mod_shift: bool;
wl_mod_ctrl:  bool;
wl_mod_alt:   bool;
wl_mod_meta:  bool;

wl_input_initialized := false;

update_wayland_window_events :: () {
    // Lazy one-time acquisition. Safe here because apps poll input at the TOP of
    // the frame, before the first swap_buffers — so wl_acquire_input's sync
    // roundtrips run with no render events in flight. Idempotent regardless.
    if !wl_input_initialized {
        WS.wl_acquire_input();
        wl_input_initialized = true;
    }

    // Same per-frame bookkeeping the X11 path does: clear events_this_frame and
    // age the START/END flags on input_button_states.
    input_per_frame_event_and_flag_update();

    // Drain anything buffered since last frame. swap_buffers' blocking pump
    // already decoded keys that arrived during frame pacing; this sweeps the rest.
    WS.wl_pump(false);

    // Emit Window_Resize_Records for any window the pump flagged as resized
    // (xdg_toplevel.configure changed its size). This is the Wayland equivalent of
    // X11's ConfigureNotify -> add_resize_record: apps read these via
    // get_window_resizes() to realloc the backend and re-lay-out (invaders does
    // exactly this). Without it, the compositor's post-map reconfigure is dropped
    // and the app renders at the stale initial size.
    for * ww: WS.wayland_global_windows {
        if ww.size_dirty {
            ww.size_dirty = false;
            rec := array_add(*pending_resizes);
            rec.window = .{ wtype = .Wayland, wayland = .{ surface = ww.surface.id } };
            rec.width  = ww.width;
            rec.height = ww.height;
        }
    }

    for ev: WS.provisional_input_events {
        if ev.kind == {
            case .MODIFIERS;
                m := ev.modifiers.mods_depressed;
                wl_mod_shift = (m & 0x01) != 0;  // Shift   (xkb index 0 == X11 ShiftMask)
                wl_mod_ctrl  = (m & 0x04) != 0;  // Control (index 2 == ControlMask)
                wl_mod_alt   = (m & 0x08) != 0;  // Mod1    (index 3 == Mod1Mask / Alt)
                wl_mod_meta  = (m & 0x40) != 0;  // Mod4    (index 6 == Mod4Mask / Super)

            case .KEY;
                event: Event;
                event.type        = .KEYBOARD;
                event.key_pressed = cast(u32)(ifx ev.key.pressed then 1 else 0);
                event.key_code    = get_key_code(xx ev.key.keysym);

                event.shift_pressed    = wl_mod_shift;
                event.ctrl_pressed     = wl_mod_ctrl;
                event.alt_pressed      = wl_mod_alt;
                event.cmd_meta_pressed = wl_mod_meta;
                // Pressing a modifier key itself should report that modifier (its
                // MODIFIERS event may not have arrived yet) — matches x11.jai.
                if event.key_code == {
                    case .SHIFT; event.shift_pressed    = true;
                    case .CTRL;  event.ctrl_pressed     = true;
                    case .ALT;   event.alt_pressed      = true;
                    case .META;  event.cmd_meta_pressed = true;
                }

                array_add(*events_this_frame, event);
                if ev.key.pressed  input_button_states[event.key_code] = .START | .DOWN;
                else               input_button_states[event.key_code] = .END;
        }
    }

    WS.wl_clear_input_events();
}
