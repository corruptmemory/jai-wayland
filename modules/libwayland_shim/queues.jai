// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jim Powers
//
// The event/dispatch engine — bucket 3, piece B (the meat).
//
// Single-owner multi-queue model (the Mesa ICD imports dispatch_queue/roundtrip_queue
// but NOT prepare_read/read_events, so no manual reader handshake is needed): one
// socket-read routine demuxes each incoming event to its target proxy's queue; each
// consumer (our pump, the ICD's private queue) drains only its own queue. Single
// threaded for slice 1.
//
// THE LISTENER-INVOKE TRICK (no C needed): the listener is a C vtable of #c_call fn
// ptrs, one per event opcode, each with the event's own signature. To call one with a
// runtime-decoded arg list we invoke it through a FIXED 12-u64 #c_call signature. On
// x86-64 SysV, every Wayland arg is integer/pointer class, so a callee that declares
// fewer params just reads its prefix of the registers/stack; the extra slots are
// ignored. Jai calls fixed-arity #c_call pointers natively — only varargs *receive*
// (wl_proxy_marshal_flags) needed C.

#import "POSIX";  // poll / pollfd / POLLIN for the blocking/timeout reads

// data + object proxy + up to 10 event args. wl_output.geometry (8 args) is the widest.
MAX_EVENT_SLOTS :: 12;

Listener_Fn :: #type (a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64,
                      a6: u64, a7: u64, a8: u64, a9: u64, a10: u64, a11: u64) -> void #c_call;

// ── queue management (exported) ──

#program_export
wl_display_create_queue :: (display: *Wl_Display) -> *Wl_Event_Queue #c_call {
    q: *Wl_Event_Queue;
    ctx := shim_context;
    push_context ctx {
        q = New(Wl_Event_Queue);
        q.display = display;
        array_add(*display.queues, q);
    }
    return q;
}

#program_export
wl_display_create_queue_with_name :: (display: *Wl_Display, name: *u8) -> *Wl_Event_Queue #c_call {
    q := wl_display_create_queue(display);
    if name != null {
        ctx := shim_context;
        push_context ctx { q.name = copy_string(to_string(name)); }
    }
    return q;
}

#program_export
wl_proxy_set_queue :: (proxy: *Wl_Proxy, queue: *Wl_Event_Queue) #c_call {
    proxy.queue = ifx queue != null then queue else *proxy.display.default_queue;
}

// A wrapper shares the wrapped object's id but can be assigned its own dispatch queue;
// new objects marshalled THROUGH it inherit that queue (how the ICD parks its protocol
// traffic on a private queue). Not registered — events still route to the real proxy.
#program_export
wl_proxy_create_wrapper :: (proxy: *Wl_Proxy) -> *Wl_Proxy #c_call {
    w: *Wl_Proxy;
    ctx := shim_context;
    push_context ctx {
        w  = New(Wl_Proxy);
        w.* = proxy.*;
    }
    return w;
}

#program_export
wl_proxy_add_listener :: (proxy: *Wl_Proxy, implementation: *void, data: *void) -> s32 #c_call {
    proxy.listener  = implementation;
    proxy.user_data = data;
    return 0;
}

// ── dispatch (exported) ──

#program_export
wl_display_dispatch_queue_pending :: (display: *Wl_Display, queue: *Wl_Event_Queue) -> s32 #c_call {
    n: int;
    ctx := shim_context;
    push_context ctx { n = decode_and_dispatch(queue); }
    return cast(s32) n;
}

#program_export
wl_display_dispatch_queue :: (display: *Wl_Display, queue: *Wl_Event_Queue) -> s32 #c_call {
    n: int;
    ctx := shim_context;
    push_context ctx {
        Way.wayland_send(*display.conn, *display.out);  // flush requests first
        while queue.pending.count == 0 {
            if !read_socket(display, -1)  break;        // block until something arrives
        }
        n = decode_and_dispatch(queue);
    }
    return cast(s32) n;
}

#program_export
wl_display_dispatch_queue_timeout :: (display: *Wl_Display, queue: *Wl_Event_Queue, timeout: *timespec) -> s32 #c_call {
    n: int;
    ctx := shim_context;
    push_context ctx {
        Way.wayland_send(*display.conn, *display.out);
        ms: s32 = -1;
        if timeout != null  ms = cast(s32)(timeout.tv_sec * 1000 + timeout.tv_nsec / 1_000_000);
        if queue.pending.count == 0  read_socket(display, ms);
        n = decode_and_dispatch(queue);
    }
    return cast(s32) n;
}

#program_export
wl_display_dispatch_queue_pending_single :: (display: *Wl_Display, queue: *Wl_Event_Queue) -> s32 #c_call {
    return wl_display_dispatch_queue_pending(display, queue);
}

// Marshal wl_display.sync on `queue`, then dispatch until its callback fires.
#program_export
wl_display_roundtrip_queue :: (display: *Wl_Display, queue: *Wl_Event_Queue) -> s32 #c_call {
    total: int;
    ctx := shim_context;
    push_context ctx {
        done := false;

        // A single-entry wl_callback listener vtable ([0] == .done). Lives on this
        // stack frame, which outlives the dispatch loop below — the callback can only
        // fire while we are inside that loop, so the stack lifetime is sufficient.
        vtable: [1] *void;
        vtable[0] = cast(*void) roundtrip_done;

        // wl_display.sync (opcode 0) → new wl_callback, routed to `queue`.
        // wl_callback_interface comes from tables.jai (Task 6).
        args: [1] wl_argument;
        args[0].n = 0;
        cb := marshal_impl(*display.proxy, WL_DISPLAY_SYNC, *wl_callback_interface, 1, 0, args.data);
        if cb != null {
            cb.queue     = queue;
            cb.listener  = vtable.data;
            cb.user_data = *done;
        }
        Way.wayland_send(*display.conn, *display.out);

        while !done {
            if !read_socket(display, -1)  break;
            total += decode_and_dispatch(queue);
        }
    }
    return cast(s32) total;
}

// The roundtrip callback's done handler: flip the *bool in user_data.
roundtrip_done :: (data: *void, callback: *void, serial: u32) #c_call {
    if data != null {
        (cast(*bool) data).* = true;
    }
}

#scope_module

// Read once from the socket (poll with timeout_ms: -1 block, 0 non-block, N ms), then
// demux whatever arrived. Returns true if any bytes were read.
read_socket :: (display: *Wl_Display, timeout_ms: s32) -> bool {
    if timeout_ms >= 0 {
        pfd: pollfd;
        pfd.fd     = display.conn.socket_fd;
        pfd.events = POLLIN;
        r := poll(*pfd, 1, timeout_ms);
        if r <= 0  return false;  // timeout or error
    }
    n := Way.wayland_receive(*display.conn, *display.in_buf);
    if n <= 0  return false;
    demux_buffer(display);
    return true;
}

#scope_export

// Move every complete message currently in the ReceiveBuffer into its target proxy's
// queue (copying payload + fds so the buffer can be compacted). Public for unit tests.
demux_buffer :: (display: *Wl_Display) {
    while true {
        src, size := Way.receive_peek_message(*display.in_buf);
        if src == null  break;

        object_id, opcode, _ := Way.unpack_header(src);
        proxy := find_proxy(display, object_id);

        // How many fds belong to this event? (one per 'h' in its signature)
        fd_count := 0;
        if proxy != null && proxy.interface_ != null && cast(s32) opcode < proxy.interface_.event_count {
            ev_msg := proxy.interface_.events + opcode;
            sig := to_string(ev_msg.signature);
            for c: sig  if c == #char "h"  fd_count += 1;
        }

        qe: Queued_Event;
        qe.object_id = object_id;
        qe.opcode    = opcode;

        payload_len := cast(s64) size - 8;
        if payload_len > 0 {
            buf := alloc(payload_len);
            memcpy(buf, src + 8, payload_len);
            qe.payload = .{ data = buf, count = payload_len };
        }
        if fd_count > 0 {
            fbuf := cast(*s32) alloc(fd_count * size_of(s32));
            for i: 0..fd_count-1  fbuf[i] = Way.receive_pop_fd(*display.in_buf);
            qe.fds = .{ data = fbuf, count = fd_count };
        }

        Way.receive_consume_message(*display.in_buf, size);

        target := ifx proxy != null then proxy.queue else *display.default_queue;
        array_add(*target.pending, qe);
    }
}

// Decode + invoke every pending event on `queue`, then clear it. Public for unit tests.
decode_and_dispatch :: (queue: *Wl_Event_Queue) -> int {
    display := queue.display;
    dispatched := 0;

    for ev: queue.pending {
        proxy := find_proxy(display, ev.object_id);
        if proxy == null || proxy.listener == null  continue;

        fn_ptr := (cast(**void) proxy.listener)[ev.opcode];
        if fn_ptr == null  continue;

        msg := proxy.interface_.events + ev.opcode;
        sig := to_string(msg.signature);

        slots: [MAX_EVENT_SLOTS] u64;
        ns := 0;
        slots[ns] = cast(u64) proxy.user_data; ns += 1;  // listener arg 0: data
        slots[ns] = cast(u64) proxy;           ns += 1;  // listener arg 1: object proxy

        src   := ev.payload.data;
        off   := 0;
        arg_k := 0;   // wire-arg index (for msg.types lookups)
        fd_i  := 0;

        for ci: 0..sig.count-1 {
            c := sig[ci];
            if c == #char "?"                    continue;
            if c >= #char "0" && c <= #char "9"  continue;

            if c == {
                case #char "i"; #through;
                case #char "u";
                    slots[ns] = cast(u64) Way.read_u32(src + off); off += 4;
                case #char "f";
                    v := Way.read_s32(src + off); off += 4;
                    slots[ns] = cast(u64) (cast(u32) v);
                case #char "s";
                    str, consumed := Way.read_string(src + off); off += consumed;
                    slots[ns] = ifx str.count > 0 then cast(u64) str.data else cast(u64) 0;
                case #char "o";
                    oid := Way.read_u32(src + off); off += 4;
                    op  := ifx oid != 0 then find_proxy(display, oid) else null;
                    slots[ns] = cast(u64) op;
                case #char "n";
                    nid := Way.read_u32(src + off); off += 4;
                    niface: *wl_interface = null;
                    if msg.types != null  niface = msg.types[arg_k];
                    np := make_proxy(display, nid, niface, proxy.version, proxy.queue);
                    slots[ns] = cast(u64) np;
                case #char "a";
                    arr, consumed := Way.read_array(src + off); off += consumed;
                    wa := New(wl_array);  // slice-1: small per-event leak (events with arrays are rare for the WSI)
                    wa.size = cast(u64) arr.count; wa.alloc = cast(u64) arr.count; wa.data = arr.data;
                    slots[ns] = cast(u64) wa;
                case #char "h";
                    slots[ns] = cast(u64) (cast(u32) ev.fds[fd_i]); fd_i += 1;
            }
            ns    += 1;
            arg_k += 1;
        }

        invoke_listener(fn_ptr, slots, ns);
        dispatched += 1;
    }

    // Free the copies and reset the queue.
    for ev: queue.pending {
        if ev.payload.data  free(ev.payload.data);
        if ev.fds.data      free(ev.fds.data);
    }
    queue.pending.count = 0;

    return dispatched;
}

#scope_module

// Call a listener fn ptr through the fixed wide signature; `n` real slots, rest zero.
invoke_listener :: (fn_ptr: *void, slots: [MAX_EVENT_SLOTS] u64, n: int) {
    f := cast(Listener_Fn) fn_ptr;
    f(slots[0], slots[1], slots[2], slots[3], slots[4],  slots[5],
      slots[6], slots[7], slots[8], slots[9], slots[10], slots[11]);
}
