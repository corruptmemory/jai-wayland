// Input discovery — keyboard acquisition via wl_seat + wl_keyboard.

#import "Basic";

Keyboard_Info :: struct {
    seat: Wl_Seat;
    keyboard: Wl_Keyboard;
    keymap_fd: Fd;
    keymap_size: u32;
}

// Bind wl_seat, check for keyboard capability, acquire wl_keyboard,
// and receive the keymap event. Returns the keyboard info and true
// if a keyboard was found, or default info and false otherwise.
// Uses the context session (must be initialized).
get_keyboard_info :: () -> Keyboard_Info, bool {
    info: Keyboard_Info;

    // Check that wl_seat is available
    has_seat := false;
    for globals() {
        if it.interface_name == "wl_seat" { has_seat = true; break; }
    }
    if !has_seat  return info, false;

    // Bind wl_seat + sync to get capabilities
    display := Wl_Display.{ id = 1 };
    info.seat = Wl_Seat.{ id = allocate_id() };

    batch: MessageBuilder;
    wl_registry_bind(*batch, registry(), *info.seat);
    sync_id := allocate_id();
    wl_display_sync(*batch, *display, sync_id);
    wayland_send(*batch);

    // Wait for capabilities event
    has_keyboard := false;
    for session() {
        if it.object_id == sync_id  break;

        if it.object_id == info.seat.id {
            event: Wl_Seat_Event;
            unmarshal_event(*event, it.opcode, it.payload, recv);
            if event.kind == .CAPABILITIES {
                if event.capabilities.capabilities & cast(u32) Wl_Seat_Capability.KEYBOARD {
                    has_keyboard = true;
                }
            }
        }
    }

    if !has_keyboard  return info, false;

    // Request keyboard + sync to get keymap
    info.keyboard = Wl_Keyboard.{ id = allocate_id() };
    wl_seat_get_keyboard(*batch, *info.seat, info.keyboard.id);
    sync_id = allocate_id();
    wl_display_sync(*batch, *display, sync_id);
    wayland_send(*batch);

    for session() {
        if it.object_id == sync_id  break;

        if it.object_id == info.keyboard.id {
            event: Wl_Keyboard_Event;
            unmarshal_event(*event, it.opcode, it.payload, recv);
            if event.kind == .KEYMAP {
                info.keymap_fd = event.keymap.fd;
                info.keymap_size = event.keymap.size;
            }
        }
    }

    return info, true;
}
