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

Touch_Info :: struct {
    seat_index: int;
    touch: Wl_Touch;
}

// Acquire touch devices from seats that advertise the TOUCH capability.
get_touch_info :: (seats: [] Seat_Info) -> [] Touch_Info {
    touch_count: int;
    for seats {
        if it.capabilities & cast(u32) Wl_Seat_Capability.TOUCH  touch_count += 1;
    }
    if touch_count == 0  return .[];

    touches: [..] Touch_Info;

    display := Wl_Display.{ id = 1 };
    batch: MessageBuilder;
    for seat, si: seats {
        if seat.capabilities & cast(u32) Wl_Seat_Capability.TOUCH {
            t := array_add(*touches);
            t.seat_index = si;
            t.touch = Wl_Touch.{ id = allocate_id() };
            wl_seat_get_touch(*batch, *seat.seat, t.touch.id);
        }
    }
    sync_id := allocate_id();
    wl_display_sync(*batch, *display, sync_id);
    wayland_send(*batch);

    // Touch has no initial burst — just drain the sync.
    for session()  if it.object_id == sync_id  break;

    return touches;
}

// Match a message to a touch device and unmarshal.
get_touch_event :: (header: WaylandMessageHeader, touches: [] Touch_Info, recv: *ReceiveBuffer) -> Wl_Touch_Event, bool {
    for touches {
        if header.object_id == it.touch.id {
            event: Wl_Touch_Event;
            unmarshal_event(*event, header.opcode, header.payload, recv);
            return event, true;
        }
    }
    return .{}, false;
}

// ─────────────────────── Data device (drag-and-drop / selection) ───────────
// wl_data_device is the per-seat handle the compositor delivers drag-and-drop
// and clipboard-selection events through. Acquired alongside keyboards/pointers
// so the single pump can decode drag sessions. The wl_data_offer objects a drag
// introduces are SERVER-allocated — the new_id rides in the data_offer event and
// unmarshal's *Interface path reads the id straight out of it (no client
// allocation, no collision: server ids live in the 0xFF000000+ range).

Data_Device_Info :: struct {
    seat_index: int;
    device: Wl_Data_Device;
}

// Bind the wl_data_device_manager singleton and acquire a wl_data_device per
// seat. Returns the devices plus the bound manager (manager.id == 0 if the
// compositor advertises no wl_data_device_manager). Mirrors get_pointers_info.
get_data_devices_info :: (seats: [] Seat_Info) -> [] Data_Device_Info, Wl_Data_Device_Manager {
    _, has_mgr := get_global("wl_data_device_manager");
    if !has_mgr || seats.count == 0  return .[], .{};

    mgr := Wl_Data_Device_Manager.{ id = allocate_id() };
    batch: MessageBuilder;
    if !wl_registry_bind(*batch, registry(), *mgr)  return .[], .{};

    devices: [..] Data_Device_Info;
    for seat, si: seats {
        d := array_add(*devices);
        d.seat_index = si;
        d.device = Wl_Data_Device.{ id = allocate_id() };
        wl_data_device_manager_get_data_device(*batch, *mgr, d.device.id, *seat.seat);
    }

    display := Wl_Display.{ id = 1 };
    sync_id := allocate_id();
    wl_display_sync(*batch, *display, sync_id);
    wayland_send(*batch);

    // Drain the sync. The compositor may introduce a data_offer for the current
    // clipboard selection in this same burst; we let it fall through (we don't
    // support paste yet) and only wait for the sync to know acquisition is done.
    for session()  if it.object_id == sync_id  break;

    return devices, mgr;
}

// Match a message to a data device and unmarshal its event. Mirrors get_pointer_event.
get_data_device_event :: (header: WaylandMessageHeader, devices: [] Data_Device_Info, recv: *ReceiveBuffer) -> Wl_Data_Device_Event, bool {
    for devices {
        if header.object_id == it.device.id {
            event: Wl_Data_Device_Event;
            unmarshal_event(*event, header.opcode, header.payload, recv);
            return event, true;
        }
    }
    return .{}, false;
}

// Unmarshal a wl_data_offer event. Unlike the device/keyboard/pointer matchers,
// a data_offer is created on the fly (server-allocated id from the data_offer
// event), so the caller matches the object id against its own tracked-offer set
// and calls this only once it knows the message targets one of those offers.
get_data_offer_event :: (header: WaylandMessageHeader, recv: *ReceiveBuffer) -> Wl_Data_Offer_Event {
    event: Wl_Data_Offer_Event;
    unmarshal_event(*event, header.opcode, header.payload, recv);
    return event;
}
