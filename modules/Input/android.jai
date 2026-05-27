// Vendored from ~/jai/jai/modules/Input/android.jai.
// Verbatim copy.



// To help get desktop code working on android, we generate mouse click events for touch input and
// Window_Creation.get_mouse_pointer_position will return position of touch. Set this to false if you don't want that 
// behaviour and are handling input with TOUCH events instead.
android_generate_mouse_clicks_for_touch_events := true;
android_last_touch_x, android_last_touch_y := -1.0;

android_using_onscreen_keyboard := false; // :AndroidSpecific way to know if keyboard events were coming from hardware or software keyboard

// @Cleanup: What is actually required to be tracked and/or exported to handle focus/background behaviour
android_in_foreground: bool;
android_in_focus: bool;

android_event_processing_block_mode: enum {
    NEVER;
    WHEN_IN_BACKGROUND;
    WHEN_NOT_IN_FOCUS;
} = .NEVER;


window_minimized :: false;

update_window_events :: () {
    input_per_frame_event_and_flag_update();

    // @CopyPasta Same thing input_per_frame_event_and_flag_update does for button states.
    mask     := ~Key_Current_State.START;
    end_mask := ~(Key_Current_State.END | .DOWN | .START);
    for * touch_pointers {
        if (it.state & .END) it.state &= end_mask;
        else it.state &= mask;
    }

    if pointer_as_mouse_releasd_last_frame {
        pointer_as_mouse_releasd_last_frame = false;
        android_last_touch_x, android_last_touch_y = -1.0;
    }
    
    android_process_events();
}

android_process_events :: () {
    // NOTE(Charles): On Android "Looper" api, what is it good for, absolutely nothing?
    //
    // By default there are two types of "events" that this procedure processes. 1) "Input" events, the kind of user
    // input you might expect - eg. screen presses or key presses. 2) "Command" events, life cycle type events, eg window
    // inited or gained focus, see APP_CMD for full list. Input events are read from a queue (AInputQueue) that is provided
    // by ANativeActivity. The command events are triggered by various android lifecycle callbacks that ANativeActivity
    // forwards to native code, eg onNativeWindowCreated. 
    //
    // Because the command event lifecycle callbacks happen on the apps activity/ui thread (ie _not_ our jai first
    // thread) there needs to be some interthread communication. This is acheived by a pipe, see android_app_write_cmd
    // and android_app_read_cmd. The InputQueue class handles this for input events, see the AInputQueue_ api calls
    // in process_input.
    //
    // So then, why do we see none of that in here, and instead have these ALooper api calls? It seems that all we get
    // out of the looper is a generic way for the code here to call one api and tell if there are either input events, or 
    // command events. But 2 is not a very large number and it seems to me it would be much clearer if we just queried for
    // if either events were ready ourselves, eg by calling AInputQueue_getEvent. (The looper can do more, eg trigger call
    // backs, or apps could add their own events and use the same infrastructure but these things are not done atm).
    //
    // For now I am keeping the ALooper stuff as it is the standard thing, but when I simplify the native_app.jai code
    // this is likely to be something that gets simplified.

    while true {
        // Read all pending events. A timeout of 0 means we return immediately, while a negative timeout means we block
        // until we receive an event.
        timeout: s32;
        if #complete android_event_processing_block_mode == {
            case .NEVER;               timeout = 0;
            case .WHEN_IN_BACKGROUND;  timeout = ifx android_in_foreground then cast(s32) 0 else -1;
            case .WHEN_NOT_IN_FOCUS;   timeout = ifx android_in_focus      then cast(s32) 0 else -1;
        }

        events: s32;
        source: *Android_Poll_Source;
        poll_result := ALooper_pollOnce(timeout, null, *events, cast(**void)*source);

        if poll_result < 0 {
            poll_error := cast(ALOOPER_POLL, poll_result);

            if #complete poll_error == {
                case .CALLBACK;  assert(false); // We never setup any callbacks (in ALooper_addFd calls).
                case .WAKE;      continue;      // It has been observed that when debugging this can sometimes happen, just continue.
                case .TIMEOUT;   break;         // No events.
                
                case .ERROR;
                    log_error("android_process_events: ALooper_pollOnce returned an error, aborting.");
                    break;
            }
        } 
        
        looper_id := cast(LOOPER_ID, poll_result);
        assert(looper_id == .MAIN || looper_id == .INPUT, "android_process_events: ALooper_pollOnce returned unexpected looper id of %. We expected 1 (LOOPER_ID_MAIN) or 2 (LOOPER_ID_INPUT)", poll_result);

        // Process this event. This triggers android_handle_command/android_handle_input_event.
        assert(source != null, "android_process_events: android_poll_source for looper id % was null. This is no good!", looper_id);
        source.process(android_app, source);

        // The apps NativeActivity is being destroyed and waiting for our native code thread to exit. Post a quit message.
        if android_app.destroyRequested {
            event: Event;
            event.type = .QUIT;
            array_add(*events_this_frame, event);
            break;
        }
    }
}

set_custom_cursor_handling :: (is_custom: bool) {}

// Mac impelmentation does this with a table. Maybe we should do that too?
get_key_code :: (key_code: AKEYCODE) -> Key_Code {
    if key_code == {
        case .DEL;     return .BACKSPACE; // Nice. Android decided to change the names so DEL == BACKSPACE, and FORWARD_DEL is DELETE...
        case .TAB;     return .TAB;
        // case ?      return .LINEFEED;
        case .ENTER;   return .ENTER;
        case .ESCAPE;  return .ESCAPE;
        case .SPACE;   return .SPACEBAR;

        case ._0;  return #char "0";
        case ._1;  return #char "1";
        case ._2;  return #char "2";
        case ._3;  return #char "3";
        case ._4;  return #char "4";
        case ._5;  return #char "5";
        case ._6;  return #char "6";
        case ._7;  return #char "7";
        case ._8;  return #char "8";
        case ._9;  return #char "9";
        case .A;   return #char "A";
        case .B;   return #char "B";
        case .C;   return #char "C";
        case .D;   return #char "D";
        case .E;   return #char "E";
        case .F;   return #char "F";
        case .G;   return #char "G";
        case .H;   return #char "H";
        case .I;   return #char "I";
        case .J;   return #char "J";
        case .K;   return #char "K";
        case .L;   return #char "L";
        case .M;   return #char "M";
        case .N;   return #char "N";
        case .O;   return #char "O";
        case .P;   return #char "P";
        case .Q;   return #char "Q";
        case .R;   return #char "R";
        case .S;   return #char "S";
        case .T;   return #char "T";
        case .U;   return #char "U";
        case .V;   return #char "V";
        case .W;   return #char "W";
        case .X;   return #char "X";
        case .Y;   return #char "Y";
        case .Z;   return #char "Z";

        // AKEYCODE contains pretty much all the keys like below. I started adding them but then realised other input
        // implementations don't do this. We will trigger TEXT_INPUT events for these kinds of characters.
        case .APOSTROPHE;           return #char "'";
        case .COMMA;                return #char ",";
        case .MINUS;                return #char "-";
        case .PERIOD;               return #char ".";
        case .SLASH;                return #char "/";
        case .SEMICOLON;            return #char ";";
        case .EQUALS;               return #char "=";
        case .LEFT_BRACKET;         return #char "(";
        case .BACKSLASH;            return #char "\\";
        case .RIGHT_BRACKET;        return #char ")";
        case .GRAVE;                return #char "`";

        case .FORWARD_DEL;  return .DELETE;

        case .DPAD_UP;     return .ARROW_UP;
        case .DPAD_DOWN;   return .ARROW_DOWN;
        case .DPAD_LEFT;   return .ARROW_LEFT;
        case .DPAD_RIGHT;  return .ARROW_RIGHT;

        case .PAGE_UP;   return .PAGE_UP;
        case .PAGE_DOWN; return .PAGE_DOWN;

        case .MOVE_HOME;  return .HOME;
        case .MOVE_END;   return .END;

        case .INSERT;  return .INSERT;

        case .BREAK;        return .PAUSE;
        case .SCROLL_LOCK;  return .SCROLL_LOCK;

        case .ALT_LEFT; #through;
        case .ALT_RIGHT;    return .ALT;
        case .CTRL_LEFT; #through;
        case .CTRL_RIGHT;   return .CTRL;
        case .SHIFT_LEFT; #through;
        case .SHIFT_RIGHT;  return .SHIFT;
        case .META_LEFT; #through;
        case .META_RIGHT;   return .META;

        case .F1;   return .F1;
        case .F2;   return .F2;
        case .F3;   return .F3;
        case .F4;   return .F4;
        case .F5;   return .F5;
        case .F6;   return .F6;
        case .F7;   return .F7;
        case .F8;   return .F8;
        case .F9;   return .F9;
        case .F10;  return .F10;
        case .F11;  return .F11;
        case .F12;  return .F12;
        // Android doesn't have F13-F24 like Input does.

        case .SYSRQ;  return .PRINT_SCREEN;
    }

    return .UNKNOWN;
}

android_handle_command :: (app: *Android_App, cmd: s32) {
    command := cast(APP_CMD) cmd;
    log("Command received: %", command, flags = .VERY_VERBOSE_ONLY);

    if #complete command == {
        case .START;
            // Store a copy of the initial config so we can compare in CONFIG_CHANGED. (This won't be necessary when glue
            // code is ported and we can do this directly.)
            reference_config = AConfiguration_new();
            AConfiguration_copy(reference_config, app.config);

        // Intentionally not handled for now.
        case .STOP;
        case .RESUME;
        case .PAUSE;
        case .DESTROY;

        case .INIT_WINDOW;
            android_in_foreground = true;
            send_window_event(.MOVED_TO_FOREGROUND); // :AndroidLifeCycle The window is being shown, get it ready.

        case .TERM_WINDOW;
            android_in_foreground = false;
            send_window_event(.MOVED_TO_BACKGROUND); // :AndroidLifeCycle The window is being hidden or closed, clean it up.

        case .GAINED_FOCUS;
            input_application_has_focus = true;
            android_in_focus = true;
            send_window_event(.GAINED_FOCUS);

        case .LOST_FOCUS;
            input_application_has_focus = false;
            android_in_focus = false;
            send_window_event(.LOST_FOCUS);
            
        case .WINDOW_REDRAW_NEEDED; // Not sure if this is ever neccesary?

        case .WINDOW_RESIZED;
            add_resize_record(app.window);

        case .CONTENT_RECT_CHANGED;
            // @Incomplete: The contentRect is the "safe to draw" area of screen. It will generally be smaller than the full window.
            // For phones with "display cutouts" (most phones now?), the part of the screen with the cutout will not be included in
            // the contentRect. Any "system bars", eg the navigation bar, or the gesture pill at the bottom, will also be exlcuded
            // from the contentRect.
            //
            // The contentRect change change in at least these ways:
            // 1) When entering/leaving "immersive mode", ie hiding/showing the system bars. (Display cutouts will still be excluded
            //    from contentRect in immersive mode)
            // 2) When show/hiding the software keyboard.
            //
            // How do we communicate this to programs? We could use window resize events, and have Simp get_render_dimensions use
            // the contentRect but that seems maybe a bad restrction, eg maybe an app wants to keep drawing below software keyboard?
            rect_width  := app.contentRect.right - app.contentRect.left;
            rect_height := app.contentRect.bottom - app.contentRect.top;

            window_width, window_height: s32;
            if app.window {
                window_width  = ANativeWindow_getWidth(app.window);
                window_height = ANativeWindow_getHeight(app.window);
            }

            log("CONTENT_RECT_CHANGED: x, y == (%, %) | width, height == (%, %) | window size == (%, %)", app.contentRect.left, app.contentRect.top, rect_width, rect_height, window_width, window_height, /*flags = .VERY_VERBOSE_ONLY*/);

        case .CONFIG_CHANGED;
            // Certain things, eg screen orientation, are known as "Configuration". When there are any changes
            // to these, the default behaviour is for the app (technically the activity) to restart. You can specifiy in
            // the manifest that the app wants to handle these things itself to avoid this (annoying!) behaviour. In that
            // case we will receive this command.
            // 
            // Our manifest generation code now adds a subset of these configs, but it might make sense to just add them all
            // and handle everything here. 
            //
            // For more - https://developer.android.com/guide/topics/manifest/activity-element#config, or Configuration.java,
            // or AConfiguration* in ndk.
            //
            // :AndroidConfigurationChange

            // The members of ACONFIGURATION that appear to be relevant when using AConfiguration_diff.
            // @TODO: These were lifted from the ACONFIGURATION enum in bindings. They are very similar to the Android_Config_Changes
            // used in manifest.jai but have slightly differnet values. Which one is correct...
            AConfiguration_Diff_Flags :: enum_flags {
                MCC                  :: 0x0001;
                MNC                  :: 0x0002;
                LOCALE               :: 0x0004;
                TOUCHSCREEN          :: 0x0008;
                KEYBOARD             :: 0x0010;
                KEYBOARD_HIDDEN      :: 0x0020;
                NAVIGATION           :: 0x0040;
                ORIENTATION          :: 0x0080;
                DENSITY              :: 0x0100;
                SCREEN_SIZE          :: 0x0200;
                VERSION              :: 0x0400;
                SCREEN_LAYOUT        :: 0x0800;
                UI_MODE              :: 0x1000;
                SMALLEST_SCREEN_SIZE :: 0x2000;
                LAYOUTDIR            :: 0x4000;
                SCREEN_ROUND         :: 0x8000;
                COLOR_MODE           :: 0x10000;
            }

            diff := cast(AConfiguration_Diff_Flags) AConfiguration_diff(app.config, reference_config);
            if diff {
                log("CONFIG_CHANGED: Configuration changed detected: %, but not currently handled!", diff, flags = .WARNING);
            }
            AConfiguration_copy(reference_config, app.config);

            // Well this is useless.. diff always appears to be 0. Eg on screen rotation we get a CONFIG_CHANGED command
            // but AConfiguration_getOrientation just returns whatever the orientation was when the app opened. So how
            // do we tell when this config stuff changes? (Screen orientation is probably fine as we get window resize
            // messages, but the others?)
            assert(diff == 0);

        case .INPUT_CHANGED; // Safe to ignore afaict.

        // @Incomplete: These ones probably do want to be handled.
        case .SAVE_STATE; // I don't think we need to do anything with this, unless we were to handle LOW_MEMORY
        case .LOW_MEMORY;
            log("Command % not currently handled!", command, flags = .WARNING);
    }
}

android_handle_input_event :: (event: *AInputEvent) -> handled: bool {
    handled := false;

    handled = android_handle_gamepad_input_event(event);
    if handled  return true;

    device_id  := AInputEvent_getDeviceId(event); 
    event_type := AInputEvent_getType(event);
    source, source_class := get_source_and_class(event);

    handled_sources := AInput_Source.TOUCHSCREEN | .KEYBOARD | .MOUSE ;
    // handled_sources |= .STYLUS; // ?
    // handled_sources |= .TOUCH_NAVIGATION; // ?

    source_is_handled  := false;
    source_is_handled ||= (source & handled_sources) > 0;

    // @crafn reports on his device software keyboard backspace events come through with source UNKNOWN, class NONE.
    // For now just let all of these through. We could maybe be more explicit and check this is a KEY event with
    // SOFT_KEYBOARD set but screw it.
    source_is_handled ||= source == .UNKNOWN;

    // NOTE(Charles): This is another nail in the coffin for :AndroidMaybeWeHaveToUseJavaAfterallSadge...
    // It seems like you just can't reliably do software keyboard text input with the NDK.
    // The recommended way for game engines to use software keyboard (amongst other things) is to use
    // the GameActivity library.
    // We could have our own java code and not use their junk library, but either way, sadly we probably
    // need to java...

    if !source_is_handled {
        log_error("Unhandled source % with class % for event of type %", source, source_class, event_type);
        return false;
    }

    if #complete event_type == {
      case .KEY;
        key_event := android_get_key_event(event);

        // It is not documented in the NDK but, according to the java apis, ACTION_MULTIPLE, and it's corresponding
        // getCharacters procedure, were deprecated in API level 29 and are "no longer used by the input system".
        // https://developer.android.com/reference/android/view/KeyEvent#ACTION_MULTIPLE
        //
        // However, some special characters (eg £) when typed on a software keyboard will trigger a MULTIPLE event.
        // repeat_count will be zero which (according to KeyEvent docs) indicates you should use getCharacters to
        // determine the character. But that is a member function and we don't have the relevant KeyEvent object
        // in native code to call it on, and don't have any information to create a dummy object like we do in 
        // to_unicode_character.
        //
        // As far as I can tell there is no way to handle these characters purely from native code and we would need
        // a custom java activity class to do so... :AndroidMaybeWeHaveToUseJavaAfterallSadge
        //                  -ctaylor 23 Sept 2024.

        if key_event.action == .MULTIPLE {
            assert(key_event.key_code == .UNKNOWN, "Received a MULTIPLE key event with key_code == %. We only ever expect to get UNKNOWN MULTIPLE events", key_event.key_code);
            assert(key_event.repeat_count == 0, "Received a MULTIPLE key event with non zero repeat_count == %. We only expect to have repeat_code == 0", key_event.repeat_count);

            log("Received key event for a special character that we have no way of telling what it was from native code. Sorry!", flags = .WARNING);
            return false;    
        }

        android_using_onscreen_keyboard = cast(bool) (key_event.flags & .SOFT_KEYBOARD);
        // @Incomplete: Do we need to handle any of the other flags, eg .CANCELED?

        // @Incomplete: I have hit this assert, I am trying to figure out what caused it!
        // assert(key_event.key_code != .UNKNOWN, "Unexpected Android KeyCode 'UNKNOWN' for KeyEvent.");
        if key_event.key_code == .UNKNOWN {
            log_error("Received KEY event but key_code was UNKNOWN? Full event: %", key_event);
            return false;    
        }

        // Key press event
        key_code := get_key_code(key_event.key_code);

        if key_code != .UNKNOWN {
            key_down := key_event.action == .DOWN;
            repeat   := key_event.repeat_count > 0;

            keyboard_event: Event;
            keyboard_event.type = .KEYBOARD;
            keyboard_event.key_code = key_code;
            keyboard_event.key_pressed = xx key_down;
            keyboard_event.shift_pressed = (key_event.meta_state & .SHIFT_ON) != 0;
            keyboard_event.ctrl_pressed  = (key_event.meta_state & .CTRL_ON)  != 0;
            keyboard_event.alt_pressed   = (key_event.meta_state & .ALT_ON)   != 0;
            keyboard_event.repeat = repeat;
            array_add(*events_this_frame, keyboard_event);
            handled = true;

            if key_down {
                input_button_states[key_code] |= .DOWN;
                if !repeat  input_button_states[key_code] |= .START;
            } else {
                input_button_states[key_code] |= .END;
            }
        } else {
            // We assert above that Android doesn't give us a AKEYCODE.UNKNOWN, but we expect our get_key_code conversion to
            // return Key_Code.UNKNOWN in two cases:
            // 1) Keys that are only treated as TEXT_INPUT rather than KEYBOARD events in other backends, eg '*'. The TEXT_INPUT
            //    event happens below.
            // 2) System buttons/gestures, eg the "Back"* button, or the volume buttons. There is not an obvious way to map these
            //    onto the current Input api, but also, some additional handling would be required. For these events, if we return
            //    true here, the default behaviour (eg changing the volume or navigating to previous app) will be ignored. We 
            //    wouldn't want that to be the default, so would need someway for the user to opt in. If you want an example of
            //    supporting back in your app speak to Charles (@ctpeepee).
            //
            // *  For the back button there is additional #Android nonsense... They are deprecating the simple "return true here to
            //    surpress default system behaviour" and replacing it with you needing to define a subclass, which we won't be able
            //    to do in native code. For now it works though... For more - https://developer.android.com/reference/android/app/Activity#onBackPressed()
        }

        // NOTE(Charles): With a software keyboard the DOWN and UP action occur on the same frame as
        // you release. I didn't realise till I tested here, but this is how all android apps with 
        // software keyboards behave. I guess it's to allow you to press and hold to do things.

        // Text input event

        // For down actions we also want to trigger TEXT_INPUT
        if key_event.action == .DOWN {
            unicode := to_unicode_character(key_event.key_code, key_event.meta_state);

            // Ignore the control characters we obviously don't care about for text input. There are maybe other ones
            // we should be ignoring?
            if unicode > 31 {
                event: Event;
                event.type = .TEXT_INPUT;
                event.utf32 = unicode;
                array_add(*events_this_frame, event);
                handled = true;
            }
        }

      case .MOTION;
        action, pointer_index := motion_event_get_action_and_pointer_index(event);
        tool_type := AMotionEvent_getToolType(event, pointer_index); // @Incomplete: Handle tool type, eg MOUSE.

        pointer_id    := AMotionEvent_getPointerId(event, pointer_index);
        num_pointers  := AMotionEvent_getPointerCount(event);
        touch_pointers_active = xx num_pointers; // This is being set, but is it correct/useful?

        primary_x := AMotionEvent_getX(event, pointer_index);
        primary_y := AMotionEvent_getY(event, pointer_index);

        window_height := ANativeWindow_getHeight(android_app.window);
        mouse_event_y := window_height - AMotionEvent_getY(event, 0);

        do_mouse := android_generate_mouse_clicks_for_touch_events;
        if do_mouse {
            // If less than zero we weren't touching last frame => delta is zero.
            // Negating y because right now mouse coordinates are right-handed,
            // though I thought we let people adjust that now?
            if android_last_touch_x >= 0 {
                mouse_delta_x = xx  (primary_x - android_last_touch_x);
                mouse_delta_y = xx -(primary_y - android_last_touch_y);
            }

            android_last_touch_x = primary_x;
            android_last_touch_y = primary_y;
        }

        // The first touch is a down/up. Subsequent touches (while still holding first) will be pointer_up/down
        if action == {
          case .DOWN; #through;
          case .POINTER_DOWN;
            // log_error("Touched by id % at (%, %)", pointer_id, primary_x, primary_y);
            touch_pointers[pointer_id].state = .DOWN | .START;
            touch_pointers[pointer_id].window_position_x = primary_x;
            touch_pointers[pointer_id].window_position_y = primary_y;

            handled = true;

            // Maybe we should only do_mouse for the first pointer?
            if do_mouse {
                e := array_add(*events_this_frame);
                e.type = .KEYBOARD;
                e.key_pressed = 1;
                e.key_code = .MOUSE_BUTTON_LEFT;

                input_button_states[Key_Code.MOUSE_BUTTON_LEFT] = .DOWN | .START;
            }

            e := array_add(*events_this_frame);
            e.type        = .TOUCH;
            e.touch_type  = .PRESSED;
            e.touch_index = pointer_id;
            e.touch_x = primary_x;
            e.touch_y = primary_y;

            input_button_states[Key_Code.TOUCH] = .DOWN | .START;
            
          case .CANCEL;
            // @Incomplete: Cancel happens if you have started touching then, eg, the system detects you are doing a system level
            // gesture back. The docs suggest to treat this like an up event but not to do normal release handling. For now it
            // is just treated exactly like an UP as it's not obvious how to correctly communicate to apps "your previous press
            // should actually be ignored bro"...
            log("MOTION event action CANCEL", flags = .VERY_VERBOSE_ONLY); // @Temp

            #through;

          case .UP;     #through;
          case .POINTER_UP;
            // log_error("Released by id % at (%, %)", pointer_id, primary_x, primary_y);
            touch_pointers[pointer_id].state = .END;
            handled = true;

            if do_mouse {
                e := array_add(*events_this_frame);
                e.type = .KEYBOARD;
                e.key_pressed = 0;
                e.key_code = .MOUSE_BUTTON_LEFT;

                input_button_states[Key_Code.MOUSE_BUTTON_LEFT] = .END;

                // Delay clearing touch_x/y till the next frame so programs that use mouse released events will find the released
                // touch position.
                pointer_as_mouse_releasd_last_frame = true;
                // android_last_touch_x, android_last_touch_y = -1.0;
            }
            
            e := array_add(*events_this_frame);
            e.type        = .TOUCH;
            e.touch_type  = .RELEASED;
            e.touch_index = pointer_id;
            e.touch_x = primary_x;
            e.touch_y = primary_y;
            
            input_button_states[Key_Code.TOUCH] = .END;
            
          case .MOVE;
            // Move gives us the position of every touching pointer so we have to loop and look at them.
            for 0..num_pointers-1 {
                pointer_id = AMotionEvent_getPointerId(event, it);

                pointer := *touch_pointers[pointer_id];
                assert((pointer.state & .DOWN) != 0, "Pointer with id % is received a move event in an unexpected state - %", pointer_id, pointer.state);

                // Android also gives you a history of positions inbetween motion events if you want, I am
                // just using current position.
                // history_size := AMotionEvent_getHistorySize(event);

                pointer.window_position_x = AMotionEvent_getX(event, it);
                pointer.window_position_y = AMotionEvent_getY(event, it);

                e := array_add(*events_this_frame);
                e.type        = .TOUCH;
                e.touch_type  = .MOVED;
                e.touch_index = pointer_id;
                e.touch_x = pointer.window_position_x;
                e.touch_y = pointer.window_position_y;
            }
            
            handled = true;

          case .HOVER_ENTER; #through;
          case .HOVER_MOVE;  #through;
          case .HOVER_EXIT;
            // @Incomplete: Running 2d apps on quest we get HOVER_ENTER/MOVE/EXIT. I guess you'd also get these on any other multi window android device.
            if !warned_about_hover_motion_events {
                log("HOVER_* motion events are currently not handled. Just warning once and then being quiet.", flags = .WARNING);
                warned_about_hover_motion_events = true;
            }

          case;
            log("Unhandled motion event of type %", action, flags = .WARNING);
        }

      // Currently unhandled, it's not really clear what they are for.
      case .FOCUS;    #through;
      case .CAPTURE;  #through;
      case .DRAG;     #through;
      case .TOUCH_MODE;
        log("Unhandled key event of type %", event_type, flags = .VERY_VERBOSE_ONLY); // @Temp
    }

    return handled;
}

Android_KeyEvent :: struct {
    action:       AKEY_EVENT_ACTION;
    key_code:     AKEYCODE;
    scan_code:    s32;
    meta_state:   AMETA;
    flags:        AKEY_EVENT_FLAG;
    repeat_count: s32;
    down_time:    s64; // Same as event_time for .DOWN events
    event_time:   s64;
}

// For KEY AInputEvents extract the relevant fields. In Java AKeyEvent is a child of AInputEvent, here we define Android_KeyEvent.
android_get_key_event :: (event: *AInputEvent) -> Android_KeyEvent {
    using key_event: Android_KeyEvent;
    action       = AKeyEvent_getAction(event);
    key_code     = AKeyEvent_getKeyCode(event);
    scan_code    = AKeyEvent_getScanCode(event); // Not currently used
    meta_state   = AKeyEvent_getMetaState(event);
    flags        = AKeyEvent_getFlags(event);
    repeat_count = AKeyEvent_getRepeatCount(event);
    down_time    = AKeyEvent_getDownTime(event);  // Not currently used 
    event_time   = AKeyEvent_getEventTime(event); // Not currently used
    return key_event;
}

// :AndroidSpecific calls to show/hide the onscreen keyboard. When we have other OS's that have similar, would be made generic.
android_show_software_keyboard :: #bake_arguments android_show_or_hide_software_keyboard(show_keyboard = true);
android_hide_software_keyboard :: #bake_arguments android_show_or_hide_software_keyboard(show_keyboard = false);

// @Broken!
//
// Sometimes when we call show/hide (maybe only with hide?) we can trigger an exception: "Only the original thread that created
// a view hierarchy can touch its views". The keyboard is hidden/shown fine so for a while we just made sure to clear the exception
// and all was well. However when this happens the CONTENT_RECT_CHANGED command doesn't happen so apps can break.
// The fix is for us to call this stuff on the main thread. In java you just do the Runnable thing, how can I solve this without
// requiring java code..? :AndroidWindowInsetsIssues :AndroidMaybeWeHaveToUseJavaAfterallSadge
android_show_or_hide_software_keyboard :: (show_keyboard: bool) {
    // NOTE(Charles): The ndk has ANativeActivity_[show/hide]SoftInput procedures, but I haven't been able to get them to
    // work. If anyone knows what we need to do to be able to use that api (without needing to override NativeActivity)
    // please let me know as it would be much simpler than the JNI stuff we do here instead!

    // The java calls we want to make:
    //   Window window = activity.getWindow();
    //   WindowInsetsController insetsController = window.getInsetsController();
    //   windowInsetsController.show(WindowInsets.Type.ime());

    // To have a "toggle" instead of "show_or_hide". We would also need to do:
    //   window.getDecorView().getRootWindowInsets().isVisible(...)

    assert(android_app != null && android_app.activity != null);
    app := android_app;

    //
    // Look up Classes, Methods, etc used
    //
    // @Incomplete: These references don't need to be looked up everytime.

    // From WindowInsets.java
    WindowInsets_Type :: enum_flags {
        FIRST :: 1 << 0;

        STATUS_BARS     :: FIRST;
        NAVIGATION_BARS :: 1 << 1;
        CAPTION_BAR     :: 1 << 2;

        IME :: 1 << 3;

        SYSTEM_GESTURES           :: 1 << 4;
        MANDATORY_SYSTEM_GESTURES :: 1 << 5;
        TAPPABLE_ELEMENT          :: 1 << 6;

        DISPLAY_CUTOUT :: 1 << 7;

        LAST :: 1 << 8;
        SIZE :: 9;
        WINDOW_DECOR :: LAST;
    }

    Activity  := FindClass("android/app/Activity");
    getWindow := GetMethodID(Activity, "getWindow", "()Landroid/view/Window;");

    Window              := FindClass("android/view/Window");
    getInsetsController := GetMethodID(Window, "getInsetsController", "()Landroid/view/WindowInsetsController;");

    WindowInsetsController := FindClass("android/view/WindowInsetsController");
    show := env.*.GetMethodID(env, WindowInsetsController, "show", "(I)V");
    hide := env.*.GetMethodID(env, WindowInsetsController, "hide", "(I)V");


    //
    // The actual calls that do the thing
    //

    activity := app.activity.clazz;

    window := CallObjectMethod(activity, getWindow);
    windowInsetsController := CallObjectMethod(window, getInsetsController);

    if show_keyboard {
        CallVoidMethod(windowInsetsController, show, cast(s32) WindowInsets_Type.IME); 
    } else {
        CallVoidMethod(windowInsetsController, hide, cast(s32) WindowInsets_Type.IME); 
    }

    log_exception(env);
}


#scope_file

#import "Android";
#import "Android/Jni";

warned_about_hover_motion_events := false;

pointer_as_mouse_releasd_last_frame := false;

reference_config: *AConfiguration;

// @CopyPasta from Input/windows.jai
add_resize_record :: (window: *ANativeWindow) {
    record: *Window_Resize_Record;
    for * pending_resizes {
        if it.window == window {
            record = it;
            break;
        }
    }

    if !record {
        record = array_add(*pending_resizes);
        this_allocation_is_not_a_leak(pending_resizes.data); // :ScanGlobalData
    }

    width  := ANativeWindow_getWidth(window);
    height := ANativeWindow_getHeight(window);

    record.window = window;
    record.width  = width;
    record.height = height;
}

// For TEXT_INPUT events we want the unicode code point, but the standard way to do this is using a java only api.
// So, we call that api via Jni.
to_unicode_character :: (key_code: AKEYCODE, meta_state: AMETA) -> u32 {
    assert(android_app != null && android_app.activity != null);
    app := android_app;

    // @Cleanup: We probably don't need to FindClass, GetMethodID etc everytime we call this.
    KeyEvent             := FindClass("android/view/KeyEvent");
    KeyEvent_Constructor := GetMethodID(KeyEvent, "<init>", "(II)V");
    getUnicodeChar       := GetMethodID(KeyEvent, "getUnicodeChar", "(I)I");

    dummy_key_event := NewObject(KeyEvent, KeyEvent_Constructor, cast(s32) AKEY_EVENT_ACTION.DOWN, key_code);
    unicode_char    := CallIntMethod(dummy_key_event, getUnicodeChar, meta_state);
    return cast(u32) unicode_char;
}

send_window_event :: (type: Window_Event_Type) {
    event: Event;
    event.type = .WINDOW;
    event.window_event_type = type;
    event.window = android_app.window;
    array_add(*events_this_frame, event);    
}

motion_event_get_action_and_pointer_index :: (event: *AInputEvent) -> AMOTION_EVENT_ACTION, u64 {
    combined      := AMotionEvent_getAction(event);
    action        := combined & .MASK;
    pointer_index := cast(u64, combined) >> AMOTION_EVENT_ACTION_POINTER_INDEX_SHIFT;
    return action, pointer_index;
}

// NOTE(Charles): I am currently a bit confused by the source/source class stuff. For now I am using these
// manual bindings instead of the generated ones. Maybe if I can resolve my confusion this stuff can be
// make it's way into generated stuff. The ndk "docs" say to refer to android.InputDevice java stuff for
// more... :AndroidInputSourceBindings 
//
// There's some weird crap going on here. If I type on keyboard I get 0x301 from getSource. Ie the class is BUTTON
// and if we ignore the SOURCE_CLASS values that are pre baked into the AINPUT_SOURCE values we are 
// .KEYBOARD | .DPAD. 1) I don't know why a keyboard is being reported as DPAD, and 2) I don't know why the ndk
// definition has the source class as part of the source value, but the source values are clearly flags?!
//
// Similarly, button presses on a gamepad are .GAMEPAD | .KEYBOARD, sigh. I guess the idea is that gamepad button
// presses go through the same path as keyboard key events, but it makes it very tricky to be sure I am handling
// things correctly... Also, triggers on xbox controller are .JOYSTICK...

// See InputDevice.java for longer comments.
AInput_Source_Class :: enum_flags u32 {
    NONE       :: 0x00; 

    BUTTON     :: 0x01; 
    POINTER    :: 0x02; 
    NAVIGATION :: 0x04; // In InputDevice.java this is TRACKBALL, NAVIGATION is not a source class at all?!
    POSITION   :: 0x08;
    JOYSTICK   :: 0x10;

    MASK       :: 0xFF;
}

AInput_Source :: enum_flags u32 {
    UNKNOWN          :: 0x00000000;
    
    KEYBOARD         :: 0x00000100 /* | AINPUT_SOURCE_CLASS_BUTTON*/ ;
    DPAD             :: 0x00000200 /* | AINPUT_SOURCE_CLASS_BUTTON*/ ;
    GAMEPAD          :: 0x00000400 /* | AINPUT_SOURCE_CLASS_BUTTON*/ ;
    TOUCHSCREEN      :: 0x00001000 /* | AINPUT_SOURCE_CLASS_POINTER*/ ;
    MOUSE            :: 0x00002000 /* | AINPUT_SOURCE_CLASS_POINTER*/ ;
    STYLUS           :: 0x00004000 /* | AINPUT_SOURCE_CLASS_POINTER*/ ;
    BLUETOOTH_STYLUS :: 0x00008000 /* | AINPUT_SOURCE_STYLUS*/ ;
    TRACKBALL        :: 0x00010000 /* | AINPUT_SOURCE_CLASS_NAVIGATION*/ ;
    MOUSE_RELATIVE   :: 0x00020000 /* | AINPUT_SOURCE_CLASS_NAVIGATION*/ ;
    TOUCHPAD         :: 0x00100000 /* | AINPUT_SOURCE_CLASS_POSITION*/ ;
    TOUCH_NAVIGATION :: 0x00200000 /* | AINPUT_SOURCE_CLASS_NONE*/ ;
    JOYSTICK         :: 0x01000000 /* | AINPUT_SOURCE_CLASS_JOYSTICK*/ ;
    HDMI             :: 0x02000000 /* | AINPUT_SOURCE_CLASS_BUTTON*/ ;
    SENSOR           :: 0x04000000 /* | AINPUT_SOURCE_CLASS_NONE*/ ;
    ROTARY_ENCODER   :: 0x00400000 /* | AINPUT_SOURCE_CLASS_NONE*/ ;

    ANY              :: 0xffffff00;
}

get_source_and_class :: (event: *AInputEvent) -> AInput_Source, AInput_Source_Class {
    source_mask := cast(u32, AInput_Source.ANY);
    class_mask  := cast(u32, AInput_Source_Class.MASK);

    source_ := AInputEvent_getSource(event);
    source  := cast(AInput_Source,       cast(u32, source_) & source_mask);
    class   := cast(AInput_Source_Class, cast(u32, source_) & class_mask);
    return source, class;
}

// AMOTION_EVENT_FLAG_WINDOW_IS_OBSCURED gets generated as anon_enum_1 for some reason atm.
// It also appears that not all the possible flags are defined in ndk headers for some reason...
AMotion_Event_Flag :: enum_flags u32 {
    IS_OBSCURED :: 0x01;
}


//
// Gamepad stuff.
//
// @Incomplete: Atm this doesn't do provide any events. I was originally planning on integrating with
// modules/Gamepad in someway. But I think Gamepad might get merged into Input anyway, so I am waiting
// to see what shakes out there to save wasted effort.
// Gamepad is a very niche use case on android!
//

android_handle_gamepad_input_event :: (event: *AInputEvent) -> bool {
    // device_id := AInputEvent_getDeviceId(event);  // @Incomplete: Multiple gamepads. Supporting this would be getting _really_ niche...

    source, source_class := get_source_and_class(event);
    event_type := AInputEvent_getType(event);

    // Being super explict for now because this all seems crazy...
    // is_from_gamepad := (source & (.GAMEPAD | .JOYSTICK)) > 0;
    is_from_gamepad := false;
    if source & .GAMEPAD {
        assert(source_class == .BUTTON, "Unexpected source class % for GAMEPAD source. The full source was %", source_class, source);
        // assert((source & .KEYBOARD) > 0); // For some reason the KEYBOARD bit is set on source for my gamepad. I don't actually want to assert this, maybe it's not always true.
        assert(event_type == .KEY, "Unexpected event type % for GAMEPAD source", event_type);

        is_from_gamepad = true;
    } else if source & .JOYSTICK {
        assert(source_class == .JOYSTICK, "Unexpected source class % for JOYSTICK source. The full source was %", source_class, source);
        assert(event_type == .MOTION, "Unexpected event type % for JOYSTICK source", event_type);

        is_from_gamepad = true;
    }

    if !is_from_gamepad  return false;

    if event_type == {
        case .KEY;
        key_event := android_get_key_event(event);

        if key_event.key_code == {
            case .BUTTON_A; #through;
            case .BUTTON_B; #through;
            // case .BUTTON_C; #through;
            case .BUTTON_X; #through;
            case .BUTTON_Y; #through;
            // case .BUTTON_Z; #through;
            case .BUTTON_L1; #through;
            case .BUTTON_R1; #through;
            case .BUTTON_L2; #through;
            case .BUTTON_R2; #through;
            case .BUTTON_THUMBL; #through;
            case .BUTTON_THUMBR; #through;
            case .BUTTON_START; #through;
            case .BUTTON_SELECT; #through;
            case .BUTTON_MODE; #through; // On xbox controler: The "xbox" button
            case .DPAD_UP; #through;
            case .DPAD_DOWN; #through;
            case .DPAD_LEFT; #through;
            case .MEDIA_RECORD; #through; // On xbox controler: The "share" button
            case .DPAD_RIGHT;
                log("% %", key_event.key_code, key_event.action);

            case; log_error("Unrecognized key % for gamepad", key_event.key_code);
        }

        case .MOTION;
        action, pointer_index := motion_event_get_action_and_pointer_index(event);

        flags := AMotionEvent_getFlags(event);

        button_state := AMotionEvent_getButtonState(event);
        action_button := AMotionEvent_getActionButton(event);

        // There is also AMotionEvent_getHistoricalAxisValue.

        pointer: s32; // Apparenlty gamepads always have a single pointer. @TODO: Confirm this?

        // Seemingly there is no way to tell what this motion event is about. If you get a motion event you just have to look at all 
        // the "axes" you care about...
        // The axes uses are also super weird, this works for my xbox controller, but other controllers who knows

        trigger_l := AMotionEvent_getAxisValue(event, .BRAKE, pointer_index);
        trigger_r := AMotionEvent_getAxisValue(event, .GAS, pointer_index);

        // Left joystick uses .X/.Y, right uses .Z/.RZ for for X/Y values. Y is left handed, ie down on the joystick is +Y.
        joystick_l_x := AMotionEvent_getAxisValue(event, .X,  pointer_index);
        joystick_l_y := AMotionEvent_getAxisValue(event, .Y,  pointer_index);
        joystick_r_x := AMotionEvent_getAxisValue(event, .Z,  pointer_index);
        joystick_r_y := AMotionEvent_getAxisValue(event, .RZ, pointer_index);
        
        // Dpad uses .HAT_X/.HAT_Y
        dpad_x := AMotionEvent_getAxisValue(event, .HAT_X, pointer_index);
        dpad_y := AMotionEvent_getAxisValue(event, .HAT_Y, pointer_index);

        // Dump all values.
        /*
        ti := type_info(AMOTION_EVENT_AXIS);
        for ti.values {
            axis_value := AMotionEvent_getAxisValue(event, xx it, pointer_index);
            if axis_value  print("%: %\n", ti.names[it_index], axis_value);
        }
        */

        case;
        log_error("Unexpected event type for gamepad %.", event_type);
    }

    return true;
}