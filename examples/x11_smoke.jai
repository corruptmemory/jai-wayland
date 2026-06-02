// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jim Powers

// x11_smoke — smoke test for the runtime-loaded X11 binding.
//
// This intentionally does not create a window. It proves the vendored X11
// module can dlopen libX11, resolve the Xlib function table, optionally open
// the current DISPLAY, and stay out of the executable's link graph.

X11 :: #import,dir "../modules/X11";
#import "Basic";
#import "POSIX";

main :: () {
    if !X11.init_x11() {
        print("Could not load libX11 at runtime.\n");
        exit(1);
    }

    print("X11 runtime loader OK\n");
    if X11.init_glx() {
        print("GLX runtime loader OK\n");
    } else {
        print("GLX runtime loader unavailable; continuing with Xlib-only smoke.\n");
    }

    display_name := getenv("DISPLAY");
    if !display_name {
        print("DISPLAY unset; skipping XOpenDisplay.\n");
        return;
    }

    display := X11.XOpenDisplay(null);
    if !display {
        print("XOpenDisplay failed for DISPLAY=%\n", to_string(display_name));
        exit(1);
    }
    defer X11.XCloseDisplay(display);

    screen := X11.DefaultScreen(display);
    root := X11.DefaultRootWindow(display);
    vendor := to_string(X11.XServerVendor(display));

    print("Opened DISPLAY=%: screen %, root %, vendor %\n", to_string(display_name), screen, root, vendor);
}
