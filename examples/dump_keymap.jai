#import "Basic";
#import "POSIX";
Wayland :: #import,dir "../modules/wayland";

main :: () {
    if !Wayland.init_wayland_session() return;
    defer Wayland.end_wayland_session();

    seats := Wayland.get_seats_info();
    keyboards := Wayland.get_keyboards_info(seats);

    if keyboards.count == 0 {
        print("No keyboards found.\n");
        return;
    }

    kb := keyboards[0];
    print("Keymap: fd=%, size=% bytes\n\n", kb.keymap_fd, kb.keymap_size);

    keymap, ok := Wayland.parse_keymap_fd(kb.keymap_fd, kb.keymap_size);
    if !ok {
        print("Failed to parse keymap\n");
        return;
    }

    // Print mappings for common keys to verify parsing
    Test_Key :: struct { evdev: u32; label: string; }
    test_keys :: Test_Key.[
        .{ 16, "Q" }, .{ 17, "W" }, .{ 18, "E" }, .{ 19, "R" },
        .{ 30, "A" }, .{ 31, "S" }, .{ 32, "D" }, .{ 33, "F" },
        .{ 34, "G" }, .{ 38, "L" }, .{ 48, "B" },
        .{ 1, "ESC" }, .{ 28, "ENTER" }, .{ 57, "SPACE" },
        .{ 2, "1" }, .{ 3, "2" }, .{ 4, "3" },
    ];

    print("Evdev → Keysym mappings:\n");
    for test_keys {
        entry := keymap.entries[it.evdev];
        print("  evdev %  (%)\t→ ", it.evdev, it.label);
        if entry.count == 0 {
            print("(none)\n");
        } else {
            for i: 0..cast(int)entry.count-1 {
                ks := entry.keysyms[i];
                if i > 0  print(", ");
                if Wayland.keysym_is_ascii(ks) {
                    print("'%' (0x%)", cast(u8) ks, formatInt(ks, base=16));
                } else {
                    print("0x%", formatInt(ks, base=16));
                }
            }
            print("\n");
        }
    }
}
