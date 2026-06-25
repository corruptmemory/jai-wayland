// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jim Powers
//
// The trivial half of bucket 3: the core wl_* the ICD imports that are pure
// accessors / list ops / flush — no engine, just a few lines each over our backing
// structs. All #program_export #c_call. Those that call a context-using Jai proc
// (unregister_proxy, wayland_send) install shim_context first; the pure field/list
// ones need no context.

// ── wl_list: libwayland's intrusive doubly-linked list (the ICD uses it for its own
//    bookkeeping — e.g. swapchain image lists). Self-contained; no context. ──

#program_export
wl_list_init :: (list: *wl_list) #c_call {
    list.prev = list;
    list.next = list;
}

// Insert `elm` immediately AFTER `list` (libwayland semantics).
#program_export
wl_list_insert :: (list: *wl_list, elm: *wl_list) #c_call {
    elm.prev = list;
    elm.next = list.next;
    list.next.prev = elm;
    list.next = elm;
}

#program_export
wl_list_remove :: (elm: *wl_list) #c_call {
    elm.prev.next = elm.next;
    elm.next.prev = elm.prev;
    elm.prev = null;
    elm.next = null;
}

// ── proxy accessors: pure field reads, no context ──

#program_export
wl_proxy_get_version :: (proxy: *Wl_Proxy) -> u32 #c_call {
    return proxy.version;
}

#program_export
wl_proxy_get_id :: (proxy: *Wl_Proxy) -> u32 #c_call {
    return proxy.id;
}

// ── lifecycle / flush: call into context-using Jai, so install shim_context ──

#program_export
wl_proxy_destroy :: (proxy: *Wl_Proxy) #c_call {
    ctx := shim_context;
    push_context ctx {
        unregister_proxy(proxy.display, proxy.id);
        // slice-1: stop routing events to this id; heap memory is leaked rather
        // than risk freeing the display's embedded proxy. Lifetimes tighten later.
    }
}

#program_export
wl_proxy_wrapper_destroy :: (proxy: *Wl_Proxy) #c_call {
    // A wrapper shares the wrapped object's id but pins a chosen dispatch queue.
    // slice-1: wrappers carry no separate allocation yet — nothing to free.
}

#program_export
wl_display_flush :: (display: *Wl_Display) -> s32 #c_call {
    ctx := shim_context;
    push_context ctx {
        Way.wayland_send(*display.conn, *display.out);
    }
    return 0;  // libwayland: bytes flushed / 0; -1 (EAGAIN) handling is slice-2
}

#program_export
wl_event_queue_destroy :: (queue: *Wl_Event_Queue) #c_call {
    // slice-1: queues live for the process lifetime — nothing to free yet.
}
