// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jim Powers
//
// Facade — the small Jai-side bring-up that stands a *Wl_Display up on a live socket and
// drives the core requests, so a harness (and, in Task 7, the Vulkan ICD path) has a
// connected display + registry to work with. Sits ABOVE the engine (marshal_runtime /
// queues) and the interface tables; the C-ABI surface the ICD calls sits above it.
//
// These are plain Jai procs (a context is in scope), so they call the engine's internals
// directly — marshal_impl, register_proxy, wl_display_roundtrip_queue. The exported
// #c_call entry points are what the ICD uses; the facade is what OUR code uses.

// Connect to the compositor and return a heap *Wl_Display ready to marshal on. The
// display IS proxy id 1; the next client id is 2 (the first get_registry). Returns null
// if the socket can't be opened. The pointer is heap-stable: the ICD (and our embedded
// proxy registration) hold its address, so it must outlive every call — never stack it.
shim_connect :: () -> *Wl_Display {
    // Capture a context for the exported #c_call entries to install (the ICD's WSI calls
    // arrive with no Jai context). We are on the main thread here; slice-1 is single
    // threaded, so one captured context serves every entry.
    shim_context = context;

    display := New(Wl_Display);

    if !Way.wayland_connect(*display.conn) {
        log_error("shim_connect: wayland_connect failed — check XDG_RUNTIME_DIR / WAYLAND_DISPLAY.");
        free(display);
        return null;
    }
    display.conn.next_id = 2;  // id 1 is the display proxy itself

    // wl_display is proxy id 1, interface wl_display, parked on the default queue.
    display.proxy.id         = 1;
    display.proxy.interface_ = *wl_display_interface;
    display.proxy.version    = 1;
    display.proxy.display     = display;
    display.proxy.queue       = *display.default_queue;
    display.default_queue.display = display;

    wl_protocol_tables_init();                 // patch the types[] back-pointers (idempotent)
    register_proxy(display, *display.proxy);   // id 1 → the embedded proxy

    return display;
}

// Marshal wl_display.get_registry → a fresh wl_registry proxy on the default queue. The
// caller installs a listener on the returned proxy, then roundtrips to drain its globals.
shim_get_registry :: (display: *Wl_Display) -> *Wl_Proxy {
    args: [1] wl_argument;
    args[0].n = 0;  // new_id placeholder; marshal_impl allocates and writes the real id
    return marshal_impl(*display.proxy, WL_DISPLAY_GET_REGISTRY, *wl_registry_interface, 1, 0, args.data);
}

// Drive a sync roundtrip on the default queue: flush queued requests, then read + dispatch
// until the sync callback fires (every prior request has been processed by the server).
shim_roundtrip :: (display: *Wl_Display) -> s32 {
    return wl_display_roundtrip_queue(display, *display.default_queue);
}
