// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jim Powers

// modules/gpu render-node choice: by default the compositor's GPU, matched by
// major:minor or, for a compositor that reports its card node, by PCI device; the
// JAI_WAYLAND_* overrides still win. The node lists are made up, so this runs the same
// on any box; one test also checks that discovery fills the new fields on this one.

#import "Basic";
#import "POSIX";
Gpu :: #import,dir "../modules/gpu";

main :: () {
    print("=== GPU Tests ===\n\n");

    // The overrides would beat every preference below; a developer's shell may set them.
    unsetenv("JAI_WAYLAND_RENDER_NODE");
    unsetenv("JAI_WAYLAND_GPU_VENDOR");

    rec: Error_Recorder;
    ctx := context;
    ctx.logger      = record_errors;
    ctx.logger_data = *rec;
    push_context ctx {
        test_preference_by_major_minor_beats_node_order();
        test_preference_by_pci_device_matches_a_card_node();
        test_unmatched_preference_falls_back_to_first_node();
        test_vendor_override_beats_preference();
        test_discovery_fills_dev_and_pci_device();
    }
    assert(rec.errors == 0, "% error(s) were logged", rec.errors);

    print("\n=== All gpu tests passed ===\n");
}

Error_Recorder :: struct { errors: int; warnings: int; }

record_errors :: (message: string, data: *void, info: Log_Info) {
    rec := cast(*Error_Recorder) data;
    if info.common_flags & .ERROR    rec.errors   += 1;
    if info.common_flags & .WARNING  rec.warnings += 1;
}

// The hybrid laptop with its render nodes numbered the other way round: the dGPU
// first. Without a preference the first node wins, which is the dGPU.
SWAPPED_LAPTOP :: Gpu.Render_Node_Info.[
    .{ path = "/dev/dri/renderD128", name = "renderD128", vendor_id = 0x10de, vendor = .NVIDIA, major = 226, minor = 128, pci_device = "0000:01:00.0" },
    .{ path = "/dev/dri/renderD129", name = "renderD129", vendor_id = 0x8086, vendor = .INTEL,  major = 226, minor = 129, pci_device = "0000:00:02.0" },
];

test_preference_by_major_minor_beats_node_order :: () {
    first, first_ok := Gpu.choose_render_node(SWAPPED_LAPTOP);
    assert(first_ok && first.vendor == .NVIDIA, "with no preference the first node should win");

    preference := Gpu.Device_Preference.{ major = 226, minor = 129, valid = true };
    node, ok := Gpu.choose_render_node(SWAPPED_LAPTOP, preference);
    assert(ok, "a matching preference should choose a node");
    assert(node.path == "/dev/dri/renderD129", "the compositor's render node should win over node order, got %", node.path);
    print("  PASS: the compositor's render node (226:129) beats node order\n");
}

test_preference_by_pci_device_matches_a_card_node :: () {
    // A compositor reporting its card node: 226:1 is no render node, but it is the
    // same PCI device as renderD129.
    preference := Gpu.Device_Preference.{ major = 226, minor = 1, pci_device = "0000:00:02.0", valid = true };
    node, ok := Gpu.choose_render_node(SWAPPED_LAPTOP, preference);
    assert(ok && node.path == "/dev/dri/renderD129", "a card-node main device should match its GPU's render node, got %", node.path);
    print("  PASS: a card-node main device (226:1) matches its GPU's render node by PCI device\n");
}

test_unmatched_preference_falls_back_to_first_node :: () {
    rec := cast(*Error_Recorder) context.logger_data;
    warnings_before := rec.warnings;
    preference := Gpu.Device_Preference.{ major = 226, minor = 200, pci_device = "0000:05:00.0", valid = true };
    node, ok := Gpu.choose_render_node(SWAPPED_LAPTOP, preference);
    assert(ok && node.path == "/dev/dri/renderD128", "an unmatched preference should fall back to the first node, got %", node.path);
    assert(rec.warnings == warnings_before + 1, "an unmatched preference should log one warning, logged %", rec.warnings - warnings_before);
    print("  PASS: an unmatched preference falls back to the first node with one warning\n");
}

test_vendor_override_beats_preference :: () {
    setenv("JAI_WAYLAND_GPU_VENDOR", "nvidia", 1);
    defer unsetenv("JAI_WAYLAND_GPU_VENDOR");
    preference := Gpu.Device_Preference.{ major = 226, minor = 129, valid = true };
    node, ok := Gpu.choose_render_node(SWAPPED_LAPTOP, preference);
    assert(ok && node.vendor == .NVIDIA, "JAI_WAYLAND_GPU_VENDOR should beat the compositor preference, got %", node.path);
    print("  PASS: JAI_WAYLAND_GPU_VENDOR beats the compositor preference (the dGPU stays an explicit opt-in)\n");
}

test_discovery_fills_dev_and_pci_device :: () {
    nodes: [..] Gpu.Render_Node_Info;
    if !Gpu.discover_render_nodes(*nodes) {
        print("  SKIP: no DRM render nodes on this box\n");
        return;
    }
    for nodes {
        assert(it.major != 0, "% has no major number", it.path);
        assert(it.minor >= 128, "% has render-node minor %", it.path, it.minor);
        assert(it.pci_device != "", "% has no PCI device", it.path);
        // The device behind the render node's own dev_t is the same PCI device.
        assert(Gpu.drm_node_pci_device(it.major, it.minor) == it.pci_device, "% resolves to two PCI devices", it.path);
    }
    print("  PASS: discovery records each render node's major:minor and PCI device (% node(s))\n", nodes.count);
}
