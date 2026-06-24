// Unit test for libwayland_shim wl_list + proxy accessors (Task 4).
// ~/jai/jai/bin/jai-linux tests/shim_list_test.jai

#import "Basic";
S :: #import,dir "../modules/libwayland_shim";

main :: () {
    // ── wl_list invariants ──
    head: S.wl_list;
    S.wl_list_init(*head);
    assert(head.next == *head && head.prev == *head, "init: empty list self-loops");

    e1: S.wl_list; e2: S.wl_list; e3: S.wl_list;
    S.wl_list_insert(*head, *e1);   // [e1]
    S.wl_list_insert(*head, *e2);   // insert after head → [e2, e1]
    S.wl_list_insert(*e2,   *e3);   // insert after e2   → [e2, e3, e1]

    assert(head.next == *e2, "order: head.next == e2");
    assert(e2.next   == *e3, "order: e2.next == e3");
    assert(e3.next   == *e1, "order: e3.next == e1");
    assert(e1.next   == *head, "order: e1.next == head (ring closed)");
    assert(e3.prev   == *e2 && e1.prev == *e3, "back-links consistent");
    print("  PASS: wl_list insert order\n");

    S.wl_list_remove(*e3);          // → [e2, e1]
    assert(e2.next == *e1 && e1.prev == *e2, "remove splices neighbours");
    assert(e3.next == null && e3.prev == null, "remove nulls the removed node");
    print("  PASS: wl_list remove\n");

    // ── proxy accessors ──
    p: S.Wl_Proxy;
    p.id = 99; p.version = 7;
    assert(S.wl_proxy_get_id(*p)      == 99, "get_id");
    assert(S.wl_proxy_get_version(*p) == 7,  "get_version");
    print("  PASS: proxy accessors\n");

    print("\nshim_list_test: ALL PASS\n");
}
