// Unit test for the libwayland_shim runtime marshaller (Task 2).
// Standalone program: ~/jai/jai/bin/jai-linux tests/shim_marshal_test.jai
//
// Builds synthetic wl_interface/wl_message graphs, calls the exported
// wl_proxy_marshal_array_flags, and asserts the exact wire image it appended to the
// native MessageBuilder — the same byte-level discipline as tests/marshal_test.jai.

#import "Basic";
S :: #import,dir "../modules/libwayland_shim";

make_message :: (name: string, sig: string) -> S.wl_message {
    m: S.wl_message;
    m.name      = to_c_string(name);
    m.signature = to_c_string(sig);
    m.types     = null;
    return m;
}

check_bytes :: (got: *u8, used: u32, expect: [] u8, label: string) {
    assert(used == cast(u32) expect.count, "[%] size: got % want %", label, used, expect.count);
    for i: 0..expect.count-1 {
        assert(got[i] == expect[i], "[%] byte %: got 0x% want 0x%", label, i, formatInt(got[i], base=16), formatInt(expect[i], base=16));
    }
    print("  PASS: %\n", label);
}

main :: () {
    S.shim_context = context;  // the exported #c_call installs this

    display: S.Wl_Display;
    display.proxy.display      = *display;
    display.default_queue.display = *display;

    // ── Case 1: signature "uf" (uint, fixed), no new object ──
    {
        display.out.out_used = 0;
        display.conn.next_id  = 100;

        reqs: [1] S.wl_message;
        reqs[0] = make_message("ping", "uf");
        iface: S.wl_interface;
        iface.name = to_c_string("test"); iface.version = 1;
        iface.method_count = 1; iface.methods = reqs.data;

        p: S.Wl_Proxy;
        p.id = 2; p.interface_ = *iface; p.version = 1; p.display = *display; p.queue = *display.default_queue;

        args: [2] S.wl_argument;
        args[0].u = 0x1122_3344;
        args[1].f = 256;  // 1.0 in 24.8 fixed

        ret := S.wl_proxy_marshal_array_flags(*p, 0, null, 0, 0, args.data);
        assert(ret == null, "case1 should create no object");
        // header: id=2, word2=(16<<16)|0 ; payload: u32 0x11223344, s32 256
        expect := u8.[0x02,0,0,0,  0x00,0x00,0x10,0x00,  0x44,0x33,0x22,0x11,  0x00,0x01,0x00,0x00];
        check_bytes(display.out.out_buf.data, display.out.out_used, expect, "case1 uf");
    }

    // ── Case 2: signature "n" (new_id) — allocates + returns a proxy ──
    {
        display.out.out_used = 0;
        display.conn.next_id  = 5;

        reqs: [1] S.wl_message;
        reqs[0] = make_message("create", "n");
        iface: S.wl_interface;
        iface.name = to_c_string("factory"); iface.version = 1;
        iface.method_count = 1; iface.methods = reqs.data;

        obj_iface: S.wl_interface;
        obj_iface.name = to_c_string("obj"); obj_iface.version = 3;

        p: S.Wl_Proxy;
        p.id = 1; p.interface_ = *iface; p.version = 1; p.display = *display; p.queue = *display.default_queue;

        args: [1] S.wl_argument;
        args[0].n = 0;  // placeholder; the marshaller fills the real id

        ret := S.wl_proxy_marshal_array_flags(*p, 0, *obj_iface, 3, 0, args.data);
        assert(ret != null, "case2 should create an object");
        assert(ret.id == 5, "case2 new id: got %", ret.id);
        assert(ret.interface_ == *obj_iface, "case2 new interface mismatch");
        assert(ret.version == 3, "case2 new version: got %", ret.version);
        // header: id=1, word2=(12<<16)|0 ; payload: new id 5
        expect := u8.[0x01,0,0,0,  0x00,0x00,0x0C,0x00,  0x05,0,0,0];
        check_bytes(display.out.out_buf.data, display.out.out_used, expect, "case2 new_id");
    }

    // ── Case 3: signature "s" (string) — length+data+nul+pad ──
    {
        display.out.out_used = 0;
        display.conn.next_id  = 100;

        reqs: [1] S.wl_message;
        reqs[0] = make_message("say", "s");
        iface: S.wl_interface;
        iface.name = to_c_string("speaker"); iface.version = 1;
        iface.method_count = 1; iface.methods = reqs.data;

        p: S.Wl_Proxy;
        p.id = 3; p.interface_ = *iface; p.version = 1; p.display = *display; p.queue = *display.default_queue;

        args: [1] S.wl_argument;
        args[0].s = to_c_string("hi");

        ret := S.wl_proxy_marshal_array_flags(*p, 0, null, 0, 0, args.data);
        assert(ret == null, "case3 should create no object");
        // header: id=3, word2=(16<<16)|0 ; payload: len=3, "hi\0" + 1 pad
        expect := u8.[0x03,0,0,0,  0x00,0x00,0x10,0x00,  0x03,0,0,0,  0x68,0x69,0x00,0x00];
        check_bytes(display.out.out_buf.data, display.out.out_used, expect, "case3 string");
    }

    print("\nshim_marshal_test: ALL PASS\n");
}
