// New file (not vendored — original to this project).
// Subsystem init ceremony for the Linux backend. Detects the runtime
// environment (Wayland vs X11) and pushes the appropriate dispatchers
// into context. Called lazily on first create_window invocation.
// See docs/plans/2026-05-26-context-dispatch-stage1-design.md.

#import "Simp";  // for simp_x11_dispatch / simp_wayland_dispatch

running_wayland :: () -> bool {
    // Stage 1: unconditionally X11.
    // Stage 2 replaces this body with real detection — typically:
    //   wayland_display := to_string(getenv("WAYLAND_DISPLAY"));
    //   return wayland_display.count > 0;
    return false;
}

init_linux_window :: () {
    if running_wayland() {
        context.simp_dispatch = simp_wayland_dispatch;
    } else {
        context.simp_dispatch = simp_x11_dispatch;
    }
    // Stage 2 will also push wc_dispatch and possibly input_pump here.
}
