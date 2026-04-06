// Compile-time marshal macro: walks arg structs via type_info at compile time
// and emits type-specific serialization code via #insert #run.

#import "Basic";

// The marshal macro. T is the arg struct type; #run runs at compile time,
// generating serialization code specific to T, which #insert injects.
marshal :: (conn: *Connection, object_id: u32, opcode: u16, args: *$T) #expand {
    #insert #run generate_marshal_code(type_info(T));
}

// Marshal a constructor request. Writes new_id as the first arg,
// then writes the struct args. Caller provides the pre-allocated new_id.
marshal_constructor :: (conn: *Connection, object_id: u32, opcode: u16, new_id: u32, args: *$T) #expand {
    _new_id := new_id;
    #insert #run generate_marshal_constructor_code(type_info(T));
}

#scope_file

generate_marshal_code :: (ti: *Type_Info) -> string {
    si := cast(*Type_Info_Struct) ti;

    // Analyze: do we have variable-size fields?
    has_variable := false;
    fixed_size: u32 = HEADER_SIZE;

    for member: si.members {
        if is_fd_type(member.type)   continue;  // fds not on wire
        if member.type.type == .STRING { has_variable = true; continue; }
        if member.type.type == .ARRAY  { has_variable = true; continue; }
        fixed_size += 4;  // all other wire types are 4 bytes
    }

    if !has_variable {
        return emit_fixed_path(si, fixed_size);
    } else {
        return emit_variable_path(si);
    }
}

emit_fixed_path :: (si: *Type_Info_Struct, msg_size: u32) -> string {
    sb: String_Builder;

    print_to_builder(*sb, "{\n");
    print_to_builder(*sb, "    MSG_SIZE :: %;\n", msg_size);
    print_to_builder(*sb, "    _buf: [MSG_SIZE] u8;\n");
    print_to_builder(*sb, "    write_u32(_buf.data, object_id);\n");
    print_to_builder(*sb, "    write_u32(_buf.data + 4, cast(u32)(cast(u32) MSG_SIZE << 16) | cast(u32) opcode);\n");

    offset: u32 = HEADER_SIZE;
    for member: si.members {
        if is_fd_type(member.type) {
            print_to_builder(*sb, "    connection_queue_fd(conn, cast(s32) args.%);\n", member.name);
            continue;
        }
        if is_fixed_type(member.type) {
            print_to_builder(*sb, "    write_s32(_buf.data + %, args.%.raw);\n", offset, member.name);
            offset += 4;
            continue;
        }
        if member.type.type == .POINTER {
            print_to_builder(*sb, "    write_u32(_buf.data + %, args.%.id);\n", offset, member.name);
            offset += 4;
            continue;
        }
        if is_signed_int(member.type) {
            print_to_builder(*sb, "    write_s32(_buf.data + %, args.%);\n", offset, member.name);
        } else {
            print_to_builder(*sb, "    write_u32(_buf.data + %, args.%);\n", offset, member.name);
        }
        offset += 4;
    }

    print_to_builder(*sb, "    connection_queue(conn, _buf.data, MSG_SIZE);\n");
    print_to_builder(*sb, "}\n");

    return builder_to_string(*sb);
}

emit_variable_path :: (si: *Type_Info_Struct) -> string {
    sb: String_Builder;

    print_to_builder(*sb, "{\n");
    print_to_builder(*sb, "    _msg_size: u32 = %;\n", HEADER_SIZE);

    // Emit size computation for each member
    for member: si.members {
        if is_fd_type(member.type)  continue;
        if member.type.type == .STRING {
            print_to_builder(*sb, "    if args.%.count > 0  _msg_size += 4 + align4(cast(u32)(args.%.count + 1));\n", member.name, member.name);
            print_to_builder(*sb, "    else  _msg_size += 4;\n");
        } else if member.type.type == .ARRAY {
            print_to_builder(*sb, "    _msg_size += 4 + align4(cast(u32) args.%.count);\n", member.name);
        } else {
            print_to_builder(*sb, "    _msg_size += 4;\n");
        }
    }

    print_to_builder(*sb, "    assert(_msg_size <= MAX_MESSAGE_SIZE);\n");
    print_to_builder(*sb, "    _buf: [MAX_MESSAGE_SIZE] u8;\n");
    print_to_builder(*sb, "    write_u32(_buf.data, object_id);\n");
    print_to_builder(*sb, "    _offset: u32 = %;\n", HEADER_SIZE);

    // Emit writes for each member
    for member: si.members {
        if is_fd_type(member.type) {
            print_to_builder(*sb, "    connection_queue_fd(conn, cast(s32) args.%);\n", member.name);
            continue;
        }
        if member.type.type == .STRING {
            print_to_builder(*sb, "    _offset += write_string(_buf.data + _offset, args.%);\n", member.name);
            continue;
        }
        if member.type.type == .ARRAY {
            print_to_builder(*sb, "    _offset += write_array(_buf.data + _offset, args.%);\n", member.name);
            continue;
        }
        if is_fixed_type(member.type) {
            print_to_builder(*sb, "    write_s32(_buf.data + _offset, args.%.raw); _offset += 4;\n", member.name);
            continue;
        }
        if member.type.type == .POINTER {
            print_to_builder(*sb, "    write_u32(_buf.data + _offset, args.%.id); _offset += 4;\n", member.name);
            continue;
        }
        if is_signed_int(member.type) {
            print_to_builder(*sb, "    write_s32(_buf.data + _offset, args.%); _offset += 4;\n", member.name);
        } else {
            print_to_builder(*sb, "    write_u32(_buf.data + _offset, args.%); _offset += 4;\n", member.name);
        }
    }

    // Write header last (now we know size)
    print_to_builder(*sb, "    write_u32(_buf.data + 4, cast(u32)(cast(u32) _offset << 16) | cast(u32) opcode);\n");
    print_to_builder(*sb, "    connection_queue(conn, _buf.data, _offset);\n");
    print_to_builder(*sb, "}\n");

    return builder_to_string(*sb);
}

is_fd_type :: (ti: *Type_Info) -> bool {
    if ti.type != .VARIANT  return false;
    vi := cast(*Type_Info_Variant) ti;
    if !(vi.variant_flags & .DISTINCT)  return false;
    // Check that it's a distinct variant of a signed 32-bit integer (s32)
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

generate_marshal_constructor_code :: (ti: *Type_Info) -> string {
    si := cast(*Type_Info_Struct) ti;

    // Analyze: do we have variable-size fields?
    has_variable := false;
    fixed_size: u32 = HEADER_SIZE + 4;  // +4 for new_id

    for member: si.members {
        if is_fd_type(member.type)   continue;
        if member.type.type == .STRING { has_variable = true; continue; }
        if member.type.type == .ARRAY  { has_variable = true; continue; }
        fixed_size += 4;
    }

    if !has_variable {
        return emit_constructor_fixed_path(si, fixed_size);
    } else {
        return emit_constructor_variable_path(si);
    }
}

emit_constructor_fixed_path :: (si: *Type_Info_Struct, msg_size: u32) -> string {
    sb: String_Builder;

    print_to_builder(*sb, "{\n");
    print_to_builder(*sb, "    MSG_SIZE :: %;\n", msg_size);
    print_to_builder(*sb, "    _buf: [MSG_SIZE] u8;\n");
    print_to_builder(*sb, "    write_u32(_buf.data, object_id);\n");
    print_to_builder(*sb, "    write_u32(_buf.data + 4, cast(u32)(cast(u32) MSG_SIZE << 16) | cast(u32) opcode);\n");
    print_to_builder(*sb, "    write_u32(_buf.data + 8, _new_id);\n");

    offset: u32 = HEADER_SIZE + 4;  // start after header + new_id
    for member: si.members {
        if is_fd_type(member.type) {
            print_to_builder(*sb, "    connection_queue_fd(conn, cast(s32) args.%);\n", member.name);
            continue;
        }
        if is_fixed_type(member.type) {
            print_to_builder(*sb, "    write_s32(_buf.data + %, args.%.raw);\n", offset, member.name);
            offset += 4;
            continue;
        }
        if member.type.type == .POINTER {
            print_to_builder(*sb, "    write_u32(_buf.data + %, args.%.id);\n", offset, member.name);
            offset += 4;
            continue;
        }
        if is_signed_int(member.type) {
            print_to_builder(*sb, "    write_s32(_buf.data + %, args.%);\n", offset, member.name);
        } else {
            print_to_builder(*sb, "    write_u32(_buf.data + %, args.%);\n", offset, member.name);
        }
        offset += 4;
    }

    print_to_builder(*sb, "    connection_queue(conn, _buf.data, MSG_SIZE);\n");
    print_to_builder(*sb, "}\n");

    return builder_to_string(*sb);
}

emit_constructor_variable_path :: (si: *Type_Info_Struct) -> string {
    sb: String_Builder;

    print_to_builder(*sb, "{\n");
    print_to_builder(*sb, "    _msg_size: u32 = %;\n", HEADER_SIZE + 4);  // header + new_id

    for member: si.members {
        if is_fd_type(member.type)  continue;
        if member.type.type == .STRING {
            print_to_builder(*sb, "    if args.%.count > 0  _msg_size += 4 + align4(cast(u32)(args.%.count + 1));\n", member.name, member.name);
            print_to_builder(*sb, "    else  _msg_size += 4;\n");
        } else if member.type.type == .ARRAY {
            print_to_builder(*sb, "    _msg_size += 4 + align4(cast(u32) args.%.count);\n", member.name);
        } else {
            print_to_builder(*sb, "    _msg_size += 4;\n");
        }
    }

    print_to_builder(*sb, "    assert(_msg_size <= MAX_MESSAGE_SIZE);\n");
    print_to_builder(*sb, "    _buf: [MAX_MESSAGE_SIZE] u8;\n");
    print_to_builder(*sb, "    write_u32(_buf.data, object_id);\n");
    print_to_builder(*sb, "    write_u32(_buf.data + 8, _new_id);\n");
    print_to_builder(*sb, "    _offset: u32 = %;\n", HEADER_SIZE + 4);  // start after header + new_id

    for member: si.members {
        if is_fd_type(member.type) {
            print_to_builder(*sb, "    connection_queue_fd(conn, cast(s32) args.%);\n", member.name);
            continue;
        }
        if member.type.type == .STRING {
            print_to_builder(*sb, "    _offset += write_string(_buf.data + _offset, args.%);\n", member.name);
            continue;
        }
        if member.type.type == .ARRAY {
            print_to_builder(*sb, "    _offset += write_array(_buf.data + _offset, args.%);\n", member.name);
            continue;
        }
        if is_fixed_type(member.type) {
            print_to_builder(*sb, "    write_s32(_buf.data + _offset, args.%.raw); _offset += 4;\n", member.name);
            continue;
        }
        if member.type.type == .POINTER {
            print_to_builder(*sb, "    write_u32(_buf.data + _offset, args.%.id); _offset += 4;\n", member.name);
            continue;
        }
        if is_signed_int(member.type) {
            print_to_builder(*sb, "    write_s32(_buf.data + _offset, args.%); _offset += 4;\n", member.name);
        } else {
            print_to_builder(*sb, "    write_u32(_buf.data + _offset, args.%); _offset += 4;\n", member.name);
        }
    }

    print_to_builder(*sb, "    write_u32(_buf.data + 4, cast(u32)(cast(u32) _offset << 16) | cast(u32) opcode);\n");
    print_to_builder(*sb, "    connection_queue(conn, _buf.data, _offset);\n");
    print_to_builder(*sb, "}\n");

    return builder_to_string(*sb);
}
