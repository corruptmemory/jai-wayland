// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jim Powers
//
// The runtime, signature-driven marshaller — the provider half of bucket 3, piece A.
//
// This is the runtime sibling of the native `wayland` module's COMPILE-TIME `marshal`
// macro: instead of walking a Jai arg struct's type_info at compile time, it walks the
// `wl_message.signature` string at run time (the ICD hands us only opcode + a generic
// `wl_argument[]`), packs the wire image onto the native MessageBuilder, allocates the
// new object on a `new_id` arg, and returns the new proxy.
//
// The variadic `wl_proxy_marshal_flags` the ICD actually calls lives in
// wl_marshal_varargs.c, which unpacks C varargs into a wl_argument[] and tail-calls
// THIS function. Pure Jai here; the only C in the project is that one bridge.

MAX_WIRE :: 4096;  // Wayland max message size; one message always fits.

// The exported C-ABI entry point. #c_call → no Jai context until we install one.
#program_export
wl_proxy_marshal_array_flags :: (proxy: *Wl_Proxy, opcode: u32, interface_: *wl_interface, version: u32, flags: u32, args: *wl_argument) -> *Wl_Proxy #c_call {
    result: *Wl_Proxy = null;
    ctx := shim_context;
    push_context ctx {
        result = marshal_impl(proxy, opcode, interface_, version, flags, args);
    }
    return result;
}

#scope_module

// `interface`/`version` describe the object a `new_id` arg creates (null/0 if none).
// The message itself is proxy.interface.methods[opcode].
marshal_impl :: (proxy: *Wl_Proxy, opcode: u32, new_iface: *wl_interface, new_version: u32, flags: u32, args: *wl_argument) -> *Wl_Proxy {
    display := proxy.display;
    msg     := proxy.interface_.methods + opcode;   // *wl_message
    sig     := to_string(msg.signature);

    buf: [MAX_WIRE] u8;
    off: u32 = 8;            // reserve the 8-byte header
    created: *Wl_Proxy = null;

    k := 0;                  // index into args[] (advances only on real arg chars)
    for ci: 0..sig.count-1 {
        c := sig[ci];
        if c == #char "?"                       continue;  // nullable modifier (no arg slot)
        if c >= #char "0" && c <= #char "9"     continue;  // leading "since" version digits

        a := args[k];
        if c == {
            case #char "i"; #through;
            case #char "u";
                Way.write_u32(buf.data + off, a.u);
                off += 4;
            case #char "f";
                Way.write_s32(buf.data + off, a.f);
                off += 4;
            case #char "s";
                s: string;
                if a.s != null  s = to_string(a.s);
                off += Way.write_string(buf.data + off, s);
            case #char "o";
                oid: u32 = 0;
                if a.o != null  oid = (cast(*Wl_Proxy) a.o).id;
                Way.write_u32(buf.data + off, oid);
                off += 4;
            case #char "n";
                // Exactly one new object per message; created from the passed interface.
                id := Way.allocate_id(*display.conn);
                created = make_proxy(display, id, new_iface, new_version, proxy.queue);
                Way.write_u32(buf.data + off, id);
                off += 4;
            case #char "a";
                slice: [] u8;
                if a.a != null { slice.data = a.a.data; slice.count = cast(s64) a.a.size; }
                off += Way.write_array(buf.data + off, slice);
            case #char "h";
                Way.message_queue_fd(*display.out, a.h);  // out-of-band (SCM_RIGHTS), not in buf
        }
        k += 1;
    }

    assert(off <= MAX_WIRE, "wayland message exceeded MAX_WIRE (%)", off);
    Way.pack_header(buf.data, proxy.id, cast(u16) opcode, off);

    // Flush first if this message would overflow the outgoing batch (libwayland-style).
    if display.out.out_used + off > cast(u32) display.out.out_buf.count {
        Way.wayland_send(*display.conn, *display.out);
    }
    Way.message_queue(*display.out, buf.data, off);

    // A destructor request folds destruction in: stop routing events to this id.
    // (slice-1: unregister only; we leak the heap proxy rather than risk freeing the
    // display's embedded proxy — lifetimes get tightened once the path is proven.)
    if (flags & WL_MARSHAL_FLAG_DESTROY) != 0 {
        unregister_proxy(display, proxy.id);
    }

    return created;
}
