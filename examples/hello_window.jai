// hello_window — display a black window via wl_shm.
// Full Wayland client in main(), no callbacks, no framework.

Wayland :: #import,dir "../modules/wayland";
#import "Basic";
#import "POSIX";

WIDTH  :: 640;
HEIGHT :: 480;
STRIDE :: WIDTH * 4;         // 4 bytes per pixel (XRGB8888)
BUF_SIZE :: STRIDE * HEIGHT;

main :: () {
    conn: Wayland.Connection;
    if !Wayland.wayland_connect(*conn) {
        print("Could not connect to Wayland compositor.\n");
        return;
    }
    defer Wayland.wayland_disconnect(*conn);

    // Phase 1: discover globals
    globals, registry_id := Wayland.discover_globals(*conn);
    print("% globals available.\n", globals.count);

    // Find the three globals we need
    compositor_name := Wayland.find_global(globals, "wl_compositor");
    shm_name        := Wayland.find_global(globals, "wl_shm");
    wm_base_name    := Wayland.find_global(globals, "xdg_wm_base");

    if compositor_name == 0 || shm_name == 0 || wm_base_name == 0 {
        print("Missing required globals (compositor=%, shm=%, xdg_wm_base=%)\n",
              compositor_name, shm_name, wm_base_name);
        return;
    }

    // Phase 2: bind globals
    registry: Wayland.Wl_Registry;
    registry.id = registry_id;
    registry.version = 1;
    registry.conn = *conn;

    compositor: Wayland.Wl_Compositor;
    compositor.id = Wayland.allocate_id(*conn);
    compositor.version = 6;
    compositor.conn = *conn;
    Wayland.wl_registry_bind(*registry, compositor_name, "wl_compositor", 6, compositor.id);

    wm_base: Wayland.Xdg_Wm_Base;
    wm_base.id = Wayland.allocate_id(*conn);
    wm_base.version = 6;
    wm_base.conn = *conn;
    Wayland.wl_registry_bind(*registry, wm_base_name, "xdg_wm_base", 6, wm_base.id);

    shm: Wayland.Wl_Shm;
    shm.id = Wayland.allocate_id(*conn);
    shm.version = 1;
    shm.conn = *conn;
    Wayland.wl_registry_bind(*registry, shm_name, "wl_shm", 1, shm.id);

    Wayland.connection_flush(*conn);

    // Drain wl_shm.format events (we don't need them, just consume)
    Wayland.connection_read(*conn);
    drain_messages(*conn);

    // Phase 3: create surface + window role
    surface: Wayland.Wl_Surface;
    surface.id = Wayland.allocate_id(*conn);
    surface.version = 6;
    surface.conn = *conn;
    Wayland.wl_compositor_create_surface(*compositor, surface.id);

    xdg_surface: Wayland.Xdg_Surface;
    xdg_surface.id = Wayland.allocate_id(*conn);
    xdg_surface.version = 6;
    xdg_surface.conn = *conn;
    Wayland.xdg_wm_base_get_xdg_surface(*wm_base, xdg_surface.id, *surface);

    toplevel: Wayland.Xdg_Toplevel;
    toplevel.id = Wayland.allocate_id(*conn);
    toplevel.version = 6;
    toplevel.conn = *conn;
    Wayland.xdg_surface_get_toplevel(*xdg_surface, toplevel.id);

    Wayland.xdg_toplevel_set_title(*toplevel, "hello");
    Wayland.wl_surface_commit(*surface);  // empty commit triggers configure
    Wayland.connection_flush(*conn);

    // Wait for xdg_surface.configure
    configure_serial: u32 = 0;
    while configure_serial == 0 && Wayland.connection_read(*conn) > 0 {
        msg, size := Wayland.connection_peek_message(*conn);
        while msg != null {
            object_id, opcode, msg_size := Wayland.unpack_header(msg);
            payload := msg + Wayland.HEADER_SIZE;

            if object_id == xdg_surface.id && opcode == Wayland.XDG_SURFACE_CONFIGURE {
                configure_serial = Wayland.read_u32(payload);
            } else if object_id == wm_base.id && opcode == Wayland.XDG_WM_BASE_PING {
                serial := Wayland.read_u32(payload);
                Wayland.xdg_wm_base_pong(*wm_base, serial);
            }

            Wayland.connection_consume_message(*conn, msg_size);
            msg, size = Wayland.connection_peek_message(*conn);
        }
    }

    if configure_serial == 0 {
        print("Did not receive xdg_surface.configure\n");
        return;
    }

    Wayland.xdg_surface_ack_configure(*xdg_surface, configure_serial);

    // Phase 4: create shared memory buffer
    fd := Wayland.memfd_create("wayland-shm".data, 0);
    if fd < 0 {
        print("memfd_create failed\n");
        return;
    }
    ftruncate(fd, BUF_SIZE);
    data := mmap(null, BUF_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if data == cast(*void) -1 {
        print("mmap failed\n");
        return;
    }
    memset(data, 0, BUF_SIZE);  // black pixels

    pool: Wayland.Wl_Shm_Pool;
    pool.id = Wayland.allocate_id(*conn);
    pool.version = 1;
    pool.conn = *conn;
    Wayland.wl_shm_create_pool(*shm, pool.id, cast(Wayland.Fd) fd, cast(s32) BUF_SIZE);

    buffer: Wayland.Wl_Buffer;
    buffer.id = Wayland.allocate_id(*conn);
    buffer.version = 1;
    buffer.conn = *conn;
    Wayland.wl_shm_pool_create_buffer(*pool, buffer.id,
        offset = 0, width = WIDTH, height = HEIGHT,
        stride = STRIDE, format = cast(u32) Wayland.Wl_Shm_Format.XRGB8888);

    Wayland.wl_shm_pool_destroy(*pool);

    // Phase 5: attach and show
    Wayland.wl_surface_attach(*surface, *buffer, 0, 0);
    Wayland.wl_surface_damage_buffer(*surface, 0, 0, WIDTH, HEIGHT);
    Wayland.wl_surface_commit(*surface);
    Wayland.connection_flush(*conn);

    print("Window displayed. Close the window or press Ctrl+C to exit.\n");

    // Phase 6: event loop — respond to pings, handle close
    while Wayland.connection_read(*conn) > 0 {
        msg, size := Wayland.connection_peek_message(*conn);
        while msg != null {
            object_id, opcode, msg_size := Wayland.unpack_header(msg);
            payload := msg + Wayland.HEADER_SIZE;

            if object_id == wm_base.id && opcode == Wayland.XDG_WM_BASE_PING {
                serial := Wayland.read_u32(payload);
                Wayland.xdg_wm_base_pong(*wm_base, serial);
                Wayland.connection_flush(*conn);
            } else if object_id == toplevel.id && opcode == Wayland.XDG_TOPLEVEL_CLOSE {
                print("Close requested.\n");
                munmap(data, BUF_SIZE);
                close(fd);
                return;
            } else if object_id == 1 && opcode == Wayland.WL_DISPLAY_ERROR {
                err_obj := Wayland.read_u32(payload);
                err_code := Wayland.read_u32(payload + 4);
                err_msg, _ := Wayland.read_string(payload + 8);
                print("FATAL: wl_display.error object=% code=%: %\n", err_obj, err_code, err_msg);
                return;
            }

            Wayland.connection_consume_message(*conn, msg_size);
            msg, size = Wayland.connection_peek_message(*conn);
        }
    }

    munmap(data, BUF_SIZE);
    close(fd);
}

// Drain all pending messages from the connection buffer.
drain_messages :: (conn: *Wayland.Connection) {
    msg, size := Wayland.connection_peek_message(conn);
    while msg != null {
        _, _, msg_size := Wayland.unpack_header(msg);
        Wayland.connection_consume_message(conn, msg_size);
        msg, size = Wayland.connection_peek_message(conn);
    }
}
