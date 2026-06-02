// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jim Powers

// Render-node discovery and selection for GBM/EGL backends.

#import "Basic";
#import "File";
#import "POSIX";
#import "String";

Gpu_Vendor :: enum {
    UNKNOWN;
    INTEL;
    AMD;
    NVIDIA;
}

Render_Node_Info :: struct {
    path:      string;
    name:      string;
    vendor_id: u32;
    vendor:    Gpu_Vendor;
}

discover_render_nodes :: (nodes: *[..] Render_Node_Info) -> bool {
    for minor: 128..255 {
        name := tprint("renderD%", minor);
        vendor_path := tprint("/sys/class/drm/%/device/vendor", name);
        if access(temp_c_string(vendor_path), F_OK) != 0  continue;

        contents, ok := read_entire_file(vendor_path);
        if !ok  continue;

        vendor_id, parsed := parse_hex_u32(contents);
        if !parsed  vendor_id = 0;

        node := Render_Node_Info.{
            path      = copy_string(tprint("/dev/dri/%", name)),
            name      = copy_string(name),
            vendor_id = vendor_id,
            vendor    = vendor_from_id(vendor_id),
        };
        array_add(nodes, node);
    }

    return nodes.count > 0;
}

select_render_node :: () -> Render_Node_Info, bool {
    nodes: [..] Render_Node_Info;
    if !discover_render_nodes(*nodes) {
        override_ptr := getenv("JAI_WAYLAND_RENDER_NODE");
        if override_ptr != null {
            return render_node_from_override(to_string(override_ptr)), true;
        }
        return .{}, false;
    }

    selected, ok := choose_render_node(nodes);
    return selected, ok;
}

choose_render_node :: (nodes: [] Render_Node_Info) -> Render_Node_Info, bool {
    override_ptr := getenv("JAI_WAYLAND_RENDER_NODE");
    if override_ptr != null {
        override := to_string(override_ptr);
        for node: nodes {
            if node.path == override  return node, true;
        }

        return render_node_from_override(override), true;
    }

    vendor_ptr := getenv("JAI_WAYLAND_GPU_VENDOR");
    if vendor_ptr != null {
        desired, ok := vendor_from_name(to_string(vendor_ptr));
        if !ok  return .{}, false;

        for node: nodes {
            if node.vendor == desired  return node, true;
        }

        return .{}, false;
    }

    return nodes[0], true;
}

print_render_nodes :: (nodes: [] Render_Node_Info) {
    if !nodes {
        log("Render nodes: none discovered");
        return;
    }

    log("Render nodes:");
    for node: nodes {
        log("  % vendor=% id=0x%",
            node.path,
            vendor_name(node.vendor),
            formatInt(node.vendor_id, base=16, minimum_digits=4));
    }
}

vendor_name :: (vendor: Gpu_Vendor) -> string {
    if vendor == {
        case .INTEL;   return "intel";
        case .AMD;     return "amd";
        case .NVIDIA;  return "nvidia";
        case;          return "unknown";
    }
}

vendor_from_id :: (vendor_id: u32) -> Gpu_Vendor {
    if vendor_id == 0x8086  return .INTEL;
    if vendor_id == 0x1002  return .AMD;
    if vendor_id == 0x1022  return .AMD;
    if vendor_id == 0x10de  return .NVIDIA;
    return .UNKNOWN;
}

vendor_from_name :: (name: string) -> Gpu_Vendor, bool {
    if name == "intel"   return .INTEL, true;
    if name == "amd"     return .AMD, true;
    if name == "nvidia"  return .NVIDIA, true;
    return .UNKNOWN, false;
}

render_node_from_override :: (path: string) -> Render_Node_Info {
    node: Render_Node_Info;
    node.path = copy_string(path);
    node.name = copy_string(render_node_name_from_path(path));

    vendor_path := tprint("/sys/class/drm/%/device/vendor", node.name);
    if access(temp_c_string(vendor_path), F_OK) == 0 {
        contents, ok := read_entire_file(vendor_path);
        if ok {
            vendor_id, parsed := parse_hex_u32(contents);
            if parsed {
                node.vendor_id = vendor_id;
                node.vendor = vendor_from_id(vendor_id);
                return node;
            }
        }
    }

    node.vendor_id = 0;
    node.vendor = .UNKNOWN;
    return node;
}

render_node_name_from_path :: (path: string) -> string {
    result := path;
    while true {
        found, remainder := contains(result, #char "/");
        if !found  break;
        result = remainder;
    }
    return result;
}

parse_hex_u32 :: (text: string) -> u32, bool {
    s := trim(text);
    if starts_with(s, "0x") || starts_with(s, "0X")  advance(*s, 2);

    // string_to_int is permissive (stops at the first non-hex byte and reports
    // success-if-any-consumed); !remainder restores our strict "whole string
    // must be hex" contract.
    value, success, remainder := string_to_int(s, 16, u32);
    return value, success && !remainder;
}
