// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jim Powers
//
// The libwayland-client ABI types (must match libwayland byte-for-byte — the ICD
// references these directly) plus our own backing structs (which the ICD only ever
// sees as opaque pointers, so their layout is ours to choose).
//
// ABI layouts mirror game-bootstrap modules/Wayland_Client/core.generated.jai, which
// in turn mirrors <wayland-util.h> / <wayland-client-core.h>.

// ── libwayland ABI: the wire-format / interface description graph ──

wl_fixed_t :: s32;  // 24.8 signed fixed-point

// One request or event: name, wire signature ("2uf?o…"), and the per-arg interface
// back-pointer table (null per slot unless an object/new_id arg names an interface).
wl_message :: struct {
    name:      *u8;
    signature: *u8;
    types:     **wl_interface;
}

// A protocol object's interface description (the marshaller consults methods[opcode]).
wl_interface :: struct {
    name:         *u8;
    version:      s32;
    method_count: s32;
    methods:      *wl_message;
    event_count:  s32;
    events:       *wl_message;
}

// Intrusive doubly-linked list node (the ICD uses wl_list for its own bookkeeping).
wl_list :: struct {
    prev: *wl_list;
    next: *wl_list;
}

// libwayland's dynamic array (an event ARRAY arg arrives as *wl_array).
wl_array :: struct {
    size:  u64;
    alloc: u64;
    data:  *void;
}

// One wire argument, tagged by the signature char: i u f s o n a h.
wl_argument :: union {
    i: s32;        // int
    u: u32;        // uint
    f: wl_fixed_t; // fixed
    s: *u8;        // string (C, NUL-terminated)
    o: *void;      // object (a *wl_proxy)
    n: u32;        // new_id
    a: *wl_array;  // array
    h: s32;        // fd
}

// ── Our backing objects (opaque to the ICD) ──

// Events queued at socket-read time, awaiting dispatch on their target queue. We copy
// the raw payload (and any fds) so the ReceiveBuffer can be compacted/reused freely.
Queued_Event :: struct {
    object_id: u32;
    opcode:    u16;
    payload:   [] u8;   // owned copy: bytes AFTER the 8-byte header
    fds:       [] s32;  // owned copy of this event's fds, in order
}

// A client-side proxy for one protocol object. Reinterpretable as the ICD's opaque
// `wl_proxy`. The display's own proxy is this struct's first member (see Wl_Display).
Wl_Proxy :: struct {
    id:         u32;
    interface_: *wl_interface;  // `interface` is a Jai reserved word
    version:    u32;
    display:   *Wl_Display;
    queue:     *Wl_Event_Queue;  // dispatch queue (default unless set_queue/create_wrapper)
    listener:  *void;            // ptr to a flat [event_count] of #c_call fn-ptrs (vtable)
    user_data: *void;
}

// A dispatch queue: events routed here at read time, drained by wl_display_dispatch_queue.
Wl_Event_Queue :: struct {
    display: *Wl_Display;
    name:    string;
    pending: [..] Queued_Event;
}

// The connection + everything hung off it. wl_display IS-A wl_proxy (id 1), so `proxy`
// MUST be the first member: the ICD passes our *Wl_Display where a *wl_proxy is expected
// (e.g. wl_display_get_registry marshals on the display proxy).
Wl_Display :: struct {
    proxy:         Wl_Proxy;        // MUST be first; id == 1
    conn:          Way.Connection;
    out:           Way.MessageBuilder;
    in_buf:        Way.ReceiveBuffer;
    default_queue: Wl_Event_Queue;
    proxies:       [..] *Wl_Proxy;  // id → proxy (linear scan; slice-1 object counts are small)
    queues:        [..] *Wl_Event_Queue;
}

// ── Proxy registry helpers (slice-1: linear scan) ──

register_proxy :: (display: *Wl_Display, p: *Wl_Proxy) {
    array_add(*display.proxies, p);
}

find_proxy :: (display: *Wl_Display, id: u32) -> *Wl_Proxy {
    for display.proxies  if it.id == id  return it;
    return null;
}

unregister_proxy :: (display: *Wl_Display, id: u32) {
    for display.proxies {
        if it.id == id {
            remove it;
            return;
        }
    }
}

// Allocate + register a fresh proxy of `interface`, assigned to `queue`.
make_proxy :: (display: *Wl_Display, id: u32, interface_: *wl_interface, version: u32, queue: *Wl_Event_Queue) -> *Wl_Proxy {
    p := New(Wl_Proxy);
    p.id         = id;
    p.interface_ = interface_;
    p.version    = version;
    p.display    = display;
    p.queue      = queue;
    register_proxy(display, p);
    return p;
}
