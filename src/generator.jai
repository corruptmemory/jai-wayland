// ── Naming utilities for the Wayland code generator ──
//
// All returned strings are temp-allocated.

// Converts snake_case to Title_Snake_Case for Jai type names.
// "wl_surface" → "Wl_Surface", "xdg_toplevel" → "Xdg_Toplevel",
// "zwp_linux_dmabuf_v1" → "Zwp_Linux_Dmabuf_V1"
to_jai_type_name :: (name: string) -> string {
    if name.count == 0 return "";

    sb: String_Builder;
    sb.allocator = temp;

    capitalize_next := true;
    for i: 0..name.count-1 {
        c := name[i];
        if c == #char "_" {
            append(*sb, c);
            capitalize_next = true;
        } else {
            if capitalize_next {
                append(*sb, to_upper(c));
                capitalize_next = false;
            } else {
                append(*sb, c);
            }
        }
    }
    return builder_to_string(*sb,, allocator = temp);
}

// Converts snake_case to UPPER_SNAKE_CASE.
// "wl_surface" → "WL_SURFACE"
to_upper_snake :: (name: string) -> string {
    if name.count == 0 return "";

    sb: String_Builder;
    sb.allocator = temp;

    for i: 0..name.count-1 {
        append(*sb, to_upper(name[i]));
    }
    return builder_to_string(*sb,, allocator = temp);
}

// Builds an opcode constant name from interface and message names.
// ("wl_surface", "attach") → "WL_SURFACE_ATTACH"
opcode_name :: (interface_name: string, message_name: string) -> string {
    return tprint("%_%", to_upper_snake(interface_name), to_upper_snake(message_name));
}

// Builds a Jai enum type name from interface and enum names.
// ("wl_surface", "error") → "Wl_Surface_Error"
to_jai_enum_name :: (interface_name: string, enum_name: string) -> string {
    return tprint("%_%", to_jai_type_name(interface_name), to_jai_type_name(enum_name));
}

// Resolves an enum reference (possibly cross-interface) to a Jai type name.
// "wl_shm.format" → "Wl_Shm_Format" (cross-interface)
// "error" within "wl_display" → "Wl_Display_Error" (local)
resolve_enum_type :: (enum_ref: string, current_interface: string) -> string {
    found, left, right := split_from_left(enum_ref, #char ".");
    if found {
        return to_jai_enum_name(left, right);
    }
    return to_jai_enum_name(current_interface, enum_ref);
}

// ── Enum generation ──

// Emits a multi-line description body as //-prefixed comment lines.
// Trims each line, skips leading/trailing empty lines, but emits "//"
// for blank lines between paragraphs.
emit_description_body :: (sb: *String_Builder, body: string) {
    remaining := body;
    lines: [..] string;
    lines.allocator = temp;

    while remaining.count > 0 {
        found, left, right := split_from_left(remaining, #char "\n");
        if found {
            array_add(*lines, trim(left));
            remaining = right;
        } else {
            array_add(*lines, trim(remaining));
            break;
        }
    }

    // Trim leading empty lines
    start := 0;
    while start < lines.count && lines[start].count == 0  start += 1;

    // Trim trailing empty lines
    end := lines.count;
    while end > start && lines[end - 1].count == 0  end -= 1;

    for i: start..end-1 {
        if lines[i].count == 0 {
            print_to_builder(sb, "//\n");
        } else {
            print_to_builder(sb, "// %\n", lines[i]);
        }
    }
}

// Generates a Jai enum definition from an Enum_Def.
// Regular enums use "enum u32", bitfield enums use "enum_flags u32".
// Values > 0xFFFF are emitted in hex for readability.
generate_enum :: (e: *Enum_Def, interface_name: string) -> string {
    sb: String_Builder;
    sb.allocator = temp;

    // Doc comment from summary
    if e.description.summary.count > 0 {
        print_to_builder(*sb, "// %\n", e.description.summary);
    }

    // Doc comment from body
    if e.description.body.count > 0 {
        emit_description_body(*sb, e.description.body);
    }

    // Enum declaration
    type_name := to_jai_enum_name(interface_name, e.name);
    keyword := ifx e.bitfield then "enum_flags" else "enum";
    print_to_builder(*sb, "% :: % u32 {\n", type_name, keyword);

    // Entries
    for entry: e.entries {
        if entry.summary.count > 0 {
            print_to_builder(*sb, "    // %\n", entry.summary);
        }
        name := to_upper_snake(entry.name);
        if entry.value > 0xFFFF {
            print_to_builder(*sb, "    % :: 0x%;\n", name, formatInt(entry.value, base = 16));
        } else {
            print_to_builder(*sb, "    % :: %;\n", name, entry.value);
        }
    }

    print_to_builder(*sb, "}\n");
    return builder_to_string(*sb,, allocator = temp);
}

// ── Event generation ──

// Maps a protocol Arg_Type to a Jai type string.
arg_type_to_jai :: (arg: *Arg) -> string {
    if arg.arg_type == {
        case .INT;    return "s32";
        case .UINT;   return "u32";
        case .FIXED;  return "Fixed";
        case .STRING; return "string";
        case .OBJECT;
            if arg.interface_name.count > 0
                return tprint("*%", to_jai_type_name(arg.interface_name));
            return "*void";
        case .NEW_ID;
            if arg.interface_name.count > 0
                return tprint("*%", to_jai_type_name(arg.interface_name));
            return "*void";
        case .ARRAY;  return "[] u8";
        case .FD;     return "s32";
    }
    assert(false, "unknown arg type"); return "s32";
}

// Generates event kind enum + args structs + tagged union for an interface.
// Returns empty string if the interface has no events.
generate_events :: (iface: *Interface) -> string {
    if iface.events.count == 0 return "";

    sb: String_Builder;
    sb.allocator = temp;

    type_prefix := to_jai_type_name(iface.name);

    // Emit args structs (one per event)
    for event: iface.events {
        struct_name := tprint("%_%_Args", type_prefix, to_jai_type_name(event.name));
        if event.description.summary.count > 0 {
            print_to_builder(*sb, "// %\n", event.description.summary);
        }
        print_to_builder(*sb, "% :: struct {\n", struct_name);
        for arg: event.args {
            print_to_builder(*sb, "    %: %;\n", arg.name, arg_type_to_jai(*arg));
        }
        print_to_builder(*sb, "}\n\n");
    }

    // Emit event kind enum
    enum_name := tprint("%_Event_Kind", type_prefix);
    print_to_builder(*sb, "% :: enum u8 {\n", enum_name);
    for event, idx: iface.events {
        if event.description.summary.count > 0 {
            print_to_builder(*sb, "    % :: %;  // %\n", to_upper_snake(event.name), idx, event.description.summary);
        } else {
            print_to_builder(*sb, "    % :: %;\n", to_upper_snake(event.name), idx);
        }
    }
    print_to_builder(*sb, "}\n\n");

    // Emit tagged union
    union_name := tprint("%_Event", type_prefix);
    print_to_builder(*sb, "% :: union kind: % {\n", union_name, enum_name);
    for event: iface.events {
        tag := to_upper_snake(event.name);
        field := event.name;
        args_type := tprint("%_%_Args", type_prefix, to_jai_type_name(event.name));
        print_to_builder(*sb, "    .% ,, %: %;\n", tag, field, args_type);
    }
    print_to_builder(*sb, "}\n");

    return builder_to_string(*sb,, allocator = temp);
}

// ── Request generation ──

// Generates a typed stub request function for a single interface request.
// new_id args with interface_name set become the return type (not a parameter).
// new_id args without interface_name (wl_registry.bind) become a polymorphic $T parameter.
generate_request :: (iface: *Interface, req: *Message, opcode: int) -> string {
    sb: String_Builder;
    sb.allocator = temp;

    // Doc comment
    if req.description.summary.count > 0 {
        summary := req.description.summary;
        if req.is_destructor {
            print_to_builder(*sb, "// % (destructor)\n", summary);
        } else {
            print_to_builder(*sb, "// %\n", summary);
        }
    } else if req.is_destructor {
        print_to_builder(*sb, "// (destructor)\n");
    }

    if req.description.body.count > 0 {
        emit_description_body(*sb, req.description.body);
    }

    // Determine return type and collect parameters
    return_type: string;
    has_untyped_new_id := false;

    for * arg: req.args {
        if arg.arg_type == .NEW_ID {
            if arg.interface_name.count > 0 {
                return_type = tprint("*%", to_jai_type_name(arg.interface_name));
            } else {
                has_untyped_new_id = true;
                return_type = "*T";
            }
        }
    }

    // Function name
    func_name := tprint("%_%", iface.name, req.name);
    const_name := opcode_name(iface.name, req.name);
    type_name := to_jai_type_name(iface.name);

    // Build parameter list
    print_to_builder(*sb, "% :: (self: *%", func_name, type_name);

    for * arg: req.args {
        if arg.arg_type == .NEW_ID {
            if arg.interface_name.count > 0 {
                // Typed new_id: becomes return type, skip as parameter
                continue;
            } else {
                // Untyped new_id: emit $T: Type parameter (skip the arg itself)
                print_to_builder(*sb, ", $T: Type");
                continue;
            }
        }
        print_to_builder(*sb, ", %: %", arg.name, arg_type_to_jai(arg));
    }

    // If untyped new_id, add version parameter after $T
    if has_untyped_new_id {
        print_to_builder(*sb, ", version: u32");
    }

    print_to_builder(*sb, ")");

    // Return type
    if return_type.count > 0 {
        print_to_builder(*sb, " -> %", return_type);
    }

    // Body
    print_to_builder(*sb, " {\n");

    if req.is_destructor {
        print_to_builder(*sb, "    // TODO(Phase 3): marshal(self, %, ...); destroy_proxy(self);\n", const_name);
    } else if return_type.count > 0 {
        print_to_builder(*sb, "    // TODO(Phase 3): marshal_constructor(self, %, ...);\n", const_name);
        print_to_builder(*sb, "    return null;\n");
    } else {
        print_to_builder(*sb, "    // TODO(Phase 3): marshal(self, %, ...);\n", const_name);
    }

    print_to_builder(*sb, "}\n");

    return builder_to_string(*sb,, allocator = temp);
}

// ── Interface struct, opcodes, and descriptor generation ──

// Generates the interface struct definition with doc comments.
generate_interface_struct :: (iface: *Interface) -> string {
    sb: String_Builder;
    sb.allocator = temp;

    type_name := to_jai_type_name(iface.name);

    // Header comment block
    print_to_builder(*sb, "//\n");
    if iface.description.summary.count > 0 {
        print_to_builder(*sb, "// % — %\n", iface.name, iface.description.summary);
    } else {
        print_to_builder(*sb, "// %\n", iface.name);
    }
    print_to_builder(*sb, "//\n");

    if iface.description.body.count > 0 {
        emit_description_body(*sb, iface.description.body);
        print_to_builder(*sb, "//\n");
    }

    print_to_builder(*sb, "% :: struct {\n", type_name);
    print_to_builder(*sb, "    id: u32;\n");
    print_to_builder(*sb, "    version: u32;\n");
    print_to_builder(*sb, "}\n");

    return builder_to_string(*sb,, allocator = temp);
}

// Generates opcode constants for requests and events.
// Returns empty string if no requests AND no events.
generate_opcodes :: (iface: *Interface) -> string {
    if iface.requests.count == 0 && iface.events.count == 0 return "";

    sb: String_Builder;
    sb.allocator = temp;

    if iface.requests.count > 0 {
        print_to_builder(*sb, "// Request opcodes\n");
        for req, idx: iface.requests {
            print_to_builder(*sb, "% :: %;\n", opcode_name(iface.name, req.name), idx);
        }
    }

    if iface.requests.count > 0 && iface.events.count > 0 {
        print_to_builder(*sb, "\n");
    }

    if iface.events.count > 0 {
        print_to_builder(*sb, "// Event opcodes\n");
        for ev, idx: iface.events {
            print_to_builder(*sb, "% :: %;\n", opcode_name(iface.name, ev.name), idx);
        }
    }

    return builder_to_string(*sb,, allocator = temp);
}

// Generates an interface descriptor constant.
generate_interface_descriptor :: (iface: *Interface) -> string {
    sb: String_Builder;
    sb.allocator = temp;

    descriptor_name := tprint("%_INTERFACE", to_upper_snake(iface.name));
    print_to_builder(*sb, "% :: Interface_Descriptor.{\n", descriptor_name);
    print_to_builder(*sb, "    name = \"%\",\n", iface.name);
    print_to_builder(*sb, "    version = %,\n", iface.version);
    print_to_builder(*sb, "    request_count = %,\n", iface.requests.count);
    print_to_builder(*sb, "    event_count = %,\n", iface.events.count);
    print_to_builder(*sb, "};\n");

    return builder_to_string(*sb,, allocator = temp);
}

// ── Full interface file assembly ──

// Assembles a complete per-interface .jai file by calling all component generators.
generate_interface_file :: (iface: *Interface) -> string {
    sb: String_Builder;
    sb.allocator = temp;

    // 1. Auto-generated header
    print_to_builder(*sb, "// Auto-generated by jai-wayland code generator. Do not edit.\n");

    // 2. Interface struct
    section := generate_interface_struct(iface);
    if section.count > 0 {
        print_to_builder(*sb, "\n%", section);
    }

    // 3. Opcode constants
    section = generate_opcodes(iface);
    if section.count > 0 {
        print_to_builder(*sb, "\n%", section);
    }

    // 4. Enums
    for * e: iface.enums {
        section = generate_enum(e, iface.name);
        if section.count > 0 {
            print_to_builder(*sb, "\n%", section);
        }
    }

    // 5. Event tagged union
    section = generate_events(iface);
    if section.count > 0 {
        print_to_builder(*sb, "\n%", section);
    }

    // 6. Request functions
    for req, idx: iface.requests {
        section = generate_request(iface, *req, idx);
        if section.count > 0 {
            print_to_builder(*sb, "\n%", section);
        }
    }

    // 7. Interface descriptor
    section = generate_interface_descriptor(iface);
    if section.count > 0 {
        print_to_builder(*sb, "\n%", section);
    }

    return builder_to_string(*sb,, allocator = temp);
}

// ── Shared types file generation ──

// Returns the content of types.jai — shared type definitions used by all
// generated interface files.
generate_types_file :: () -> string {
    content :: #string DONE
// Auto-generated by jai-wayland code generator. Do not edit.

// Interface metadata for runtime dispatch
Interface_Descriptor :: struct {
    name: string;
    version: u32;
    request_count: u32;
    event_count: u32;
}

// Wire protocol argument types
Wire_Arg_Type :: enum u8 {
    INT;
    UINT;
    FIXED;
    STRING;
    OBJECT;
    NEW_ID;
    ARRAY;
    FD;
}

// Fixed-point 24.8 type used by the Wayland wire protocol
Fixed :: struct {
    raw: s32;
}

fixed_from_float :: (v: float64) -> Fixed {
    return .{ raw = cast(s32)(v * 256.0) };
}

fixed_to_float :: (f: Fixed) -> float64 {
    return cast(float64) f.raw / 256.0;
}
DONE;
    return content;
}
