#import "Basic";
#import,dir "../modules/wayland";

test_types_exist :: () {
    d: Wl_Display;
    assert(d.id == 0);
    s: Wl_Surface;
    assert(s.version == 0);
    print("  PASS: test_types_exist\n");
}

test_opcodes_exist :: () {
    assert(WL_DISPLAY_SYNC == 0);
    assert(WL_DISPLAY_GET_REGISTRY == 1);
    assert(WL_SURFACE_ATTACH == 1);
    print("  PASS: test_opcodes_exist\n");
}

test_enums_exist :: () {
    err: Wl_Display_Error = .INVALID_OBJECT;
    assert(cast(u32) err == 0);
    print("  PASS: test_enums_exist\n");
}

test_events_exist :: () {
    assert(size_of(Wl_Display_Event) > 0);
    assert(size_of(Wl_Surface_Event) > 0);
    print("  PASS: test_events_exist\n");
}

test_descriptors_exist :: () {
    assert(WL_DISPLAY_INTERFACE.name == "wl_display");
    assert(WL_DISPLAY_INTERFACE.version == 1);
    assert(WL_SURFACE_INTERFACE.version == 6);
    print("  PASS: test_descriptors_exist\n");
}

test_xdg_types :: () {
    t: Xdg_Toplevel;
    assert(t.id == 0);
    assert(XDG_TOPLEVEL_INTERFACE.name == "xdg_toplevel");
    print("  PASS: test_xdg_types\n");
}

main :: () {
    print("Running compilation tests...\n\n");
    print("generated module:\n");
    test_types_exist();
    test_opcodes_exist();
    test_enums_exist();
    test_events_exist();
    test_descriptors_exist();
    test_xdg_types();
    print("\nAll tests passed.\n");
}
