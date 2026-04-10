// Input discovery — seat, keyboard, and pointer acquisition.

#import "Basic";

Seat_Info :: struct {
    seat: Wl_Seat;
    name: string;
    capabilities: u32;  // Wl_Seat_Capability flags
}

Keyboard_Info :: struct {
    seat_index: int;
    keyboard: Wl_Keyboard;
    keymap_fd: Fd;
    keymap_size: u32;
}

Pointer_Info :: struct {
    seat_index: int;
    pointer: Wl_Pointer;
}

// Discover all seats from the compositor. Binds each wl_seat global,
// performs a sync roundtrip, collects capabilities and name.
get_seats_info :: () -> [] Seat_Info {
    seat_count: int;
    for globals() {
        if it.interface_name == "wl_seat"  seat_count += 1;
    }
    if seat_count == 0  return .[];

    seats: [..] Seat_Info;

    display := Wl_Display.{ id = 1 };
    batch: MessageBuilder;
    for 1..seat_count {
        seat := array_add(*seats);
        seat.seat = Wl_Seat.{ id = allocate_id() };
        wl_registry_bind(*batch, registry(), *seat.seat);
    }
    sync_id := allocate_id();
    wl_display_sync(*batch, *display, sync_id);
    wayland_send(*batch);

    for session() {
        if it.object_id == sync_id  break;

        for *seat, si: seats {
            if it.object_id == seat.seat.id {
                event: Wl_Seat_Event;
                unmarshal_event(*event, it.opcode, it.payload, recv);
                if event.kind == {
                  case .CAPABILITIES;
                    seat.capabilities = event.capabilities.capabilities;
                  case .NAME;
                    seat.name = copy_string(event.name.name);
                }
                break;
            }
        }
    }

    return seats;
}

// Acquire keyboards from seats that have the KEYBOARD capability.
// Binds wl_keyboard for each, receives keymap events.
get_keyboards_info :: (seats: [] Seat_Info) -> [] Keyboard_Info {
    // Count seats with keyboard capability
    kb_count: int;
    for seats {
        if it.capabilities & cast(u32) Wl_Seat_Capability.KEYBOARD  kb_count += 1;
    }
    if kb_count == 0  return .[];

    keyboards: [..] Keyboard_Info;

    display := Wl_Display.{ id = 1 };
    batch: MessageBuilder;
    for seat, si: seats {
        if seat.capabilities & cast(u32) Wl_Seat_Capability.KEYBOARD {
            kb := array_add(*keyboards);
            kb.seat_index = si;
            kb.keyboard = Wl_Keyboard.{ id = allocate_id() };
            wl_seat_get_keyboard(*batch, *seat.seat, kb.keyboard.id);
        }
    }
    sync_id := allocate_id();
    wl_display_sync(*batch, *display, sync_id);
    wayland_send(*batch);

    for session() {
        if it.object_id == sync_id  break;

        for *kb: keyboards {
            if it.object_id == kb.keyboard.id {
                event: Wl_Keyboard_Event;
                unmarshal_event(*event, it.opcode, it.payload, recv);
                if event.kind == .KEYMAP {
                    kb.keymap_fd = event.keymap.fd;
                    kb.keymap_size = event.keymap.size;
                }
                break;
            }
        }
    }

    return keyboards;
}

// Acquire pointers from seats that have the POINTER capability.
get_pointers_info :: (seats: [] Seat_Info) -> [] Pointer_Info {
    ptr_count: int;
    for seats {
        if it.capabilities & cast(u32) Wl_Seat_Capability.POINTER  ptr_count += 1;
    }
    if ptr_count == 0  return .[];

    pointers: [..] Pointer_Info;

    display := Wl_Display.{ id = 1 };
    batch: MessageBuilder;
    for seat, si: seats {
        if seat.capabilities & cast(u32) Wl_Seat_Capability.POINTER {
            ptr := array_add(*pointers);
            ptr.seat_index = si;
            ptr.pointer = Wl_Pointer.{ id = allocate_id() };
            wl_seat_get_pointer(*batch, *seat.seat, ptr.pointer.id);
        }
    }
    sync_id := allocate_id();
    wl_display_sync(*batch, *display, sync_id);
    wayland_send(*batch);

    // Pointer has no initial burst like keymap — just drain the sync
    for session() {
        if it.object_id == sync_id  break;
    }

    return pointers;
}

// Match a message to a keyboard and unmarshal. Returns the event and true
// if the message belongs to one of the keyboards, false otherwise.
get_keyboard_event :: (header: WaylandMessageHeader, keyboards: [] Keyboard_Info, recv: *ReceiveBuffer) -> Wl_Keyboard_Event, bool {
    for keyboards {
        if header.object_id == it.keyboard.id {
            event: Wl_Keyboard_Event;
            unmarshal_event(*event, header.opcode, header.payload, recv);
            return event, true;
        }
    }
    return .{}, false;
}

// Match a message to a pointer and unmarshal. Returns the event and true
// if the message belongs to one of the pointers, false otherwise.
get_pointer_event :: (header: WaylandMessageHeader, pointers: [] Pointer_Info, recv: *ReceiveBuffer) -> Wl_Pointer_Event, bool {
    for pointers {
        if header.object_id == it.pointer.id {
            event: Wl_Pointer_Event;
            unmarshal_event(*event, header.opcode, header.payload, recv);
            return event, true;
        }
    }
    return .{}, false;
}
