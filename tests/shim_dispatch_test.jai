// Unit test for the libwayland_shim event/dispatch engine (Task 5).
// ~/jai/jai/bin/jai-linux tests/shim_dispatch_test.jai
//
// Crafts a synthetic compositor event, runs it through demux_buffer +
// decode_and_dispatch, and asserts the decoded args arrive at a REAL-signature
// listener invoked through the fixed 12-u64 wide signature — the ABI trick that lets
// the engine call any listener with no C trampoline.

#import "Basic";
S :: #import,dir "../modules/libwayland_shim";

// What the listener records (string copied out, since the event payload is freed
// after dispatch — exactly the contract real libwayland listeners live under).
rec_data:    *void;
rec_proxy:   *void;
rec_val:     u32;
rec_str_buf: [64] u8;

// The actual event callback — real signature for event "us" (uint, string). #c_call,
// no context, so the string copy is a manual NUL-bounded loop (no to_string).
test_on_event :: (data: *void, proxy: *void, val: u32, str: *u8) #c_call {
    rec_data  = data;
    rec_proxy = proxy;
    rec_val   = val;
    i := 0;
    while str != null && str[i] != 0 && i < 63 { rec_str_buf[i] = str[i]; i += 1; }
    rec_str_buf[i] = 0;
}

w32 :: (m: *u8, off: int, v: u32) { (cast(*u32)(m + off)).* = v; }

main :: () {
    S.shim_context = context;

    display: S.Wl_Display;
    display.proxy.display         = *display;
    display.default_queue.display = *display;

    // Synthetic interface "evt": one event, opcode 0, signature "us".
    events: [1] S.wl_message;
    events[0].name = to_c_string("ping"); events[0].signature = to_c_string("us"); events[0].types = null;
    iface: S.wl_interface;
    iface.name = to_c_string("evt"); iface.version = 1;
    iface.event_count = 1; iface.events = events.data;

    // Proxy id 5 on the default queue, with our listener installed.
    p := S.make_proxy(*display, 5, *iface, 1, *display.default_queue);
    vtable: [1] *void;
    vtable[0] = cast(*void) test_on_event;
    my_data := cast(*void) 0xD00D;
    S.wl_proxy_add_listener(p, cast(*void) vtable.data, my_data);

    // Craft the wire event: object 5, opcode 0, payload = uint 0xCAFE + string "hi".
    // payload = 4 (uint) + 4 (len=3) + 4 ("hi\0"+pad) = 12 ; total size = 20.
    msg: [20] u8;
    w32(msg.data, 0, 5);                          // object id
    w32(msg.data, 4, (cast(u32) 20 << 16) | 0);   // (size<<16)|opcode
    w32(msg.data, 8, 0xCAFE);                     // uint arg
    w32(msg.data, 12, 3);                         // string length (incl NUL)
    msg[16] = #char "h"; msg[17] = #char "i"; msg[18] = 0; msg[19] = 0;

    memcpy(display.in_buf.in_buf.data, msg.data, 20);
    display.in_buf.in_used = 20;
    display.in_buf.in_read = 0;

    S.demux_buffer(*display);
    assert(display.default_queue.pending.count == 1, "demux routed exactly 1 event");
    print("  PASS: demux routed event to its queue\n");

    n := S.decode_and_dispatch(*display.default_queue);
    assert(n == 1, "dispatched exactly 1 event, got %", n);
    assert(display.default_queue.pending.count == 0, "queue drained after dispatch");

    assert(rec_data  == my_data,        "listener data arg");
    assert(rec_proxy == cast(*void) p,  "listener proxy arg");
    assert(rec_val   == 0xCAFE,         "decoded uint: got 0x%", formatInt(rec_val, base=16));
    s := to_string(rec_str_buf.data);
    assert(s == "hi", "decoded string: got '%'", s);
    print("  PASS: decode + wide-signature invoke (data, proxy, uint, string all correct)\n");

    print("\nshim_dispatch_test: ALL PASS\n");
}
