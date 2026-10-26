// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jim Powers

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
    sync_id := allocate_id(conn);

    batch: MessageBuilder;
    wl_display_get_registry(*batch, *display, registry_id);
    wl_display_sync(*batch, *display, sync_id);
    wayland_send(conn, *batch);

    recv: ReceiveBuffer;
    globals: [..] Global_Info;

    done := false;
    while !done && wayland_receive(conn, *recv) > 0 {
        msg, size := receive_peek_message(*recv);
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

            receive_consume_message(*recv, size);
            msg, size = receive_peek_message(*recv);
        }
    }

    return globals, registry_id;
}

// Same as above, but fills in session registry and globals.
discover_globals :: () -> u32 {
    s := context.wayland_session;
    display := init_display(*s.conn);

    registry_id := allocate_id(*s.conn);
    sync_id := allocate_id(*s.conn);

    batch: MessageBuilder;
    wl_display_get_registry(*batch, *display, registry_id);
    wl_display_sync(*batch, *display, sync_id);
    wayland_send(*s.conn, *batch);

    recv: ReceiveBuffer;
    done := false;
    while !done && wayland_receive(*s.conn, *recv) > 0 {
        msg, size := receive_peek_message(*recv);
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
                    array_add(*s.globals, .{
                        name = gname,
                        interface_name = copy_string(iface),
                        version = ver,
                    });
                }
            } else if object_id == sync_id {
                done = true;
            }

            receive_consume_message(*recv, size);
            msg, size = receive_peek_message(*recv);
        }
    }

    s.registry = Wl_Registry.{ id = registry_id };
    return registry_id;
}

// Look up a global by interface name.
get_global :: (globals: [] Global_Info, iface_name: string) -> Global_Info, bool {
    for globals {
        if it.interface_name == iface_name  return it, true;
    }
    return .{}, false;
}

// Same as above, but uses the context session.
get_global :: (iface_name: string) -> Global_Info, bool {
    for context.wayland_session.globals {
        if it.interface_name == iface_name  return it, true;
    }
    return .{}, false;
}

// Overload 1: common case — pass the struct, type known at compile time.
// Version negotiated automatically as min(advertised, supported).
wl_registry_bind :: (batch: *MessageBuilder, self: *Wl_Registry, target: *$T/interface Versionable) -> bool {
    return wl_registry_bind(batch, self, target.id, type_info(T));
}

// Overload 2: explicit type + id
wl_registry_bind :: (batch: *MessageBuilder, self: *Wl_Registry, id: u32, $T: Type) -> bool {
    return wl_registry_bind(batch, self, id, type_info(T));
}

// Overload 3: fully dynamic — id + *Type_Info.
// Binds the FIRST global advertising the type's interface (get_global), which is
// right for singletons (wl_compositor, xdg_wm_base, ...). For an interface the
// compositor can advertise several times (wl_output, wl_seat), loop over the
// globals and use overload 4.
wl_registry_bind :: (batch: *MessageBuilder, self: *Wl_Registry, id: u32, ti: *Type_Info) -> bool {
    md, found := find_type_metadata(ti);
    if !found return false;

    gi, gfound := get_global(md.interface_name);
    if !gfound return false;

    return wl_registry_bind(batch, self, gi, id, ti);
}

// Overload 4: bind the specific global the caller names by its Global_Info.
// Several globals can share an interface name (one wl_output per monitor, one
// wl_seat per seat), each with its own compositor-assigned gi.name; binding each
// of them needs the Global_Info, since get_global() only finds the first.
// The one place the wl_registry.bind wire bytes are written. Pure wire: reads
// no context session.
// Wire: header, gi.name u32, interface string, min(gi.version, supported) u32, id u32.
wl_registry_bind :: (batch: *MessageBuilder, self: *Wl_Registry, gi: Global_Info, id: u32, ti: *Type_Info) -> bool {
    md, found := find_type_metadata(ti);
    if !found return false;

    version: u32 = ifx gi.version < md.version then gi.version else md.version;

    buf: [MAX_MESSAGE_SIZE] u8;
    offset: u32 = HEADER_SIZE;
    write_u32(buf.data + offset, gi.name); offset += 4;
    offset += write_string(buf.data + offset, md.interface_name);
    write_u32(buf.data + offset, version); offset += 4;
    write_u32(buf.data + offset, id); offset += 4;
    pack_header(buf.data, self.id, WL_REGISTRY_BIND, offset);
    message_queue(batch, buf.data, offset);
    return true;
}

// Initialize a wl_display proxy. Always ID 1.
// Advances the ID allocator past 1 so subsequent allocate_id calls start at 2.
init_display :: (conn: *Connection) -> Wl_Display {
    display: Wl_Display;
    display.id = 1;
    if conn.next_id <= 1  conn.next_id = 2;
    return display;
}
