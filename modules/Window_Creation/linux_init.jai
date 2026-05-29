// New file (not vendored — original to this project).
// Subsystem init ceremony for the Linux backend. Detects the runtime
// environment (Wayland vs X11) and pushes the appropriate dispatchers
// into context. Called lazily on first create_window invocation.
// See docs/plans/2026-05-26-context-dispatch-stage1-design.md.

#import "Simp";  // for simp_x11_dispatch / simp_wayland_dispatch.
                 // Note: Simp also imports Window_Creation, but Jai resolves
                 // the cycle cleanly because neither side needs the other
                 // at file/load scope.

running_wayland :: () -> bool {
    // A Wayland session sets WAYLAND_DISPLAY; X11 sessions leave it unset (an
    // X11 app under XWayland sees DISPLAY, not WAYLAND_DISPLAY). getenv returns
    // a null *u8 when unset — guard before to_string so we never walk null.
    // POSIX is the named import from linux.jai (same module scope).
    wd := POSIX.getenv("WAYLAND_DISPLAY");
    if !wd  return false;
    return to_string(wd).count > 0;
}

init_linux_window :: () {
    if running_wayland() {
        context.simp_dispatch = simp_wayland_dispatch;
    } else {
        context.simp_dispatch = simp_x11_dispatch;
    }
    // Stage 2 will also push wc_dispatch and possibly input_pump here.
}
