#import "Basic";
#import "File";
#import "File_Utilities";
#import "String";
#load "xml.jai";
#load "protocol.jai";

Visit_Context :: struct {
    total_files: int;
    total_interfaces: int;
    failures: int;
}

main :: () {
    // Detailed parse of core wayland.xml for spot-checking
    contents, ok := read_entire_file("vendor/wayland-protocols/core/wayland.xml");
    if !ok { print("Failed to read wayland.xml\n"); return; }

    protocol := parse_protocol(contents);
    print("Protocol: % (%  interfaces)\n\n", protocol.name, protocol.interfaces.count);

    // Verbose output for first 3 interfaces (wl_display, wl_registry, wl_callback)
    for iface, iface_idx: protocol.interfaces {
        if iface_idx >= 3 break;

        print("═══ % v% ═══\n", iface.name, iface.version);
        if iface.description.summary.count > 0
            print("    %\n", iface.description.summary);

        for req, idx: iface.requests {
            print("  request[%]: %", idx, req.name);
            if req.is_destructor print(" (destructor)");
            if req.since > 1 print(" since=%", req.since);
            print("\n");
            for arg: req.args {
                print("    arg: % : %", arg.name, arg.arg_type);
                if arg.interface_name.count > 0 print(" interface=%", arg.interface_name);
                if arg.enum_name.count > 0      print(" enum=%", arg.enum_name);
                if arg.allow_null                print(" nullable");
                print("\n");
            }
        }

        for ev, idx: iface.events {
            print("  event[%]: %", idx, ev.name);
            if ev.is_destructor print(" (destructor)");
            if ev.since > 1 print(" since=%", ev.since);
            print("\n");
            for arg: ev.args {
                print("    arg: % : %", arg.name, arg.arg_type);
                if arg.interface_name.count > 0 print(" interface=%", arg.interface_name);
                if arg.enum_name.count > 0      print(" enum=%", arg.enum_name);
                if arg.allow_null                print(" nullable");
                print("\n");
            }
        }

        for e, idx: iface.enums {
            print("  enum[%]: %", idx, e.name);
            if e.bitfield print(" (bitfield)");
            print("\n");
            for entry: e.entries {
                print("    % = %\n", entry.name, entry.value);
            }
        }
        print("\n");
    }

    // Bulk validation of all files
    print("──── Bulk validation ────\n");
    ctx: Visit_Context;
    visit_files("vendor/wayland-protocols", true, *ctx, (info: *File_Visit_Info, ctx: *Visit_Context) {
        if !ends_with(info.full_name, ".xml") return;
        file_contents, file_ok := read_entire_file(info.full_name);
        if !file_ok { ctx.failures += 1; return; }
        proto := parse_protocol(file_contents);
        ctx.total_files += 1;
        ctx.total_interfaces += proto.interfaces.count;
    });
    print("%/% files OK, % interfaces total\n", ctx.total_files, ctx.total_files + ctx.failures, ctx.total_interfaces);
    assert(ctx.failures == 0);
}
