// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jim Powers

// Input acquisition and per-frame key state. No compositor: the keymap test
// plays the compositor on the far end of a socketpair.

#import "Basic";
#import "POSIX";
Input   :: #import "Input";
// By NAME, not #import,dir: Input reaches wayland by name through
// Wayland_Support, and a second, directory-imported instance would declare the
// #add_context wayland_session member twice.
Wayland :: #import "wayland";
Socket  :: #import "Socket";

#load "fixtures/xkb_sample_keymap.jai";

main :: () {
    print("=== Input Tests ===\n\n");

    test_release_preserves_start_bit();
    test_keyboards_info_parses_keymap_on_arrival();

    print("\n=== All input tests passed ===\n");
}

// A press and release inside one frame must still read as pressed this frame:
// the release keeps START and swaps DOWN for END. A release with no press this
// frame is a plain END.
test_release_preserves_start_bit :: () {
    State :: Input.Key_Current_State;

    tap := Input.button_state_after_release(State.START | .DOWN);
    assert(tap == State.START | .END, "release after a same-frame press = %", tap);

    held := Input.button_state_after_release(State.DOWN);
    assert(held == State.END, "release of a key held from an earlier frame = %", held);

    none := Input.button_state_after_release(State.NONE);
    assert(none == State.END, "release of a key not known to be down = %", none);

    print("  PASS: release_preserves_start_bit\n");
}

// get_keyboards_info must parse the keymap while the KEYMAP event's fd is live,
// close that fd itself, and keep the REPEAT_INFO the compositor sends right
// after it in the same burst.
//
// The server end of a socketpair sends, in order: wl_keyboard.keymap on the
// keyboard (id 7) carrying a memfd that holds SAMPLE_KEYMAP,
// wl_keyboard.repeat_info on the keyboard (rate 30, delay 400), and
// wl_callback.done on the sync (id 8). get_keyboards_info allocates one keyboard
// id per capable seat and then the sync id, so next_id = 7 with one seat gives
// exactly those two ids.
test_keyboards_info_parses_keymap_on_arrival :: () {
    KEYBOARD_ID : u32 : 7;
    SYNC_ID     : u32 : 8;

    keymap_fd := Wayland.memfd_create("input_test".data, 0);
    assert(keymap_fd >= 0, "memfd_create failed, errno=%", errno());
    written := write(keymap_fd, SAMPLE_KEYMAP.data, cast(u64) SAMPLE_KEYMAP.count);
    assert(written == SAMPLE_KEYMAP.count, "write to memfd returned %", written);

    sv: [2] s32;
    rc := Socket.socketpair(Socket.AF_LOCAL, .STREAM, cast(Socket.IPPROTO) 0, *sv);
    assert(rc == 0, "socketpair failed, errno=%", errno());
    defer { close(sv[0]); close(sv[1]); }

    server := Wayland.Connection.{ socket_fd = sv[0], next_id = 2 };
    batch: Wayland.MessageBuilder;
    keymap := Wayland.Wl_Keyboard_Keymap_Args.{
        format = cast(u32) Wayland.Wl_Keyboard_Keymap_Format.XKB_V1,
        fd     = cast(Wayland.Fd) keymap_fd,
        size   = cast(u32) SAMPLE_KEYMAP.count,
    };
    Wayland.marshal(*batch, KEYBOARD_ID, Wayland.WL_KEYBOARD_KEYMAP, *keymap);
    repeat_info := Wayland.Wl_Keyboard_Repeat_Info_Args.{ rate = 30, delay = 400 };
    Wayland.marshal(*batch, KEYBOARD_ID, Wayland.WL_KEYBOARD_REPEAT_INFO, *repeat_info);
    sync_done := Wayland.Wl_Callback_Done_Args.{ callback_data = 0 };
    Wayland.marshal(*batch, SYNC_ID, Wayland.WL_CALLBACK_DONE, *sync_done);

    sent := Wayland.wayland_send(*server, *batch);
    assert(sent, "wayland_send failed");
    close(keymap_fd);  // the kernel duplicated it into the stream

    // The keymap fd is received onto the lowest free descriptor. Find that number
    // now so we can check afterwards that get_keyboards_info closed it.
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

    assert(kbs.count == 1, "expected 1 keyboard, got %", kbs.count);
    assert(kbs[0].keyboard.id == KEYBOARD_ID, "keyboard bound as id %", kbs[0].keyboard.id);
    assert(kbs[0].keymap_valid, "the keymap was not parsed on arrival");
    q := Wayland.keymap_get_keysym(*kbs[0].keymap, 16, 0);
    assert(q == #char "q", "AD01 level 0 should decode to q, got 0x%", formatInt(q, base = 16));
    assert(fcntl(received_fd, F_GETFD) == -1, "the keymap fd (%) is still open after get_keyboards_info", received_fd);

    assert(kbs[0].have_repeat_info, "the REPEAT_INFO after KEYMAP was dropped");
    assert(kbs[0].repeat_rate == 30, "repeat_rate = %", kbs[0].repeat_rate);
    assert(kbs[0].repeat_delay == 400, "repeat_delay = %", kbs[0].repeat_delay);

    assert(sess.recv.in_fds_read == sess.recv.in_fds_count,
           "fd FIFO not drained: read % of %", sess.recv.in_fds_read, sess.recv.in_fds_count);

    print("  PASS: keyboards_info_parses_keymap_on_arrival\n");
}
