// hello_window — resizable window with pooled shared memory buffers.
// Discovers native screen resolution, allocates one shm pool sized to it,
// and creates cheap wl_buffer objects on resize. No remapping, no syscalls
// on the resize hot path.

#import,dir "../modules/wayland";
#import "Basic";
#import "POSIX";

BPP :: 4;  // bytes per pixel (XRGB8888)

main :: () {
    if !init_wayland_session() {
        print("Failed to create Wayland session\n");
        return;
    }
    defer end_wayland_session();

    // --- Discover screen dimensions for pool sizing ---
    screens := get_screens_info();
    screen_width:  s32 = 1920;
    screen_height: s32 = 1080;
    if screens.count > 0 {
        screen_width  = screens[0].current_mode.width;
        screen_height = screens[0].current_mode.height;
    }
    pool_size := cast(s32)(screen_width * screen_height * BPP);
    print("Screen: %x%, pool: % bytes\n", screen_width, screen_height, pool_size);

    batch: MessageBuilder;

    // --- Bind wl_shm ---
    shm := Wl_Shm.{ id = allocate_id() };
    wl_registry_bind(*batch, registry(), *shm);
    wayland_send(*batch);
    drain_messages();

    // --- One-time pool allocation ---
    shm_fd := memfd_create("wayland-shm".data, 0);
    if shm_fd < 0 { print("memfd_create failed\n"); return; }
    ftruncate(shm_fd, cast(s64) pool_size);
    pixel_data := mmap(null, cast(u64) pool_size, PROT_READ | PROT_WRITE, MAP_SHARED, shm_fd, 0);
    if pixel_data == cast(*void) -1 { print("mmap failed\n"); return; }
    defer { munmap(pixel_data, cast(u64) pool_size); close(shm_fd); }

    pool := Wl_Shm_Pool.{ id = allocate_id() };
    wl_shm_create_pool(*batch, *shm, pool.id, cast(Fd) shm_fd, pool_size);
    wayland_send(*batch);

    // --- Create surface + window role ---
    surface := Wl_Surface.{ id = allocate_id() };
    xdg_surface := Xdg_Surface.{ id = allocate_id() };
    toplevel := Xdg_Toplevel.{ id = allocate_id() };
    wl_compositor_create_surface(*batch, compositor(), surface.id);
    xdg_wm_base_get_xdg_surface(*batch, wm_base(), xdg_surface.id, *surface);
    xdg_surface_get_toplevel(*batch, *xdg_surface, toplevel.id);
    xdg_toplevel_set_title(*batch, *toplevel, "hello");
    wl_surface_commit(*batch, *surface);
    wayland_send(*batch);

    // --- Wait for initial configure ---
    win_width:  s32 = 640;
    win_height: s32 = 480;
    configure_serial: u32 = 0;
    for session() {
        if it.object_id == toplevel.id && it.opcode == XDG_TOPLEVEL_CONFIGURE {
            args: Xdg_Toplevel_Configure_Args;
            demarshal(*args, it.payload, recv);
            if args.width > 0 && args.height > 0 {
                win_width = args.width;
                win_height = args.height;
            }
        } else if it.object_id == xdg_surface.id && it.opcode == XDG_SURFACE_CONFIGURE {
            configure_serial = read_u32(it.payload);
            break;
        }
    }

    if configure_serial == 0 {
        print("Did not receive xdg_surface.configure\n");
        return;
    }

    // --- Create initial buffer from pool and present ---
    current_buffer := Wl_Buffer.{ id = allocate_id() };
    stride := win_width * BPP;
    paint(pixel_data, win_width, win_height, stride);

    xdg_surface_ack_configure(*batch, *xdg_surface, configure_serial);
    wl_shm_pool_create_buffer(*batch, *pool, current_buffer.id,
        offset = 0, width = win_width, height = win_height,
        stride = stride, format = cast(u32) Wl_Shm_Format.XRGB8888);
    wl_surface_attach(*batch, *surface, *current_buffer, 0, 0);
    wl_surface_damage_buffer(*batch, *surface, 0, 0, win_width, win_height);
    wl_surface_commit(*batch, *surface);
    wayland_send(*batch);

    print("Window: %x%. Close to exit.\n", win_width, win_height);

    // --- Event loop with resize handling ---
    pending_width:  s32 = 0;
    pending_height: s32 = 0;

    for session() {
        if it.object_id == toplevel.id {
            if it.opcode == XDG_TOPLEVEL_CONFIGURE {
                args: Xdg_Toplevel_Configure_Args;
                demarshal(*args, it.payload, recv);
                if args.width > 0 && args.height > 0 {
                    pending_width = args.width;
                    pending_height = args.height;
                }
            } else if it.opcode == XDG_TOPLEVEL_CLOSE {
                print("Close requested.\n");
                break;
            }
        } else if it.object_id == xdg_surface.id && it.opcode == XDG_SURFACE_CONFIGURE {
            serial := read_u32(it.payload);

            if pending_width > 0 && pending_height > 0 &&
               (pending_width != win_width || pending_height != win_height)
            {
                win_width = pending_width;
                win_height = pending_height;
                stride = win_width * BPP;

                // Destroy old buffer, create new from same pool
                old_buffer := current_buffer;
                current_buffer = Wl_Buffer.{ id = allocate_id() };
                paint(pixel_data, win_width, win_height, stride);

                wl_buffer_destroy(*batch, *old_buffer);
                wl_shm_pool_create_buffer(*batch, *pool, current_buffer.id,
                    offset = 0, width = win_width, height = win_height,
                    stride = stride, format = cast(u32) Wl_Shm_Format.XRGB8888);
                wl_surface_attach(*batch, *surface, *current_buffer, 0, 0);
                wl_surface_damage_buffer(*batch, *surface, 0, 0, win_width, win_height);
            }

            xdg_surface_ack_configure(*batch, *xdg_surface, serial);
            wl_surface_commit(*batch, *surface);
            wayland_send(*batch);
        } else if it.object_id == 1 && it.opcode == WL_DISPLAY_ERROR {
            err_obj := read_u32(it.payload);
            err_code := read_u32(it.payload + 4);
            err_msg, _ := read_string(it.payload + 8);
            print("FATAL: wl_display.error object=% code=%: %\n", err_obj, err_code, err_msg);
            break;
        }
    }
}

// Paint the visible region with a dark blue gradient
paint :: (data: *void, width: s32, height: s32, stride: s32) {
    pixels := cast(*u8) data;
    for y: 0..height-1 {
        row := pixels + y * stride;
        for x: 0..width-1 {
            pixel := cast(*u32)(row + x * BPP);
            // Dark blue gradient: brighter toward bottom-right
            r := cast(u32)(x * 30 / width);
            g := cast(u32)(y * 30 / height);
            b := cast(u32)(40 + y * 60 / height);
            pixel.* = (r << 16) | (g << 8) | b;
        }
    }
}

drain_messages :: () {
    recv: ReceiveBuffer;
    wayland_receive(connection(), *recv);
    msg, size := receive_peek_message(*recv);
    while msg != null {
        _, _, msg_size := unpack_header(msg);
        receive_consume_message(*recv, msg_size);
        msg, size = receive_peek_message(*recv);
    }
}
