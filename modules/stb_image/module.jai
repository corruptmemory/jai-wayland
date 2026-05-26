// Vendored stb_image — no build-time linkage.
// The upstream module declares `#library,system,link_always "libm"` to satisfy
// internal C math symbols inside stb_image.a. We replace the static-archive
// `#foreign stb_image` calls with runtime-loaded function pointers backed by
// the bundled stb_image.so (which DT_NEEDED only libc, not libm).

#load "bindings.jai";
#load "loader.jai";

#if OS == .WINDOWS ||  OS == .PS5 || OS == .NN_SWITCH2 {
    #scope_module
    FILE :: void;
} else #if OS_IS_UNIX {
    #import "POSIX";
} else {
    #assert false;
}
