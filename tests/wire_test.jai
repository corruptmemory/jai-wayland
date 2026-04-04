#import "Basic";
Wayland :: #import,dir "../modules/wayland";

main :: () {
    print("=== Wire Protocol Tests ===\n\n");

    test_write_u32();
    test_write_s32();
    test_read_u32();
    test_read_s32();
    test_pack_header();
    test_unpack_header();
    test_message_size_from_header();
    test_align4();
    test_write_string();
    test_write_string_padding();
    test_write_string_empty();
    test_write_array();
    test_write_array_padding();

    test_connection_queue_message();
    test_connection_queue_fd();
    test_connection_queue_multiple();

    print("\n=== All wire tests passed ===\n");
}

test_write_u32 :: () {
    buf: [4] u8;
    Wayland.write_u32(buf.data, 0x12345678);
    result := (cast(*u32) buf.data).*;
    assert(result == 0x12345678, "write_u32 failed");
    print("  PASS: write_u32\n");
}

test_write_s32 :: () {
    buf: [4] u8;
    Wayland.write_s32(buf.data, -42);
    result := (cast(*s32) buf.data).*;
    assert(result == -42, "write_s32 failed");
    print("  PASS: write_s32\n");
}

test_read_u32 :: () {
    buf: [4] u8;
    (cast(*u32) buf.data).* = 0xDEADBEEF;
    result := Wayland.read_u32(buf.data);
    assert(result == 0xDEADBEEF, "read_u32 failed");
    print("  PASS: read_u32\n");
}

test_read_s32 :: () {
    buf: [4] u8;
    (cast(*s32) buf.data).* = -1;
    result := Wayland.read_s32(buf.data);
    assert(result == -1, "read_s32 failed");
    print("  PASS: read_s32\n");
}

test_pack_header :: () {
    buf: [8] u8;
    Wayland.pack_header(buf.data, object_id = 5, opcode = 1, size = 20);
    obj_id := (cast(*u32) buf.data).*;
    assert(obj_id == 5, "pack_header: wrong object_id");
    word2 := (cast(*u32) (buf.data + 4)).*;
    assert(word2 == (20 << 16) | 1, "pack_header: wrong size|opcode");
    print("  PASS: pack_header\n");
}

test_unpack_header :: () {
    buf: [8] u8;
    (cast(*u32) buf.data).* = 7;
    (cast(*u32) (buf.data + 4)).* = (24 << 16) | 3;
    object_id, opcode, size := Wayland.unpack_header(buf.data);
    assert(object_id == 7, "unpack_header: wrong object_id");
    assert(opcode == 3, "unpack_header: wrong opcode");
    assert(size == 24, "unpack_header: wrong size");
    print("  PASS: unpack_header\n");
}

test_message_size_from_header :: () {
    buf: [8] u8;
    (cast(*u32) buf.data).* = 1;
    (cast(*u32) (buf.data + 4)).* = (32 << 16) | 0;
    _, _, size := Wayland.unpack_header(buf.data);
    assert(size == 32);
    print("  PASS: message_size_from_header\n");
}

test_align4 :: () {
    assert(Wayland.align4(0) == 0, "align4(0) should be 0");
    assert(Wayland.align4(1) == 4, "align4(1) should be 4");
    assert(Wayland.align4(2) == 4, "align4(2) should be 4");
    assert(Wayland.align4(3) == 4, "align4(3) should be 4");
    assert(Wayland.align4(4) == 4, "align4(4) should be 4");
    assert(Wayland.align4(5) == 8, "align4(5) should be 8");
    assert(Wayland.align4(7) == 8, "align4(7) should be 8");
    assert(Wayland.align4(8) == 8, "align4(8) should be 8");
    print("  PASS: align4\n");
}

test_write_string :: () {
    // "hello" = 5 chars + NUL = 6 bytes, padded to 8, + 4 prefix = 12 total
    buf: [16] u8;
    memset(buf.data, 0xFF, buf.count);  // fill with 0xFF to detect zeroing
    written := Wayland.write_string(buf.data, "hello");
    assert(written == 12, "write_string(\"hello\") should return 12");
    // Length prefix: 6 (includes NUL)
    length := Wayland.read_u32(buf.data);
    assert(length == 6, "write_string length should be 6");
    // Data bytes
    assert(buf[4] == #char "h", "write_string data[0]");
    assert(buf[5] == #char "e", "write_string data[1]");
    assert(buf[6] == #char "l", "write_string data[2]");
    assert(buf[7] == #char "l", "write_string data[3]");
    assert(buf[8] == #char "o", "write_string data[4]");
    // NUL terminator
    assert(buf[9] == 0, "write_string NUL terminator");
    // Padding bytes (2 bytes to reach 8-byte aligned data)
    assert(buf[10] == 0, "write_string padding[0]");
    assert(buf[11] == 0, "write_string padding[1]");
    print("  PASS: write_string\n");
}

test_write_string_padding :: () {
    // "ab" = 2 chars + NUL = 3 bytes, padded to 4, + 4 prefix = 8 total
    buf: [12] u8;
    memset(buf.data, 0xFF, buf.count);
    written := Wayland.write_string(buf.data, "ab");
    assert(written == 8, "write_string(\"ab\") should return 8");
    length := Wayland.read_u32(buf.data);
    assert(length == 3, "write_string length should be 3");
    assert(buf[4] == #char "a", "write_string data[0]");
    assert(buf[5] == #char "b", "write_string data[1]");
    assert(buf[6] == 0, "write_string NUL terminator");
    // 1 byte padding to reach 4-byte boundary
    assert(buf[7] == 0, "write_string padding[0]");
    print("  PASS: write_string_padding\n");
}

test_write_string_empty :: () {
    // Empty string: length 0, no data, 4 bytes total
    buf: [8] u8;
    memset(buf.data, 0xFF, buf.count);
    written := Wayland.write_string(buf.data, "");
    assert(written == 4, "write_string(\"\") should return 4");
    length := Wayland.read_u32(buf.data);
    assert(length == 0, "write_string empty length should be 0");
    // Byte after the length word should be untouched (still 0xFF)
    assert(buf[4] == 0xFF, "write_string empty should not write past length");
    print("  PASS: write_string_empty\n");
}

test_write_array :: () {
    // 5 bytes data, padded to 8, + 4 prefix = 12 total
    buf: [16] u8;
    memset(buf.data, 0xFF, buf.count);
    data: [5] u8 = u8.[1, 2, 3, 4, 5];
    arr: [] u8;
    arr.data = data.data;
    arr.count = data.count;
    written := Wayland.write_array(buf.data, arr);
    assert(written == 12, "write_array(5 bytes) should return 12");
    length := Wayland.read_u32(buf.data);
    assert(length == 5, "write_array length should be 5");
    assert(buf[4] == 1, "write_array data[0]");
    assert(buf[5] == 2, "write_array data[1]");
    assert(buf[6] == 3, "write_array data[2]");
    assert(buf[7] == 4, "write_array data[3]");
    assert(buf[8] == 5, "write_array data[4]");
    // 3 padding bytes
    assert(buf[9] == 0, "write_array padding[0]");
    assert(buf[10] == 0, "write_array padding[1]");
    assert(buf[11] == 0, "write_array padding[2]");
    print("  PASS: write_array\n");
}

test_connection_queue_message :: () {
    conn: Wayland.Connection;
    // Build a 20-byte message: 8-byte header + 12 bytes payload
    msg: [20] u8;
    Wayland.pack_header(msg.data, object_id = 1, opcode = 0, size = 20);
    // Fill payload with recognizable pattern
    for i: 8..19  msg[i] = cast(u8)(i - 8 + 0xA0);

    Wayland.connection_queue(*conn, msg.data, 20);
    assert(conn.out_used == 20, "out_used should be 20");
    // Verify header was copied correctly
    obj_id, opcode, size := Wayland.unpack_header(conn.out_buf.data);
    assert(obj_id == 1, "queued object_id should be 1");
    assert(opcode == 0, "queued opcode should be 0");
    assert(size == 20, "queued size should be 20");
    // Verify payload byte
    assert(conn.out_buf[8] == 0xA0, "queued payload byte");
    print("  PASS: connection_queue_message\n");
}

test_connection_queue_fd :: () {
    conn: Wayland.Connection;
    Wayland.connection_queue_fd(*conn, 42);
    assert(conn.out_fds_count == 1, "out_fds_count should be 1");
    assert(conn.out_fds[0] == 42, "queued fd should be 42");
    print("  PASS: connection_queue_fd\n");
}

test_connection_queue_multiple :: () {
    conn: Wayland.Connection;
    // Queue first message: 12 bytes
    msg1: [12] u8;
    Wayland.pack_header(msg1.data, object_id = 1, opcode = 0, size = 12);
    Wayland.write_u32(msg1.data + 8, 0xDEADBEEF);
    Wayland.connection_queue(*conn, msg1.data, 12);
    assert(conn.out_used == 12, "out_used should be 12 after first queue");

    // Queue second message: 16 bytes
    msg2: [16] u8;
    Wayland.pack_header(msg2.data, object_id = 2, opcode = 1, size = 16);
    Wayland.write_u32(msg2.data + 8, 0xCAFEBABE);
    Wayland.write_u32(msg2.data + 12, 0x12345678);
    Wayland.connection_queue(*conn, msg2.data, 16);
    assert(conn.out_used == 28, "out_used should be 28 after second queue");

    // Verify second message header at offset 12
    obj_id, opcode, size := Wayland.unpack_header(conn.out_buf.data + 12);
    assert(obj_id == 2, "second message object_id should be 2");
    assert(opcode == 1, "second message opcode should be 1");
    assert(size == 16, "second message size should be 16");

    // Queue two fds
    Wayland.connection_queue_fd(*conn, 10);
    Wayland.connection_queue_fd(*conn, 20);
    assert(conn.out_fds_count == 2, "out_fds_count should be 2");
    assert(conn.out_fds[0] == 10, "first fd should be 10");
    assert(conn.out_fds[1] == 20, "second fd should be 20");
    print("  PASS: connection_queue_multiple\n");
}

test_write_array_padding :: () {
    // 4 bytes exactly aligned, + 4 prefix = 8 total, no padding needed
    buf: [12] u8;
    memset(buf.data, 0xFF, buf.count);
    data: [4] u8 = u8.[10, 20, 30, 40];
    arr: [] u8;
    arr.data = data.data;
    arr.count = data.count;
    written := Wayland.write_array(buf.data, arr);
    assert(written == 8, "write_array(4 bytes) should return 8");
    length := Wayland.read_u32(buf.data);
    assert(length == 4, "write_array length should be 4");
    assert(buf[4] == 10, "write_array data[0]");
    assert(buf[5] == 20, "write_array data[1]");
    assert(buf[6] == 30, "write_array data[2]");
    assert(buf[7] == 40, "write_array data[3]");
    // Next byte should be untouched (still 0xFF)
    assert(buf[8] == 0xFF, "write_array should not write past data when aligned");
    print("  PASS: write_array_padding\n");
}
