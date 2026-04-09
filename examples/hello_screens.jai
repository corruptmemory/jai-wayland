#import "Basic";
Wayland :: #import,dir "../modules/wayland";

main :: () {
    if !Wayland.init_wayland_session() return;
    defer Wayland.end_wayland_session();

    screens := Wayland.get_screens_info();
    print("Found % output(s):\n\n", screens.count);

    for screen, i: screens {
        print("Output %: %\n", i, screen.name);
        if screen.description.count > 0
            print("  Description: %\n", screen.description);
        if screen.make.count > 0
            print("  Make/Model:  % / %\n", screen.make, screen.model);
        print("  Position:    %, %\n", screen.x, screen.y);
        print("  Physical:    %x% mm\n", screen.physical_width, screen.physical_height);
        print("  Scale:       %\n", screen.scale_factor);
        print("  Current:     %x% @%Hz\n",
            screen.current_mode.width, screen.current_mode.height,
            screen.current_mode.refresh / 1000);
        print("  Modes:\n");
        for mode: screen.modes {
            current  := cast(bool)(mode.flags & cast(u32) Wayland.Wl_Output_Mode.CURRENT);
            preferred := cast(bool)(mode.flags & cast(u32) Wayland.Wl_Output_Mode.PREFERRED);
            flags := "";
            if current && preferred  flags = " [current, preferred]";
            else if current          flags = " [current]";
            else if preferred        flags = " [preferred]";
            print("    %x% @%Hz%\n", mode.width, mode.height, mode.refresh / 1000, flags);
        }
        print("\n");
    }
}
