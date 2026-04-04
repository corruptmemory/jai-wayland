
#import "Basic";
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

    print("\nAll tests passed.\n");
}
