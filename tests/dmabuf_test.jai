// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jim Powers

#import "Basic";
#import "POSIX";
Wayland :: #import,dir "../modules/wayland";
Socket  :: #import "Socket";

main :: () {
    print("=== Dmabuf Tests ===\n\n");

    test_make_drm_modifier_keeps_high_word();
    test_format_table_parse_keeps_high_word();
    test_feedback_collector_routes_foreign_fd_message();

    print("\n=== All dmabuf tests passed ===\n");
}

test_make_drm_modifier_keeps_high_word :: () {
    nvidia := Wayland.make_drm_modifier(0x03000000, 0x00e08014);
    assert(nvidia == 0x0300000000e08014, "make_drm_modifier(0x03000000, 0x00e08014) = 0x%", formatInt(nvidia, base = 16));

    invalid := Wayland.make_drm_modifier(0x00ffffff, 0xffffffff);
    assert(invalid == Wayland.DRM_FORMAT_MOD_INVALID, "make_drm_modifier(0x00ffffff, 0xffffffff) = 0x%", formatInt(invalid, base = 16));

    print("  PASS: make_drm_modifier_keeps_high_word\n");
}

// One 16-byte zwp_linux_dmabuf_feedback_v1 format-table entry:
// format u32 at 0, padding at 4, modifier_lo u32 at 8, modifier_hi u32 at 12.
test_format_table_parse_keeps_high_word :: () {
    entry: [16] u8;
    Wayland.write_u32(entry.data,      0xAABBCCDD);
    Wayland.write_u32(entry.data + 8,  0x55667788);
    Wayland.write_u32(entry.data + 12, 0x11223344);

    fd := Wayland.memfd_create("dmabuf_test".data, 0);
    assert(fd >= 0, "memfd_create failed");
    written := write(fd, entry.data, cast(u64) entry.count);
    assert(written == entry.count, "write to memfd returned %", written);

    // append_feedback_format_table takes ownership of the fd and closes it.
    out: [..] Wayland.Format_Modifier;
    Wayland.append_feedback_format_table(*out, cast(Wayland.Fd) fd, 16);

    assert(out.count == 1, "expected 1 format-table entry, got %", out.count);
    assert(out[0].format == 0xAABBCCDD, "format = 0x%", formatInt(out[0].format, base = 16));
    assert(out[0].modifier == 0x1122334455667788, "modifier = 0x%", formatInt(out[0].modifier, base = 16));

    print("  PASS: format_table_parse_keeps_high_word\n");
}

// A roundtrip drain must hand a message it does not own to the session's
// foreign_handler BEFORE consuming it, so the handler can pop that message's fds.
// Incoming fds ride a separate FIFO (ReceiveBuffer.in_fds) that only unmarshal
// pops. A foreign fd-bearing message the drain merely skipped (wl_keyboard.keymap
// on a layout switch, say) would leave its fd at the head of the FIFO, and the
// feedback's FORMAT_TABLE would then pop and mmap the wrong file.
//
// The server end of a socketpair sends, in order: a foreign message on object 99
// carrying fd A, FORMAT_TABLE on the feedback object 50 carrying fd B, the
// feedback's DONE, and wl_callback.done on the sync object 51. So in_fds = [A, B].
// The mock handler pops one fd, as the keyboard handler would pop the keymap fd.
// With routing, FORMAT_TABLE pops B; without it, FORMAT_TABLE pops A and reads
// 0xDEADBEEF as the format. The mock also checks that it sees the message before
// the drain consumes it: still the unread head of the receive buffer, with its
// payload (FOREIGN_PAYLOAD) readable.

FOREIGN_PAYLOAD : u32 : 0xF00DCAFE;

foreign_mock_pops:           int;
foreign_mock_last_object_id: u32;

foreign_mock_handler :: (header: *Wayland.WaylandMessageHeader) {
    recv := *context.wayland_session.recv;
    head := recv.in_buf.data + recv.in_read;
    assert(header.payload == head + Wayland.HEADER_SIZE,
           "the foreign handler ran after the drain consumed its message");
    value := Wayland.read_u32(header.payload);
    assert(value == FOREIGN_PAYLOAD, "foreign payload = 0x%", formatInt(value, base = 16));

    fd := Wayland.receive_pop_fd(recv);
    if fd >= 0  close(fd);
    foreign_mock_pops += 1;
    foreign_mock_last_object_id = header.object_id;
}

Foreign_Args       :: struct { fd: Wayland.Fd; value: u32; }
Format_Table_Args  :: struct { fd: Wayland.Fd; size: u32; }
Feedback_Done_Args :: struct {}
Sync_Done_Args     :: struct { callback_data: u32; }

make_memfd_with :: (bytes: [] u8) -> s32 {
    fd := Wayland.memfd_create("dmabuf_test".data, 0);
    assert(fd >= 0, "memfd_create failed, errno=%", errno());
    written := write(fd, bytes.data, cast(u64) bytes.count);
    assert(written == bytes.count, "write to memfd returned %", written);
    return fd;
}

test_feedback_collector_routes_foreign_fd_message :: () {
    FEEDBACK_ID : u32 : 50;
    SYNC_ID     : u32 : 51;
    FOREIGN_ID  : u32 : 99;

    // fd A: what the foreign message carries. Read as a format table, its first
    // entry's format is 0xDEADBEEF.
    junk: [16] u8;
    Wayland.write_u32(junk.data, 0xDEADBEEF);
    fd_a := make_memfd_with(junk);

    // fd B: a real one-entry format table.
    table: [16] u8;
    Wayland.write_u32(table.data,      0xAABBCCDD);
    Wayland.write_u32(table.data + 8,  0x55667788);
    Wayland.write_u32(table.data + 12, 0x11223344);
    fd_b := make_memfd_with(table);

    sv: [2] s32;
    rc := Socket.socketpair(Socket.AF_LOCAL, .STREAM, cast(Socket.IPPROTO) 0, *sv);
    assert(rc == 0, "socketpair failed, errno=%", errno());
    defer { close(sv[0]); close(sv[1]); }

    // marshal queues Fd fields into out_fds in call order, so out_fds = [A, B].
    server := Wayland.Connection.{ socket_fd = sv[0], next_id = 2 };
    batch: Wayland.MessageBuilder;
    foreign := Foreign_Args.{ fd = cast(Wayland.Fd) fd_a, value = FOREIGN_PAYLOAD };
    Wayland.marshal(*batch, FOREIGN_ID, 0, *foreign);
    format_table := Format_Table_Args.{ fd = cast(Wayland.Fd) fd_b, size = 16 };
    Wayland.marshal(*batch, FEEDBACK_ID, Wayland.ZWP_LINUX_DMABUF_FEEDBACK_V1_FORMAT_TABLE, *format_table);
    feedback_done := Feedback_Done_Args.{};
    Wayland.marshal(*batch, FEEDBACK_ID, Wayland.ZWP_LINUX_DMABUF_FEEDBACK_V1_DONE, *feedback_done);
    sync_done := Sync_Done_Args.{ callback_data = 0 };
    Wayland.marshal(*batch, SYNC_ID, Wayland.WL_CALLBACK_DONE, *sync_done);

    sent := Wayland.wayland_send(*server, *batch);
    assert(sent, "wayland_send failed");
    close(fd_a);  // the kernel duplicated both into the stream
    close(fd_b);

    sess: Wayland.WaylandSession;
    sess.conn.socket_fd = sv[1];
    sess.foreign_handler = foreign_mock_handler;

    info: Wayland.Dmabuf_Feedback_Info;
    ok: bool;
    ctx := context;
    ctx.wayland_session = *sess;
    push_context ctx {
        info, ok = Wayland.collect_dmabuf_feedback(.{ id = FEEDBACK_ID }, SYNC_ID);
    }

    assert(ok && info.complete, "feedback collection should complete (ok=%, complete=%)", ok, info.complete);
    assert(info.format_table.count == 1, "expected 1 format-table entry, got %", info.format_table.count);
    assert(info.format_table[0].format == 0xAABBCCDD,
           "FORMAT_TABLE read the wrong fd: format = 0x%", formatInt(info.format_table[0].format, base = 16));
    assert(info.format_table[0].modifier == 0x1122334455667788,
           "FORMAT_TABLE read the wrong fd: modifier = 0x%", formatInt(info.format_table[0].modifier, base = 16));
    assert(foreign_mock_pops == 1, "the foreign handler should run exactly once, ran % times", foreign_mock_pops);
    assert(foreign_mock_last_object_id == FOREIGN_ID, "the foreign handler saw object %", foreign_mock_last_object_id);
    assert(sess.recv.in_fds_read == sess.recv.in_fds_count,
           "fd FIFO not drained: read % of %", sess.recv.in_fds_read, sess.recv.in_fds_count);

    print("  PASS: feedback_collector_routes_foreign_fd_message\n");
}
