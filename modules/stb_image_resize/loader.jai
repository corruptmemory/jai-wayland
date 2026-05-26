// Runtime loader: dlopen the bundled stb_image_resize.so and resolve function pointers.

#import "POSIX";
#import "Basic";

stb_image_resize_lib: *void;

init_stb_image_resize :: () -> bool {
    if stbir_resize_uint8 != null  return true;

    stb_image_resize_lib = try_dlopen("modules/stb_image_resize/linux/stb_image_resize.so");
    if !stb_image_resize_lib  stb_image_resize_lib = try_dlopen(tprint("%linux/stb_image_resize.so", #filepath));
    if !stb_image_resize_lib  stb_image_resize_lib = dlopen("stb_image_resize.so", RTLD_LAZY);
    if !stb_image_resize_lib  return false;

    return load_stb_image_resize_functions();
}

#scope_file

try_dlopen :: (path: string) -> *void {
    cs := to_c_string(path,, temp);
    return dlopen(cs, RTLD_LAZY);
}

load_stb_image_resize_functions :: () -> bool {
    ok := true;
    stbir_resize_uint8                = xx dlsym(stb_image_resize_lib, "stbir_resize_uint8");                if stbir_resize_uint8 == null                ok = false;
    stbir_resize_float                = xx dlsym(stb_image_resize_lib, "stbir_resize_float");                if stbir_resize_float == null                ok = false;
    stbir_resize_uint8_srgb           = xx dlsym(stb_image_resize_lib, "stbir_resize_uint8_srgb");           if stbir_resize_uint8_srgb == null           ok = false;
    stbir_resize_uint8_srgb_edgemode  = xx dlsym(stb_image_resize_lib, "stbir_resize_uint8_srgb_edgemode");  if stbir_resize_uint8_srgb_edgemode == null  ok = false;
    stbir_resize_uint8_generic        = xx dlsym(stb_image_resize_lib, "stbir_resize_uint8_generic");        if stbir_resize_uint8_generic == null        ok = false;
    stbir_resize_uint16_generic       = xx dlsym(stb_image_resize_lib, "stbir_resize_uint16_generic");       if stbir_resize_uint16_generic == null       ok = false;
    stbir_resize_float_generic        = xx dlsym(stb_image_resize_lib, "stbir_resize_float_generic");        if stbir_resize_float_generic == null        ok = false;
    stbir_resize                      = xx dlsym(stb_image_resize_lib, "stbir_resize");                      if stbir_resize == null                      ok = false;
    stbir_resize_subpixel             = xx dlsym(stb_image_resize_lib, "stbir_resize_subpixel");             if stbir_resize_subpixel == null             ok = false;
    stbir_resize_region               = xx dlsym(stb_image_resize_lib, "stbir_resize_region");               if stbir_resize_region == null               ok = false;
    return ok;
}
