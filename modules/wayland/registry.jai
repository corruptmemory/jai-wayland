// Registry discovery helpers — plain functions, no inversion of control.

#import "Basic";

Global_Info :: struct {
    name: u32;
    interface_name: string;   // heap-allocated copy, stable after return
    version: u32;
}

// Perform the wl_display.get_registry + wl_display.sync roundtrip.
// Returns all globals the compositor advertised, plus the registry ID
// (needed for subsequent wl_registry_bind calls).
discover_globals :: (conn: *Connection) -> [] Global_Info, u32 {
    display := init_display(conn);

    registry_id := allocate_id(conn);
    wl_display_get_registry(*display, registry_id);
    sync_id := allocate_id(conn);
    wl_display_sync(*display, sync_id);
    connection_flush(conn);

    globals: [..] Global_Info;

    done := false;
    while !done && connection_read(conn) > 0 {
        msg, size := connection_peek_message(conn);
        while msg != null {
            object_id, opcode, _ := unpack_header(msg);
            payload := msg + HEADER_SIZE;

            if object_id == registry_id {
                if opcode == WL_REGISTRY_GLOBAL {
                    offset: u32 = 0;
                    gname := read_u32(payload + offset);
                    offset += 4;
                    iface, iface_bytes := read_string(payload + offset);
                    offset += iface_bytes;
                    ver := read_u32(payload + offset);
                    array_add(*globals, .{
                        name = gname,
                        interface_name = copy_string(iface),
                        version = ver,
                    });
                }
            } else if object_id == sync_id {
                done = true;
            }

            connection_consume_message(conn, size);
            msg, size = connection_peek_message(conn);
        }
    }

    return globals, registry_id;
}

// Same as above, but fills in registry
discover_globals :: () -> u32 {
    using context.wayland_session;
    display := init_display(*conn);

    registry_id := allocate_id(*conn);
    wl_display_get_registry(*display, registry_id);
    sync_id := allocate_id(*conn);
    wl_display_sync(*display, sync_id);
    connection_flush(*conn);

    done := false;
    while !done && connection_read(*conn) > 0 {
        msg, size := connection_peek_message(*conn);
        while msg != null {
            object_id, opcode, _ := unpack_header(msg);
            payload := msg + HEADER_SIZE;

            if object_id == registry_id {
                if opcode == WL_REGISTRY_GLOBAL {
                    offset: u32 = 0;
                    gname := read_u32(payload + offset);
                    offset += 4;
                    iface, iface_bytes := read_string(payload + offset);
                    offset += iface_bytes;
                    ver := read_u32(payload + offset);
                    array_add(*globals, .{
                        name = gname,
                        interface_name = copy_string(iface),
                        version = ver,
                    });
                }
            } else if object_id == sync_id {
                done = true;
            }

            connection_consume_message(*conn, size);
            msg, size = connection_peek_message(*conn);
        }
    }

    return registry_id;
}


// Look up a global by interface name. Returns the global's name (u32)
// for use with wl_registry_bind, or 0 if not found.
find_global :: (globals: [] Global_Info, iface_name: string) -> u32 {
    for globals {
        if it.interface_name == iface_name  return it.name;
    }
    return 0;
}

// Same as above, but uses the context
find_global :: (iface_name: string) -> u32 {
    for context.wayland_session.globals {
        if it.interface_name == iface_name  return it.name;
    }
    return 0;
}

// Initialize a wl_display proxy. Always ID 1, always version 1.
// Advances the ID allocator past 1 so subsequent allocate_id calls start at 2.
init_display :: (conn: *Connection) -> Wl_Display {
    display: Wl_Display;
    display.id = 1;
    display.version = 1;
    display.conn = conn;
    // Ensure the allocator skips past ID 1
    if conn.next_id <= 1  conn.next_id = 2;
    return display;
}
