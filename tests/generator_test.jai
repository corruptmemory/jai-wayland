
#import "Basic";
#import "File";
#import "String";
#load "../src/generator.jai";
#load "../src/xml.jai";
#load "../src/protocol.jai";

// ── to_jai_type_name tests ──

test_type_name_simple :: () {
    assert(to_jai_type_name("wl_surface") == "Wl_Surface", "Expected 'Wl_Surface', got '%'", to_jai_type_name("wl_surface"));
    print("  PASS: test_type_name_simple\n");
}

test_type_name_multi_segment :: () {
    assert(to_jai_type_name("xdg_toplevel") == "Xdg_Toplevel", "Expected 'Xdg_Toplevel', got '%'", to_jai_type_name("xdg_toplevel"));
    print("  PASS: test_type_name_multi_segment\n");
}

test_type_name_long :: () {
    result := to_jai_type_name("zwp_linux_dmabuf_v1");
    assert(result == "Zwp_Linux_Dmabuf_V1", "Expected 'Zwp_Linux_Dmabuf_V1', got '%'", result);
    print("  PASS: test_type_name_long\n");
}

test_type_name_single_word :: () {
    assert(to_jai_type_name("display") == "Display", "Expected 'Display'");
    print("  PASS: test_type_name_single_word\n");
}

test_empty_string_handling :: () {
    assert(to_jai_type_name("") == "");
    assert(to_upper_snake("") == "");
    print("  PASS: test_empty_string_handling\n");
}

// ── to_upper_snake tests ──

test_upper_snake_simple :: () {
    assert(to_upper_snake("wl_surface") == "WL_SURFACE", "Expected 'WL_SURFACE', got '%'", to_upper_snake("wl_surface"));
    print("  PASS: test_upper_snake_simple\n");
}

test_upper_snake_single :: () {
    assert(to_upper_snake("attach") == "ATTACH", "Expected 'ATTACH'");
    print("  PASS: test_upper_snake_single\n");
}

// ── opcode_name tests ──

test_opcode_name :: () {
    result := opcode_name("wl_surface", "attach");
    assert(result == "WL_SURFACE_ATTACH", "Expected 'WL_SURFACE_ATTACH', got '%'", result);
    print("  PASS: test_opcode_name\n");
}

test_opcode_name_compound_message :: () {
    result := opcode_name("wl_display", "get_registry");
    assert(result == "WL_DISPLAY_GET_REGISTRY", "Expected 'WL_DISPLAY_GET_REGISTRY', got '%'", result);
    print("  PASS: test_opcode_name_compound_message\n");
}

// ── to_jai_enum_name tests ──

test_enum_name :: () {
    result := to_jai_enum_name("wl_surface", "error");
    assert(result == "Wl_Surface_Error", "Expected 'Wl_Surface_Error', got '%'", result);
    print("  PASS: test_enum_name\n");
}

test_enum_name_format :: () {
    result := to_jai_enum_name("wl_shm", "format");
    assert(result == "Wl_Shm_Format", "Expected 'Wl_Shm_Format', got '%'", result);
    print("  PASS: test_enum_name_format\n");
}

// ── resolve_enum_type tests ──

test_resolve_enum_cross_interface :: () {
    result := resolve_enum_type("wl_shm.format", "wl_buffer");
    assert(result == "Wl_Shm_Format", "Expected 'Wl_Shm_Format', got '%'", result);
    print("  PASS: test_resolve_enum_cross_interface\n");
}

test_resolve_enum_local :: () {
    result := resolve_enum_type("error", "wl_display");
    assert(result == "Wl_Display_Error", "Expected 'Wl_Display_Error', got '%'", result);
    print("  PASS: test_resolve_enum_local\n");
}

test_resolve_enum_cross_interface_long :: () {
    result := resolve_enum_type("zwp_linux_dmabuf_v1.modifier", "wl_surface");
    assert(result == "Zwp_Linux_Dmabuf_V1_Modifier", "Expected 'Zwp_Linux_Dmabuf_V1_Modifier', got '%'", result);
    print("  PASS: test_resolve_enum_cross_interface_long\n");
}

// ── generate_types_file tests ──

test_generate_types_file :: () {
    result := generate_types_file();
    assert(contains(result, "Interface_Descriptor :: struct"), "Missing Interface_Descriptor");
    assert(contains(result, "Wire_Arg_Type :: enum u8"), "Missing Wire_Arg_Type");
    assert(contains(result, "Fixed :: struct"), "Missing Fixed");
    assert(contains(result, "fixed_from_float"), "Missing fixed_from_float");
    assert(contains(result, "fixed_to_float"), "Missing fixed_to_float");
    print("  PASS: test_generate_types_file\n");
}

// ── enum generation tests ──

test_generate_enum_regular :: () {
    e: Enum_Def;
    e.name = "error";
    e.description.summary = "surface errors";
    entry1: Entry; entry1.name = "invalid_scale"; entry1.value = 0; entry1.summary = "buffer scale is not positive";
    entry2: Entry; entry2.name = "invalid_transform"; entry2.value = 1; entry2.summary = "buffer transform is not valid";
    array_add(*e.entries, entry1);
    array_add(*e.entries, entry2);

    result := generate_enum(*e, "wl_surface");
    assert(contains(result, "Wl_Surface_Error :: enum u32"), "Missing enum declaration, got:\n%", result);
    assert(contains(result, "INVALID_SCALE"), "Missing INVALID_SCALE");
    assert(contains(result, "INVALID_TRANSFORM"), "Missing INVALID_TRANSFORM");
    assert(contains(result, ":: 0"), "Missing value 0");
    assert(contains(result, ":: 1"), "Missing value 1");
    assert(contains(result, "surface errors"), "Missing summary comment");
    print("  PASS: test_generate_enum_regular\n");
}

test_generate_enum_bitfield :: () {
    e: Enum_Def;
    e.name = "capability";
    e.bitfield = true;
    entry1: Entry; entry1.name = "pointer"; entry1.value = 1;
    entry2: Entry; entry2.name = "keyboard"; entry2.value = 2;
    entry3: Entry; entry3.name = "touch"; entry3.value = 4;
    array_add(*e.entries, entry1);
    array_add(*e.entries, entry2);
    array_add(*e.entries, entry3);

    result := generate_enum(*e, "wl_seat");
    assert(contains(result, "enum_flags u32"), "Bitfield should use enum_flags, got:\n%", result);
    assert(contains(result, "POINTER"), "Missing POINTER");
    assert(contains(result, ":: 1"), "Missing value 1");
    print("  PASS: test_generate_enum_bitfield\n");
}

test_generate_enum_hex_values :: () {
    e: Enum_Def;
    e.name = "format";
    entry1: Entry; entry1.name = "argb8888"; entry1.value = 0;
    entry2: Entry; entry2.name = "c8"; entry2.value = 0x20203843;
    array_add(*e.entries, entry1);
    array_add(*e.entries, entry2);

    result := generate_enum(*e, "wl_shm");
    assert(contains(result, "0x20203843"), "Large value should be hex, got:\n%", result);
    print("  PASS: test_generate_enum_hex_values\n");
}

test_emit_description_body :: () {
    sb: String_Builder;
    sb.allocator = temp;
    emit_description_body(*sb, "\n  First paragraph.\n\n  Second paragraph.\n  ");
    result := builder_to_string(*sb,, allocator = temp);
    assert(contains(result, "// First paragraph."), "Missing first paragraph");
    assert(contains(result, "// Second paragraph."), "Missing second paragraph");
    // Should have blank comment line between paragraphs
    assert(contains(result, "//\n"), "Missing paragraph separator");
    // Should NOT start with bare // (leading blank stripped)
    assert(!begins_with(result, "//\n//"), "Should strip leading blank lines");
    print("  PASS: test_emit_description_body\n");
}

// ── event generation tests ──

test_generate_events_basic :: () {
    iface: Interface;
    iface.name = "wl_surface";

    ev1: Message; ev1.name = "enter";
    arg1: Arg; arg1.name = "output"; arg1.arg_type = .UINT;
    array_add(*ev1.args, arg1);

    ev2: Message; ev2.name = "leave";
    arg2: Arg; arg2.name = "output"; arg2.arg_type = .UINT;
    array_add(*ev2.args, arg2);

    array_add(*iface.events, ev1);
    array_add(*iface.events, ev2);

    result := generate_events(*iface);
    assert(contains(result, "Wl_Surface_Event_Kind :: enum u8"), "Missing event kind enum");
    assert(contains(result, "ENTER :: 0"), "Missing ENTER");
    assert(contains(result, "LEAVE :: 1"), "Missing LEAVE");
    assert(contains(result, "Wl_Surface_Event :: union kind: Wl_Surface_Event_Kind"), "Missing tagged union");
    assert(contains(result, ".ENTER"), "Missing .ENTER binding");
    assert(contains(result, ".LEAVE"), "Missing .LEAVE binding");
    print("  PASS: test_generate_events_basic\n");
}

test_generate_events_no_events :: () {
    iface: Interface;
    iface.name = "wl_callback";
    result := generate_events(*iface);
    assert(result.count == 0, "No events should produce empty output");
    print("  PASS: test_generate_events_no_events\n");
}

test_generate_events_multi_arg :: () {
    iface: Interface;
    iface.name = "wl_pointer";

    ev: Message; ev.name = "motion";
    arg1: Arg; arg1.name = "time"; arg1.arg_type = .UINT;
    arg2: Arg; arg2.name = "surface_x"; arg2.arg_type = .FIXED;
    arg3: Arg; arg3.name = "surface_y"; arg3.arg_type = .FIXED;
    array_add(*ev.args, arg1);
    array_add(*ev.args, arg2);
    array_add(*ev.args, arg3);
    array_add(*iface.events, ev);

    result := generate_events(*iface);
    // Multi-arg event needs wrapper struct
    assert(contains(result, "Wl_Pointer_Motion_Args :: struct"), "Missing args struct");
    assert(contains(result, "time: u32"), "UINT should map to u32");
    assert(contains(result, "surface_x: Fixed"), "FIXED should map to Fixed");
    assert(contains(result, "surface_y: Fixed"), "FIXED should map to Fixed");
    assert(contains(result, "Wl_Pointer_Event :: union kind: Wl_Pointer_Event_Kind"), "Missing tagged union");
    print("  PASS: test_generate_events_multi_arg\n");
}

test_generate_events_typed_object :: () {
    iface: Interface;
    iface.name = "wl_surface";

    ev: Message; ev.name = "enter";
    arg1: Arg; arg1.name = "output"; arg1.arg_type = .OBJECT; arg1.interface_name = "wl_output";
    array_add(*ev.args, arg1);
    array_add(*iface.events, ev);

    result := generate_events(*iface);
    assert(contains(result, "*Wl_Output"), "OBJECT with interface should produce typed pointer");
    print("  PASS: test_generate_events_typed_object\n");
}

test_generate_events_zero_args :: () {
    iface: Interface;
    iface.name = "wl_data_source";

    ev: Message; ev.name = "cancelled";
    // No args
    array_add(*iface.events, ev);

    result := generate_events(*iface);
    assert(contains(result, "Wl_Data_Source_Event_Kind"), "Missing kind enum");
    assert(contains(result, "Wl_Data_Source_Event :: union"), "Missing union");
    assert(contains(result, "CANCELLED"), "Missing CANCELLED variant");
    print("  PASS: test_generate_events_zero_args\n");
}

// ── request generation tests ──

test_generate_request_simple :: () {
    iface: Interface; iface.name = "wl_surface";
    req: Message; req.name = "damage";
    arg1: Arg; arg1.name = "x"; arg1.arg_type = .INT;
    arg2: Arg; arg2.name = "y"; arg2.arg_type = .INT;
    arg3: Arg; arg3.name = "width"; arg3.arg_type = .INT;
    arg4: Arg; arg4.name = "height"; arg4.arg_type = .INT;
    array_add(*req.args, arg1);
    array_add(*req.args, arg2);
    array_add(*req.args, arg3);
    array_add(*req.args, arg4);

    result := generate_request(*iface, *req, 2);
    assert(contains(result, "wl_surface_damage"), "Missing function name");
    assert(contains(result, "self: *Wl_Surface"), "Missing self parameter");
    assert(contains(result, "x: s32"), "Missing x param");
    assert(contains(result, "width: s32"), "Missing width param");
    assert(contains(result, "Wl_Surface_Damage_Args.{"), "Missing args struct literal, got:\n%", result);
    assert(contains(result, "marshal(self.conn, self.id, WL_SURFACE_DAMAGE"), "Missing marshal call, got:\n%", result);
    print("  PASS: test_generate_request_simple\n");
}

test_generate_request_constructor :: () {
    iface: Interface; iface.name = "wl_surface";
    req: Message; req.name = "frame";
    arg1: Arg; arg1.name = "callback"; arg1.arg_type = .NEW_ID; arg1.interface_name = "wl_callback";
    array_add(*req.args, arg1);

    result := generate_request(*iface, *req, 3);
    assert(contains(result, "new_id: u32"), "Constructor should take new_id param, got:\n%", result);
    assert(contains(result, "marshal_constructor(self.conn, self.id, WL_SURFACE_FRAME"), "Missing marshal_constructor call, got:\n%", result);
    assert(!contains(result, "return null"), "Constructor should not return null, got:\n%", result);
    print("  PASS: test_generate_request_constructor\n");
}

test_generate_request_destructor :: () {
    iface: Interface; iface.name = "wl_surface";
    req: Message; req.name = "destroy"; req.is_destructor = true;

    result := generate_request(*iface, *req, 0);
    assert(contains(result, "destructor"), "Should note destructor");
    assert(contains(result, "marshal(self.conn, self.id, WL_SURFACE_DESTROY"), "Missing marshal call, got:\n%", result);
    assert(contains(result, "TODO(Phase 4): destroy_proxy"), "Missing Phase 4 destroy TODO, got:\n%", result);
    print("  PASS: test_generate_request_destructor\n");
}

test_generate_request_untyped_new_id :: () {
    iface: Interface; iface.name = "wl_registry";
    req: Message; req.name = "bind";
    arg1: Arg; arg1.name = "name"; arg1.arg_type = .UINT;
    arg2: Arg; arg2.name = "id"; arg2.arg_type = .NEW_ID;  // no interface_name!
    array_add(*req.args, arg1);
    array_add(*req.args, arg2);

    result := generate_request(*iface, *req, 0);
    assert(contains(result, "interface_name: string"), "Untyped new_id should have interface_name param, got:\n%", result);
    assert(contains(result, "version: u32"), "Untyped new_id should have version param, got:\n%", result);
    assert(contains(result, "new_id: u32"), "Untyped new_id should have new_id param, got:\n%", result);
    assert(contains(result, "write_string"), "Should use write_string for interface_name, got:\n%", result);
    assert(contains(result, "connection_queue"), "Should use connection_queue, got:\n%", result);
    print("  PASS: test_generate_request_untyped_new_id\n");
}

// ── interface components tests ──

test_generate_interface_struct :: () {
    iface: Interface;
    iface.name = "wl_surface";
    iface.version = 6;
    iface.description.summary = "a compositable surface";

    result := generate_interface_struct(*iface);
    assert(contains(result, "Wl_Surface :: struct"), "Missing struct");
    assert(contains(result, "id: u32"), "Missing id field");
    assert(contains(result, "version: u32"), "Missing version field");
    assert(contains(result, "conn: *Connection"), "Missing conn field");
    assert(contains(result, "a compositable surface"), "Missing summary comment");
    print("  PASS: test_generate_interface_struct\n");
}

test_generate_opcodes :: () {
    iface: Interface;
    iface.name = "wl_surface";

    req1: Message; req1.name = "destroy";
    req2: Message; req2.name = "attach";
    req3: Message; req3.name = "damage";
    array_add(*iface.requests, req1);
    array_add(*iface.requests, req2);
    array_add(*iface.requests, req3);

    ev1: Message; ev1.name = "enter";
    ev2: Message; ev2.name = "leave";
    array_add(*iface.events, ev1);
    array_add(*iface.events, ev2);

    result := generate_opcodes(*iface);
    assert(contains(result, "WL_SURFACE_DESTROY :: 0"), "Missing destroy opcode");
    assert(contains(result, "WL_SURFACE_ATTACH :: 1"), "Missing attach opcode");
    assert(contains(result, "WL_SURFACE_DAMAGE :: 2"), "Missing damage opcode");
    assert(contains(result, "WL_SURFACE_ENTER :: 0"), "Missing enter event opcode");
    assert(contains(result, "WL_SURFACE_LEAVE :: 1"), "Missing leave event opcode");
    print("  PASS: test_generate_opcodes\n");
}

test_generate_interface_descriptor :: () {
    iface: Interface;
    iface.name = "wl_surface";
    iface.version = 6;
    req1: Message; req1.name = "a";
    req2: Message; req2.name = "b";
    array_add(*iface.requests, req1);
    array_add(*iface.requests, req2);
    ev1: Message; ev1.name = "c";
    array_add(*iface.events, ev1);

    result := generate_interface_descriptor(*iface);
    assert(contains(result, "WL_SURFACE_INTERFACE"), "Missing descriptor name");
    assert(contains(result, "Interface_Descriptor"), "Missing type");
    assert(contains(result, "\"wl_surface\""), "Missing name string");
    assert(contains(result, "version = 6"), "Missing version");
    assert(contains(result, "request_count = 2"), "Missing request count");
    assert(contains(result, "event_count = 1"), "Missing event count");
    print("  PASS: test_generate_interface_descriptor\n");
}

// ── full interface file tests ──

test_generate_interface_file :: () {
    iface: Interface;
    iface.name = "wl_surface";
    iface.version = 6;
    iface.description.summary = "a compositable surface";

    // One enum
    e: Enum_Def; e.name = "error";
    entry: Entry; entry.name = "invalid_scale"; entry.value = 0; entry.summary = "bad scale";
    array_add(*e.entries, entry);
    array_add(*iface.enums, e);

    // One request
    req: Message; req.name = "destroy"; req.is_destructor = true;
    array_add(*iface.requests, req);

    // One event
    ev: Message; ev.name = "enter";
    arg: Arg; arg.name = "output"; arg.arg_type = .UINT;
    array_add(*ev.args, arg);
    array_add(*iface.events, ev);

    result := generate_interface_file(*iface);

    // Check all sections are present
    assert(contains(result, "Auto-generated"), "Missing header");
    assert(contains(result, "Wl_Surface :: struct"), "Missing struct");
    assert(contains(result, "WL_SURFACE_DESTROY :: 0"), "Missing opcodes");
    assert(contains(result, "Wl_Surface_Error :: enum u32"), "Missing enum");
    assert(contains(result, "Wl_Surface_Event_Kind"), "Missing event kind");
    assert(contains(result, "Wl_Surface_Event :: union"), "Missing event union");
    assert(contains(result, "wl_surface_destroy"), "Missing request function");
    assert(contains(result, "WL_SURFACE_INTERFACE"), "Missing descriptor");
    print("  PASS: test_generate_interface_file\n");
}

// ── protocol structure tests ──

test_generate_protocol_loader :: () {
    proto: Protocol;
    proto.name = "wayland";
    iface1: Interface; iface1.name = "wl_display"; iface1.version = 1;
    iface2: Interface; iface2.name = "wl_registry"; iface2.version = 1;
    array_add(*proto.interfaces, iface1);
    array_add(*proto.interfaces, iface2);

    result := generate_protocol_loader(*proto);
    assert(contains(result, "#load \"wl_display.jai\""), "Missing wl_display load");
    assert(contains(result, "#load \"wl_registry.jai\""), "Missing wl_registry load");
    assert(contains(result, "wayland"), "Missing protocol name");
    print("  PASS: test_generate_protocol_loader\n");
}

test_generate_module_root :: () {
    names: [2] string;
    names[0] = "wayland";
    names[1] = "xdg_shell";

    result := generate_module_root(names);
    assert(contains(result, "#load \"types.jai\""), "Missing types load");
    assert(contains(result, "#load \"wayland/wayland.jai\""), "Missing wayland load");
    assert(contains(result, "#load \"xdg_shell/xdg_shell.jai\""), "Missing xdg_shell load");
    print("  PASS: test_generate_module_root\n");
}

// ── end-to-end tests ──

test_generate_from_xml :: () {
    contents, ok := read_entire_file("vendor/wayland-protocols/core/wayland.xml");
    assert(ok);
    proto := parse_protocol(contents);

    assert(proto.interfaces.count >= 22);
    display := proto.interfaces[0];
    assert(display.name == "wl_display");

    result := generate_interface_file(*display);
    assert(contains(result, "Wl_Display :: struct"), "Missing struct");
    assert(contains(result, "WL_DISPLAY_SYNC :: 0"), "Missing sync opcode");
    assert(contains(result, "WL_DISPLAY_GET_REGISTRY :: 1"), "Missing get_registry opcode");
    assert(contains(result, "Wl_Display_Error :: enum u32"), "Missing error enum");
    assert(contains(result, "Wl_Display_Event"), "Missing event union");
    assert(contains(result, "wl_display_sync"), "Missing sync request");
    assert(contains(result, "new_id: u32"), "sync constructor should take new_id param");
    assert(contains(result, "WL_DISPLAY_INTERFACE"), "Missing descriptor");
    print("  PASS: test_generate_from_xml\n");
}

main :: () {
    print("Running generator tests...\n\n");

    print("to_jai_type_name:\n");
    test_type_name_simple();
    test_type_name_multi_segment();
    test_type_name_long();
    test_type_name_single_word();

    print("\nnaming utilities edge cases:\n");
    test_empty_string_handling();

    print("\nto_upper_snake:\n");
    test_upper_snake_simple();
    test_upper_snake_single();

    print("\nopcode_name:\n");
    test_opcode_name();
    test_opcode_name_compound_message();

    print("\nto_jai_enum_name:\n");
    test_enum_name();
    test_enum_name_format();

    print("\nresolve_enum_type:\n");
    test_resolve_enum_cross_interface();
    test_resolve_enum_local();
    test_resolve_enum_cross_interface_long();

    print("\nshared types:\n");
    test_generate_types_file();

    print("\nenum generation:\n");
    test_generate_enum_regular();
    test_generate_enum_bitfield();
    test_generate_enum_hex_values();
    test_emit_description_body();

    print("\nevent generation:\n");
    test_generate_events_basic();
    test_generate_events_no_events();
    test_generate_events_multi_arg();
    test_generate_events_typed_object();
    test_generate_events_zero_args();

    print("\nrequest generation:\n");
    test_generate_request_simple();
    test_generate_request_constructor();
    test_generate_request_destructor();
    test_generate_request_untyped_new_id();

    print("\ninterface components:\n");
    test_generate_interface_struct();
    test_generate_opcodes();
    test_generate_interface_descriptor();

    print("\nfull interface file:\n");
    test_generate_interface_file();

    print("\nprotocol structure:\n");
    test_generate_protocol_loader();
    test_generate_module_root();

    print("\nend-to-end:\n");
    test_generate_from_xml();

    print("\nAll tests passed.\n");
}
