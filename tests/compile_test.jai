// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jim Powers

#import "Basic";
#import,dir "../modules/wayland";

test_types_exist :: () {
    d: Wl_Display;
    assert(d.id == 0);
    s: Wl_Surface;
    assert(s.id == 0);
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

test_fd_type :: () {
    fd: Fd;
    fd = cast(Fd) 42;
    raw := cast(s32) fd;
    assert(raw == 42);
    print("  PASS: test_fd_type\n");
}

test_type_metadata :: () {
    md, found := find_type_metadata(type_info(Wl_Display));
    assert(found);
    assert(md.interface_name == "wl_display");
    assert(md.version == 1);
    print("  PASS: test_type_metadata\n");
}

test_request_arg_structs :: () {
    // Verify request arg structs exist and compile
    args: Wl_Surface_Attach_Args;
    assert(args.buffer == 0);
    assert(args.x == 0);
    assert(args.y == 0);
    print("  PASS: test_request_arg_structs\n");
}

test_allocate_id_bounds :: () {
    conn: Connection;
    conn.next_id = 2;
    assert(allocate_id(*conn) == 2);
    assert(allocate_id(*conn) == 3);

    conn.next_id = WAYLAND_SERVER_ID_START - 1;
    assert(allocate_id(*conn) == WAYLAND_SERVER_ID_START - 1);
    assert(conn.next_id == WAYLAND_SERVER_ID_START);
    print("  PASS: test_allocate_id_bounds\n");
}

test_id_cache_reuse :: () {
    conn: Connection;
    conn.next_id = 10;

    cache: Id_Cache;
    first := cache_alloc(*cache, *conn);
    second := cache_alloc(*cache, *conn);

    assert(first == 10);
    assert(second == 11);
    assert(conn.next_id == 12);
    assert(cache.entries.count == 2);
    assert(cache.entries[0].live);
    assert(cache.entries[1].live);

    cache_free(*cache, first);
    assert(!cache.entries[0].live);

    reused := cache_alloc(*cache, *conn);
    assert(reused == first);
    assert(conn.next_id == 12);
    assert(cache.entries[0].live);
    print("  PASS: test_id_cache_reuse\n");
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
    test_fd_type();
    test_type_metadata();
    test_request_arg_structs();
    test_allocate_id_bounds();
    test_id_cache_reuse();
    print("\nAll tests passed.\n");
}
