// Vendored stb_vorbis — no build-time linkage.
// Replaces the upstream module's static-archive `#foreign stb_vorbis`
// declarations with runtime-loaded function pointers backed by the bundled
// stb_vorbis.so. The .so has no DT_NEEDED for libm, so this also breaks
// the libm dependency the static archive otherwise pulled in via
// `#library,system,link_always "libm"`.

#load "bindings.jai";
#load "loader.jai";

#if OS == .WINDOWS || OS == .PS5 || OS == .NN_SWITCH2 {
    #scope_module
    FILE :: void;
} else #if OS_IS_UNIX {
    #import "POSIX";
} else {
    #assert false;
}
