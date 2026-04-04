
#import "Basic";
#import "String";
#load "../src/generator.jai";

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

test_opcode_name_destroy :: () {
    result := opcode_name("wl_display", "get_registry");
    assert(result == "WL_DISPLAY_GET_REGISTRY", "Expected 'WL_DISPLAY_GET_REGISTRY', got '%'", result);
    print("  PASS: test_opcode_name_destroy\n");
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

main :: () {
    print("Running generator tests...\n\n");

    print("to_jai_type_name:\n");
    test_type_name_simple();
    test_type_name_multi_segment();
    test_type_name_long();
    test_type_name_single_word();

    print("\nto_upper_snake:\n");
    test_upper_snake_simple();
    test_upper_snake_single();

    print("\nopcode_name:\n");
    test_opcode_name();
    test_opcode_name_destroy();

    print("\nto_jai_enum_name:\n");
    test_enum_name();
    test_enum_name_format();

    print("\nresolve_enum_type:\n");
    test_resolve_enum_cross_interface();
    test_resolve_enum_local();
    test_resolve_enum_cross_interface_long();

    print("\nAll tests passed.\n");
}
