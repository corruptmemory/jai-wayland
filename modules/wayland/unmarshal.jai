// Compile-time unmarshal macro: walks event arg structs via type_info at compile time
// and emits type-specific deserialization code via #insert #run.
// This is the mirror of marshal.jai — marshal serializes requests, unmarshal
// deserializes events.

#import "Basic";

// The unmarshal macro. T is the event arg struct type; #run runs at compile time,
// generating deserialization code specific to T, which #insert injects.
// recv is needed for Fd fields (popped from ReceiveBuffer via SCM_RIGHTS).
unmarshal :: (args: *$T, payload: *u8, recv: *ReceiveBuffer) #expand {
    #insert #run generate_unmarshal_code(type_info(T));
}

// Demarshal a tagged union event. Dispatches on opcode to fill the correct
// variant of the union. T is the tagged union type (e.g., Wl_Output_Event).
unmarshal_event :: (event: *$T, opcode: u16, payload: *u8, recv: *ReceiveBuffer) #expand {
    #insert #run generate_unmarshal_event_code(type_info(T));
}

#scope_file

generate_unmarshal_code :: (ti: *Type_Info) -> string {
    si := cast(*Type_Info_Struct) ti;

    if si.members.count == 0 return "{}";

    has_variable := false;
    for member: si.members {
        if is_fd_type(member.type)   continue;
        if member.type.type == .STRING { has_variable = true; continue; }
        if member.type.type == .ARRAY  { has_variable = true; continue; }
    }

    if !has_variable {
        return emit_unmarshal_fixed(si, "args");
    } else {
        return emit_unmarshal_variable(si, "args");
    }
}

emit_unmarshal_fixed :: (si: *Type_Info_Struct, prefix: string) -> string {
    sb: String_Builder;

    print_to_builder(*sb, "{\n");

    offset: u32 = 0;
    for member: si.members {
        if is_fd_type(member.type) {
            print_to_builder(*sb, "    %.% = cast(Fd) receive_pop_fd(recv);\n", prefix, member.name);
            continue;
        }
        if is_fixed_type(member.type) {
            print_to_builder(*sb, "    %.% = Fixed.{ raw = read_s32(payload + %) };\n", prefix, member.name, offset);
            offset += 4;
            continue;
        }
        if is_void_pointer(member.type) {
            print_to_builder(*sb, "    %.% = cast(*void) cast(u64) read_u32(payload + %);\n", prefix, member.name, offset);
            offset += 4;
            continue;
        }
        if member.type.type == .POINTER {
            type_name := get_pointee_type_name(member.type);
            print_to_builder(*sb, "    %.% = New(%,, temp);\n", prefix, member.name, type_name);
            print_to_builder(*sb, "    %.%.id = read_u32(payload + %);\n", prefix, member.name, offset);
            offset += 4;
            continue;
        }
        if is_signed_int(member.type) {
            print_to_builder(*sb, "    %.% = read_s32(payload + %);\n", prefix, member.name, offset);
        } else {
            print_to_builder(*sb, "    %.% = read_u32(payload + %);\n", prefix, member.name, offset);
        }
        offset += 4;
    }

    print_to_builder(*sb, "}\n");
    return builder_to_string(*sb);
}

emit_unmarshal_variable :: (si: *Type_Info_Struct, prefix: string) -> string {
    sb: String_Builder;

    print_to_builder(*sb, "{\n");
    print_to_builder(*sb, "    _offset: u32 = 0;\n");

    bytes_counter: s32 = 0;
    for member: si.members {
        if is_fd_type(member.type) {
            print_to_builder(*sb, "    %.% = cast(Fd) receive_pop_fd(recv);\n", prefix, member.name);
            continue;
        }
        if member.type.type == .STRING {
            print_to_builder(*sb, "    _str_%, _bytes_% := read_string(payload + _offset);\n",
                bytes_counter, bytes_counter);
            print_to_builder(*sb, "    %.% = _str_%;\n", prefix, member.name, bytes_counter);
            print_to_builder(*sb, "    _offset += _bytes_%;\n", bytes_counter);
            bytes_counter += 1;
            continue;
        }
        if member.type.type == .ARRAY {
            print_to_builder(*sb, "    _arr_%, _bytes_% := read_array(payload + _offset);\n",
                bytes_counter, bytes_counter);
            print_to_builder(*sb, "    %.% = _arr_%;\n", prefix, member.name, bytes_counter);
            print_to_builder(*sb, "    _offset += _bytes_%;\n", bytes_counter);
            bytes_counter += 1;
            continue;
        }
        if is_fixed_type(member.type) {
            print_to_builder(*sb, "    %.% = Fixed.{ raw = read_s32(payload + _offset) }; _offset += 4;\n", prefix, member.name);
            continue;
        }
        if is_void_pointer(member.type) {
            print_to_builder(*sb, "    %.% = cast(*void) cast(u64) read_u32(payload + _offset); _offset += 4;\n", prefix, member.name);
            continue;
        }
        if member.type.type == .POINTER {
            type_name := get_pointee_type_name(member.type);
            print_to_builder(*sb, "    %.% = New(%,, temp);\n", prefix, member.name, type_name);
            print_to_builder(*sb, "    %.%.id = read_u32(payload + _offset); _offset += 4;\n", prefix, member.name);
            continue;
        }
        if is_signed_int(member.type) {
            print_to_builder(*sb, "    %.% = read_s32(payload + _offset); _offset += 4;\n", prefix, member.name);
        } else {
            print_to_builder(*sb, "    %.% = read_u32(payload + _offset); _offset += 4;\n", prefix, member.name);
        }
    }

    print_to_builder(*sb, "}\n");
    return builder_to_string(*sb);
}

generate_unmarshal_event_code :: (ti: *Type_Info) -> string {
    si := cast(*Type_Info_Struct) ti;

    if si.tagged_union_bindings.count == 0 return "{}";

    // Member 0 is the tag field (e.g., kind: Event_Kind)
    tag_member := si.members[0];
    tag_type_name := (cast(*Type_Info_Struct) tag_member.type).name;
    tag_name := tag_member.name;

    sb: String_Builder;
    print_to_builder(*sb, "{\n");

    first := true;
    for binding: si.tagged_union_bindings {
        variant := si.members[binding.member_index];
        variant_si := cast(*Type_Info_Struct) variant.type;

        if first {
            print_to_builder(*sb, "    if opcode == % {\n", binding.constant_value);
            first = false;
        } else {
            print_to_builder(*sb, " else if opcode == % {\n", binding.constant_value);
        }

        print_to_builder(*sb, "        event.% = cast(%) %;\n", tag_name, tag_type_name, binding.constant_value);

        // Inline unmarshal code for this variant's args struct
        if variant_si.members.count > 0 {
            variant_prefix := tprint("event.%", variant.name);

            has_variable := false;
            for member: variant_si.members {
                if is_fd_type(member.type) continue;
                if member.type.type == .STRING { has_variable = true; break; }
                if member.type.type == .ARRAY  { has_variable = true; break; }
            }

            if !has_variable {
                inline_code := emit_unmarshal_fixed(variant_si, variant_prefix);
                print_to_builder(*sb, "    %", inline_code);
            } else {
                inline_code := emit_unmarshal_variable(variant_si, variant_prefix);
                print_to_builder(*sb, "    %", inline_code);
            }
        }

        print_to_builder(*sb, "    }");
    }

    print_to_builder(*sb, "\n}\n");
    return builder_to_string(*sb);
}

// --- Type classification helpers (duplicated from marshal.jai, #scope_file there) ---

is_fd_type :: (ti: *Type_Info) -> bool {
    if ti.type != .VARIANT  return false;
    vi := cast(*Type_Info_Variant) ti;
    if !(vi.variant_flags & .DISTINCT)  return false;
    inner := vi.variant_of;
    if inner.type != .INTEGER  return false;
    ii := cast(*Type_Info_Integer) inner;
    return ii.signed && inner.runtime_size == 4;
}

is_fixed_type :: (ti: *Type_Info) -> bool {
    if ti.type != .STRUCT  return false;
    si := cast(*Type_Info_Struct) ti;
    return si.name == "Fixed";
}

is_signed_int :: (ti: *Type_Info) -> bool {
    if ti.type != .INTEGER  return false;
    ii := cast(*Type_Info_Integer) ti;
    return ii.signed;
}

is_void_pointer :: (ti: *Type_Info) -> bool {
    if ti.type != .POINTER  return false;
    pi := cast(*Type_Info_Pointer) ti;
    return pi.pointer_to.type == .VOID;
}

get_pointee_type_name :: (ti: *Type_Info) -> string {
    pi := cast(*Type_Info_Pointer) ti;
    ps := cast(*Type_Info_Struct) pi.pointer_to;
    return ps.name;
}
