// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jim Powers
//
// libwayland-client PROXY (duck-type) module.
//
// Exposes the public libwayland-client C ABI (the ~26 wl_* symbols a Vulkan ICD
// imports) backed by the native `wayland` wire client, so the driver can be handed
// our objects through vkCreateWaylandSurfaceKHR and never touch real libwayland.
//
// See docs/plans/2026-06-24-libwayland-proxy-{design,plan}.md and the proven
// symbol-scope linchpin in spikes/symbol-scope/.
//
// CONTEXT DISCIPLINE: every exported entry point is #c_call — the ICD calls it with
// the C ABI and NO Jai context. Such a body cannot allocate/log until it installs a
// context. We capture one on the main thread at shim_connect() into `shim_context`
// and each exported #c_call wraps its body in `push_context shim_context { ... }`.
// This is single-threaded for slice 1 (the game-bootstrap "Thread idiom", minus the
// per-thread refresh we defer). The ICD's WSI calls land on our render thread,
// strictly sequenced with our own pump.

#import "Basic";

// The native wire engine. Qualified so its names (write_*, Connection, allocate_id,
// MAX_MESSAGE_SIZE, …) never collide with the libwayland C ABI we define here.
Way :: #import,dir "../wayland";

// Captured at shim_connect() on the main thread; installed by every exported #c_call.
shim_context: #Context;

// Marshal flag: fold object destruction into the marshal (no separate wl_proxy_destroy).
WL_MARSHAL_FLAG_DESTROY :: 1;

#load "types.jai";
#load "tables.jai";
#load "marshal_runtime.jai";
#load "core_trivial.jai";
#load "queues.jai";
#load "facade.jai";
