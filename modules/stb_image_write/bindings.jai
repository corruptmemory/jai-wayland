//
// This file was auto-generated using the following command:
//
// jai modules/stb_image_write/generate.jai
//

stbi_write_png_to_mem: #type (pixels: *u8, stride_bytes: s32, x: s32, y: s32, n: s32, out_len: *s32) -> *u8  #c_call;
stbi_zlib_compress: #type (data: *u8, data_len: s32, out_len: *s32, quality: s32) -> *u8  #c_call;



// Configuration globals exposed by the C library. Treated as compile-time
// constants here for compatibility with callers that read them; runtime
// updates would require dlsym + write, which no existing caller needs.
stbi_write_tga_with_rle: s32;
stbi_write_png_compression_level: s32;
stbi_write_force_png_filter: s32;

stbi_write_png: #type (filename: *u8, w: s32, h: s32, comp: s32, data: *void, stride_in_bytes: s32) -> s32  #c_call;
stbi_write_bmp: #type (filename: *u8, w: s32, h: s32, comp: s32, data: *void) -> s32  #c_call;
stbi_write_tga: #type (filename: *u8, w: s32, h: s32, comp: s32, data: *void) -> s32  #c_call;
stbi_write_hdr: #type (filename: *u8, w: s32, h: s32, comp: s32, data: *float) -> s32  #c_call;
stbi_write_jpg: #type (filename: *u8, x: s32, y: s32, comp: s32, data: *void, quality: s32) -> s32  #c_call;

stbi_write_func :: #type (_context: *void, data: *void, size: s32) -> void #c_call;

stbi_write_png_to_func: #type (func: stbi_write_func, _context: *void, w: s32, h: s32, comp: s32, data: *void, stride_in_bytes: s32) -> s32  #c_call;
stbi_write_bmp_to_func: #type (func: stbi_write_func, _context: *void, w: s32, h: s32, comp: s32, data: *void) -> s32  #c_call;
stbi_write_tga_to_func: #type (func: stbi_write_func, _context: *void, w: s32, h: s32, comp: s32, data: *void) -> s32  #c_call;
stbi_write_hdr_to_func: #type (func: stbi_write_func, _context: *void, w: s32, h: s32, comp: s32, data: *float) -> s32  #c_call;
stbi_write_jpg_to_func: #type (func: stbi_write_func, _context: *void, x: s32, y: s32, comp: s32, data: *void, quality: s32) -> s32  #c_call;

stbi_flip_vertically_on_write: #type (flip_boolean: s32) -> void  #c_call;

// All function pointers above are resolved at runtime by init_stb_image_write()
// in loader.jai (dlopen of linux/stb_image_write.so).

