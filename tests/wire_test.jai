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
