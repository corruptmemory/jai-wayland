// Vendored stb_image_resize — no build-time linkage.
// Replaces the upstream module's static-archive `#foreign stb_image_resize`
// declarations with runtime-loaded function pointers backed by the bundled
// stb_image_resize.so. The .so has no DT_NEEDED for libm, so this also
// breaks the libm dependency the static archive otherwise pulled in.

#load "bindings.jai";
#load "loader.jai";
