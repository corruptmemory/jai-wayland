// DATA-INTERPOSITION SPIKE (libwayland-client-proxy, Task 7 gate).
// Mirrors gate-1 but for a DATA (OBJECT) symbol: does our exe's exported
// interface table interpose over a real-libwayland-shaped provider that a
// dlopened ICD pulls in via DT_NEEDED? This is the exact condition for the
// ICD's `wl_registry_interface` extern-data ref to bind to OUR tables.
#import "Basic";
#import "POSIX";

Thing :: struct { a: s32; b: s32; p: *void; }
OUR_SENTINEL : s32 : 0xC0FFEE;

#program_export
my_test_interface: Thing = .{ OUR_SENTINEL, 0, null };

Addr_Proc :: #type () -> *void #c_call;
Read_Proc :: #type () -> s32   #c_call;

main :: () {
    print("\n=== data-interposition spike: does a Jai exe interpose a DATA symbol? ===\n");
    icd_path := "/home/jim/projects/jai-wayland/spikes/data-export/build/libdata_icd.so";
    h := dlopen(to_c_string(icd_path), RTLD_NOW | RTLD_GLOBAL);
    if !h { print("FAIL: dlopen(%) -> %\n", icd_path, to_string(dlerror())); return; }

    addr := cast(Addr_Proc) dlsym(h, to_c_string("icd_addr_of_interface"));
    read := cast(Read_Proc) dlsym(h, to_c_string("icd_read_interface_a"));
    if addr == null || read == null { print("FAIL: dlsym -> %\n", to_string(dlerror())); return; }

    our_addr := cast(*void) *my_test_interface;
    icd_addr := addr();
    icd_a    := read();
    interposed := icd_addr == our_addr;

    print("\nour  my_test_interface @ %\n", our_addr);
    print("icd-resolved table     @ %\n", icd_addr);
    print("address interposition  : %\n", ifx interposed then "YES" else "NO");
    print("icd read .a            : 0x%  (ours=0x%, real-provider=0xDEAD)\n",
          formatInt(icd_a, base=16), formatInt(OUR_SENTINEL, base=16));

    ok := interposed && (icd_a == OUR_SENTINEL);
    print("\nVERDICT: %\n", ifx ok
        then "DATA INTERPOSITION HOLDS — the ICD's extern-data table ref binds to OUR tables."
        else "DATA INTERPOSITION FAILED — exe cannot interpose data; need C-owned tables.");
}
