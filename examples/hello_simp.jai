// examples/hello_simp.jai — Slice 1 proving vehicle for the Wayland Simp backend.
//
// The minimal program that exercises the WHOLE Wayland backend path through
// Simp's own public API, using it exactly as invaders does (minus game logic):
//
//   create_window  →  create_window_wayland (surface stack + first configure)
//   set_render_target (ONCE)  →  Simp BACKEND_INIT (EGL/GBM + BO-backed slots)
//   loop { clear → draw one quad → swap_buffers }
//       clear/draw target the current slot's BO-backed FBO (window_framebuffer);
//       swap_buffers exports the BO as a wl_buffer, commits, blocks on the frame
//       callback, rotates to the next slot, and rebinds its FBO.
//
// Resize works (compositor-driven), and keyboard input now works too: 'q' quits
// through the REAL Wayland input path — WS.wl_acquire_input + the single pump
// decoding keys into stable Wl_Input_Events that this loop drains — not a
// hand-rolled wire reader. A coloured quad animating on the compositor, that
// resizes and responds to 'q', is the functional gate.
//
// set_render_target is called ONCE (like invaders): on Wayland the dispatcher
// rebinds the rotated slot's FBO inside swap_buffers, so the rotation stays
// invisible to the app — the same contract X11's back-buffer swap provides.
//
// JAI_WAYLAND_SIMP_FRAMES=N bounds the run to N frames (0 / unset = until killed).
// Same ldd-clean invariant as the rest of the project: no libwayland linkage.
// Built with import_path = modules/ first (see first.jai) so the name-based
// `wayland` imports in Simp + Window_Creation resolve to one shared instance.

#import "Basic";
#import "Math";
#import "POSIX";              // getenv (frame cap)
#import "Window_Creation";   // create_window, Window_Type
Simp :: #import "Simp";
WS   :: #import "Wayland_Support";  // keyboard input: acquire + drain the pump's decoded events

WIDTH  :: 800;
HEIGHT :: 600;

main :: () {
    window := create_window(window_name = "hello_simp", width = WIDTH, height = HEIGHT);
    Simp.set_render_target(window);  // ONCE — triggers Simp BACKEND_INIT.

    // Acquire keyboard input BEFORE the render loop. wl_acquire_input does sync
    // roundtrips that must not run once frames are in flight; here the window is
    // configured and the backend is up, but nothing has been presented yet.
    WS.wl_acquire_input();

    frame_limit := frame_limit_from_env();
    if frame_limit > 0  print("hello_simp: bounded run, % frame(s)\n", frame_limit);
    else                print("hello_simp: running until killed (JAI_WAYLAND_SIMP_FRAMES=N to bound)\n");

    frame: u64 = 0;
    quit := false;
    while true {
        // Pick up compositor-driven resize (invaders' pattern): update_window
        // detects a size change and reallocates the backend's render target — for
        // Wayland that retires + reallocs the BO slots at the new size. Then drive
        // the quad geometry off the current size so it re-centers on resize.
        Simp.update_window(window);
        win_w, win_h := Simp.get_render_dimensions(window);

        // Cycle the quad colour so frame advancement is visually obvious — a
        // frozen first frame would look identical to a working static one.
        t := cast(float) frame * 0.03;
        r := 0.5 + 0.5 * sin(t);
        g := 0.5 + 0.5 * sin(t + 2.094);  // +120°
        b := 0.5 + 0.5 * sin(t + 4.189);  // +240°

        Simp.clear_render_target(0.10, 0.10, 0.12, 1.0);

        Simp.set_shader_for_color();
        Simp.immediate_begin();
        cx := cast(float) win_w * 0.5;
        cy := cast(float) win_h * 0.5;
        hw := cast(float) win_w * 0.25;
        hh := cast(float) win_h * 0.25;
        Simp.immediate_quad(cx - hw, cy - hh, cx + hw, cy + hh, .{r, g, b, 1.0});
        Simp.immediate_flush();

        Simp.swap_buffers(window);  // present current slot, block on frame, rotate.

        // Drain the keyboard input the pump decoded. swap_buffers above pumped
        // (blocking) for frame pacing, decoding any keys that arrived during the
        // block; the non-blocking sweep here catches anything since the frame
        // callback fired. 'q' quits — through the real Wayland input path.
        WS.wl_pump(false);
        for ev: WS.provisional_input_events {
            if ev.kind == .KEY && ev.key.pressed && ev.key.keysym == #char "q" {
                print("hello_simp: 'q' pressed — exiting\n");
                quit = true;
            }
        }
        WS.wl_clear_input_events();
        if quit  break;

        // Quit cleanly when the compositor asks (Super+Q → killactive →
        // xdg_toplevel.close). Without this the window ignores the close request.
        if Simp.window_should_close(window) {
            print("hello_simp: close requested — exiting\n");
            break;
        }

        frame += 1;
        if frame_limit > 0 && frame >= frame_limit  break;
    }

    print("hello_simp: presented % frame(s) cleanly\n", frame);
}

// Mirrors hello_vulkan_dmabuf's frame_limit_from_env: returns 0 (unbounded) when
// the env var is unset/empty, else the leading decimal value.
frame_limit_from_env :: () -> u64 {
    value_ptr := getenv("JAI_WAYLAND_SIMP_FRAMES");
    if value_ptr == null  return 0;

    text := to_string(value_ptr);
    if text.count == 0  return 0;

    value: u64 = 0;
    for text {
        if it < #char "0" || it > #char "9"  break;
        value = value * 10 + cast(u64)(it - #char "0");
    }
    return value;
}
