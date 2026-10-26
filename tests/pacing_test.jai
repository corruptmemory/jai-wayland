// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jim Powers

// Frame-callback orphan list (Wayland_Support's starvation recovery). A pacing
// wait that gives up on a frame callback orphans its id; a late wl_callback.done
// for that id is taken back exactly once, which is what lets the router clear
// wl_pacing_starved and recycle the id. Pure bookkeeping on a stack window: no
// compositor, nothing dlopen'd.

#import "Basic";
WS :: #import,file "../modules/Wayland_Support.jai";

main :: () {
    print("=== Pacing Tests ===\n\n");

    test_orphan_take_returns_true_once();
    test_orphan_cap_evicts_oldest();

    print("\n=== All pacing tests passed ===\n");
}

// An orphaned id is taken back once; a second take, or a take of an id never
// orphaned, finds nothing.
test_orphan_take_returns_true_once :: () {
    ww: WS.Wayland_Window;
    WS.wl_orphan_frame_callback(*ww, 7);

    assert(WS.wl_take_orphaned_frame_callback(*ww, 7),  "first take of orphaned 7 returned false");
    assert(!WS.wl_take_orphaned_frame_callback(*ww, 7), "second take of 7 returned true");
    assert(!WS.wl_take_orphaned_frame_callback(*ww, 8), "take of never-orphaned 8 returned true");

    print("  PASS: orphan_take_returns_true_once\n");
}

// One past the cap drops the OLDEST entry; everything newer survives. The
// oldest-first order must also survive a take from the middle of the list.
test_orphan_cap_evicts_oldest :: () {
    assert(WS.WL_ORPHANED_CALLBACK_CAP == 256, "cap is %, the test counts on 256", WS.WL_ORPHANED_CALLBACK_CAP);

    ww: WS.Wayland_Window;
    for id: 1..257  WS.wl_orphan_frame_callback(*ww, cast(u32) id);

    assert(!WS.wl_take_orphaned_frame_callback(*ww, 1), "oldest id 1 survived past the cap");
    assert(WS.wl_take_orphaned_frame_callback(*ww, 2),   "id 2 was evicted, only 1 should be");
    assert(WS.wl_take_orphaned_frame_callback(*ww, 257), "newest id 257 was not kept");

    // Take, then overflow: after taking 1 from a full list, 257 refills it and
    // 258 must evict 2 (now the oldest), not the second-newest 256.
    taken: WS.Wayland_Window;
    for id: 1..256  WS.wl_orphan_frame_callback(*taken, cast(u32) id);
    assert(WS.wl_take_orphaned_frame_callback(*taken, 1), "take of orphaned 1 from a full list returned false");
    WS.wl_orphan_frame_callback(*taken, 257);
    WS.wl_orphan_frame_callback(*taken, 258);

    assert(!WS.wl_take_orphaned_frame_callback(*taken, 2), "oldest id 2 survived the overflow after a take");
    assert(WS.wl_take_orphaned_frame_callback(*taken, 256), "id 256 was evicted in place of the oldest");

    print("  PASS: orphan_cap_evicts_oldest\n");
}
