#import "Basic";
#import "File";
#import "File_Utilities";
#import "Hash_Table";
#import "Sort";
#import "String";

#load "xml.jai";
#load "protocol.jai";
#load "generator.jai";

OUTPUT_DIR :: "modules/wayland";
INPUT_DIR  :: "vendor/wayland-protocols";

// Sort priority: core=0, stable=1, staging=2, unstable=3, other=4.
// Lower priority number wins when interface names collide.
protocol_priority :: (path: string) -> int {
    if contains(path, "/core/")     return 0;
    if contains(path, "/stable/")   return 1;
    if contains(path, "/staging/")  return 2;
    if contains(path, "/unstable/") return 3;
    return 4;
}

Parsed_Protocol :: struct {
    proto: Protocol;
    priority: int;
    source_path: string;
}

main :: () {
    print("Generating Wayland bindings...\n\n");

    // 1. Walk INPUT_DIR to find all .xml files
    xml_files: [..] string;
    visit_files(INPUT_DIR, recursive = true, *xml_files, (info: *File_Visit_Info, files: *[..] string) {
        if ends_with(info.full_name, ".xml") {
            array_add(files, copy_string(info.full_name));
        }
    });

    if xml_files.count == 0 {
        print("ERROR: No .xml files found in %/\n", INPUT_DIR);
        return;
    }

    print("Found % protocol XML files.\n", xml_files.count);

    // 2. Parse each XML into a Protocol
    parsed: [..] Parsed_Protocol;
    for path: xml_files {
        contents, ok := read_entire_file(path);
        if !ok {
            print("ERROR: Could not read '%'\n", path);
            continue;
        }
        proto := parse_protocol(contents);
        if proto.name.count == 0 {
            print("WARNING: Skipping '%' (no protocol name)\n", path);
            continue;
        }
        array_add(*parsed, .{proto = proto, priority = protocol_priority(path), source_path = path});
        print("  Parsed: % (% interfaces)\n", proto.name, proto.interfaces.count);
    }

    print("\nParsed % protocols total.\n", parsed.count);

    // 3. Sort by priority (core first, unstable last) for deterministic dedup
    quick_sort(parsed, (a: Parsed_Protocol, b: Parsed_Protocol) -> s64 {
        return cast(s64)(a.priority - b.priority);
    });

    // 4. Deduplicate: skip protocols whose interface names collide with
    //    already-claimed names from higher-priority protocols.
    seen_interfaces: Table(string, string);  // interface_name -> protocol_name
    protocols: [..] Protocol;
    skipped_count := 0;

    for * pp: parsed {
        has_collision := false;
        for iface: pp.proto.interfaces {
            existing := table_find_pointer(*seen_interfaces, iface.name);
            if existing != null {
                if !has_collision {
                    print("  Skipping '%' — interface '%' already defined by '%'\n",
                        pp.proto.name, iface.name, existing.*);
                    has_collision = true;
                }
            }
        }
        if has_collision {
            skipped_count += 1;
            continue;
        }
        // Claim all interface names
        for iface: pp.proto.interfaces {
            table_add(*seen_interfaces, iface.name, pp.proto.name);
        }
        array_add(*protocols, pp.proto);
    }

    if skipped_count > 0 {
        print("  Skipped % protocols with name collisions.\n", skipped_count);
    }
    print("\nGenerating % protocols.\n\n", protocols.count);

    // 5. Create output directory
    make_directory_if_it_does_not_exist(OUTPUT_DIR, recursive = true);

    // 6. Write types.jai
    {
        types_content := generate_types_file();
        types_path := tprint("%/types.jai", OUTPUT_DIR);
        sb: String_Builder;
        print_to_builder(*sb, "%", types_content);
        ok := write_entire_file(types_path, *sb);
        if ok  print("Wrote %\n", types_path);
        else   print("ERROR: Failed to write %\n", types_path);
    }

    // 7. For each protocol, create subdirectory, write interface files and loader
    protocol_names: [..] string;
    total_interfaces := 0;

    for * proto: protocols {
        array_add(*protocol_names, proto.name);

        proto_dir := tprint("%/%", OUTPUT_DIR, proto.name);
        make_directory_if_it_does_not_exist(proto_dir, recursive = true);

        // Write each interface file
        for * iface: proto.interfaces {
            iface_content := generate_interface_file(iface);
            // Avoid self-referencing #load: if interface name == protocol name,
            // append _interface suffix to the filename.
            file_base := ifx iface.name == proto.name then tprint("%_interface", iface.name) else iface.name;
            iface_path := tprint("%/%.jai", proto_dir, file_base);

            sb: String_Builder;
            print_to_builder(*sb, "%", iface_content);
            ok := write_entire_file(iface_path, *sb);
            if !ok  print("ERROR: Failed to write %\n", iface_path);
            total_interfaces += 1;
        }

        // Write protocol loader
        loader_content := generate_protocol_loader(proto);
        loader_path := tprint("%/%.jai", proto_dir, proto.name);

        sb: String_Builder;
        print_to_builder(*sb, "%", loader_content);
        ok := write_entire_file(loader_path, *sb);
        if ok  print("Wrote %/%.jai (% interfaces)\n", proto_dir, proto.name, proto.interfaces.count);
        else   print("ERROR: Failed to write %\n", loader_path);
    }

    // 8. Write module.jai
    {
        module_content := generate_module_root(protocol_names);
        module_path := tprint("%/module.jai", OUTPUT_DIR);
        sb: String_Builder;
        print_to_builder(*sb, "%", module_content);
        ok := write_entire_file(module_path, *sb);
        if ok  print("Wrote %\n", module_path);
        else   print("ERROR: Failed to write %\n", module_path);
    }

    // 9. Write type_registry.jai
    {
        registry_content := generate_type_registry(protocols);
        registry_path := tprint("%/type_registry.jai", OUTPUT_DIR);
        sb: String_Builder;
        print_to_builder(*sb, "%", registry_content);
        ok := write_entire_file(registry_path, *sb);
        if ok  print("Wrote %\n", registry_path);
        else   print("ERROR: Failed to write %\n", registry_path);
    }

    // 10. Summary
    print("\nGeneration complete: % protocols, % interfaces.\n", protocols.count, total_interfaces);
    print("Output directory: %/\n", OUTPUT_DIR);
}
