// hello_globals — connect to compositor, print available globals.
// The simplest possible Wayland client.

Wayland :: #import,dir "../modules/wayland";
#import "Basic";

main :: () {
    conn: Wayland.Connection;
    if !Wayland.wayland_connect(*conn) {
        print("Could not connect to Wayland compositor.\n");
        return;
    }
    defer Wayland.wayland_disconnect(*conn);

    globals, registry_id := Wayland.discover_globals(*conn);
    print("Connected to Wayland compositor. % globals available:\n\n", globals.count);
    for globals {
        print("  [%] % v%\n", it.name, it.interface_name, it.version);
    }
}
