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
wl_quit_emitted      := false;  // emit the .QUIT event for a compositor close only once

// Pointer position tracking — wl_pointer.motion gives surface-ABSOLUTE position;
// we derive the relative mouse_delta the camera/UI use by differencing it. ENTER
// (re)baselines so the first motion after entering doesn't make a huge jump.
wl_last_mouse_x:   float;
wl_last_mouse_y:   float;
wl_have_mouse_pos: bool;

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

    // Drain anything ready since last frame with a non-blocking (zero-timeout)
    // pump, so input, pings, and buffer releases that arrived since the last
    // present are read from the socket before the app reads this frame's events.
    WS.wl_pump_timed(0);

    // Emit Window_Resize_Records for any window the pump flagged as resized
    // (xdg_toplevel.configure changed its size). This is the Wayland equivalent of
    // X11's ConfigureNotify -> add_resize_record: apps read these via
    // get_window_resizes() to realloc the backend and re-lay-out (invaders does
    // exactly this). Without it, the compositor's post-map reconfigure is dropped
    // and the app renders at the stale initial size.
    for * ww: WS.wayland_global_windows {
        if ww.size_dirty {
            ww.size_dirty = false;
            rec: *Window_Resize_Record;
            for * pending_resizes {
                if it.window.wtype == .Wayland && it.window.wayland.surface == ww.surface.id {
                    rec = it;
                    break;
                }
            }
            if !rec  rec = array_add(*pending_resizes);
            rec.window = .{ wtype = .Wayland, wayland = .{ surface = ww.surface.id } };
            rec.width  = ww.width;
            rec.height = ww.height;
        }
        // Compositor-requested close (xdg_toplevel.close: Hyprland killactive/Super+Q,
        // a title-bar X, etc.) -> emit a .QUIT event so apps that watch
        // events_this_frame for it (skeletal-animation) terminate. (Simp.window_should_close
        // reads the same ww.wl_close_requested flag for apps that poll instead.)
        if ww.wl_close_requested && !wl_quit_emitted {
            wl_quit_emitted = true;
            qev: Event;
            qev.type = .QUIT;
            array_add(*events_this_frame, qev);
        }
    }

    // Reflect keyboard focus (set in the pump on wl_keyboard.enter/leave) so apps
    // that gate on focus (e.g. skeletal-animation's camera) behave correctly.
    input_application_has_focus = WS.wl_keyboard_focused;

    for ev: WS.provisional_input_events {
        if ev.kind == {
            case .MODIFIERS;
                m := ev.modifiers.mods_depressed;
                wl_mod_shift = (m & 0x01) != 0;  // Shift   (xkb index 0 == X11 ShiftMask)
                wl_mod_ctrl  = (m & 0x04) != 0;  // Control (index 2 == ControlMask)
                wl_mod_alt   = (m & 0x08) != 0;  // Mod1    (index 3 == Mod1Mask / Alt)
                wl_mod_meta  = (m & 0x40) != 0;  // Mod4    (index 6 == Mod4Mask / Super)

            case .KEY;
                wl_emit_key(ev.key, is_repeat = false);

            case .POINTER_ENTER;
                // (Re)baseline the pointer position so the first motion delta after
                // entering isn't a huge jump.
                wl_last_mouse_x   = ev.pointer_enter.x;
                wl_last_mouse_y   = ev.pointer_enter.y;
                wl_have_mouse_pos = true;

            case .POINTER_MOTION;
                // Derive relative motion (camera/UI read mouse_delta; reset to 0 each
                // frame by input_per_frame_event_and_flag_update).
                if wl_have_mouse_pos {
                    mouse_delta_x += cast(int)(ev.pointer_motion.x - wl_last_mouse_x);
                    mouse_delta_y += cast(int)(ev.pointer_motion.y - wl_last_mouse_y);
                }
                wl_last_mouse_x   = ev.pointer_motion.x;
                wl_last_mouse_y   = ev.pointer_motion.y;
                wl_have_mouse_pos = true;

            case .POINTER_BUTTON;
                kc := wl_button_to_key_code(ev.pointer_button.button);
                if kc != .UNKNOWN {
                    bev: Event;
                    bev.type        = .KEYBOARD;
                    bev.key_pressed = cast(u32)(ifx ev.pointer_button.pressed then 1 else 0);
                    bev.key_code    = kc;
                    bev.shift_pressed    = wl_mod_shift;
                    bev.ctrl_pressed     = wl_mod_ctrl;
                    bev.alt_pressed      = wl_mod_alt;
                    bev.cmd_meta_pressed = wl_mod_meta;
                    array_add(*events_this_frame, bev);
                    if ev.pointer_button.pressed  input_button_states[kc] = .START | .DOWN;
                    else                          input_button_states[kc] = .END;
                }

            case .POINTER_AXIS;
                // Vertical scroll -> MOUSE_WHEEL + mouse_delta_z (matches x11.jai).
                // Wayland: positive value = scroll DOWN; X11 convention: up = +WHEEL_DELTA.
                if ev.pointer_axis.axis == 0 {  // VERTICAL_SCROLL
                    wev: Event;
                    wev.type                = .MOUSE_WHEEL;
                    wev.typical_wheel_delta = WHEEL_DELTA;
                    wev.wheel_delta         = cast(s32)(ifx ev.pointer_axis.value < 0 then WHEEL_DELTA else -WHEEL_DELTA);
                    array_add(*events_this_frame, wev);
                    mouse_delta_z += wev.wheel_delta;
                }

            case .TOUCH_DOWN;
                tv: Event;
                tv.type        = .TOUCH;
                tv.touch_type  = .PRESSED;
                tv.touch_index = ev.touch_down.id;
                tv.touch_x     = ev.touch_down.x;
                tv.touch_y     = ev.touch_down.y;
                array_add(*events_this_frame, tv);
                wl_set_touch_pointer(ev.touch_down.id, true, ev.touch_down.x, ev.touch_down.y);

            case .TOUCH_MOTION;
                tv: Event;
                tv.type        = .TOUCH;
                tv.touch_type  = .MOVED;
                tv.touch_index = ev.touch_motion.id;
                tv.touch_x     = ev.touch_motion.x;
                tv.touch_y     = ev.touch_motion.y;
                array_add(*events_this_frame, tv);
                wl_set_touch_pointer(ev.touch_motion.id, true, ev.touch_motion.x, ev.touch_motion.y);

            case .TOUCH_UP;
                tv: Event;
                tv.type        = .TOUCH;
                tv.touch_type  = .RELEASED;
                tv.touch_index = ev.touch_up.id;
                array_add(*events_this_frame, tv);
                wl_set_touch_pointer(ev.touch_up.id, false, 0, 0);

            case .DRAG_DROP;
                // The pump pulled the raw text/uri-list across the pipe; parse it
                // into heap-allocated paths (the same shape x11.jai emits, freed by
                // input_per_frame_event_and_flag_update) and emit one event.
                files := wl_parse_uri_list(ev.drag_drop.uri_list);
                free(ev.drag_drop.uri_list.data);  // the pump heap-allocated it; ownership ends here
                if files.count > 0 {
                    dev: Event;
                    dev.type  = .DRAG_AND_DROP_FILES;
                    dev.files = files;
                    array_add(*events_this_frame, dev);
                } else {
                    array_free(files);
                }
        }
    }

    // Synthesize key autorepeat. Wayland sends NO repeat events — while a key is
    // held the client replays it at the compositor's repeat_info rate after its
    // delay (WS tracks the held key + timing). Reusing wl_emit_key gives repeats
    // the same modifier handling, TEXT_INPUT, and input_button_states as a real
    // press — so e.g. holding Backspace in a GetRect field deletes repeatedly.
    repeat_count, repeat_key := WS.wl_repeats_due();
    for 1..repeat_count  wl_emit_key(repeat_key, is_repeat = true);

    WS.wl_clear_input_events();
}

// Turn one decoded key event into Input events: a KEYBOARD event always, plus a
// TEXT_INPUT event when the keysym is printable AND no command modifier is held.
// Used for both real key events and synthesized autorepeats (is_repeat sets
// Event.repeat). Suppressing TEXT_INPUT under Ctrl/Alt/Meta is what keeps Ctrl+C/
// V/X from inserting a literal 'c'/'v'/'x' into a text field — those chords are
// commands, not text. (Shift is NOT a command modifier: Shift+a is 'A'.) This
// mirrors the X11 path, where XwcLookupString maps Ctrl+key to a control char
// that its `< 32` filter drops.
wl_emit_key :: (kev: WS.Wl_Key_Event, is_repeat: bool) {
    event: Event;
    event.type        = .KEYBOARD;
    event.key_pressed = cast(u32)(ifx kev.pressed then 1 else 0);
    event.key_code    = get_key_code(xx kev.keysym);
    event.repeat      = is_repeat;

    event.shift_pressed    = wl_mod_shift;
    event.ctrl_pressed     = wl_mod_ctrl;
    event.alt_pressed      = wl_mod_alt;
    event.cmd_meta_pressed = wl_mod_meta;
    // Pressing a modifier key itself should report that modifier (its MODIFIERS
    // event may not have arrived yet) — matches x11.jai.
    if event.key_code == {
        case .SHIFT; event.shift_pressed    = true;
        case .CTRL;  event.ctrl_pressed     = true;
        case .ALT;   event.alt_pressed      = true;
        case .META;  event.cmd_meta_pressed = true;
    }

    command_chord := wl_mod_ctrl || wl_mod_alt || wl_mod_meta;
    utf32 := ifx (kev.pressed && !command_chord) then keysym_to_utf32(kev.keysym) else 0;
    if utf32 != 0  event.text_input_count = 1;

    if WS.wl_should_log_keys() {
        log("INPUT_KEY evdev=% keysym=0x% -> key=% pressed=% repeat=% shift=% ctrl=% alt=% meta=% command_chord=% utf32=0x% text_count=%",
            kev.keycode,
            formatInt(kev.keysym, base=16),
            event.key_code,
            event.key_pressed,
            event.repeat,
            event.shift_pressed,
            event.ctrl_pressed,
            event.alt_pressed,
            event.cmd_meta_pressed,
            command_chord,
            formatInt(utf32, base=16),
            event.text_input_count);
    }

    array_add(*events_this_frame, event);
    if kev.pressed  input_button_states[event.key_code] = .START | .DOWN;
    else            input_button_states[event.key_code] = .END;

    if utf32 != 0 {
        tev: Event;
        tev.type        = .TEXT_INPUT;
        tev.key_pressed = 1;
        tev.key_code    = event.key_code;
        tev.utf32       = utf32;
        array_add(*events_this_frame, tev);
    }
}

// Parse a text/uri-list (RFC 2483) into heap-allocated file paths — matching the
// X11 backend's output (copy_string'd; both array and strings freed by Input's
// per-frame reset). Tolerates CRLF or LF endings and a missing final newline;
// skips blank lines, '#' comment lines, and non-file:// or hostname'd URIs (the
// same hostname restriction x11.jai applies).
wl_parse_uri_list :: (uri_list: string) -> [..] string {
    files: [..] string;
    URI_PREFIX :: "file://";

    remaining := uri_list;
    while remaining.count > 0 {
        line: string;
        nl := find_index_from_left(remaining, "\n");
        if nl == -1 {
            line = remaining;
            remaining.count = 0;
        } else {
            line = slice(remaining, 0, nl);
            advance(*remaining, nl + 1);
        }
        if line.count > 0 && line[line.count - 1] == #char "\r"  line.count -= 1;  // trim CRLF

        if line.count == 0          continue;  // blank line
        if line[0] == #char "#"     continue;  // comment line (text/uri-list spec)
        if !begins_with(line, URI_PREFIX)  continue;

        path := slice(line, URI_PREFIX.count, line.count - URI_PREFIX.count);
        if path.count == 0  continue;
        if path[0] != #char "/" {
            // "file://host/path" — hostname'd URIs unsupported (matches x11.jai).
            log_error("Wayland drag & drop: file URIs with hostnames are not supported. Ignoring \"%\".", line);
            continue;
        }
        array_add(*files, copy_string(path));
    }
    return files;
}

// Map an xkb/X11 keysym to a Unicode codepoint, or 0 if it is not a text
// character (function keys, arrows, modifiers, etc.). ASCII and Latin-1 keysyms
// ARE their codepoint; the 0x0100xxxx range encodes Unicode directly.
keysym_to_utf32 :: (keysym: u32) -> u32 {
    if keysym >= 0x20 && keysym <= 0x7e  return keysym;                  // printable ASCII
    if keysym >= 0xa0 && keysym <= 0xff  return keysym;                  // Latin-1 supplement
    if (keysym & 0xff000000) == 0x01000000  return keysym & 0x00ffffff;  // direct Unicode keysym
    return 0;
}

// Update the touch_pointers snapshot (active fingers + positions) and recount
// touch_pointers_active. wl_touch ids are small and sequential per active touch,
// so we use the id directly as the slot index. (Untested — no touch device here.)
wl_set_touch_pointer :: (id: s32, down: bool, x: float, y: float) {
    if id < 0 || id >= TOUCH_POINTERS_COUNT  return;
    if down {
        touch_pointers[id].state = .DOWN;
        touch_pointers[id].window_position_x = x;
        touch_pointers[id].window_position_y = y;
    } else {
        touch_pointers[id].state = 0;
    }
    n := 0;
    for touch_pointers  if it.state & .DOWN  n += 1;
    touch_pointers_active = n;
}

// Map a Linux evdev button code (what wl_pointer.button carries) to a Key_Code.
wl_button_to_key_code :: (button: u32) -> Key_Code {
    if button == {
        case 0x110; return .MOUSE_BUTTON_LEFT;     // BTN_LEFT
        case 0x111; return .MOUSE_BUTTON_RIGHT;    // BTN_RIGHT
        case 0x112; return .MOUSE_BUTTON_MIDDLE;   // BTN_MIDDLE
        case 0x113; return .MOUSE_BUTTON_EXTRA_1;  // BTN_SIDE
        case 0x114; return .MOUSE_BUTTON_EXTRA_2;  // BTN_EXTRA
    }
    return .UNKNOWN;
}
