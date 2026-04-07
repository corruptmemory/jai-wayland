// hello_window — display a black window via wl_shm.
// Full Wayland client using the session API, no callbacks, no framework.

#import,dir "../modules/wayland";
#import "Basic";
#import "POSIX";

WIDTH  :: 640;
HEIGHT :: 480;
STRIDE :: WIDTH * 4;         // 4 bytes per pixel (XRGB8888)
BUF_SIZE :: STRIDE * HEIGHT;

main :: () {
    if !init_wayland_session() {
        print("Failed to create Wayland session\n");
        return;
    }
    defer end_wayland_session();

    // Bind wl_shm
    shm := Wl_Shm.{ id = allocate_id() };
    {
        batch: MessageBuilder;
        wl_registry_bind(*batch, registry(), shm_name(), "wl_shm", 1, shm.id);
        wayland_send(*batch);
    }

    // Drain wl_shm.format events
    drain_messages();

    // Create surface + window role
    surface := Wl_Surface.{ id = allocate_id() };
    xdg_surface := Xdg_Surface.{ id = allocate_id() };
    toplevel := Xdg_Toplevel.{ id = allocate_id() };
    {
        batch: MessageBuilder;
        wl_compositor_create_surface(*batch, compositor(), surface.id);
        xdg_wm_base_get_xdg_surface(*batch, wm_base(), xdg_surface.id, *surface);
        xdg_surface_get_toplevel(*batch, *xdg_surface, toplevel.id);
        xdg_toplevel_set_title(*batch, *toplevel, "hello");
        wl_surface_commit(*batch, *surface);
        wayland_send(*batch);
    }

    // Wait for xdg_surface.configure
    configure_serial: u32 = 0;
    for session() {
        if it.object_id == xdg_surface.id && it.opcode == XDG_SURFACE_CONFIGURE {
            configure_serial = read_u32(it.payload);
            break;
        }
    }

    if configure_serial == 0 {
        print("Did not receive xdg_surface.configure\n");
        return;
    }

    // Create shared memory buffer
    fd := memfd_create("wayland-shm".data, 0);
    if fd < 0 { print("memfd_create failed\n"); return; }
    ftruncate(fd, BUF_SIZE);
    data := mmap(null, BUF_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if data == cast(*void) -1 { print("mmap failed\n"); return; }
    memset(data, 0, BUF_SIZE);

    pool := Wl_Shm_Pool.{ id = allocate_id() };
    buffer := Wl_Buffer.{ id = allocate_id() };
    {
        batch: MessageBuilder;
        xdg_surface_ack_configure(*batch, *xdg_surface, configure_serial);
        wl_shm_create_pool(*batch, *shm, pool.id, cast(Fd) fd, cast(s32) BUF_SIZE);
        wl_shm_pool_create_buffer(*batch, *pool, buffer.id,
            offset = 0, width = WIDTH, height = HEIGHT,
            stride = STRIDE, format = cast(u32) Wl_Shm_Format.XRGB8888);
        wl_shm_pool_destroy(*batch, *pool);
        wl_surface_attach(*batch, *surface, *buffer, 0, 0);
        wl_surface_damage_buffer(*batch, *surface, 0, 0, WIDTH, HEIGHT);
        wl_surface_commit(*batch, *surface);
        wayland_send(*batch);
    }

    print("Window displayed. Close the window or press Ctrl+C to exit.\n");

    // Event loop — ping/pong handled by for_expansion
    for session() {
        if it.object_id == toplevel.id && it.opcode == XDG_TOPLEVEL_CLOSE {
            print("Close requested.\n");
            break;
        } else if it.object_id == 1 && it.opcode == WL_DISPLAY_ERROR {
            err_obj := read_u32(it.payload);
            err_code := read_u32(it.payload + 4);
            err_msg, _ := read_string(it.payload + 8);
            print("FATAL: wl_display.error object=% code=%: %\n", err_obj, err_code, err_msg);
            break;
        }
    }

    munmap(data, BUF_SIZE);
    close(fd);
}

drain_messages :: () {
    recv := *context.wayland_session.recv;
    wayland_receive(connection(), recv);
    msg, size := receive_peek_message(recv);
    while msg != null {
        _, _, msg_size := unpack_header(msg);
        receive_consume_message(recv, msg_size);
        msg, size = receive_peek_message(recv);
    }
}
