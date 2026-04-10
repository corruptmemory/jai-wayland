// hello_window — resizable window with pooled shared memory buffers.
// Discovers native screen resolution, allocates one shm pool sized to it,
// and creates cheap wl_buffer objects on resize. No remapping, no syscalls
// on the resize hot path.
// Keyboard: r/g/b switch gradient color, q quits.
// Pointer: click prints coordinates and cycles color.

#import,dir "../modules/wayland";
#import "Basic";
#import "POSIX";

BPP :: 4;  // bytes per pixel (XRGB8888)

COLORS :: Color.[.RED, .GREEN, .BLUE];
Color :: enum { RED; GREEN; BLUE; }

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

    // --- Acquire input devices ---
    seats := get_seats_info();
    keyboards := get_keyboards_info(seats);
    pointers := get_pointers_info(seats);
    keymap: Keymap;
    if keyboards.count > 0 {
        keymap_ok: bool;
        keymap, keymap_ok = parse_keymap_fd(keyboards[0].keymap_fd, keyboards[0].keymap_size);
        if !keymap_ok  print("Warning: could not parse keymap\n");
    }
    print("Input: % seat(s), % keyboard(s), % pointer(s)\n", seats.count, keyboards.count, pointers.count);
    if keyboards.count > 0  print("  Keys: r/g/b = color, q = quit\n");
    if pointers.count > 0   print("  Click: print coords + cycle color\n");

    batch: MessageBuilder;

    // --- Bind wl_shm ---
    shm := Wl_Shm.{ id = allocate_id() };
    wl_registry_bind(*batch, registry(), *shm);
    wayland_send(*batch, drain=true);

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
            unmarshal(*args, it.payload, recv);
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
    current_color := Color.BLUE;
    current_buffer := Wl_Buffer.{ id = allocate_id() };
    stride := win_width * BPP;
    paint(pixel_data, win_width, win_height, stride, current_color);

    xdg_surface_ack_configure(*batch, *xdg_surface, configure_serial);
    wl_shm_pool_create_buffer(*batch, *pool, current_buffer.id,
        offset = 0, width = win_width, height = win_height,
        stride = stride, format = cast(u32) Wl_Shm_Format.XRGB8888);
    wl_surface_attach(*batch, *surface, *current_buffer, 0, 0);
    wl_surface_damage_buffer(*batch, *surface, 0, 0, win_width, win_height);
    wl_surface_commit(*batch, *surface);
    wayland_send(*batch);

    print("Window: %x%. Close to exit.\n", win_width, win_height);

    // --- Event loop with resize + input handling ---
    pending_width:  s32 = 0;
    pending_height: s32 = 0;
    pointer_x: float64 = 0;
    pointer_y: float64 = 0;

    for session() {
        needs_repaint := false;
        defer if needs_repaint {
            paint(pixel_data, win_width, win_height, stride, current_color);
            wl_surface_attach(*batch, *surface, *current_buffer, 0, 0);
            wl_surface_damage_buffer(*batch, *surface, 0, 0, win_width, win_height);
            wl_surface_commit(*batch, *surface);
            wayland_send(*batch);
        }

        kb_event, is_kb := get_keyboard_event(it, keyboards, recv);
        if is_kb {
            if kb_event.kind == .KEY && kb_event.key.state == cast(u32) Wl_Keyboard_Key_State.PRESSED {
                keysym := keymap_get_keysym(*keymap, kb_event.key.key);
                if keysym == {
                  case #char "q";
                    print("Quit requested.\n");
                    break;
                  case #char "r"; current_color = .RED;   needs_repaint = true;
                  case #char "g"; current_color = .GREEN; needs_repaint = true;
                  case #char "b"; current_color = .BLUE;  needs_repaint = true;
                }
            }
            continue;
        }

        ptr_event, is_ptr := get_pointer_event(it, pointers, recv);
        if is_ptr {
            if ptr_event.kind == {
              case .ENTER;
                pointer_x = fixed_to_float(ptr_event.enter.surface_x);
                pointer_y = fixed_to_float(ptr_event.enter.surface_y);
              case .MOTION;
                pointer_x = fixed_to_float(ptr_event.motion.surface_x);
                pointer_y = fixed_to_float(ptr_event.motion.surface_y);
              case .BUTTON;
                if ptr_event.button.state == cast(u32) Wl_Pointer_Button_State.PRESSED {
                    print("Click at (%, %)\n", pointer_x, pointer_y);
                    // Cycle to next color
                    for COLORS  if it == current_color {
                        current_color = COLORS[(it_index + 1) % COLORS.count];
                        break;
                    }
                    needs_repaint = true;
                }
            }
            continue;
        }

        if it.object_id == toplevel.id {
            if it.opcode == XDG_TOPLEVEL_CONFIGURE {
                args: Xdg_Toplevel_Configure_Args;
                unmarshal(*args, it.payload, recv);
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

                wl_buffer_destroy(*batch, *old_buffer);
                wl_shm_pool_create_buffer(*batch, *pool, current_buffer.id,
                    offset = 0, width = win_width, height = win_height,
                    stride = stride, format = cast(u32) Wl_Shm_Format.XRGB8888);
                needs_repaint = true;
            }

            xdg_surface_ack_configure(*batch, *xdg_surface, serial);
            if !needs_repaint {
                wl_surface_commit(*batch, *surface);
                wayland_send(*batch);
            }
        }
    }
}

// Paint the visible region with a gradient in the given color
paint :: (data: *void, width: s32, height: s32, stride: s32, color: Color) {
    pixels := cast(*u8) data;
    for y: 0..height-1 {
        row := pixels + y * stride;
        for x: 0..width-1 {
            pixel := cast(*u32)(row + x * BPP);
            // Gradient: primary channel 40-100, other channels 0-30
            primary := cast(u32)(40 + y * 60 / height);
            accent_x := cast(u32)(x * 30 / width);
            accent_y := cast(u32)(y * 30 / height);
            if color == {
              case .RED;   pixel.* = (primary << 16) | (accent_y << 8) | accent_x;
              case .GREEN; pixel.* = (accent_x << 16) | (primary << 8) | accent_y;
              case .BLUE;  pixel.* = (accent_x << 16) | (accent_y << 8) | primary;
            }
        }
    }
}

