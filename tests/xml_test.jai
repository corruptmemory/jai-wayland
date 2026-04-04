
#import "Basic";
#import "File";
#import "String";
#load "../src/xml.jai";
#load "../src/protocol.jai";

// ── XML pull parser tests ──

test_empty_document :: () {
    parser := xml_parser_init("");
    _, ok := xml_next(*parser);
    assert(!ok, "Empty document should yield no events");
    print("  PASS: test_empty_document\n");
}

test_processing_instruction :: () {
    parser := xml_parser_init("<?xml version=\"1.0\"?>");
    event, ok := xml_next(*parser);
    assert(ok);
    assert(event.kind == .PROCESSING_INSTRUCTION);
    _, ok2 := xml_next(*parser);
    assert(!ok2, "Should be done after PI");
    print("  PASS: test_processing_instruction\n");
}

test_comment :: () {
    parser := xml_parser_init("<!-- hello -->");
    event, ok := xml_next(*parser);
    assert(ok);
    assert(event.kind == .COMMENT);
    assert(event.value == " hello ", "Expected ' hello ', got '%'", event.value);
    print("  PASS: test_comment\n");
}

test_open_close_tag :: () {
    parser := xml_parser_init("<foo></foo>");
    e1, ok1 := xml_next(*parser);
    assert(ok1 && e1.kind == .OPEN_TAG && e1.name == "foo");
    e2, ok2 := xml_next(*parser);
    assert(ok2 && e2.kind == .CLOSE_TAG && e2.name == "foo");
    print("  PASS: test_open_close_tag\n");
}

test_self_closing_tag :: () {
    parser := xml_parser_init("<br/>");
    e1, ok1 := xml_next(*parser);
    assert(ok1 && e1.kind == .OPEN_TAG && e1.name == "br");
    e2, ok2 := xml_next(*parser);
    assert(ok2 && e2.kind == .CLOSE_TAG && e2.name == "br");
    print("  PASS: test_self_closing_tag\n");
}

test_attributes :: () {
    parser := xml_parser_init("<tag a=\"1\" b='2'/>");
    e1, ok1 := xml_next(*parser);
    assert(ok1 && e1.kind == .OPEN_TAG && e1.name == "tag");

    e2, ok2 := xml_next(*parser);
    assert(ok2 && e2.kind == .ATTRIBUTE);
    assert(e2.name == "a" && e2.value == "1", "Expected a=1, got %=%", e2.name, e2.value);

    e3, ok3 := xml_next(*parser);
    assert(ok3 && e3.kind == .ATTRIBUTE);
    assert(e3.name == "b" && e3.value == "2");

    e4, ok4 := xml_next(*parser);
    assert(ok4 && e4.kind == .CLOSE_TAG);
    print("  PASS: test_attributes\n");
}

test_character_data :: () {
    parser := xml_parser_init("<p>hello world</p>");
    e1, ok1 := xml_next(*parser);
    assert(ok1 && e1.kind == .OPEN_TAG && e1.name == "p");
    e2, ok2 := xml_next(*parser);
    assert(ok2 && e2.kind == .CHARACTER_DATA);
    assert(e2.value == "hello world", "Expected 'hello world', got '%'", e2.value);
    e3, ok3 := xml_next(*parser);
    assert(ok3 && e3.kind == .CLOSE_TAG && e3.name == "p");
    print("  PASS: test_character_data\n");
}

test_open_close_balance :: () {
    contents, ok := read_entire_file("vendor/wayland-protocols/core/wayland.xml");
    assert(ok, "Failed to read wayland.xml");
    parser := xml_parser_init(contents);
    opens := 0;
    closes := 0;
    while true {
        event, has := xml_next(*parser);
        if !has break;
        if event.kind == .OPEN_TAG   opens += 1;
        if event.kind == .CLOSE_TAG  closes += 1;
    }
    assert(opens == closes, "Open/close mismatch: % opens vs % closes", opens, closes);
    assert(opens > 700, "Expected 700+ tags, got %", opens);
    print("  PASS: test_open_close_balance (% tags)\n", opens);
}

// ── Entity decoding tests ──

test_entity_no_entities :: () {
    result := xml_decode_entities("plain text");
    assert(result == "plain text");
    print("  PASS: test_entity_no_entities\n");
}

test_entity_all_five :: () {
    result := xml_decode_entities("a &amp; b &lt; c &gt; d &quot; e &apos; f");
    assert(result == "a & b < c > d \" e ' f", "Got '%'", result);
    print("  PASS: test_entity_all_five\n");
}

test_entity_passthrough :: () {
    result := xml_decode_entities("&unknown; kept");
    assert(result == "&unknown; kept", "Got '%'", result);
    print("  PASS: test_entity_passthrough\n");
}

// ── Protocol parser tests ──

test_parse_wayland_protocol_name :: () {
    contents, ok := read_entire_file("vendor/wayland-protocols/core/wayland.xml");
    assert(ok);
    protocol := parse_protocol(contents);
    assert(protocol.name == "wayland", "Expected 'wayland', got '%'", protocol.name);
    print("  PASS: test_parse_wayland_protocol_name\n");
}

test_parse_interface_count :: () {
    contents, ok := read_entire_file("vendor/wayland-protocols/core/wayland.xml");
    assert(ok);
    protocol := parse_protocol(contents);
    assert(protocol.interfaces.count >= 22, "Expected >=22 interfaces, got %", protocol.interfaces.count);
    print("  PASS: test_parse_interface_count (% interfaces)\n", protocol.interfaces.count);
}

test_parse_wl_display :: () {
    contents, ok := read_entire_file("vendor/wayland-protocols/core/wayland.xml");
    assert(ok);
    protocol := parse_protocol(contents);
    display := protocol.interfaces[0];
    assert(display.name == "wl_display", "Expected 'wl_display', got '%'", display.name);
    assert(display.version == 1);
    assert(display.requests.count == 2, "Expected 2 requests, got %", display.requests.count);
    assert(display.events.count == 2, "Expected 2 events, got %", display.events.count);
    assert(display.enums.count == 1, "Expected 1 enum, got %", display.enums.count);

    // sync request
    sync := display.requests[0];
    assert(sync.name == "sync");
    assert(sync.args.count == 1);
    assert(sync.args[0].arg_type == .NEW_ID);
    assert(sync.args[0].interface_name == "wl_callback");

    // error event
    error_ev := display.events[0];
    assert(error_ev.name == "error");
    assert(error_ev.args.count == 3);
    assert(error_ev.args[0].arg_type == .OBJECT);
    assert(error_ev.args[1].arg_type == .UINT);
    assert(error_ev.args[2].arg_type == .STRING);

    // error enum
    err_enum := display.enums[0];
    assert(err_enum.name == "error");
    assert(err_enum.entries.count == 4);
    assert(err_enum.entries[0].name == "invalid_object");
    assert(err_enum.entries[0].value == 0);
    assert(err_enum.entries[3].name == "implementation");
    assert(err_enum.entries[3].value == 3);

    print("  PASS: test_parse_wl_display\n");
}

test_parse_destructor :: () {
    contents, ok := read_entire_file("vendor/wayland-protocols/core/wayland.xml");
    assert(ok);
    protocol := parse_protocol(contents);
    // wl_callback is interface[2], its event[0] "done" is a destructor
    callback := protocol.interfaces[2];
    assert(callback.name == "wl_callback");
    assert(callback.events.count == 1);
    assert(callback.events[0].name == "done");
    assert(callback.events[0].is_destructor, "done event should be destructor");
    print("  PASS: test_parse_destructor\n");
}

test_parse_bitfield_enum :: () {
    contents, ok := read_entire_file("vendor/wayland-protocols/core/wayland.xml");
    assert(ok);
    protocol := parse_protocol(contents);
    // wl_data_device_manager has a dnd_action bitfield enum
    for iface: protocol.interfaces {
        if iface.name != "wl_data_device_manager" continue;
        assert(iface.enums.count == 1);
        assert(iface.enums[0].name == "dnd_action");
        assert(iface.enums[0].bitfield, "dnd_action should be bitfield");
        print("  PASS: test_parse_bitfield_enum\n");
        return;
    }
    assert(false, "wl_data_device_manager not found");
}

test_parse_hex_entry_value :: () {
    contents, ok := read_entire_file("vendor/wayland-protocols/core/wayland.xml");
    assert(ok);
    protocol := parse_protocol(contents);
    // wl_shm.format enum has hex values like 0x20203843
    for iface: protocol.interfaces {
        if iface.name != "wl_shm" continue;
        for e: iface.enums {
            if e.name != "format" continue;
            // c8 = 0x20203843
            for entry: e.entries {
                if entry.name == "c8" {
                    assert(entry.value == 0x20203843, "Expected 0x20203843, got %", entry.value);
                    print("  PASS: test_parse_hex_entry_value\n");
                    return;
                }
            }
        }
    }
    assert(false, "wl_shm.format.c8 not found");
}

test_parse_allow_null :: () {
    contents, ok := read_entire_file("vendor/wayland-protocols/core/wayland.xml");
    assert(ok);
    protocol := parse_protocol(contents);
    // wl_surface.attach has buffer arg with allow-null="true"
    for iface: protocol.interfaces {
        if iface.name != "wl_surface" continue;
        for req: iface.requests {
            if req.name != "attach" continue;
            assert(req.args[0].name == "buffer");
            assert(req.args[0].allow_null, "buffer arg should be nullable");
            print("  PASS: test_parse_allow_null\n");
            return;
        }
    }
    assert(false, "wl_surface.attach not found");
}

test_parse_enum_reference :: () {
    contents, ok := read_entire_file("vendor/wayland-protocols/core/wayland.xml");
    assert(ok);
    protocol := parse_protocol(contents);
    // wl_shm_pool.create_buffer has format arg with enum="wl_shm.format"
    for iface: protocol.interfaces {
        if iface.name != "wl_shm_pool" continue;
        for req: iface.requests {
            if req.name != "create_buffer" continue;
            for arg: req.args {
                if arg.name == "format" {
                    assert(arg.enum_name == "wl_shm.format", "Expected 'wl_shm.format', got '%'", arg.enum_name);
                    print("  PASS: test_parse_enum_reference\n");
                    return;
                }
            }
        }
    }
    assert(false, "wl_shm_pool.create_buffer.format not found");
}

test_parse_all_59_files :: () {
    Visit_Ctx :: struct { files: int; failures: int; }
    ctx: Visit_Ctx;
    visit_files("vendor/wayland-protocols", true, *ctx, (info: *File_Visit_Info, ctx: *Visit_Ctx) {
        if !ends_with(info.full_name, ".xml") return;
        file_contents, file_ok := read_entire_file(info.full_name);
        if !file_ok { ctx.failures += 1; return; }
        parse_protocol(file_contents);
        ctx.files += 1;
    });
    assert(ctx.failures == 0, "% files failed to parse", ctx.failures);
    assert(ctx.files >= 59, "Expected >=59 files, got %", ctx.files);
    print("  PASS: test_parse_all_59_files (% files)\n", ctx.files);
}

test_parse_xdg_shell :: () {
    contents, ok := read_entire_file("vendor/wayland-protocols/stable/xdg-shell/xdg-shell.xml");
    assert(ok);
    protocol := parse_protocol(contents);
    assert(protocol.name == "xdg_shell", "Expected 'xdg_shell', got '%'", protocol.name);
    assert(protocol.interfaces.count == 5, "Expected 5 interfaces, got %", protocol.interfaces.count);
    // Verify xdg_toplevel exists and has a reasonable number of requests/events
    for iface: protocol.interfaces {
        if iface.name == "xdg_toplevel" {
            assert(iface.requests.count > 5, "xdg_toplevel should have >5 requests");
            assert(iface.events.count > 0, "xdg_toplevel should have events");
            print("  PASS: test_parse_xdg_shell\n");
            return;
        }
    }
    assert(false, "xdg_toplevel not found");
}

// ── Helpers ──

parse_u32_test :: () {
    assert(parse_u32("0") == 0);
    assert(parse_u32("42") == 42);
    assert(parse_u32("0xff") == 255);
    assert(parse_u32("0x20203843") == 0x20203843);
    assert(parse_u32("0xFF") == 255);
    print("  PASS: parse_u32_test\n");
}

// ── Main ──

main :: () {
    print("Running XML parser tests...\n\n");

    print("xml pull parser:\n");
    test_empty_document();
    test_processing_instruction();
    test_comment();
    test_open_close_tag();
    test_self_closing_tag();
    test_attributes();
    test_character_data();
    test_open_close_balance();

    print("\nentity decoding:\n");
    test_entity_no_entities();
    test_entity_all_five();
    test_entity_passthrough();

    print("\nprotocol parser:\n");
    test_parse_wayland_protocol_name();
    test_parse_interface_count();
    test_parse_wl_display();
    test_parse_destructor();
    test_parse_bitfield_enum();
    test_parse_hex_entry_value();
    test_parse_allow_null();
    test_parse_enum_reference();
    test_parse_all_59_files();
    test_parse_xdg_shell();

    print("\nhelpers:\n");
    parse_u32_test();

    print("\nAll tests passed.\n");
}

#import "File_Utilities";
