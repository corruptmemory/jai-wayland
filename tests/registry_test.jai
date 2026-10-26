// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jim Powers

#import "Basic";
Wayland :: #import,dir "../modules/wayland";

main :: () {
    print("=== Registry Tests ===\n\n");

    test_bind_by_global_info_writes_each_name();
    test_bind_by_global_info_negotiates_min_version();

    print("\n=== All registry tests passed ===\n");
}

// The fields of one wl_registry.bind message as it sits in a MessageBuilder.
Bind_Message :: struct {
    object_id:      u32;
    opcode:         u16;
    size:           u32;
    name:           u32;
    interface_name: string;
    version:        u32;
    new_id:         u32;
}

// Decode the wl_registry.bind message at src. The header's size word must
// cover exactly the fields that follow it.
read_bind_message :: (src: *u8) -> Bind_Message {
    m: Bind_Message;
    object_id, opcode, size := Wayland.unpack_header(src);
    m.object_id = object_id;
    m.opcode    = opcode;
    m.size      = size;

    offset: u32 = Wayland.HEADER_SIZE;
    m.name = Wayland.read_u32(src + offset);
    offset += 4;
    iface, iface_bytes := Wayland.read_string(src + offset);
    m.interface_name = iface;
    offset += iface_bytes;
    m.version = Wayland.read_u32(src + offset);
    offset += 4;
    m.new_id = Wayland.read_u32(src + offset);
    offset += 4;

    assert(offset == m.size, "header size % != decoded bytes %", m.size, offset);
    return m;
}

// Two globals share the interface name "wl_output" (two monitors). Each bind
// must carry its own compositor-assigned name, not the first match's.
test_bind_by_global_info_writes_each_name :: () {
    registry := Wayland.Wl_Registry.{ id = 2 };
    first  := Wayland.Global_Info.{ name = 10, interface_name = "wl_output", version = 4 };
    second := Wayland.Global_Info.{ name = 11, interface_name = "wl_output", version = 4 };

    batch: Wayland.MessageBuilder;
    ok := Wayland.wl_registry_bind(*batch, *registry, first, 3, type_info(Wayland.Wl_Output));
    assert(ok, "bind of global 10 returned false");
    ok = Wayland.wl_registry_bind(*batch, *registry, second, 4, type_info(Wayland.Wl_Output));
    assert(ok, "bind of global 11 returned false");

    a := read_bind_message(batch.out_buf.data);
    b := read_bind_message(batch.out_buf.data + a.size);
    assert(a.size + b.size == batch.out_used, "two messages span % bytes, batch holds %", a.size + b.size, batch.out_used);

    assert(a.object_id == 2, "first message object id = %", a.object_id);
    assert(a.opcode == Wayland.WL_REGISTRY_BIND, "first message opcode = %", a.opcode);
    assert(a.name == 10, "first message binds global name %, want 10", a.name);
    assert(a.interface_name == "wl_output", "first message interface = \"%\"", a.interface_name);
    assert(a.new_id == 3, "first message new_id = %, want 3", a.new_id);

    assert(b.object_id == 2, "second message object id = %", b.object_id);
    assert(b.opcode == Wayland.WL_REGISTRY_BIND, "second message opcode = %", b.opcode);
    assert(b.name == 11, "second message binds global name %, want 11", b.name);
    assert(b.interface_name == "wl_output", "second message interface = \"%\"", b.interface_name);
    assert(b.new_id == 4, "second message new_id = %, want 4", b.new_id);

    print("  PASS: bind_by_global_info_writes_each_name\n");
}

// The bound version is min(advertised, supported): an old compositor's
// version wins when it is lower, the descriptor's when the compositor's is higher.
test_bind_by_global_info_negotiates_min_version :: () {
    // The generated Wl_Output struct carries only `id`; the supported version
    // lives on its interface descriptor.
    supported := Wayland.WL_OUTPUT_INTERFACE.version;
    assert(supported > 1 && supported < 99, "descriptor version % cannot tell the two cases apart", supported);

    registry := Wayland.Wl_Registry.{ id = 2 };
    older := Wayland.Global_Info.{ name = 10, interface_name = "wl_output", version = 1 };
    newer := Wayland.Global_Info.{ name = 11, interface_name = "wl_output", version = 99 };

    batch: Wayland.MessageBuilder;
    ok := Wayland.wl_registry_bind(*batch, *registry, older, 3, type_info(Wayland.Wl_Output));
    assert(ok, "bind of the version-1 global returned false");
    ok = Wayland.wl_registry_bind(*batch, *registry, newer, 4, type_info(Wayland.Wl_Output));
    assert(ok, "bind of the version-99 global returned false");

    a := read_bind_message(batch.out_buf.data);
    b := read_bind_message(batch.out_buf.data + a.size);

    assert(a.version == 1, "advertised 1, bound %, want 1", a.version);
    assert(b.version == supported, "advertised 99, bound %, want the descriptor's %", b.version, supported);

    print("  PASS: bind_by_global_info_negotiates_min_version\n");
}
