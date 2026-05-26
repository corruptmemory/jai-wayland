// Runtime loader: dlopen the bundled stb_image.so and resolve function pointers.
// Falls back through several candidate paths so the binary can be run from any cwd.

#import "POSIX";
#import "Basic";

stb_image_lib: *void;

init_stb_image :: () -> bool {
    if stbi_load_from_memory != null  return true;

    // Try in order: cwd-relative (build/), absolute next-to-this loader.jai (#filepath baked at compile time),
    // and finally the unqualified library name in case the user has installed it system-wide.
    stb_image_lib = try_dlopen("modules/stb_image/linux/stb_image.so");
    if !stb_image_lib  stb_image_lib = try_dlopen(tprint("%linux/stb_image.so", #filepath));
    if !stb_image_lib  stb_image_lib = dlopen("stb_image.so", RTLD_LAZY);
    if !stb_image_lib  return false;

    return load_stb_image_functions();
}

#scope_file

try_dlopen :: (path: string) -> *void {
    cs := to_c_string(path,, temp);
    return dlopen(cs, RTLD_LAZY);
}

load_stb_image_functions :: () -> bool {
    ok := true;
    stbi_load_from_memory                     = xx dlsym(stb_image_lib, "stbi_load_from_memory");                     if stbi_load_from_memory == null                     ok = false;
    stbi_load_from_callbacks                  = xx dlsym(stb_image_lib, "stbi_load_from_callbacks");                  if stbi_load_from_callbacks == null                  ok = false;
    stbi_load                                 = xx dlsym(stb_image_lib, "stbi_load");                                 if stbi_load == null                                 ok = false;
    stbi_load_from_file                       = xx dlsym(stb_image_lib, "stbi_load_from_file");                       if stbi_load_from_file == null                       ok = false;
    stbi_load_gif_from_memory                 = xx dlsym(stb_image_lib, "stbi_load_gif_from_memory");                 if stbi_load_gif_from_memory == null                 ok = false;
    stbi_load_16_from_memory                  = xx dlsym(stb_image_lib, "stbi_load_16_from_memory");                  if stbi_load_16_from_memory == null                  ok = false;
    stbi_load_16_from_callbacks               = xx dlsym(stb_image_lib, "stbi_load_16_from_callbacks");               if stbi_load_16_from_callbacks == null               ok = false;
    stbi_load_16                              = xx dlsym(stb_image_lib, "stbi_load_16");                              if stbi_load_16 == null                              ok = false;
    stbi_load_from_file_16                    = xx dlsym(stb_image_lib, "stbi_load_from_file_16");                    if stbi_load_from_file_16 == null                    ok = false;
    stbi_loadf_from_memory                    = xx dlsym(stb_image_lib, "stbi_loadf_from_memory");                    if stbi_loadf_from_memory == null                    ok = false;
    stbi_loadf_from_callbacks                 = xx dlsym(stb_image_lib, "stbi_loadf_from_callbacks");                 if stbi_loadf_from_callbacks == null                 ok = false;
    stbi_loadf                                = xx dlsym(stb_image_lib, "stbi_loadf");                                if stbi_loadf == null                                ok = false;
    stbi_loadf_from_file                      = xx dlsym(stb_image_lib, "stbi_loadf_from_file");                      if stbi_loadf_from_file == null                      ok = false;
    stbi_hdr_to_ldr_gamma                     = xx dlsym(stb_image_lib, "stbi_hdr_to_ldr_gamma");                     if stbi_hdr_to_ldr_gamma == null                     ok = false;
    stbi_hdr_to_ldr_scale                     = xx dlsym(stb_image_lib, "stbi_hdr_to_ldr_scale");                     if stbi_hdr_to_ldr_scale == null                     ok = false;
    stbi_ldr_to_hdr_gamma                     = xx dlsym(stb_image_lib, "stbi_ldr_to_hdr_gamma");                     if stbi_ldr_to_hdr_gamma == null                     ok = false;
    stbi_ldr_to_hdr_scale                     = xx dlsym(stb_image_lib, "stbi_ldr_to_hdr_scale");                     if stbi_ldr_to_hdr_scale == null                     ok = false;
    stbi_is_hdr_from_callbacks                = xx dlsym(stb_image_lib, "stbi_is_hdr_from_callbacks");                if stbi_is_hdr_from_callbacks == null                ok = false;
    stbi_is_hdr_from_memory                   = xx dlsym(stb_image_lib, "stbi_is_hdr_from_memory");                   if stbi_is_hdr_from_memory == null                   ok = false;
    stbi_is_hdr                               = xx dlsym(stb_image_lib, "stbi_is_hdr");                               if stbi_is_hdr == null                               ok = false;
    stbi_is_hdr_from_file                     = xx dlsym(stb_image_lib, "stbi_is_hdr_from_file");                     if stbi_is_hdr_from_file == null                     ok = false;
    stbi_failure_reason                       = xx dlsym(stb_image_lib, "stbi_failure_reason");                       if stbi_failure_reason == null                       ok = false;
    stbi_image_free                           = xx dlsym(stb_image_lib, "stbi_image_free");                           if stbi_image_free == null                           ok = false;
    stbi_info_from_memory                     = xx dlsym(stb_image_lib, "stbi_info_from_memory");                     if stbi_info_from_memory == null                     ok = false;
    stbi_info_from_callbacks                  = xx dlsym(stb_image_lib, "stbi_info_from_callbacks");                  if stbi_info_from_callbacks == null                  ok = false;
    stbi_is_16_bit_from_memory                = xx dlsym(stb_image_lib, "stbi_is_16_bit_from_memory");                if stbi_is_16_bit_from_memory == null                ok = false;
    stbi_is_16_bit_from_callbacks             = xx dlsym(stb_image_lib, "stbi_is_16_bit_from_callbacks");             if stbi_is_16_bit_from_callbacks == null             ok = false;
    stbi_info                                 = xx dlsym(stb_image_lib, "stbi_info");                                 if stbi_info == null                                 ok = false;
    stbi_info_from_file                       = xx dlsym(stb_image_lib, "stbi_info_from_file");                       if stbi_info_from_file == null                       ok = false;
    stbi_is_16_bit                            = xx dlsym(stb_image_lib, "stbi_is_16_bit");                            if stbi_is_16_bit == null                            ok = false;
    stbi_is_16_bit_from_file                  = xx dlsym(stb_image_lib, "stbi_is_16_bit_from_file");                  if stbi_is_16_bit_from_file == null                  ok = false;
    stbi_set_unpremultiply_on_load            = xx dlsym(stb_image_lib, "stbi_set_unpremultiply_on_load");            if stbi_set_unpremultiply_on_load == null            ok = false;
    stbi_convert_iphone_png_to_rgb            = xx dlsym(stb_image_lib, "stbi_convert_iphone_png_to_rgb");            if stbi_convert_iphone_png_to_rgb == null            ok = false;
    stbi_set_flip_vertically_on_load          = xx dlsym(stb_image_lib, "stbi_set_flip_vertically_on_load");          if stbi_set_flip_vertically_on_load == null          ok = false;
    stbi_set_unpremultiply_on_load_thread     = xx dlsym(stb_image_lib, "stbi_set_unpremultiply_on_load_thread");     if stbi_set_unpremultiply_on_load_thread == null     ok = false;
    stbi_convert_iphone_png_to_rgb_thread     = xx dlsym(stb_image_lib, "stbi_convert_iphone_png_to_rgb_thread");     if stbi_convert_iphone_png_to_rgb_thread == null     ok = false;
    stbi_set_flip_vertically_on_load_thread   = xx dlsym(stb_image_lib, "stbi_set_flip_vertically_on_load_thread");   if stbi_set_flip_vertically_on_load_thread == null   ok = false;
    stbi_zlib_decode_malloc_guesssize         = xx dlsym(stb_image_lib, "stbi_zlib_decode_malloc_guesssize");         if stbi_zlib_decode_malloc_guesssize == null         ok = false;
    stbi_zlib_decode_malloc_guesssize_headerflag = xx dlsym(stb_image_lib, "stbi_zlib_decode_malloc_guesssize_headerflag"); if stbi_zlib_decode_malloc_guesssize_headerflag == null ok = false;
    stbi_zlib_decode_malloc                   = xx dlsym(stb_image_lib, "stbi_zlib_decode_malloc");                   if stbi_zlib_decode_malloc == null                   ok = false;
    stbi_zlib_decode_buffer                   = xx dlsym(stb_image_lib, "stbi_zlib_decode_buffer");                   if stbi_zlib_decode_buffer == null                   ok = false;
    stbi_zlib_decode_noheader_malloc          = xx dlsym(stb_image_lib, "stbi_zlib_decode_noheader_malloc");          if stbi_zlib_decode_noheader_malloc == null          ok = false;
    stbi_zlib_decode_noheader_buffer          = xx dlsym(stb_image_lib, "stbi_zlib_decode_noheader_buffer");          if stbi_zlib_decode_noheader_buffer == null          ok = false;
    return ok;
}
