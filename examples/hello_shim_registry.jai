// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jim Powers

// hello_shim_registry — the FIRST live compositor interaction through the duck-type
// libwayland proxy (modules/libwayland_shim). It drives wl_display.get_registry +
// wl_display.sync round-trip entirely through OUR engine — the runtime signature-driven
// marshaller, the socket pump/demux, and the wide-signature listener dispatch — against
// real Hyprland, and logs every global the compositor advertises.
//
// This is the end-to-end proof that the marshaller + dispatch + interface tables agree
// with a real Wayland server. `hello_globals` produces the SAME list via the native
// `wayland` path, so the two are directly comparable. (No Vulkan ICD yet — that is the
// Task-7 milestone; this run is also the discovery hook for which globals it will bind.)

S :: #import,dir "../modules/libwayland_shim";
#import "Basic";

// Listener callbacks are #c_call (the C ABI the ICD uses) — NO Jai context on entry. To
// print, we install the shim's captured context with push_context. The interface string
// (*u8) is valid only for the duration of the call (the event payload is freed right
// after dispatch), so we consume it here, not later.

global_count: u32 = 0;

on_global :: (data: *void, registry: *void, name: u32, interface_: *u8, version: u32) #c_call {
    global_count += 1;
    push_context S.shim_context {
        print("  [%] %  (v%)\n", name, to_string(interface_), version);
    }
}

on_global_remove :: (data: *void, registry: *void, name: u32) #c_call {
    // Not expected during the initial round-trip; ignore for slice-1.
}

// A wl_display listener so any protocol error during first contact is visible rather than
// silently dropped (the native path handles wl_display.error transparently; here we log).
on_error :: (data: *void, display: *void, object_id: *void, code: u32, message: *u8) #c_call {
    push_context S.shim_context {
        print("  !! wl_display.error: code=%  object=%  msg=%\n", code, object_id, to_string(message));
    }
}

on_delete_id :: (data: *void, display: *void, id: u32) #c_call {
    // slice-1: no client-id recycling; ignore.
}

main :: () {
    print("hello_shim_registry — duck-type libwayland → live Hyprland\n\n");

    display := S.shim_connect();
    if display == null {
        print("FAILED: could not connect to the compositor.\n");
        exit(1);
    }
    print("connected: wl_display id=%  (socket fd=%)\n", display.proxy.id, display.conn.socket_fd);

    // Install the display error listener BEFORE issuing any request.
    disp_vtable: [2] *void;
    disp_vtable[0] = cast(*void) on_error;
    disp_vtable[1] = cast(*void) on_delete_id;
    S.wl_proxy_add_listener(*display.proxy, cast(*void) disp_vtable.data, null);

    // get_registry through the runtime marshaller → a fresh wl_registry proxy.
    registry := S.shim_get_registry(display);
    if registry == null {
        print("FAILED: get_registry returned null.\n");
        exit(1);
    }
    print("get_registry: wl_registry id=%\n\n", registry.id);

    reg_vtable: [2] *void;
    reg_vtable[0] = cast(*void) on_global;
    reg_vtable[1] = cast(*void) on_global_remove;
    S.wl_proxy_add_listener(registry, cast(*void) reg_vtable.data, null);

    print("globals advertised by the compositor:\n");
    S.shim_roundtrip(display);  // flush + read + dispatch until the sync callback fires

    print("\n% globals total.\n", global_count);
    if global_count == 0 {
        print("FAILED: zero globals — the marshaller/dispatch/tables did not round-trip.\n");
        exit(1);
    }
    print("\nhello_shim_registry: OK — the duck-type engine talked to Hyprland.\n");
}
