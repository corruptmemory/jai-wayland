#import "Basic";
#import "Pool";

WaylandSession :: struct {
    pool: Pool;
    conn: Connection;
    registry: Wl_Registry;
    compositor: Wl_Compositor;
    wm_base: Xdg_Wm_Base;
    compositor_name: u32;
    shm_name: u32;
    wm_base_name: u32;
    globals: [..] Global_Info;
}

#add_context wayland_session: *WaylandSession;

WaylandMessageHeader :: struct {
    object_id: u32;
    opcode: u16;
    msg_size: u32;
    payload: *u8;
}

for_expansion :: (session: *WaylandSession, body: Code, flags: For_Flags) #expand {
    {
        recv: ReceiveBuffer;
        while bts := wayland_receive(*session.conn, *recv) {
            if bts <= 0 break;
            msg, size := receive_peek_message(*recv);
            while msg != null {
                header: WaylandMessageHeader;
                header.object_id, header.opcode, header.msg_size = unpack_header(msg);
                header.payload = msg + HEADER_SIZE;

                if header.object_id == session.wm_base.id && header.opcode == XDG_WM_BASE_PING {
                    serial := read_u32(header.payload);
                    ping_batch: MessageBuilder;
                    xdg_wm_base_pong(*ping_batch, *session.wm_base, serial);
                    wayland_send(*session.conn, *ping_batch);
                } else {
                    `it := header;
                    `it_index := 0;
                    #insert(break=break bts) body;
                }

                receive_consume_message(*recv, header.msg_size);
                msg, size = receive_peek_message(*recv);
            }
        }
    }
}

init_wayland_session :: () -> bool {
    s := New(WaylandSession);
    context.wayland_session = s;
    set_allocators(*s.pool);

    if !wayland_connect(*s.conn) {
        print("Could not connect to Wayland compositor.\n");
        release(*s.pool);
        free(s);
        return false;
    }

    // All allocations during discovery (globals array, copy_string'd interface
    // names) go through the pool — released in one shot by end_wayland_session.
    new_context := context;
    new_context.allocator.proc = pool_allocator_proc;
    new_context.allocator.data = *s.pool;
    push_context new_context {
        discover_globals();
    }

    s.compositor_name = find_global("wl_compositor");
    s.shm_name        = find_global("wl_shm");
    s.wm_base_name    = find_global("xdg_wm_base");

    if s.compositor_name == 0 || s.shm_name == 0 || s.wm_base_name == 0 {
        print("Missing required globals\n");
        wayland_disconnect(*s.conn);
        release(*s.pool);
        free(s);
        return false;
    }

    s.compositor = Wl_Compositor.{ id = allocate_id() };
    s.wm_base    = Xdg_Wm_Base.{ id = allocate_id() };

    batch: MessageBuilder;
    wl_registry_bind(*batch, *s.registry, s.compositor_name, "wl_compositor", 6, s.compositor.id);
    wl_registry_bind(*batch, *s.registry, s.wm_base_name, "xdg_wm_base", 6, s.wm_base.id);
    wayland_send(*s.conn, *batch);

    return true;
}

end_wayland_session :: () {
    wayland_disconnect(*context.wayland_session.conn);
    release(*context.wayland_session.pool);
    free(context.wayland_session);
}

session :: inline () -> *WaylandSession {
    return context.wayland_session;
}

connection :: inline () -> *Connection {
    return *context.wayland_session.conn;
}

registry :: inline () -> *Wl_Registry {
    return *context.wayland_session.registry;
}

compositor :: inline () -> *Wl_Compositor {
    return *context.wayland_session.compositor;
}

wm_base :: inline () -> *Xdg_Wm_Base {
    return *context.wayland_session.wm_base;
}

shm_name :: inline () -> u32 {
    return context.wayland_session.shm_name;
}

allocate_id :: inline () -> u32 {
    return allocate_id(*context.wayland_session.conn);
}

wayland_send :: (batch: *MessageBuilder) -> bool {
    return wayland_send(*context.wayland_session.conn, batch);
}
