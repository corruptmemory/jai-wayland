#import "Basic";
Wayland :: #import,dir "../modules/wayland";

// Test struct mimicking wl_surface.attach args (all fixed-size)
Test_Attach_Args :: struct {
    buffer_id: u32;
    x: s32;
    y: s32;
}

// Test struct with an fd (out-of-band) and a string (variable-size)
Test_Fd_Args :: struct {
    mime_type: string;
    fd: Wayland.Fd;
}

// Test struct with no args at all
Test_Empty_Args :: struct {}

// Test struct with string + u32 (variable-size path)
Test_String_Args :: struct {
    name: string;
    version: u32;
}

// Test struct with Fixed (24.8) type
Test_Fixed_Args :: struct {
    position: Wayland.Fixed;
    scale: Wayland.Fixed;
}

// Test struct with array (variable-size)
Test_Array_Args :: struct {
    data: [] u8;
}

// Test structs for marshal_constructor
Test_Constructor_Empty :: struct {}

Test_Constructor_With_Args :: struct {
    x: s32;
    y: s32;
}

main :: () {
    print("=== Marshal Macro Tests ===\n\n");
    test_marshal_fixed_args();
    test_marshal_with_fd();
    test_marshal_with_string();
    test_marshal_empty_args();
    test_marshal_with_fixed();
    test_marshal_with_array();
    test_marshal_string_empty();
    test_marshal_constructor_empty();
    test_marshal_constructor_with_args();
    print("\n=== All marshal tests passed ===\n");
}

test_marshal_fixed_args :: () {
    batch: Wayland.MessageBuilder;
    args := Test_Attach_Args.{buffer_id = 7, x = 10, y = -5};
    Wayland.marshal(*batch, object_id = 5, opcode = 1, *args);

    // Header: object_id=5, size=20, opcode=1
    assert(batch.out_used == 20);
    assert(Wayland.read_u32(batch.out_buf.data) == 5);  // object_id
    word2 := Wayland.read_u32(batch.out_buf.data + 4);
    assert(word2 == (20 << 16) | 1);  // size|opcode
    // Args
    assert(Wayland.read_u32(batch.out_buf.data + 8) == 7);   // buffer_id
    assert(Wayland.read_s32(batch.out_buf.data + 12) == 10);  // x
    assert(Wayland.read_s32(batch.out_buf.data + 16) == -5);  // y
    print("  PASS: marshal_fixed_args\n");
}

test_marshal_with_fd :: () {
    batch: Wayland.MessageBuilder;
    args := Test_Fd_Args.{mime_type = "text/plain", fd = cast(Wayland.Fd) 42};
    Wayland.marshal(*batch, object_id = 3, opcode = 0, *args);

    // Fd queued out-of-band, not in buffer
    assert(batch.out_fds_count == 1);
    assert(batch.out_fds[0] == 42);
    // "text/plain" = 10 chars + NUL = 11, padded to 12, wire = 4+12=16
    // header(8) + string(16) = 24 (fd not counted)
    assert(batch.out_used == 24);
    print("  PASS: marshal_with_fd\n");
}

test_marshal_with_string :: () {
    batch: Wayland.MessageBuilder;
    args := Test_String_Args.{name = "wl_compositor", version = 4};
    Wayland.marshal(*batch, object_id = 2, opcode = 0, *args);

    // "wl_compositor" = 13 chars + NUL = 14, padded to 16, wire = 4+16 = 20
    // header(8) + string(20) + u32(4) = 32
    assert(batch.out_used == 32);
    // Check header
    assert(Wayland.read_u32(batch.out_buf.data) == 2);
    word2 := Wayland.read_u32(batch.out_buf.data + 4);
    assert(word2 == (32 << 16) | 0);
    // Check string length prefix
    assert(Wayland.read_u32(batch.out_buf.data + 8) == 14);  // 13 + NUL
    // Check version at offset 28
    assert(Wayland.read_u32(batch.out_buf.data + 28) == 4);
    print("  PASS: marshal_with_string\n");
}

test_marshal_empty_args :: () {
    batch: Wayland.MessageBuilder;
    args: Test_Empty_Args;
    Wayland.marshal(*batch, object_id = 1, opcode = 6, *args);

    // Header only
    assert(batch.out_used == 8);
    assert(Wayland.read_u32(batch.out_buf.data) == 1);
    word2 := Wayland.read_u32(batch.out_buf.data + 4);
    assert(word2 == (8 << 16) | 6);
    print("  PASS: marshal_empty_args\n");
}

test_marshal_with_fixed :: () {
    batch: Wayland.MessageBuilder;
    args := Test_Fixed_Args.{
        position = Wayland.fixed_from_float(1.5),   // raw = 384
        scale = Wayland.fixed_from_float(-0.25),     // raw = -64
    };
    Wayland.marshal(*batch, object_id = 10, opcode = 3, *args);

    // header(8) + Fixed(4) + Fixed(4) = 16
    assert(batch.out_used == 16);
    assert(Wayland.read_s32(batch.out_buf.data + 8) == 384);   // 1.5 * 256
    assert(Wayland.read_s32(batch.out_buf.data + 12) == -64);  // -0.25 * 256
    print("  PASS: marshal_with_fixed\n");
}

test_marshal_with_array :: () {
    batch: Wayland.MessageBuilder;
    data: [5] u8 = u8.[1, 2, 3, 4, 5];
    arr: [] u8;
    arr.data = data.data;
    arr.count = data.count;
    args := Test_Array_Args.{data = arr};
    Wayland.marshal(*batch, object_id = 4, opcode = 2, *args);

    // header(8) + array(4 + align4(5)=8) = 20
    assert(batch.out_used == 20);
    // Check array length prefix
    assert(Wayland.read_u32(batch.out_buf.data + 8) == 5);
    // Check first data byte
    assert(batch.out_buf[12] == 1);
    assert(batch.out_buf[16] == 5);
    print("  PASS: marshal_with_array\n");
}

test_marshal_string_empty :: () {
    batch: Wayland.MessageBuilder;
    args := Test_String_Args.{name = "", version = 99};
    Wayland.marshal(*batch, object_id = 1, opcode = 0, *args);

    // Empty string: length 0 (4 bytes), no data
    // header(8) + empty_string(4) + u32(4) = 16
    assert(batch.out_used == 16);
    // String length should be 0
    assert(Wayland.read_u32(batch.out_buf.data + 8) == 0);
    // Version at offset 12
    assert(Wayland.read_u32(batch.out_buf.data + 12) == 99);
    print("  PASS: marshal_string_empty\n");
}

test_marshal_constructor_empty :: () {
    batch: Wayland.MessageBuilder;
    args: Test_Constructor_Empty;
    Wayland.marshal_constructor(*batch, object_id = 1, opcode = 0, new_id = 42, *args);

    // header(8) + new_id(4) = 12
    assert(batch.out_used == 12);
    assert(Wayland.read_u32(batch.out_buf.data + 8) == 42);  // new_id in message
    print("  PASS: marshal_constructor_empty\n");
}

test_marshal_constructor_with_args :: () {
    batch: Wayland.MessageBuilder;
    args := Test_Constructor_With_Args.{x = 10, y = 20};
    Wayland.marshal_constructor(*batch, object_id = 5, opcode = 3, new_id = 7, *args);

    // header(8) + new_id(4) + x(4) + y(4) = 20
    assert(batch.out_used == 20);
    assert(Wayland.read_u32(batch.out_buf.data + 8) == 7);  // new_id
    assert(Wayland.read_s32(batch.out_buf.data + 12) == 10);  // x
    assert(Wayland.read_s32(batch.out_buf.data + 16) == 20);  // y
    print("  PASS: marshal_constructor_with_args\n");
}
