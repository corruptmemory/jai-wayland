#import "Basic";
#import "File";
#load "xml.jai";
#load "protocol.jai";

main :: () {
    contents, ok := read_entire_file("vendor/wayland-protocols/core/wayland.xml");
    if !ok { print("Failed to read file\n"); return; }

    protocol := parse_protocol(contents);
    print("Protocol: %\n", protocol.name);
    print("Interfaces: %\n", protocol.interfaces.count);
    for protocol.interfaces {
        print("  % v% — % requests, % events, % enums\n",
              it.name, it.version, it.requests.count, it.events.count, it.enums.count);
    }
}
