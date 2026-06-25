// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jim Powers
//
// Interface tables (bucket 1) — the libwayland-flavored wl_*_interface / wl_message
// graph the marshaller (proxy.interface_.methods[opcode]) and dispatch
// (proxy.interface_.events[opcode]) walk at run time, plus the request opcode constants.
//
// PROVENANCE: lifted byte-for-byte from game-bootstrap
// modules/Wayland_Client/protocol.generated.jai (emitted by that project's
// modules/wayland/code-generator/src/libwayland_emit.jai). Our wl_message /
// wl_interface ABI structs (types.jai) are identical to game-bootstrap's, and a Jai
// string literal implicitly converts to the *u8 (const char*) name/signature fields as
// a NUL-terminated data-segment constant — so the data lifts verbatim. The `types`
// back-pointer arrays start null and are patched at run time by wl_protocol_tables_init
// (call it once at facade connect).
//
// SLICE-1 SCOPE: these are plain Jai data, consumed only by OUR engine. For Task 7 the
// Vulkan ICD will reference a subset (wl_display/registry/callback/compositor/surface/…)
// as undefined DATA symbols to be interposed — that data-symbol export is a separate
// step (see the Task-7 spike); annotating these globals does not change the data.
//
// Covers: wayland (23 interfaces) + xdg_shell (5 interfaces). No zwp_linux_dmabuf_v1
// (the Mesa ICD bundles its own); extension tables get added if registry-log discovery
// shows the ICD imports them.


// ══ interface / message table graph ══

// ── wl_display (v1) ──
wl_display_types: [5] *wl_interface = .[
    null,
    null,
    null,
    null,
    null,
];
wl_display_requests: [2] wl_message = .[
    .{ "sync", "n", wl_display_types.data + 3 },
    .{ "get_registry", "n", wl_display_types.data + 4 },
];
wl_display_events: [2] wl_message = .[
    .{ "error", "ous", wl_display_types.data + 0 },
    .{ "delete_id", "u", wl_display_types.data + 0 },
];
wl_display_interface: wl_interface = .{
    name         = "wl_display",
    version      = 1,
    method_count = 2,
    methods      = wl_display_requests.data,
    event_count  = 2,
    events       = wl_display_events.data,
};

// ── wl_registry (v1) ──
wl_registry_types: [4] *wl_interface = .[
    null,
    null,
    null,
    null,
];
wl_registry_requests: [1] wl_message = .[
    .{ "bind", "usun", wl_registry_types.data + 0 },
];
wl_registry_events: [2] wl_message = .[
    .{ "global", "usu", wl_registry_types.data + 0 },
    .{ "global_remove", "u", wl_registry_types.data + 0 },
];
#program_export   // ICD data import (nm -D --undefined libvulkan_radeon.so)
wl_registry_interface: wl_interface = .{
    name         = "wl_registry",
    version      = 1,
    method_count = 1,
    methods      = wl_registry_requests.data,
    event_count  = 2,
    events       = wl_registry_events.data,
};

// ── wl_callback (v1) ──
wl_callback_types: [1] *wl_interface = .[
    null,
];
wl_callback_events: [1] wl_message = .[
    .{ "done", "u", wl_callback_types.data + 0 },
];
#program_export   // ICD data import (nm -D --undefined libvulkan_radeon.so)
wl_callback_interface: wl_interface = .{
    name         = "wl_callback",
    version      = 1,
    method_count = 0,
    methods      = null,
    event_count  = 1,
    events       = wl_callback_events.data,
};

// ── wl_compositor (v6) ──
wl_compositor_types: [2] *wl_interface = .[
    null,
    null,
];
wl_compositor_requests: [2] wl_message = .[
    .{ "create_surface", "n", wl_compositor_types.data + 0 },
    .{ "create_region", "n", wl_compositor_types.data + 1 },
];
wl_compositor_interface: wl_interface = .{
    name         = "wl_compositor",
    version      = 6,
    method_count = 2,
    methods      = wl_compositor_requests.data,
    event_count  = 0,
    events       = null,
};

// ── wl_shm_pool (v2) ──
wl_shm_pool_types: [7] *wl_interface = .[
    null,
    null,
    null,
    null,
    null,
    null,
    null,
];
wl_shm_pool_requests: [3] wl_message = .[
    .{ "create_buffer", "niiiiu", wl_shm_pool_types.data + 1 },
    .{ "destroy", "", wl_shm_pool_types.data + 0 },
    .{ "resize", "i", wl_shm_pool_types.data + 0 },
];
#program_export   // ICD data import (nm -D --undefined libvulkan_radeon.so)
wl_shm_pool_interface: wl_interface = .{
    name         = "wl_shm_pool",
    version      = 2,
    method_count = 3,
    methods      = wl_shm_pool_requests.data,
    event_count  = 0,
    events       = null,
};

// ── wl_shm (v2) ──
wl_shm_types: [4] *wl_interface = .[
    null,
    null,
    null,
    null,
];
wl_shm_requests: [2] wl_message = .[
    .{ "create_pool", "nhi", wl_shm_types.data + 1 },
    .{ "release", "2", wl_shm_types.data + 0 },
];
wl_shm_events: [1] wl_message = .[
    .{ "format", "u", wl_shm_types.data + 0 },
];
#program_export   // ICD data import (nm -D --undefined libvulkan_radeon.so)
wl_shm_interface: wl_interface = .{
    name         = "wl_shm",
    version      = 2,
    method_count = 2,
    methods      = wl_shm_requests.data,
    event_count  = 1,
    events       = wl_shm_events.data,
};

// ── wl_buffer (v1) ──
wl_buffer_types: [0] *wl_interface = .[
];
wl_buffer_requests: [1] wl_message = .[
    .{ "destroy", "", wl_buffer_types.data + 0 },
];
wl_buffer_events: [1] wl_message = .[
    .{ "release", "", wl_buffer_types.data + 0 },
];
#program_export   // ICD data import (nm -D --undefined libvulkan_radeon.so)
wl_buffer_interface: wl_interface = .{
    name         = "wl_buffer",
    version      = 1,
    method_count = 1,
    methods      = wl_buffer_requests.data,
    event_count  = 1,
    events       = wl_buffer_events.data,
};

// ── wl_data_offer (v3) ──
wl_data_offer_types: [2] *wl_interface = .[
    null,
    null,
];
wl_data_offer_requests: [5] wl_message = .[
    .{ "accept", "u?s", wl_data_offer_types.data + 0 },
    .{ "receive", "sh", wl_data_offer_types.data + 0 },
    .{ "destroy", "", wl_data_offer_types.data + 0 },
    .{ "finish", "3", wl_data_offer_types.data + 0 },
    .{ "set_actions", "3uu", wl_data_offer_types.data + 0 },
];
wl_data_offer_events: [3] wl_message = .[
    .{ "offer", "s", wl_data_offer_types.data + 0 },
    .{ "source_actions", "3u", wl_data_offer_types.data + 0 },
    .{ "action", "3u", wl_data_offer_types.data + 0 },
];
wl_data_offer_interface: wl_interface = .{
    name         = "wl_data_offer",
    version      = 3,
    method_count = 5,
    methods      = wl_data_offer_requests.data,
    event_count  = 3,
    events       = wl_data_offer_events.data,
};

// ── wl_data_source (v3) ──
wl_data_source_types: [2] *wl_interface = .[
    null,
    null,
];
wl_data_source_requests: [3] wl_message = .[
    .{ "offer", "s", wl_data_source_types.data + 0 },
    .{ "destroy", "", wl_data_source_types.data + 0 },
    .{ "set_actions", "3u", wl_data_source_types.data + 0 },
];
wl_data_source_events: [6] wl_message = .[
    .{ "target", "?s", wl_data_source_types.data + 0 },
    .{ "send", "sh", wl_data_source_types.data + 0 },
    .{ "cancelled", "", wl_data_source_types.data + 0 },
    .{ "dnd_drop_performed", "3", wl_data_source_types.data + 0 },
    .{ "dnd_finished", "3", wl_data_source_types.data + 0 },
    .{ "action", "3u", wl_data_source_types.data + 0 },
];
wl_data_source_interface: wl_interface = .{
    name         = "wl_data_source",
    version      = 3,
    method_count = 3,
    methods      = wl_data_source_requests.data,
    event_count  = 6,
    events       = wl_data_source_events.data,
};

// ── wl_data_device (v3) ──
wl_data_device_types: [16] *wl_interface = .[
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
];
wl_data_device_requests: [3] wl_message = .[
    .{ "start_drag", "?oo?ou", wl_data_device_types.data + 3 },
    .{ "set_selection", "?ou", wl_data_device_types.data + 7 },
    .{ "release", "2", wl_data_device_types.data + 0 },
];
wl_data_device_events: [6] wl_message = .[
    .{ "data_offer", "n", wl_data_device_types.data + 9 },
    .{ "enter", "uoff?o", wl_data_device_types.data + 10 },
    .{ "leave", "", wl_data_device_types.data + 0 },
    .{ "motion", "uff", wl_data_device_types.data + 0 },
    .{ "drop", "", wl_data_device_types.data + 0 },
    .{ "selection", "?o", wl_data_device_types.data + 15 },
];
wl_data_device_interface: wl_interface = .{
    name         = "wl_data_device",
    version      = 3,
    method_count = 3,
    methods      = wl_data_device_requests.data,
    event_count  = 6,
    events       = wl_data_device_events.data,
};

// ── wl_data_device_manager (v3) ──
wl_data_device_manager_types: [3] *wl_interface = .[
    null,
    null,
    null,
];
wl_data_device_manager_requests: [2] wl_message = .[
    .{ "create_data_source", "n", wl_data_device_manager_types.data + 0 },
    .{ "get_data_device", "no", wl_data_device_manager_types.data + 1 },
];
wl_data_device_manager_interface: wl_interface = .{
    name         = "wl_data_device_manager",
    version      = 3,
    method_count = 2,
    methods      = wl_data_device_manager_requests.data,
    event_count  = 0,
    events       = null,
};

// ── wl_shell (v1) ──
wl_shell_types: [2] *wl_interface = .[
    null,
    null,
];
wl_shell_requests: [1] wl_message = .[
    .{ "get_shell_surface", "no", wl_shell_types.data + 0 },
];
wl_shell_interface: wl_interface = .{
    name         = "wl_shell",
    version      = 1,
    method_count = 1,
    methods      = wl_shell_requests.data,
    event_count  = 0,
    events       = null,
};

// ── wl_shell_surface (v1) ──
wl_shell_surface_types: [22] *wl_interface = .[
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
];
wl_shell_surface_requests: [10] wl_message = .[
    .{ "pong", "u", wl_shell_surface_types.data + 0 },
    .{ "move", "ou", wl_shell_surface_types.data + 3 },
    .{ "resize", "ouu", wl_shell_surface_types.data + 5 },
    .{ "set_toplevel", "", wl_shell_surface_types.data + 0 },
    .{ "set_transient", "oiiu", wl_shell_surface_types.data + 8 },
    .{ "set_fullscreen", "uu?o", wl_shell_surface_types.data + 12 },
    .{ "set_popup", "ouoiiu", wl_shell_surface_types.data + 15 },
    .{ "set_maximized", "?o", wl_shell_surface_types.data + 21 },
    .{ "set_title", "s", wl_shell_surface_types.data + 0 },
    .{ "set_class", "s", wl_shell_surface_types.data + 0 },
];
wl_shell_surface_events: [3] wl_message = .[
    .{ "ping", "u", wl_shell_surface_types.data + 0 },
    .{ "configure", "uii", wl_shell_surface_types.data + 0 },
    .{ "popup_done", "", wl_shell_surface_types.data + 0 },
];
wl_shell_surface_interface: wl_interface = .{
    name         = "wl_shell_surface",
    version      = 1,
    method_count = 10,
    methods      = wl_shell_surface_requests.data,
    event_count  = 3,
    events       = wl_shell_surface_events.data,
};

// ── wl_surface (v6) ──
wl_surface_types: [12] *wl_interface = .[
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
];
wl_surface_requests: [11] wl_message = .[
    .{ "destroy", "", wl_surface_types.data + 0 },
    .{ "attach", "?oii", wl_surface_types.data + 4 },
    .{ "damage", "iiii", wl_surface_types.data + 0 },
    .{ "frame", "n", wl_surface_types.data + 7 },
    .{ "set_opaque_region", "?o", wl_surface_types.data + 8 },
    .{ "set_input_region", "?o", wl_surface_types.data + 9 },
    .{ "commit", "", wl_surface_types.data + 0 },
    .{ "set_buffer_transform", "2i", wl_surface_types.data + 0 },
    .{ "set_buffer_scale", "3i", wl_surface_types.data + 0 },
    .{ "damage_buffer", "4iiii", wl_surface_types.data + 0 },
    .{ "offset", "5ii", wl_surface_types.data + 0 },
];
wl_surface_events: [4] wl_message = .[
    .{ "enter", "o", wl_surface_types.data + 10 },
    .{ "leave", "o", wl_surface_types.data + 11 },
    .{ "preferred_buffer_scale", "6i", wl_surface_types.data + 0 },
    .{ "preferred_buffer_transform", "6u", wl_surface_types.data + 0 },
];
#program_export   // ICD data import (nm -D --undefined libvulkan_radeon.so)
wl_surface_interface: wl_interface = .{
    name         = "wl_surface",
    version      = 6,
    method_count = 11,
    methods      = wl_surface_requests.data,
    event_count  = 4,
    events       = wl_surface_events.data,
};

// ── wl_seat (v10) ──
wl_seat_types: [4] *wl_interface = .[
    null,
    null,
    null,
    null,
];
wl_seat_requests: [4] wl_message = .[
    .{ "get_pointer", "n", wl_seat_types.data + 1 },
    .{ "get_keyboard", "n", wl_seat_types.data + 2 },
    .{ "get_touch", "n", wl_seat_types.data + 3 },
    .{ "release", "5", wl_seat_types.data + 0 },
];
wl_seat_events: [2] wl_message = .[
    .{ "capabilities", "u", wl_seat_types.data + 0 },
    .{ "name", "2s", wl_seat_types.data + 0 },
];
wl_seat_interface: wl_interface = .{
    name         = "wl_seat",
    version      = 10,
    method_count = 4,
    methods      = wl_seat_requests.data,
    event_count  = 2,
    events       = wl_seat_events.data,
};

// ── wl_pointer (v10) ──
wl_pointer_types: [14] *wl_interface = .[
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
];
wl_pointer_requests: [2] wl_message = .[
    .{ "set_cursor", "u?oii", wl_pointer_types.data + 4 },
    .{ "release", "3", wl_pointer_types.data + 0 },
];
wl_pointer_events: [11] wl_message = .[
    .{ "enter", "uoff", wl_pointer_types.data + 8 },
    .{ "leave", "uo", wl_pointer_types.data + 12 },
    .{ "motion", "uff", wl_pointer_types.data + 0 },
    .{ "button", "uuuu", wl_pointer_types.data + 0 },
    .{ "axis", "uuf", wl_pointer_types.data + 0 },
    .{ "frame", "5", wl_pointer_types.data + 0 },
    .{ "axis_source", "5u", wl_pointer_types.data + 0 },
    .{ "axis_stop", "5uu", wl_pointer_types.data + 0 },
    .{ "axis_discrete", "5ui", wl_pointer_types.data + 0 },
    .{ "axis_value120", "8ui", wl_pointer_types.data + 0 },
    .{ "axis_relative_direction", "9uu", wl_pointer_types.data + 0 },
];
wl_pointer_interface: wl_interface = .{
    name         = "wl_pointer",
    version      = 10,
    method_count = 2,
    methods      = wl_pointer_requests.data,
    event_count  = 11,
    events       = wl_pointer_events.data,
};

// ── wl_keyboard (v10) ──
wl_keyboard_types: [10] *wl_interface = .[
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
];
wl_keyboard_requests: [1] wl_message = .[
    .{ "release", "3", wl_keyboard_types.data + 0 },
];
wl_keyboard_events: [6] wl_message = .[
    .{ "keymap", "uhu", wl_keyboard_types.data + 0 },
    .{ "enter", "uoa", wl_keyboard_types.data + 5 },
    .{ "leave", "uo", wl_keyboard_types.data + 8 },
    .{ "key", "uuuu", wl_keyboard_types.data + 0 },
    .{ "modifiers", "uuuuu", wl_keyboard_types.data + 0 },
    .{ "repeat_info", "4ii", wl_keyboard_types.data + 0 },
];
wl_keyboard_interface: wl_interface = .{
    name         = "wl_keyboard",
    version      = 10,
    method_count = 1,
    methods      = wl_keyboard_requests.data,
    event_count  = 6,
    events       = wl_keyboard_events.data,
};

// ── wl_touch (v10) ──
wl_touch_types: [10] *wl_interface = .[
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
];
wl_touch_requests: [1] wl_message = .[
    .{ "release", "3", wl_touch_types.data + 0 },
];
wl_touch_events: [7] wl_message = .[
    .{ "down", "uuoiff", wl_touch_types.data + 4 },
    .{ "up", "uui", wl_touch_types.data + 0 },
    .{ "motion", "uiff", wl_touch_types.data + 0 },
    .{ "frame", "", wl_touch_types.data + 0 },
    .{ "cancel", "", wl_touch_types.data + 0 },
    .{ "shape", "6iff", wl_touch_types.data + 0 },
    .{ "orientation", "6if", wl_touch_types.data + 0 },
];
wl_touch_interface: wl_interface = .{
    name         = "wl_touch",
    version      = 10,
    method_count = 1,
    methods      = wl_touch_requests.data,
    event_count  = 7,
    events       = wl_touch_events.data,
};

// ── wl_output (v4) ──
wl_output_types: [8] *wl_interface = .[
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
];
wl_output_requests: [1] wl_message = .[
    .{ "release", "3", wl_output_types.data + 0 },
];
wl_output_events: [6] wl_message = .[
    .{ "geometry", "iiiiissi", wl_output_types.data + 0 },
    .{ "mode", "uiii", wl_output_types.data + 0 },
    .{ "done", "2", wl_output_types.data + 0 },
    .{ "scale", "2i", wl_output_types.data + 0 },
    .{ "name", "4s", wl_output_types.data + 0 },
    .{ "description", "4s", wl_output_types.data + 0 },
];
#program_export   // ICD data import (nm -D --undefined libvulkan_radeon.so)
wl_output_interface: wl_interface = .{
    name         = "wl_output",
    version      = 4,
    method_count = 1,
    methods      = wl_output_requests.data,
    event_count  = 6,
    events       = wl_output_events.data,
};

// ── wl_region (v1) ──
wl_region_types: [4] *wl_interface = .[
    null,
    null,
    null,
    null,
];
wl_region_requests: [3] wl_message = .[
    .{ "destroy", "", wl_region_types.data + 0 },
    .{ "add", "iiii", wl_region_types.data + 0 },
    .{ "subtract", "iiii", wl_region_types.data + 0 },
];
wl_region_interface: wl_interface = .{
    name         = "wl_region",
    version      = 1,
    method_count = 3,
    methods      = wl_region_requests.data,
    event_count  = 0,
    events       = null,
};

// ── wl_subcompositor (v1) ──
wl_subcompositor_types: [3] *wl_interface = .[
    null,
    null,
    null,
];
wl_subcompositor_requests: [2] wl_message = .[
    .{ "destroy", "", wl_subcompositor_types.data + 0 },
    .{ "get_subsurface", "noo", wl_subcompositor_types.data + 0 },
];
wl_subcompositor_interface: wl_interface = .{
    name         = "wl_subcompositor",
    version      = 1,
    method_count = 2,
    methods      = wl_subcompositor_requests.data,
    event_count  = 0,
    events       = null,
};

// ── wl_subsurface (v1) ──
wl_subsurface_types: [4] *wl_interface = .[
    null,
    null,
    null,
    null,
];
wl_subsurface_requests: [6] wl_message = .[
    .{ "destroy", "", wl_subsurface_types.data + 0 },
    .{ "set_position", "ii", wl_subsurface_types.data + 0 },
    .{ "place_above", "o", wl_subsurface_types.data + 2 },
    .{ "place_below", "o", wl_subsurface_types.data + 3 },
    .{ "set_sync", "", wl_subsurface_types.data + 0 },
    .{ "set_desync", "", wl_subsurface_types.data + 0 },
];
wl_subsurface_interface: wl_interface = .{
    name         = "wl_subsurface",
    version      = 1,
    method_count = 6,
    methods      = wl_subsurface_requests.data,
    event_count  = 0,
    events       = null,
};

// ── wl_fixes (v1) ──
wl_fixes_types: [1] *wl_interface = .[
    null,
];
wl_fixes_requests: [2] wl_message = .[
    .{ "destroy", "", wl_fixes_types.data + 0 },
    .{ "destroy_registry", "o", wl_fixes_types.data + 0 },
];
#program_export   // ICD data import (nm -D --undefined libvulkan_radeon.so)
wl_fixes_interface: wl_interface = .{
    name         = "wl_fixes",
    version      = 1,
    method_count = 2,
    methods      = wl_fixes_requests.data,
    event_count  = 0,
    events       = null,
};

// ── xdg_wm_base (v7) ──
xdg_wm_base_types: [4] *wl_interface = .[
    null,
    null,
    null,
    null,
];
xdg_wm_base_requests: [4] wl_message = .[
    .{ "destroy", "", xdg_wm_base_types.data + 0 },
    .{ "create_positioner", "n", xdg_wm_base_types.data + 1 },
    .{ "get_xdg_surface", "no", xdg_wm_base_types.data + 2 },
    .{ "pong", "u", xdg_wm_base_types.data + 0 },
];
xdg_wm_base_events: [1] wl_message = .[
    .{ "ping", "u", xdg_wm_base_types.data + 0 },
];
xdg_wm_base_interface: wl_interface = .{
    name         = "xdg_wm_base",
    version      = 7,
    method_count = 4,
    methods      = xdg_wm_base_requests.data,
    event_count  = 1,
    events       = xdg_wm_base_events.data,
};

// ── xdg_positioner (v7) ──
xdg_positioner_types: [4] *wl_interface = .[
    null,
    null,
    null,
    null,
];
xdg_positioner_requests: [10] wl_message = .[
    .{ "destroy", "", xdg_positioner_types.data + 0 },
    .{ "set_size", "ii", xdg_positioner_types.data + 0 },
    .{ "set_anchor_rect", "iiii", xdg_positioner_types.data + 0 },
    .{ "set_anchor", "u", xdg_positioner_types.data + 0 },
    .{ "set_gravity", "u", xdg_positioner_types.data + 0 },
    .{ "set_constraint_adjustment", "u", xdg_positioner_types.data + 0 },
    .{ "set_offset", "ii", xdg_positioner_types.data + 0 },
    .{ "set_reactive", "3", xdg_positioner_types.data + 0 },
    .{ "set_parent_size", "3ii", xdg_positioner_types.data + 0 },
    .{ "set_parent_configure", "3u", xdg_positioner_types.data + 0 },
];
xdg_positioner_interface: wl_interface = .{
    name         = "xdg_positioner",
    version      = 7,
    method_count = 10,
    methods      = xdg_positioner_requests.data,
    event_count  = 0,
    events       = null,
};

// ── xdg_surface (v7) ──
xdg_surface_types: [8] *wl_interface = .[
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
];
xdg_surface_requests: [5] wl_message = .[
    .{ "destroy", "", xdg_surface_types.data + 0 },
    .{ "get_toplevel", "n", xdg_surface_types.data + 4 },
    .{ "get_popup", "n?oo", xdg_surface_types.data + 5 },
    .{ "set_window_geometry", "iiii", xdg_surface_types.data + 0 },
    .{ "ack_configure", "u", xdg_surface_types.data + 0 },
];
xdg_surface_events: [1] wl_message = .[
    .{ "configure", "u", xdg_surface_types.data + 0 },
];
xdg_surface_interface: wl_interface = .{
    name         = "xdg_surface",
    version      = 7,
    method_count = 5,
    methods      = xdg_surface_requests.data,
    event_count  = 1,
    events       = xdg_surface_events.data,
};

// ── xdg_toplevel (v7) ──
xdg_toplevel_types: [14] *wl_interface = .[
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
];
xdg_toplevel_requests: [14] wl_message = .[
    .{ "destroy", "", xdg_toplevel_types.data + 0 },
    .{ "set_parent", "?o", xdg_toplevel_types.data + 3 },
    .{ "set_title", "s", xdg_toplevel_types.data + 0 },
    .{ "set_app_id", "s", xdg_toplevel_types.data + 0 },
    .{ "show_window_menu", "ouii", xdg_toplevel_types.data + 4 },
    .{ "move", "ou", xdg_toplevel_types.data + 8 },
    .{ "resize", "ouu", xdg_toplevel_types.data + 10 },
    .{ "set_max_size", "ii", xdg_toplevel_types.data + 0 },
    .{ "set_min_size", "ii", xdg_toplevel_types.data + 0 },
    .{ "set_maximized", "", xdg_toplevel_types.data + 0 },
    .{ "unset_maximized", "", xdg_toplevel_types.data + 0 },
    .{ "set_fullscreen", "?o", xdg_toplevel_types.data + 13 },
    .{ "unset_fullscreen", "", xdg_toplevel_types.data + 0 },
    .{ "set_minimized", "", xdg_toplevel_types.data + 0 },
];
xdg_toplevel_events: [4] wl_message = .[
    .{ "configure", "iia", xdg_toplevel_types.data + 0 },
    .{ "close", "", xdg_toplevel_types.data + 0 },
    .{ "configure_bounds", "4ii", xdg_toplevel_types.data + 0 },
    .{ "wm_capabilities", "5a", xdg_toplevel_types.data + 0 },
];
xdg_toplevel_interface: wl_interface = .{
    name         = "xdg_toplevel",
    version      = 7,
    method_count = 14,
    methods      = xdg_toplevel_requests.data,
    event_count  = 4,
    events       = xdg_toplevel_events.data,
};

// ── xdg_popup (v7) ──
xdg_popup_types: [8] *wl_interface = .[
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
];
xdg_popup_requests: [3] wl_message = .[
    .{ "destroy", "", xdg_popup_types.data + 0 },
    .{ "grab", "ou", xdg_popup_types.data + 4 },
    .{ "reposition", "3ou", xdg_popup_types.data + 6 },
];
xdg_popup_events: [3] wl_message = .[
    .{ "configure", "iiii", xdg_popup_types.data + 0 },
    .{ "popup_done", "", xdg_popup_types.data + 0 },
    .{ "repositioned", "3u", xdg_popup_types.data + 0 },
];
xdg_popup_interface: wl_interface = .{
    name         = "xdg_popup",
    version      = 7,
    method_count = 3,
    methods      = xdg_popup_requests.data,
    event_count  = 3,
    events       = xdg_popup_events.data,
};

// ══ runtime types-array back-pointer patch ══
//
// Fills each shared types array's object/new_id slots with *<iface>_interface.
// Call ONCE after init_wayland_client(), before the first object-carrying request
// or listener registration. Idempotent.
wl_protocol_tables_init :: () {
    if wl_protocol_tables_initted  return;
    wl_protocol_tables_initted = true;
    wl_display_types[3] = *wl_callback_interface;
    wl_display_types[4] = *wl_registry_interface;
    wl_compositor_types[0] = *wl_surface_interface;
    wl_compositor_types[1] = *wl_region_interface;
    wl_shm_pool_types[1] = *wl_buffer_interface;
    wl_shm_types[1] = *wl_shm_pool_interface;
    wl_data_device_types[3] = *wl_data_source_interface;
    wl_data_device_types[4] = *wl_surface_interface;
    wl_data_device_types[5] = *wl_surface_interface;
    wl_data_device_types[7] = *wl_data_source_interface;
    wl_data_device_types[9] = *wl_data_offer_interface;
    wl_data_device_types[11] = *wl_surface_interface;
    wl_data_device_types[14] = *wl_data_offer_interface;
    wl_data_device_types[15] = *wl_data_offer_interface;
    wl_data_device_manager_types[0] = *wl_data_source_interface;
    wl_data_device_manager_types[1] = *wl_data_device_interface;
    wl_data_device_manager_types[2] = *wl_seat_interface;
    wl_shell_types[0] = *wl_shell_surface_interface;
    wl_shell_types[1] = *wl_surface_interface;
    wl_shell_surface_types[3] = *wl_seat_interface;
    wl_shell_surface_types[5] = *wl_seat_interface;
    wl_shell_surface_types[8] = *wl_surface_interface;
    wl_shell_surface_types[14] = *wl_output_interface;
    wl_shell_surface_types[15] = *wl_seat_interface;
    wl_shell_surface_types[17] = *wl_surface_interface;
    wl_shell_surface_types[21] = *wl_output_interface;
    wl_surface_types[4] = *wl_buffer_interface;
    wl_surface_types[7] = *wl_callback_interface;
    wl_surface_types[8] = *wl_region_interface;
    wl_surface_types[9] = *wl_region_interface;
    wl_surface_types[10] = *wl_output_interface;
    wl_surface_types[11] = *wl_output_interface;
    wl_seat_types[1] = *wl_pointer_interface;
    wl_seat_types[2] = *wl_keyboard_interface;
    wl_seat_types[3] = *wl_touch_interface;
    wl_pointer_types[5] = *wl_surface_interface;
    wl_pointer_types[9] = *wl_surface_interface;
    wl_pointer_types[13] = *wl_surface_interface;
    wl_keyboard_types[6] = *wl_surface_interface;
    wl_keyboard_types[9] = *wl_surface_interface;
    wl_touch_types[6] = *wl_surface_interface;
    wl_subcompositor_types[0] = *wl_subsurface_interface;
    wl_subcompositor_types[1] = *wl_surface_interface;
    wl_subcompositor_types[2] = *wl_surface_interface;
    wl_subsurface_types[2] = *wl_surface_interface;
    wl_subsurface_types[3] = *wl_surface_interface;
    wl_fixes_types[0] = *wl_registry_interface;
    xdg_wm_base_types[1] = *xdg_positioner_interface;
    xdg_wm_base_types[2] = *xdg_surface_interface;
    xdg_wm_base_types[3] = *wl_surface_interface;
    xdg_surface_types[4] = *xdg_toplevel_interface;
    xdg_surface_types[5] = *xdg_popup_interface;
    xdg_surface_types[6] = *xdg_surface_interface;
    xdg_surface_types[7] = *xdg_positioner_interface;
    xdg_toplevel_types[3] = *xdg_toplevel_interface;
    xdg_toplevel_types[4] = *wl_seat_interface;
    xdg_toplevel_types[8] = *wl_seat_interface;
    xdg_toplevel_types[10] = *wl_seat_interface;
    xdg_toplevel_types[13] = *wl_output_interface;
    xdg_popup_types[4] = *wl_seat_interface;
    xdg_popup_types[6] = *xdg_positioner_interface;
}
wl_protocol_tables_initted: bool;

// ══ request opcodes ══

WL_DISPLAY_SYNC :: 0;
WL_DISPLAY_GET_REGISTRY :: 1;
WL_REGISTRY_BIND :: 0;
WL_COMPOSITOR_CREATE_SURFACE :: 0;
WL_COMPOSITOR_CREATE_REGION :: 1;
WL_SHM_POOL_CREATE_BUFFER :: 0;
WL_SHM_POOL_DESTROY :: 1;
WL_SHM_POOL_RESIZE :: 2;
WL_SHM_CREATE_POOL :: 0;
WL_SHM_RELEASE :: 1;
WL_BUFFER_DESTROY :: 0;
WL_DATA_OFFER_ACCEPT :: 0;
WL_DATA_OFFER_RECEIVE :: 1;
WL_DATA_OFFER_DESTROY :: 2;
WL_DATA_OFFER_FINISH :: 3;
WL_DATA_OFFER_SET_ACTIONS :: 4;
WL_DATA_SOURCE_OFFER :: 0;
WL_DATA_SOURCE_DESTROY :: 1;
WL_DATA_SOURCE_SET_ACTIONS :: 2;
WL_DATA_DEVICE_START_DRAG :: 0;
WL_DATA_DEVICE_SET_SELECTION :: 1;
WL_DATA_DEVICE_RELEASE :: 2;
WL_DATA_DEVICE_MANAGER_CREATE_DATA_SOURCE :: 0;
WL_DATA_DEVICE_MANAGER_GET_DATA_DEVICE :: 1;
WL_SHELL_GET_SHELL_SURFACE :: 0;
WL_SHELL_SURFACE_PONG :: 0;
WL_SHELL_SURFACE_MOVE :: 1;
WL_SHELL_SURFACE_RESIZE :: 2;
WL_SHELL_SURFACE_SET_TOPLEVEL :: 3;
WL_SHELL_SURFACE_SET_TRANSIENT :: 4;
WL_SHELL_SURFACE_SET_FULLSCREEN :: 5;
WL_SHELL_SURFACE_SET_POPUP :: 6;
WL_SHELL_SURFACE_SET_MAXIMIZED :: 7;
WL_SHELL_SURFACE_SET_TITLE :: 8;
WL_SHELL_SURFACE_SET_CLASS :: 9;
WL_SURFACE_DESTROY :: 0;
WL_SURFACE_ATTACH :: 1;
WL_SURFACE_DAMAGE :: 2;
WL_SURFACE_FRAME :: 3;
WL_SURFACE_SET_OPAQUE_REGION :: 4;
WL_SURFACE_SET_INPUT_REGION :: 5;
WL_SURFACE_COMMIT :: 6;
WL_SURFACE_SET_BUFFER_TRANSFORM :: 7;
WL_SURFACE_SET_BUFFER_SCALE :: 8;
WL_SURFACE_DAMAGE_BUFFER :: 9;
WL_SURFACE_OFFSET :: 10;
WL_SEAT_GET_POINTER :: 0;
WL_SEAT_GET_KEYBOARD :: 1;
WL_SEAT_GET_TOUCH :: 2;
WL_SEAT_RELEASE :: 3;
WL_POINTER_SET_CURSOR :: 0;
WL_POINTER_RELEASE :: 1;
WL_KEYBOARD_RELEASE :: 0;
WL_TOUCH_RELEASE :: 0;
WL_OUTPUT_RELEASE :: 0;
WL_REGION_DESTROY :: 0;
WL_REGION_ADD :: 1;
WL_REGION_SUBTRACT :: 2;
WL_SUBCOMPOSITOR_DESTROY :: 0;
WL_SUBCOMPOSITOR_GET_SUBSURFACE :: 1;
WL_SUBSURFACE_DESTROY :: 0;
WL_SUBSURFACE_SET_POSITION :: 1;
WL_SUBSURFACE_PLACE_ABOVE :: 2;
WL_SUBSURFACE_PLACE_BELOW :: 3;
WL_SUBSURFACE_SET_SYNC :: 4;
WL_SUBSURFACE_SET_DESYNC :: 5;
WL_FIXES_DESTROY :: 0;
WL_FIXES_DESTROY_REGISTRY :: 1;
XDG_WM_BASE_DESTROY :: 0;
XDG_WM_BASE_CREATE_POSITIONER :: 1;
XDG_WM_BASE_GET_XDG_SURFACE :: 2;
XDG_WM_BASE_PONG :: 3;
XDG_POSITIONER_DESTROY :: 0;
XDG_POSITIONER_SET_SIZE :: 1;
XDG_POSITIONER_SET_ANCHOR_RECT :: 2;
XDG_POSITIONER_SET_ANCHOR :: 3;
XDG_POSITIONER_SET_GRAVITY :: 4;
XDG_POSITIONER_SET_CONSTRAINT_ADJUSTMENT :: 5;
XDG_POSITIONER_SET_OFFSET :: 6;
XDG_POSITIONER_SET_REACTIVE :: 7;
XDG_POSITIONER_SET_PARENT_SIZE :: 8;
XDG_POSITIONER_SET_PARENT_CONFIGURE :: 9;
XDG_SURFACE_DESTROY :: 0;
XDG_SURFACE_GET_TOPLEVEL :: 1;
XDG_SURFACE_GET_POPUP :: 2;
XDG_SURFACE_SET_WINDOW_GEOMETRY :: 3;
XDG_SURFACE_ACK_CONFIGURE :: 4;
XDG_TOPLEVEL_DESTROY :: 0;
XDG_TOPLEVEL_SET_PARENT :: 1;
XDG_TOPLEVEL_SET_TITLE :: 2;
XDG_TOPLEVEL_SET_APP_ID :: 3;
XDG_TOPLEVEL_SHOW_WINDOW_MENU :: 4;
XDG_TOPLEVEL_MOVE :: 5;
XDG_TOPLEVEL_RESIZE :: 6;
XDG_TOPLEVEL_SET_MAX_SIZE :: 7;
XDG_TOPLEVEL_SET_MIN_SIZE :: 8;
XDG_TOPLEVEL_SET_MAXIMIZED :: 9;
XDG_TOPLEVEL_UNSET_MAXIMIZED :: 10;
XDG_TOPLEVEL_SET_FULLSCREEN :: 11;
XDG_TOPLEVEL_UNSET_FULLSCREEN :: 12;
XDG_TOPLEVEL_SET_MINIMIZED :: 13;
XDG_POPUP_DESTROY :: 0;
XDG_POPUP_GRAB :: 1;
XDG_POPUP_REPOSITION :: 2;

// NOTE: game-bootstrap's generator also emits protocol enums, event-listener structs,
// and request-wrapper procs after this point. They are intentionally dropped here:
// the listener/wrapper code references the ICD's own opaque `wl_proxy` (bucket 2, which
// lives in C as static inline and is never one of our symbols), and the enums are YAGNI
// for slice-1 (re-add specific constants — e.g. wl_shm formats, xdg states — on demand).
