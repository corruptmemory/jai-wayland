// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jim Powers
//
// Interface tables (bucket 1) — the #program_export'd wl_*_interface graphs the ICD
// references as DATA symbols, plus the request opcode constants the engine needs.
//
// TASK 6 (in progress): hand-author / lift from game-bootstrap the full slice-1 set
// (wl_display, wl_registry, wl_callback, wl_compositor, wl_surface, wl_shm, xdg_wm_base,
// xdg_surface, xdg_toplevel, zwp_linux_dmabuf_v1, …). For now this carries only the
// minimum the engine references so the module compiles and the dispatch path can be
// unit-tested; roundtrip_queue is exercised at the integration milestone once the real
// wl_display/wl_callback tables land here.

WL_DISPLAY_SYNC         :: 0;  // wl_display.sync
WL_DISPLAY_GET_REGISTRY :: 1;  // wl_display.get_registry

// Placeholder — real table (name/version/methods/events) lands in Task 6. Zeroed is
// safe because nothing exercises it until roundtrip_queue runs against a live socket.
wl_callback_interface: wl_interface;
