// examples/hello_clipboard.jai — exercises the Wayland clipboard (copy/paste) path
// through the vendored Clipboard module's public API (os_clipboard_get_text /
// os_clipboard_set_text), exactly as a real app (GetRect's text input) would.
//
//   'c' -> os_clipboard_set_text("...")   (COPY: we take the selection)
//   'p' -> print os_clipboard_get_text()  (PASTE: read the current selection)
//   'q' -> quit
//
// On Wayland these route to Wayland_Support's wl_clipboard_* over wl_data_device;
// on X11 they'd hit the stock X11 selection path. A window is created + rendered
// (like hello_simp) so it maps and gains keyboard focus — the compositor only
// delivers selection events to a focused data device.
//
// Automated test (no manual clicking needed — clipboard ops are plain keypresses):
//   wl-copy "EXTERNAL"          # seed the system clipboard
//   ./build.sh - hello_clipboard &  (or run build/hello_clipboard)
//   wtype p                      # -> prints "pasted: EXTERNAL"
//   wtype c                      # -> we copy our message
//   wl-paste                     # -> prints our message
//
// Same ldd-clean invariant as the rest of the project: no windowing/GPU libs.

#import "Basic";
#import "Math";
#import "POSIX";              // getenv (frame cap)
#import "Window_Creation";
Simp :: #import "Simp";
#import "Input";
Clipboard :: #import "Clipboard";

WIDTH  :: 480;
HEIGHT :: 200;

main :: () {
    window := create_window(window_name = "hello_clipboard", width = WIDTH, height = HEIGHT);
    Simp.set_render_target(window);

    print("hello_clipboard: 'c' copies, 'p' pastes (prints), 'q' quits.\n");

    copy_counter := 0;
    frame: u64 = 0;
    quit := false;
    while !quit {
        update_window_events();
        for events_this_frame {
            if it.type != .KEYBOARD || !it.key_pressed  continue;
            if it.key_code == {
                case #char "Q";
                    quit = true;
                case #char "C";
                    copy_counter += 1;
                    msg := tprint("clipboard from jai-wayland #%", copy_counter);
                    Clipboard.os_clipboard_set_text(msg);
                    print("copied: %\n", msg);
                case #char "P";
                    text := Clipboard.os_clipboard_get_text();
                    print("pasted: \"%\"\n", text);
                    free(text);
            }
        }
        if quit  break;

        Simp.update_window(window);
        Simp.clear_render_target(0.08, 0.10, 0.14, 1.0);
        Simp.swap_buffers(window);

        if Simp.window_should_close(window)  break;

        frame += 1;
        if frame_limit() > 0 && frame >= frame_limit()  break;
    }

    print("hello_clipboard: done (% frame(s)).\n", frame);
}

frame_limit :: () -> u64 {
    p := getenv("JAI_WAYLAND_CLIPBOARD_FRAMES");
    if p == null  return 0;
    t := to_string(p);
    v: u64 = 0;
    for t { if it < #char "0" || it > #char "9"  break; v = v * 10 + cast(u64)(it - #char "0"); }
    return v;
}
