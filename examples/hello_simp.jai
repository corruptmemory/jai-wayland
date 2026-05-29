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
// No input, no resize — that is the point: the smallest surface that proves
// render-target ownership (§2) + block-on-frame-callback present (§3) end to end.
// A coloured quad animating on the compositor is the Slice-1 functional gate.
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

WIDTH  :: 800;
HEIGHT :: 600;

main :: () {
    window := create_window(window_name = "hello_simp", width = WIDTH, height = HEIGHT);
    Simp.set_render_target(window);  // ONCE — triggers Simp BACKEND_INIT.

    // The compositor may give us a different size than requested (Hyprland tiles
    // it), so drive the quad geometry off the actual render size, not the
    // requested constants. Slice 1 has no resize, so query once.
    win_w, win_h := Simp.get_render_dimensions(window);

    frame_limit := frame_limit_from_env();
    if frame_limit > 0  print("hello_simp: bounded run, % frame(s)\n", frame_limit);
    else                print("hello_simp: running until killed (JAI_WAYLAND_SIMP_FRAMES=N to bound)\n");

    frame: u64 = 0;
    while true {
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
