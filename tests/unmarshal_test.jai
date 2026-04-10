#import "Basic";
Wayland :: #import,dir "../modules/wayland";

// Test struct mimicking wl_surface.attach args (all fixed-size)
Test_Attach_Args :: struct {
    buffer_id: u32;
    x: s32;
    y: s32;
}

// Test struct with string + u32 (variable-size path)
Test_String_Args :: struct {
    name: string;
    version: u32;
}

// Test struct with no args at all
Test_Empty_Args :: struct {}

// Test struct with Fixed (24.8) type
Test_Fixed_Args :: struct {
    position: Wayland.Fixed;
    scale: Wayland.Fixed;
}

// Test struct with array (variable-size)
Test_Array_Args :: struct {
    data: [] u8;
}

// Test struct with an fd (out-of-band) and a string (variable-size)
Test_Fd_Args :: struct {
    mime_type: string;
    fd: Wayland.Fd;
}

// Test struct with *void field
Test_Void_Pointer_Args :: struct {
    object_id: *void;
    code: u32;
}

// Test struct with *Interface field
Test_Interface_Pointer_Args :: struct {
    surface: *Wayland.Wl_Surface;
    serial: u32;
}

main :: () {
    print("=== Demarshal Macro Tests ===\n\n");
    test_unmarshal_fixed_args();
    test_unmarshal_empty_args();
    test_unmarshal_with_string();
    test_unmarshal_string_empty();
    test_unmarshal_with_fixed();
    test_unmarshal_with_array();
    test_unmarshal_with_fd();
    test_unmarshal_void_pointer();
    test_unmarshal_interface_pointer();
    test_unmarshal_event_fixed();
    test_unmarshal_event_variable();
    test_unmarshal_event_empty();
    print("\n=== All unmarshal tests passed ===\n");
}

// --- Test 1: Fixed-size args round-trip ---
test_unmarshal_fixed_args :: () {
    // Marshal known args
    batch: Wayland.MessageBuilder;
    args := Test_Attach_Args.{buffer_id = 7, x = 10, y = -5};
    Wayland.marshal(*batch, object_id = 5, opcode = 1, *args);

    // Demarshal from payload (skip 8-byte header)
    recv: Wayland.ReceiveBuffer;
    result: Test_Attach_Args;
    Wayland.unmarshal(*result, batch.out_buf.data + 8, *recv);

    assert(result.buffer_id == 7);
    assert(result.x == 10);
    assert(result.y == -5);
    print("  PASS: unmarshal_fixed_args\n");
}

// --- Test 2: Empty args ---
test_unmarshal_empty_args :: () {
    recv: Wayland.ReceiveBuffer;
    result: Test_Empty_Args;
    // Payload pointer doesn't matter for empty struct
    dummy: [4] u8;
    Wayland.unmarshal(*result, dummy.data, *recv);
    print("  PASS: unmarshal_empty_args\n");
}

// --- Test 3: String + u32 (variable path) ---
test_unmarshal_with_string :: () {
    batch: Wayland.MessageBuilder;
    args := Test_String_Args.{name = "wl_compositor", version = 4};
    Wayland.marshal(*batch, object_id = 2, opcode = 0, *args);

    recv: Wayland.ReceiveBuffer;
    result: Test_String_Args;
    Wayland.unmarshal(*result, batch.out_buf.data + 8, *recv);

    assert(result.name == "wl_compositor");
    assert(result.version == 4);
    print("  PASS: unmarshal_with_string\n");
}

// --- Test 4: Empty string edge case ---
test_unmarshal_string_empty :: () {
    batch: Wayland.MessageBuilder;
    args := Test_String_Args.{name = "", version = 99};
    Wayland.marshal(*batch, object_id = 1, opcode = 0, *args);

    recv: Wayland.ReceiveBuffer;
    result: Test_String_Args;
    Wayland.unmarshal(*result, batch.out_buf.data + 8, *recv);

    assert(result.name == "");
    assert(result.version == 99);
    print("  PASS: unmarshal_string_empty\n");
}

// --- Test 5: Fixed 24.8 fields ---
test_unmarshal_with_fixed :: () {
    batch: Wayland.MessageBuilder;
    args := Test_Fixed_Args.{
        position = Wayland.fixed_from_float(1.5),
        scale = Wayland.fixed_from_float(-0.25),
    };
    Wayland.marshal(*batch, object_id = 10, opcode = 3, *args);

    recv: Wayland.ReceiveBuffer;
    result: Test_Fixed_Args;
    Wayland.unmarshal(*result, batch.out_buf.data + 8, *recv);

    assert(result.position.raw == 384);   // 1.5 * 256
    assert(result.scale.raw == -64);      // -0.25 * 256
    print("  PASS: unmarshal_with_fixed\n");
}

// --- Test 6: Array ---
test_unmarshal_with_array :: () {
    batch: Wayland.MessageBuilder;
    data: [5] u8 = u8.[1, 2, 3, 4, 5];
    arr: [] u8;
    arr.data = data.data;
    arr.count = data.count;
    args := Test_Array_Args.{data = arr};
    Wayland.marshal(*batch, object_id = 4, opcode = 2, *args);

    recv: Wayland.ReceiveBuffer;
    result: Test_Array_Args;
    Wayland.unmarshal(*result, batch.out_buf.data + 8, *recv);

    assert(result.data.count == 5);
    assert(result.data[0] == 1);
    assert(result.data[4] == 5);
    print("  PASS: unmarshal_with_array\n");
}

// --- Test 7: Fd (popped from ReceiveBuffer) ---
test_unmarshal_with_fd :: () {
    // Marshal: string goes on wire, fd goes to out_fds
    batch: Wayland.MessageBuilder;
    args := Test_Fd_Args.{mime_type = "text/plain", fd = cast(Wayland.Fd) 42};
    Wayland.marshal(*batch, object_id = 3, opcode = 0, *args);

    // Set up recv with the fd manually pushed
    recv: Wayland.ReceiveBuffer;
    recv.in_fds[0] = 42;
    recv.in_fds_count = 1;

    result: Test_Fd_Args;
    Wayland.unmarshal(*result, batch.out_buf.data + 8, *recv);

    assert(result.mime_type == "text/plain");
    assert(cast(s32) result.fd == 42);
    assert(recv.in_fds_read == 1);  // fd was consumed
    print("  PASS: unmarshal_with_fd\n");
}

// --- Test 8: *void pointer ---
test_unmarshal_void_pointer :: () {
    // Manually construct payload: object_id as u32 + code as u32
    buf: [8] u8;
    Wayland.write_u32(buf.data, 0xDEAD);  // object_id
    Wayland.write_u32(buf.data + 4, 42);   // code

    recv: Wayland.ReceiveBuffer;
    result: Test_Void_Pointer_Args;
    Wayland.unmarshal(*result, buf.data, *recv);

    assert(cast(u64) result.object_id == 0xDEAD);
    assert(result.code == 42);
    print("  PASS: unmarshal_void_pointer\n");
}

// --- Test 9: *Interface pointer (temp-allocated) ---
test_unmarshal_interface_pointer :: () {
    // Manually construct payload: surface_id as u32 + serial as u32
    buf: [8] u8;
    Wayland.write_u32(buf.data, 15);   // surface id
    Wayland.write_u32(buf.data + 4, 7);  // serial

    recv: Wayland.ReceiveBuffer;
    result: Test_Interface_Pointer_Args;
    Wayland.unmarshal(*result, buf.data, *recv);

    assert(result.surface != null);
    assert(result.surface.id == 15);
    assert(result.serial == 7);
    print("  PASS: unmarshal_interface_pointer\n");
}

// --- Test 10: unmarshal_event with fixed variant (MODE) ---
test_unmarshal_event_fixed :: () {
    // Build wl_output.mode payload: flags(u32) + width(s32) + height(s32) + refresh(s32)
    buf: [16] u8;
    Wayland.write_u32(buf.data, 3);       // flags: CURRENT | PREFERRED
    Wayland.write_s32(buf.data + 4, 1920);
    Wayland.write_s32(buf.data + 8, 1080);
    Wayland.write_s32(buf.data + 12, 60000);

    recv: Wayland.ReceiveBuffer;
    event: Wayland.Wl_Output_Event;
    Wayland.unmarshal_event(*event, opcode = 1, buf.data, *recv);

    assert(event.kind == .MODE);
    assert(event.mode.flags == 3);
    assert(event.mode.width == 1920);
    assert(event.mode.height == 1080);
    assert(event.mode.refresh == 60000);
    print("  PASS: unmarshal_event_fixed (MODE)\n");
}

// --- Test 11: unmarshal_event with variable variant (NAME) ---
test_unmarshal_event_variable :: () {
    // Build wl_output.name payload: string "eDP-1"
    // Wire string: u32 length (incl NUL) + data + NUL + padding
    buf: [16] u8;
    // "eDP-1" = 5 chars + NUL = 6, padded to 8
    Wayland.write_u32(buf.data, 6);  // length including NUL
    name := "eDP-1";
    memcpy(buf.data + 4, name.data, name.count);
    buf[9] = 0;  // NUL terminator

    recv: Wayland.ReceiveBuffer;
    event: Wayland.Wl_Output_Event;
    Wayland.unmarshal_event(*event, opcode = 4, buf.data, *recv);

    assert(event.kind == .NAME);
    assert(event.name.name == "eDP-1");
    print("  PASS: unmarshal_event_variable (NAME)\n");
}

// --- Test 12: unmarshal_event with empty variant (DONE) ---
test_unmarshal_event_empty :: () {
    dummy: [4] u8;

    recv: Wayland.ReceiveBuffer;
    event: Wayland.Wl_Output_Event;
    Wayland.unmarshal_event(*event, opcode = 2, dummy.data, *recv);

    assert(event.kind == .DONE);
    print("  PASS: unmarshal_event_empty (DONE)\n");
}
