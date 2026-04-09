// Output discovery — typed wl_output event processing using demarshal.

#import "Basic";

Mode_Info :: struct {
    width: s32;
    height: s32;
    refresh: s32;    // in mHz (e.g., 60000 = 60Hz)
    flags: u32;      // Wl_Output_Mode flags (CURRENT, PREFERRED)
}

Screen_Info :: struct {
    name: string;
    description: string;
    current_mode: Mode_Info;
    modes: [..] Mode_Info;
    scale_factor: s32;
    x: s32;              // compositor-space position
    y: s32;
    physical_width: s32;  // mm
    physical_height: s32; // mm
    make: string;
    model: string;
    transform: s32;
    subpixel: s32;
}

// Discover all outputs from the compositor. Binds each wl_output global,
// performs a sync roundtrip, collects typed events via demarshal_event,
// and returns an array of Screen_Info.
// Uses the context session (must be initialized).
get_screens_info :: () -> [] Screen_Info {
    s := context.wayland_session;

    // Find all wl_output globals
    Output_Binding :: struct {
        global: Global_Info;
        output: Wl_Output;
    }
    bindings: [..] Output_Binding;
    bindings.allocator = temp;

    for s.globals {
        if it.interface_name == "wl_output" {
            array_add(*bindings, .{ global = it });
        }
    }

    if bindings.count == 0  return .[];

    // Bind each output, then sync (IDs must be allocated in wire order)
    display := Wl_Display.{ id = 1 };

    batch: MessageBuilder;
    for *binding: bindings {
        binding.output.id = allocate_id(*s.conn);
        bind_to_global(*batch, *s.registry, binding.global, binding.output.id,
            WL_OUTPUT_INTERFACE.name, WL_OUTPUT_INTERFACE.version);
    }
    sync_id := allocate_id(*s.conn);
    wl_display_sync(*batch, *display, sync_id);
    wayland_send(*s.conn, *batch);

    // Pre-allocate one screen per binding (index matches binding index)
    screens: [..] Screen_Info;
    for bindings {
        screen := array_add(*screens);
        screen.scale_factor = 1;  // default
    }

    recv: ReceiveBuffer;
    done := false;
    while !done && wayland_receive(*s.conn, *recv) > 0 {
        msg, size := receive_peek_message(*recv);
        while msg != null {
            object_id, opcode, msg_size := unpack_header(msg);
            payload := msg + HEADER_SIZE;

            if object_id == sync_id {
                done = true;
            } else {
                // Find which output this event belongs to
                for binding, bi: bindings {
                    if object_id == binding.output.id {
                        screen := *screens[bi];
                        event: Wl_Output_Event;
                        demarshal_event(*event, opcode, payload, *recv);

                        if event.kind == {
                          case .GEOMETRY;
                            screen.x = event.geometry.x;
                            screen.y = event.geometry.y;
                            screen.physical_width = event.geometry.physical_width;
                            screen.physical_height = event.geometry.physical_height;
                            screen.subpixel = event.geometry.subpixel;
                            screen.make = copy_string(event.geometry.make);
                            screen.model = copy_string(event.geometry.model);
                            screen.transform = event.geometry.transform;
                          case .MODE;
                            mode := Mode_Info.{
                                width = event.mode.width,
                                height = event.mode.height,
                                refresh = event.mode.refresh,
                                flags = event.mode.flags,
                            };
                            array_add(*screen.modes, mode);
                            if event.mode.flags & cast(u32) Wl_Output_Mode.CURRENT {
                                screen.current_mode = mode;
                            }
                          case .SCALE;
                            screen.scale_factor = event.scale.factor;
                          case .NAME;
                            screen.name = copy_string(event.name.name);
                          case .DESCRIPTION;
                            screen.description = copy_string(event.description.description);
                          case .DONE;
                            // All properties for this output have been sent
                        }
                        break;
                    }
                }
            }

            receive_consume_message(*recv, size);
            msg, size = receive_peek_message(*recv);
        }
    }

    return screens;
}

#scope_file

// Bind to a specific global (by its registry name), bypassing the
// find-first-matching behavior of the standard wl_registry_bind overloads.
bind_to_global :: (batch: *MessageBuilder, reg: *Wl_Registry, global: Global_Info,
                   new_id: u32, iface_name: string, supported_version: u32) {
    version: u32 = ifx global.version < supported_version then global.version else supported_version;

    _buf: [MAX_MESSAGE_SIZE] u8;
    write_u32(_buf.data, reg.id);
    _offset: u32 = HEADER_SIZE;
    write_u32(_buf.data + _offset, global.name); _offset += 4;
    _offset += write_string(_buf.data + _offset, iface_name);
    write_u32(_buf.data + _offset, version); _offset += 4;
    write_u32(_buf.data + _offset, new_id); _offset += 4;
    write_u32(_buf.data + 4, cast(u32)(cast(u32) _offset << 16) | cast(u32) WL_REGISTRY_BIND);
    message_queue(batch, _buf.data, _offset);
}
