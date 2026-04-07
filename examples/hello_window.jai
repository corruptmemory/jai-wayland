// hello_window — display a black window via wl_shm.
// Full Wayland client in main(), no callbacks, no framework.

#import,dir "../modules/wayland";
#import "Basic";
#import "POSIX";

WIDTH  :: 640;
HEIGHT :: 480;
STRIDE :: WIDTH * 4;         // 4 bytes per pixel (XRGB8888)
BUF_SIZE :: STRIDE * HEIGHT;

main :: () {
    if !init_wayland_session() {
        printf("Failed to create Wayland session\n");
    }
    defer end_wayland_session();

    shm: Wl_Shm;
    shm.id = allocate_id();
    shm.version = 1;
    shm.conn = connection();
    wl_registry_bind(registry(), shm_name(), "wl_shm", 1, shm.id);

    print("wl_registry_bind\n");
    connection_flush();

    // Drain wl_shm.format events (we don't need them, just consume)
    connection_read();
    drain_messages();

    // Phase 3: create surface + window role
    surface: Wl_Surface;
    surface.id = allocate_id();
    surface.version = 6;
    surface.conn = connection();
    wl_compositor_create_surface(compositor(), surface.id);

    xdg_surface: Xdg_Surface;
    xdg_surface.id = allocate_id();
    xdg_surface.version = 6;
    xdg_surface.conn = connection();
    xdg_wm_base_get_xdg_surface(wm_base(), xdg_surface.id, *surface);

    toplevel: Xdg_Toplevel;
    toplevel.id = allocate_id();
    toplevel.version = 6;
    toplevel.conn = connection();
    xdg_surface_get_toplevel(*xdg_surface, toplevel.id);

    xdg_toplevel_set_title(*toplevel, "hello");
    wl_surface_commit(*surface);  // empty commit triggers configure

    print("wl_compositor_create_surface, xdg_wm_base_get_xdg_surface, xdg_surface_get_toplevel, xdg_toplevel_set_title, wl_surface_commit\n");
    connection_flush();

    // Wait for xdg_surface.configure
    configure_serial: u32 = 0;
    for session() {
        print("it.object_id = %\n", it.object_id);
        if it.object_id == xdg_surface.id && it.opcode == XDG_SURFACE_CONFIGURE {
            configure_serial = read_u32(it.payload);
            break;
        }
    }

    if configure_serial == 0 {
        print("Did not receive xdg_surface.configure\n");
        return;
    }

    xdg_surface_ack_configure(*xdg_surface, configure_serial);

    // Phase 4: create shared memory buffer
    fd := memfd_create("wayland-shm".data, 0);
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

    pool: Wl_Shm_Pool;
    pool.id = allocate_id();
    pool.version = 1;
    pool.conn = connection();
    wl_shm_create_pool(*shm, pool.id, cast(Fd) fd, cast(s32) BUF_SIZE);

    buffer: Wl_Buffer;
    buffer.id = allocate_id();
    buffer.version = 1;
    buffer.conn = connection();
    wl_shm_pool_create_buffer(*pool, buffer.id,
        offset = 0, width = WIDTH, height = HEIGHT,
        stride = STRIDE, format = cast(u32) Wl_Shm_Format.XRGB8888);

    wl_shm_pool_destroy(*pool);

    // Phase 5: attach and show
    wl_surface_attach(*surface, *buffer, 0, 0);
    wl_surface_damage_buffer(*surface, 0, 0, WIDTH, HEIGHT);
    wl_surface_commit(*surface);
    connection_flush();

    print("Window displayed. Close the window or press Ctrl+C to exit.\n");

    // Phase 6: event loop — respond to pings, handle close
    for session() {
        if it.object_id == toplevel.id && it.opcode == XDG_TOPLEVEL_CLOSE {
            print("Close requested.\n");
            munmap(data, BUF_SIZE);
            close(fd);
            return;
        } else if it.object_id == 1 && it.opcode == WL_DISPLAY_ERROR {
            err_obj := read_u32(it.payload);
            err_code := read_u32(it.payload + 4);
            err_msg, _ := read_string(it.payload + 8);
            print("FATAL: wl_display.error object=% code=%: %\n", err_obj, err_code, err_msg);
            return;
        }
    }

    munmap(data, BUF_SIZE);
    close(fd);
}

// Drain all pending messages from the connection buffer.
drain_messages :: (conn: *Connection) {
    msg, size := connection_peek_message(conn);
    print("draining: %\n", size);
    while msg != null {
        _, _, msg_size := unpack_header(msg);
        connection_consume_message(conn, msg_size);
        msg, size = connection_peek_message(conn);
    }
}

drain_messages :: () {
    drain_messages(connection());
}