// Vendored from ~/jai/jai/modules/Window_Type.jai.
// Modified: Linux branch extended from `Window_Type :: X11.Window` to a
//           tagged union covering both X11 and Wayland backends, to
//           support runtime backend selection. See
//           docs/plans/2026-05-26-context-dispatch-stage1-design.md.

// This module defines the Window_Type used by Windows/X11/etc.
// You only need to include it if you want to define Window_Type and
// you are not using one of the Windows-type modules directly.


#if OS == .WINDOWS {
    #scope_module;
    Windows :: #import "Windows";
    #scope_export;
    Window_Type :: Windows.HWND;
    INVALID_WINDOW : Window_Type : null;
} else #if OS == .LINUX {
    #scope_module;
    X11 :: #import "X11";
    #scope_export;

    Window_Tag :: enum u32 {
        X11;
        Wayland;
    }

    // Stage 1 placeholder. Stage 2 populates this with EGL_Context +
    // wl_surface/xdg_surface refs + BO slot state. The struct exists
    // now so the tagged union compiles; it is never instantiated in
    // Stage 1 (running_wayland() always returns false).
    Wayland_Window_State :: struct {
    }

    Window_Type :: union wtype: Window_Tag {
        .X11     ,, x11     : X11.Window;
        .Wayland ,, wayland : Wayland_Window_State;
    }

    INVALID_WINDOW : Window_Type : .{ wtype = .X11, x11 = 0 };
    // X11 Window 0 is None — valid sentinel for X11. Stage 2 may want
    // to revisit if Wayland needs a different sentinel for its variant.

    // Equality overloads. Consumers (Simp, Input) treated the old
    // u64-alias Window_Type as a plain comparable value. The tagged
    // union is not comparable by default, so we have to provide these
    // explicitly. Two flavors:
    //   * Window_Type <-> Window_Type : tag-aware comparison.
    //   * Window_Type <-> X11.Window  : convenience for callers that
    //     already hold an X11.Window (e.g. Input's per-event lookup).
    operator == :: (a: Window_Type, b: Window_Type) -> bool {
        if a.wtype != b.wtype  return false;
        if a.wtype == {
            case .X11;     return a.x11 == b.x11;
            case .Wayland; return true;  // Wayland_Window_State is empty in Stage 1.
        }
        return false;
    }

    operator == :: (a: Window_Type, b: X11.Window) -> bool {
        return a.wtype == .X11 && a.x11 == b;
    }
} else #if OS == .MACOS {
    #scope_module;
    ObjC :: #import "Objective_C/AppKit";
    #scope_export;
    Window_Type :: *ObjC.NSWindow;
    INVALID_WINDOW : Window_Type : null;
} else #if OS == .PS5 {
    #scope_export;
    Window_Type :: *void;
    INVALID_WINDOW : Window_Type : null;
} else #if OS == .NN_SWITCH2 {
    #scope_export;
    Window_Type :: *void;
    INVALID_WINDOW : Window_Type : null;
} else #if OS == .ANDROID {
    #scope_module;
    Android :: #import "Android";
    #scope_export;
    Window_Type :: *Android.ANativeWindow;
    INVALID_WINDOW : Window_Type : null;
}

