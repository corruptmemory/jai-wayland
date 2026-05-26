// Runtime loader: dlopen the bundled stb_image_write.so and resolve function pointers.

#import "POSIX";
#import "Basic";

stb_image_write_lib: *void;

init_stb_image_write :: () -> bool {
    if stbi_write_png != null  return true;

    stb_image_write_lib = try_dlopen("modules/stb_image_write/linux/stb_image_write.so");
    if !stb_image_write_lib  stb_image_write_lib = try_dlopen(tprint("%linux/stb_image_write.so", #filepath));
    if !stb_image_write_lib  stb_image_write_lib = dlopen("stb_image_write.so", RTLD_LAZY);
    if !stb_image_write_lib  return false;

    return load_stb_image_write_functions();
}

#scope_file

try_dlopen :: (path: string) -> *void {
    cs := to_c_string(path,, temp);
    return dlopen(cs, RTLD_LAZY);
}

load_stb_image_write_functions :: () -> bool {
    ok := true;
    stbi_write_png_to_mem            = xx dlsym(stb_image_write_lib, "stbi_write_png_to_mem");            if stbi_write_png_to_mem == null            ok = false;
    stbi_zlib_compress               = xx dlsym(stb_image_write_lib, "stbi_zlib_compress");               if stbi_zlib_compress == null               ok = false;
    stbi_write_png                   = xx dlsym(stb_image_write_lib, "stbi_write_png");                   if stbi_write_png == null                   ok = false;
    stbi_write_bmp                   = xx dlsym(stb_image_write_lib, "stbi_write_bmp");                   if stbi_write_bmp == null                   ok = false;
    stbi_write_tga                   = xx dlsym(stb_image_write_lib, "stbi_write_tga");                   if stbi_write_tga == null                   ok = false;
    stbi_write_hdr                   = xx dlsym(stb_image_write_lib, "stbi_write_hdr");                   if stbi_write_hdr == null                   ok = false;
    stbi_write_jpg                   = xx dlsym(stb_image_write_lib, "stbi_write_jpg");                   if stbi_write_jpg == null                   ok = false;
    stbi_write_png_to_func           = xx dlsym(stb_image_write_lib, "stbi_write_png_to_func");           if stbi_write_png_to_func == null           ok = false;
    stbi_write_bmp_to_func           = xx dlsym(stb_image_write_lib, "stbi_write_bmp_to_func");           if stbi_write_bmp_to_func == null           ok = false;
    stbi_write_tga_to_func           = xx dlsym(stb_image_write_lib, "stbi_write_tga_to_func");           if stbi_write_tga_to_func == null           ok = false;
    stbi_write_hdr_to_func           = xx dlsym(stb_image_write_lib, "stbi_write_hdr_to_func");           if stbi_write_hdr_to_func == null           ok = false;
    stbi_write_jpg_to_func           = xx dlsym(stb_image_write_lib, "stbi_write_jpg_to_func");           if stbi_write_jpg_to_func == null           ok = false;
    stbi_flip_vertically_on_write    = xx dlsym(stb_image_write_lib, "stbi_flip_vertically_on_write");    if stbi_flip_vertically_on_write == null    ok = false;
    return ok;
}
