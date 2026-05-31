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

    // Window IDENTITY for the Wayland backend — the analogue of X11's bare
    // X11.Window handle. Just the wl_surface id: the stable key into the shared
    // WS.wayland_global_windows registry (Wayland_Support), which owns the full
    // per-window state — xdg roles, current size, EGL ctx, BO slots. Window_Type
    // is a freely-copied VALUE, so it must stay a lightweight handle, not a copy
    // of state that would go stale the instant it is copied. Resolve the full
    // record with WS.find_wayland_window(surface).
    Wayland_Window_State :: struct {
        surface: u32;    // wl_surface id — identity key into WS.wayland_global_windows
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
            case .Wayland; return a.wayland.surface == b.wayland.surface;  // wl_surface id is the window's identity
        }
        return false;
    }

    operator == :: (a: Window_Type, b: X11.Window) -> bool {
        return a.wtype == .X11 && a.x11 == b;
    }

    // Cross-module handoff for the Wayland arm of X11.enable_drag_and_drop. The
    // GetRect examples call `X11.enable_drag_and_drop(window, typelist)` to opt a
    // window into file drops; on X11 that sets the XdndAware property, but Wayland
    // has no per-window drop-target property — instead that overload flips this
    // flag, and Wayland_Support's data-device pump gates drop ACCEPTANCE on it (so
    // an app that never opts in is not a drop target, matching the X11 backend).
    // It lives here because Window_Type is the one module both X11 (the setter)
    // and Wayland_Support (the reader) already share, so neither backend module
    // has to import the other.
    wayland_drag_and_drop_requested: bool;
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

