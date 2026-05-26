//
// This file was auto-generated using the following command:
//
// jai modules/stb_image/generate.jai
//



STBI_VERSION :: 1;

STBI :: enum u32 {
    default    :: 0;

    grey       :: 1;
    grey_alpha :: 2;
    rgb        :: 3;
    rgb_alpha  :: 4;

    STBI_default    :: default;

    STBI_grey       :: grey;
    STBI_grey_alpha :: grey_alpha;
    STBI_rgb        :: rgb;
    STBI_rgb_alpha  :: rgb_alpha;
}

//
// load image by filename, open file, or memory buffer
//
stbi_io_callbacks :: struct {
    read: #type (user: *void, data: *u8, size: s32) -> s32 #c_call; // fill 'data' with 'size' bytes.  return number of bytes actually read
    skip: #type (user: *void, n: s32) -> void #c_call; // skip the next 'n' bytes, or 'unget' the last -n bytes if negative
    eof:  #type (user: *void) -> s32 #c_call; // returns nonzero if we are at end of file/data
}

////////////////////////////////////
//
// 8-bits-per-channel interface
//
stbi_load_from_memory: #type (buffer: *u8, len: s32, x: *s32, y: *s32, channels_in_file: *s32, desired_channels: s32) -> *u8  #c_call;
stbi_load_from_callbacks: #type (clbk: *stbi_io_callbacks, user: *void, x: *s32, y: *s32, channels_in_file: *s32, desired_channels: s32) -> *u8  #c_call;

stbi_load: #type (filename: *u8, x: *s32, y: *s32, channels_in_file: *s32, desired_channels: s32) -> *u8  #c_call;
stbi_load_from_file: #type (f: *FILE, x: *s32, y: *s32, channels_in_file: *s32, desired_channels: s32) -> *u8  #c_call;

stbi_load_gif_from_memory: #type (buffer: *u8, len: s32, delays: **s32, x: *s32, y: *s32, z: *s32, comp: *s32, req_comp: s32) -> *u8  #c_call;

////////////////////////////////////
//
// 16-bits-per-channel interface
//
stbi_load_16_from_memory: #type (buffer: *u8, len: s32, x: *s32, y: *s32, channels_in_file: *s32, desired_channels: s32) -> *u16  #c_call;
stbi_load_16_from_callbacks: #type (clbk: *stbi_io_callbacks, user: *void, x: *s32, y: *s32, channels_in_file: *s32, desired_channels: s32) -> *u16  #c_call;

stbi_load_16: #type (filename: *u8, x: *s32, y: *s32, channels_in_file: *s32, desired_channels: s32) -> *u16  #c_call;
stbi_load_from_file_16: #type (f: *FILE, x: *s32, y: *s32, channels_in_file: *s32, desired_channels: s32) -> *u16  #c_call;

stbi_loadf_from_memory: #type (buffer: *u8, len: s32, x: *s32, y: *s32, channels_in_file: *s32, desired_channels: s32) -> *float  #c_call;
stbi_loadf_from_callbacks: #type (clbk: *stbi_io_callbacks, user: *void, x: *s32, y: *s32, channels_in_file: *s32, desired_channels: s32) -> *float  #c_call;

stbi_loadf: #type (filename: *u8, x: *s32, y: *s32, channels_in_file: *s32, desired_channels: s32) -> *float  #c_call;
stbi_loadf_from_file: #type (f: *FILE, x: *s32, y: *s32, channels_in_file: *s32, desired_channels: s32) -> *float  #c_call;

stbi_hdr_to_ldr_gamma: #type (gamma: float) -> void  #c_call;
stbi_hdr_to_ldr_scale: #type (scale: float) -> void  #c_call;

stbi_ldr_to_hdr_gamma: #type (gamma: float) -> void  #c_call;
stbi_ldr_to_hdr_scale: #type (scale: float) -> void  #c_call;

// stbi_is_hdr is always defined, but always returns false if STBI_NO_HDR
stbi_is_hdr_from_callbacks: #type (clbk: *stbi_io_callbacks, user: *void) -> s32  #c_call;
stbi_is_hdr_from_memory: #type (buffer: *u8, len: s32) -> s32  #c_call;

stbi_is_hdr: #type (filename: *u8) -> s32  #c_call;
stbi_is_hdr_from_file: #type (f: *FILE) -> s32  #c_call;

// get a VERY brief reason for failure
// on most compilers (and ALL modern mainstream compilers) this is threadsafe
stbi_failure_reason: #type () -> *u8  #c_call;

// free the loaded image -- this is just free()
stbi_image_free: #type (retval_from_stbi_load: *void) -> void  #c_call;

// get image dimensions & components without fully decoding
stbi_info_from_memory: #type (buffer: *u8, len: s32, x: *s32, y: *s32, comp: *s32) -> s32  #c_call;
stbi_info_from_callbacks: #type (clbk: *stbi_io_callbacks, user: *void, x: *s32, y: *s32, comp: *s32) -> s32  #c_call;
stbi_is_16_bit_from_memory: #type (buffer: *u8, len: s32) -> s32  #c_call;
stbi_is_16_bit_from_callbacks: #type (clbk: *stbi_io_callbacks, user: *void) -> s32  #c_call;

stbi_info: #type (filename: *u8, x: *s32, y: *s32, comp: *s32) -> s32  #c_call;
stbi_info_from_file: #type (f: *FILE, x: *s32, y: *s32, comp: *s32) -> s32  #c_call;
stbi_is_16_bit: #type (filename: *u8) -> s32  #c_call;
stbi_is_16_bit_from_file: #type (f: *FILE) -> s32  #c_call;

// for image formats that explicitly notate that they have premultiplied alpha,
// we just return the colors as stored in the file. set this flag to force
// unpremultiplication. results are undefined if the unpremultiply overflow.
stbi_set_unpremultiply_on_load: #type (flag_true_if_should_unpremultiply: s32) -> void  #c_call;

// indicate whether we should process iphone images back to canonical format,
// or just pass them through "as-is"
stbi_convert_iphone_png_to_rgb: #type (flag_true_if_should_convert: s32) -> void  #c_call;

// flip the image vertically, so the first pixel in the output array is the bottom left
stbi_set_flip_vertically_on_load: #type (flag_true_if_should_flip: s32) -> void  #c_call;

// as above, but only applies to images loaded on the thread that calls the function
// this function is only available if your compiler supports thread-local variables;
// calling it will fail to link if your compiler doesn't
stbi_set_unpremultiply_on_load_thread: #type (flag_true_if_should_unpremultiply: s32) -> void  #c_call;
stbi_convert_iphone_png_to_rgb_thread: #type (flag_true_if_should_convert: s32) -> void  #c_call;
stbi_set_flip_vertically_on_load_thread: #type (flag_true_if_should_flip: s32) -> void  #c_call;

// ZLIB client - used by PNG, available for other purposes
stbi_zlib_decode_malloc_guesssize: #type (buffer: *u8, len: s32, initial_size: s32, outlen: *s32) -> *u8  #c_call;
stbi_zlib_decode_malloc_guesssize_headerflag: #type (buffer: *u8, len: s32, initial_size: s32, outlen: *s32, parse_header: s32) -> *u8  #c_call;
stbi_zlib_decode_malloc: #type (buffer: *u8, len: s32, outlen: *s32) -> *u8  #c_call;
stbi_zlib_decode_buffer: #type (obuffer: *u8, olen: s32, ibuffer: *u8, ilen: s32) -> s32  #c_call;

stbi_zlib_decode_noheader_malloc: #type (buffer: *u8, len: s32, outlen: *s32) -> *u8  #c_call;
stbi_zlib_decode_noheader_buffer: #type (obuffer: *u8, olen: s32, ibuffer: *u8, ilen: s32) -> s32  #c_call;

// All function pointers above are resolved at runtime by init_stb_image()
// in loader.jai (dlopen of linux/stb_image.so).

