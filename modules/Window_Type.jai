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

