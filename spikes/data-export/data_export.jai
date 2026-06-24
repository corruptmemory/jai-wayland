// Spike: can Jai #program_export a DATA (OBJECT) symbol with a bare C name?
#import "Basic";

// A struct mirroring the shape we actually need (wl_interface-like).
Thing :: struct { a: s32; b: s32; p: *void; }

#program_export
my_exported_struct: Thing = .{ 0x11, 0x22, null };

#program_export
my_exported_scalar: s64 = 0x1234ABCD;

main :: () {
    print("struct=% scalar=%\n", my_exported_struct, my_exported_scalar);
}
