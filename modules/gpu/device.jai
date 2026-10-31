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
    path:       string;
    name:       string;
    vendor_id:  u32;
    vendor:     Gpu_Vendor;
    major:      u32;      // the node's dev_t, from /sys/class/drm/<name>/dev (0:0 when unread)
    minor:      u32;
    pci_device: string;   // the GPU's PCI address, e.g. "0000:00:02.0" ("" when unread)
}

// The GPU a compositor composites on, as its dmabuf feedback names it (main_device,
// decoded to major:minor). Compositors report either the card node or the render
// node, so matching falls back to the PCI device behind the node.
Device_Preference :: struct {
    major:      u32;
    minor:      u32;
    pci_device: string;
    valid:      bool;
}

device_preference :: (major: u32, minor: u32) -> Device_Preference {
    return .{ major = major, minor = minor, pci_device = drm_node_pci_device(major, minor), valid = true };
}

// The PCI address of the device behind any DRM node (card or render), from the
// last component of /sys/dev/char/M:m/device ("../../../0000:00:02.0"). "" if absent.
drm_node_pci_device :: (major: u32, minor: u32) -> string {
    return pci_device_from_link(tprint("/sys/dev/char/%:%/device", major, minor));
}

pci_device_from_link :: (link_path: string) -> string {
    buf: [512] u8;
    n := readlink(temp_c_string(link_path), buf.data, buf.count);
    if n <= 0  return "";
    return copy_string(render_node_name_from_path(to_string(buf.data, n)));
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
            path       = copy_string(tprint("/dev/dri/%", name)),
            name       = copy_string(name),
            vendor_id  = vendor_id,
            vendor     = vendor_from_id(vendor_id),
            pci_device = pci_device_from_link(tprint("/sys/class/drm/%/device", name)),
        };
        dev_text, dev_ok := read_entire_file(tprint("/sys/class/drm/%/dev", name), log_errors = false);
        if dev_ok {
            found, major_text, minor_text := split_from_left(trim(dev_text), #char ":");
            major, major_ok := string_to_int(major_text, 10, u32);
            minor, minor_ok := string_to_int(minor_text, 10, u32);
            if found && major_ok && minor_ok { node.major = major; node.minor = minor; }
        }
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

// Selection policy, first match wins: the JAI_WAYLAND_RENDER_NODE path, the
// JAI_WAYLAND_GPU_VENDOR name, the compositor's GPU when the caller knows it
// (`preference`), then the first node. Preferring the compositor's GPU is what keeps
// a hybrid laptop's client on the GPU whose buffers its compositor can read, whatever
// order the kernel numbered the render nodes in; the dGPU stays an explicit opt-in.
choose_render_node :: (nodes: [] Render_Node_Info, preference := Device_Preference.{}) -> Render_Node_Info, bool {
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

    if preference.valid {
        for node: nodes  if node.major == preference.major && node.minor == preference.minor  return node, true;
        if preference.pci_device {
            for node: nodes  if node.pci_device == preference.pci_device  return node, true;
        }
        log("The compositor's main device %:% (%) matches no render node; using the first", preference.major, preference.minor,
            ifx preference.pci_device then preference.pci_device else "PCI device unknown", flags = .WARNING);
    }

    if !nodes  return .{}, false;
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
