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
    ctx: Visit_Context;

    visit_files("vendor/wayland-protocols", true, *ctx, (info: *File_Visit_Info, ctx: *Visit_Context) {
        if !ends_with(info.full_name, ".xml") return;

        contents, ok := read_entire_file(info.full_name);
        if !ok {
            print("FAIL (read): %\n", info.full_name);
            ctx.failures += 1;
            return;
        }

        protocol := parse_protocol(contents);
        ctx.total_files += 1;
        ctx.total_interfaces += protocol.interfaces.count;
        print("OK: % — % interfaces\n", protocol.name, protocol.interfaces.count);
    });

    print("\n%/% files parsed successfully, % total interfaces\n", ctx.total_files, ctx.total_files + ctx.failures, ctx.total_interfaces);
    if ctx.failures > 0  print("FAILURES: %\n", ctx.failures);
    assert(ctx.failures == 0, "Some protocol files failed to parse");
}
