#import "Basic";
#import "File";
#import "File_Utilities";
#import "String";

#load "xml.jai";
#load "protocol.jai";
#load "generator.jai";

OUTPUT_DIR :: "modules/wayland";
INPUT_DIR  :: "vendor/wayland-protocols";

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
    protocols: [..] Protocol;
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
        array_add(*protocols, proto);
        print("  Parsed: % (% interfaces)\n", proto.name, proto.interfaces.count);
    }

    print("\nParsed % protocols total.\n\n", protocols.count);

    // 3. Create output directory
    make_directory_if_it_does_not_exist(OUTPUT_DIR, recursive = true);

    // 4. Write types.jai
    {
        types_content := generate_types_file();
        types_path := tprint("%/types.jai", OUTPUT_DIR);
        sb: String_Builder;
        print_to_builder(*sb, "%", types_content);
        ok := write_entire_file(types_path, *sb);
        if ok  print("Wrote %\n", types_path);
        else   print("ERROR: Failed to write %\n", types_path);
    }

    // 5. For each protocol, create subdirectory, write interface files and loader
    protocol_names: [..] string;
    total_interfaces := 0;

    for * proto: protocols {
        array_add(*protocol_names, proto.name);

        proto_dir := tprint("%/%", OUTPUT_DIR, proto.name);
        make_directory_if_it_does_not_exist(proto_dir, recursive = true);

        // Write each interface file
        for * iface: proto.interfaces {
            iface_content := generate_interface_file(iface);
            iface_path := tprint("%/%.jai", proto_dir, iface.name);

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

    // 6. Write module.jai
    {
        module_content := generate_module_root(protocol_names);
        module_path := tprint("%/module.jai", OUTPUT_DIR);
        sb: String_Builder;
        print_to_builder(*sb, "%", module_content);
        ok := write_entire_file(module_path, *sb);
        if ok  print("Wrote %\n", module_path);
        else   print("ERROR: Failed to write %\n", module_path);
    }

    // 7. Summary
    print("\nGeneration complete: % protocols, % interfaces.\n", protocols.count, total_interfaces);
    print("Output directory: %/\n", OUTPUT_DIR);
}
