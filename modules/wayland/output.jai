// Output discovery — typed wl_output event processing using unmarshal.

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
// performs a sync roundtrip, collects typed events via unmarshal_event,
// and returns an array of Screen_Info.
// Uses the context session (must be initialized).
get_screens_info :: () -> [] Screen_Info {
    // Count wl_output globals
    output_count: int;
    for globals() {
        if it.interface_name == "wl_output"  output_count += 1;
    }
    if output_count == 0  return .[];

    // Bind each output, then sync (IDs must be allocated in wire order)
    outputs: [..] Wl_Output;
    outputs.allocator = temp;

    display := Wl_Display.{ id = 1 };
    batch: MessageBuilder;
    for 1..output_count {
        output := array_add(*outputs);
        output.id = allocate_id();
        wl_registry_bind(*batch, registry(), output);
    }
    sync_id := allocate_id();
    wl_display_sync(*batch, *display, sync_id);
    wayland_send(*batch);

    // Pre-allocate one screen per output (index matches output index)
    screens: [..] Screen_Info;
    for outputs {
        screen := array_add(*screens);
        screen.scale_factor = 1;  // default
    }

    for session() {
        if it.object_id == sync_id  break;

        // Find which output this event belongs to
        for output, oi: outputs {
            if it.object_id == output.id {
                screen := *screens[oi];
                event: Wl_Output_Event;
                unmarshal_event(*event, it.opcode, it.payload, recv);

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

    return screens;
}