// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jim Powers

// Input acquisition and per-frame key state. No compositor: the keymap tests
// play the compositor on the far end of a socketpair.

#import "Basic";
#import "POSIX";
Input   :: #import "Input";
// By NAME, not #import,dir: Input reaches wayland by name through
// Wayland_Support, and a second, directory-imported instance would declare the
// #add_context wayland_session member twice.
Wayland :: #import "wayland";
// By NAME too: the instance Input imports, so its keymap globals are the ones
// the pump handler writes.
WS      :: #import "Wayland_Support";
Socket  :: #import "Socket";

#load "fixtures/xkb_sample_keymap.jai";

main :: () {
    print("=== Input Tests ===\n\n");

    test_release_preserves_start_bit();
    test_keyboards_info_parses_keymap_on_arrival();
    test_keyboards_info_no_keymap_is_a_warning();
    test_pump_keymap_change_to_no_keymap_is_a_warning();
    test_pump_keymap_mmap_failure_is_an_error();

    print("\n=== All input tests passed ===\n");
}

// A press and release inside one frame must still read as pressed this frame:
// the release keeps START and swaps DOWN for END. A release with no press this
// frame is a plain END. The tap then clears to NONE on the next frame.
test_release_preserves_start_bit :: () {
    State :: Input.Key_Current_State;

    tap := Input.button_state_after_release(State.START | .DOWN);
    assert(tap == State.START | .END, "release after a same-frame press = %", tap);

    held := Input.button_state_after_release(State.DOWN);
    assert(held == State.END, "release of a key held from an earlier frame = %", held);

    none := Input.button_state_after_release(State.NONE);
    assert(none == State.END, "release of a key not known to be down = %", none);

    // ...and it clears the next frame: the per-frame update takes a tapped
    // key's START | END all the way to NONE, so it does not read as held.
    k := cast(int) #char "A";
    Input.input_button_states[k] = State.START | .END;
    Input.input_per_frame_event_and_flag_update();
    after := Input.input_button_states[k];
    assert(after == State.NONE, "a tapped key's state the next frame = %", after);

    print("  PASS: release_preserves_start_bit\n");
}

// get_keyboards_info must parse the keymap while the KEYMAP event's fd is live,
// close that fd itself, and keep the REPEAT_INFO the compositor sends right
// after it in the same burst.
test_keyboards_info_parses_keymap_on_arrival :: () {
    kbs, received_fd := keyboards_info_from_fake_compositor(.XKB_V1, SAMPLE_KEYMAP, send_repeat_info = true);

    assert(kbs.count == 1, "expected 1 keyboard, got %", kbs.count);
    assert(kbs[0].keyboard.id == KEYBOARD_ID, "keyboard bound as id %", kbs[0].keyboard.id);
    assert(kbs[0].keymap_valid, "the keymap was not parsed on arrival");
    q := Wayland.keymap_get_keysym(*kbs[0].keymap, 16, 0);
    assert(q == #char "q", "AD01 level 0 should decode to q, got 0x%", formatInt(q, base = 16));
    assert(fcntl(received_fd, F_GETFD) == -1, "the keymap fd (%) is still open after get_keyboards_info", received_fd);

    assert(kbs[0].have_repeat_info, "the REPEAT_INFO after KEYMAP was dropped");
    assert(kbs[0].repeat_rate == 30, "repeat_rate = %", kbs[0].repeat_rate);
    assert(kbs[0].repeat_delay == 400, "repeat_delay = %", kbs[0].repeat_delay);

    print("  PASS: keyboards_info_parses_keymap_on_arrival\n");
}

// A no_keymap keymap event (format 0, an empty fd, size 0) is legitimate: the
// compositor offers raw keycodes only. get_keyboards_info must still close the
// fd and say so with a WARNING, but must not log_error, which a release logger
// surfaces to the user as a failure.
test_keyboards_info_no_keymap_is_a_warning :: () {
    rec: Log_Recorder;
    defer free_log_recorder(*rec);

    kbs: [] Wayland.Keyboard_Info;
    received_fd: s32;
    ctx := context;
    ctx.logger      = record_log;
    ctx.logger_data = *rec;
    push_context ctx {
        kbs, received_fd = keyboards_info_from_fake_compositor(.NO_KEYMAP, "", send_repeat_info = false);
    }

    assert(kbs.count == 1, "expected 1 keyboard, got %", kbs.count);
    assert(!kbs[0].keymap_valid, "a no_keymap event produced a valid keymap");
    assert(!kbs[0].have_repeat_info, "no REPEAT_INFO was sent, yet have_repeat_info is set");
    assert(fcntl(received_fd, F_GETFD) == -1, "the keymap fd (%) is still open after get_keyboards_info", received_fd);
    assert(rec.errors.count == 0, "no_keymap logged % error(s), first: %", rec.errors.count,
           ifx rec.errors.count then rec.errors[0] else "");
    assert(rec.warnings.count == 1, "no_keymap should log exactly one warning, logged %", rec.warnings.count);

    print("  PASS: keyboards_info_no_keymap_is_a_warning\n");
}

// A mid-session wl_keyboard.keymap reaches Wayland_Support's pump handler, not
// get_keyboards_info. A switch to no_keymap (format 0, size 0) is the compositor
// offering raw keycodes only: one warning, no error, logged without
// JAI_WAYLAND_LOG_KEYS, the old keymap no longer used, the fd closed.
test_pump_keymap_change_to_no_keymap_is_a_warning :: () {
    fd := Wayland.memfd_create("input_test_pump".data, 0);
    assert(fd >= 0, "memfd_create failed, errno=%", errno());

    kev: Wayland.Wl_Keyboard_Event;
    kev.kind   = .KEYMAP;
    kev.keymap = .{ format = cast(u32) Wayland.Wl_Keyboard_Keymap_Format.NO_KEYMAP, fd = cast(Wayland.Fd) fd, size = 0 };

    WS.wl_keymap_valid = true;  // a keymap from before the switch
    rec: Log_Recorder;
    defer free_log_recorder(*rec);
    ctx := context;
    ctx.logger      = record_log;
    ctx.logger_data = *rec;
    push_context ctx {
        WS.wl_handle_keyboard_event(kev);
    }

    assert(rec.errors.count == 0, "no_keymap logged % error(s), first: %", rec.errors.count,
           ifx rec.errors.count then rec.errors[0] else "");
    assert(rec.warnings.count == 1, "no_keymap should log exactly one warning, logged %", rec.warnings.count);
    assert(!WS.wl_keymap_valid, "the pre-switch keymap is still marked valid after a switch to no_keymap");
    assert(fcntl(fd, F_GETFD) == -1, "the keymap fd (%) is still open after the pump handled it", fd);

    print("  PASS: pump_keymap_change_to_no_keymap_is_a_warning\n");
}

// An XKB_V1 keymap whose mmap fails (a pipe cannot be mapped) is an error, logged
// with errno whether or not key logging is on, and the old keymap stops being used.
test_pump_keymap_mmap_failure_is_an_error :: () {
    pipe_fds: [2] s32;
    rc := pipe(*pipe_fds);
    assert(rc == 0, "pipe failed, errno=%", errno());
    defer close(pipe_fds[1]);

    kev: Wayland.Wl_Keyboard_Event;
    kev.kind   = .KEYMAP;
    kev.keymap = .{ format = cast(u32) Wayland.Wl_Keyboard_Keymap_Format.XKB_V1, fd = cast(Wayland.Fd) pipe_fds[0], size = 4096 };

    WS.wl_keymap_valid = true;
    rec: Log_Recorder;
    defer free_log_recorder(*rec);
    ctx := context;
    ctx.logger      = record_log;
    ctx.logger_data = *rec;
    push_context ctx {
        WS.wl_handle_keyboard_event(kev);
    }

    assert(rec.errors.count == 1, "a failed keymap mmap should log exactly one error, logged %", rec.errors.count);
    assert(!WS.wl_keymap_valid, "the pre-switch keymap is still marked valid after a failed re-parse");
    assert(fcntl(pipe_fds[0], F_GETFD) == -1, "the keymap fd (%) is still open after the pump handled it", pipe_fds[0]);

    print("  PASS: pump_keymap_mmap_failure_is_an_error\n");
}

#scope_file

KEYBOARD_ID : u32 : 7;
SYNC_ID     : u32 : 8;

// Plays the compositor on the server end of a socketpair and runs
// get_keyboards_info against it, under the caller's context (so a caller's
// logger sees what it logs). The server sends, in order: wl_keyboard.keymap on
// the keyboard (id 7) with `format` and a memfd holding `keymap_text` (size = its
// byte count), wl_keyboard.repeat_info on the keyboard (rate 30, delay 400) if
// asked, and wl_callback.done on the sync (id 8). get_keyboards_info allocates
// one keyboard id per capable seat and then the sync id, so next_id = 7 with one
// seat gives exactly those two ids. Returns the keyboards and the descriptor
// number the keymap fd was received on, so the caller can check it was closed.
keyboards_info_from_fake_compositor :: (format: Wayland.Wl_Keyboard_Keymap_Format, keymap_text: string,
                                        send_repeat_info: bool) -> [] Wayland.Keyboard_Info, s32 {
    keymap_fd := Wayland.memfd_create("input_test".data, 0);
    assert(keymap_fd >= 0, "memfd_create failed, errno=%", errno());
    written := write(keymap_fd, keymap_text.data, cast(u64) keymap_text.count);
    assert(written == keymap_text.count, "write to memfd returned %", written);

    sv: [2] s32;
    rc := Socket.socketpair(Socket.AF_LOCAL, .STREAM, cast(Socket.IPPROTO) 0, *sv);
    assert(rc == 0, "socketpair failed, errno=%", errno());
    defer { close(sv[0]); close(sv[1]); }

    server := Wayland.Connection.{ socket_fd = sv[0], next_id = 2 };
    batch: Wayland.MessageBuilder;
    keymap := Wayland.Wl_Keyboard_Keymap_Args.{
        format = cast(u32) format,
        fd     = cast(Wayland.Fd) keymap_fd,
        size   = cast(u32) keymap_text.count,
    };
    Wayland.marshal(*batch, KEYBOARD_ID, Wayland.WL_KEYBOARD_KEYMAP, *keymap);
    if send_repeat_info {
        repeat_info := Wayland.Wl_Keyboard_Repeat_Info_Args.{ rate = 30, delay = 400 };
        Wayland.marshal(*batch, KEYBOARD_ID, Wayland.WL_KEYBOARD_REPEAT_INFO, *repeat_info);
    }
    sync_done := Wayland.Wl_Callback_Done_Args.{ callback_data = 0 };
    Wayland.marshal(*batch, SYNC_ID, Wayland.WL_CALLBACK_DONE, *sync_done);

    sent := Wayland.wayland_send(*server, *batch);
    assert(sent, "wayland_send failed");
    close(keymap_fd);  // the kernel duplicated it into the stream

    // The keymap fd is received onto the lowest free descriptor. Find that number
    // now so the caller can check afterwards that get_keyboards_info closed it.
    received_fd := dup(sv[0]);
    assert(received_fd >= 0, "dup failed, errno=%", errno());
    close(received_fd);

    sess: Wayland.WaylandSession;
    sess.conn.socket_fd = sv[1];
    sess.conn.next_id   = KEYBOARD_ID;

    seats := Wayland.Seat_Info.[
        .{ seat = .{ id = 5 }, capabilities = cast(u32) Wayland.Wl_Seat_Capability.KEYBOARD },
    ];

    kbs: [] Wayland.Keyboard_Info;
    ctx := context;
    ctx.wayland_session = *sess;
    push_context ctx {
        kbs = Wayland.get_keyboards_info(seats);
    }

    assert(sess.recv.in_fds_read == sess.recv.in_fds_count,
           "fd FIFO not drained: read % of %", sess.recv.in_fds_read, sess.recv.in_fds_count);
    return kbs, received_fd;
}

// Collects every .ERROR and .WARNING message logged while it is the context
// logger (the Error_Recorder pattern from wire_test, plus warnings, so a test can
// tell a degraded condition from a failure).
Log_Recorder :: struct {
    errors:   [..] string;
    warnings: [..] string;
}

record_log :: (message: string, data: *void, info: Log_Info) {
    rec := cast(*Log_Recorder) data;
    if info.common_flags & .ERROR         array_add(*rec.errors,   copy_string(message));
    else if info.common_flags & .WARNING  array_add(*rec.warnings, copy_string(message));
}

free_log_recorder :: (rec: *Log_Recorder) {
    for rec.errors    free(it);
    for rec.warnings  free(it);
    array_free(rec.errors);
    array_free(rec.warnings);
}
