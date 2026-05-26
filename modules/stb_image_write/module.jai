// Vendored stb_image_write — no build-time linkage.
// Replaces the upstream module's static-archive `#foreign stb_image_write`
// declarations with runtime-loaded function pointers backed by the bundled
// stb_image_write.so. The .so has no DT_NEEDED for libm, so this also
// breaks the libm dependency the static archive otherwise pulled in.

#load "bindings.jai";
#load "loader.jai";
