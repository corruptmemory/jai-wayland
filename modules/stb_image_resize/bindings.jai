//
// This file was auto-generated using the following command:
//
// jai modules/stb_image_resize/generate.jai
//



STBIR_ALPHA_CHANNEL_NONE :: -1;

Resize_Flags :: enum_flags s32 {
    ALPHA_PREMULTIPLIED   :: 1 << 0;

    ALPHA_USES_COLORSPACE :: 1 << 1;

    STBIR_FLAG_ALPHA_PREMULTIPLIED   :: ALPHA_PREMULTIPLIED;

    STBIR_FLAG_ALPHA_USES_COLORSPACE :: ALPHA_USES_COLORSPACE;
}

//////////////////////////////////////////////////////////////////////////////
//
// Easy-to-use API:
//
//     * "input pixels" points to an array of image data with 'num_channels' channels (e.g. RGB=3, RGBA=4)
//     * input_w is input image width (x-axis), input_h is input image height (y-axis)
//     * stride is the offset between successive rows of image data in memory, in bytes. you can
//       specify 0 to mean packed continuously in memory
//     * alpha channel is treated identically to other channels.
//     * colorspace is linear or sRGB as specified by function name
//     * returned result is 1 for success or 0 in case of an error.
//       #define STBIR_ASSERT() to trigger an assert on parameter validation errors.
//     * Memory required grows approximately linearly with input and output size, but with
//       discontinuities at input_w == output_w and input_h == output_h.
//     * These functions use a "default" resampling filter defined at compile time. To change the filter,
//       you can change the compile-time defaults by #defining STBIR_DEFAULT_FILTER_UPSAMPLE
//       and STBIR_DEFAULT_FILTER_DOWNSAMPLE, or you can use the medium-complexity API.
stbir_resize_uint8: #type (input_pixels: *u8, input_w: s32, input_h: s32, input_stride_in_bytes: s32, output_pixels: *u8, output_w: s32, output_h: s32, output_stride_in_bytes: s32, num_channels: s32) -> s32  #c_call;

stbir_resize_float: #type (input_pixels: *float, input_w: s32, input_h: s32, input_stride_in_bytes: s32, output_pixels: *float, output_w: s32, output_h: s32, output_stride_in_bytes: s32, num_channels: s32) -> s32  #c_call;

stbir_resize_uint8_srgb: #type (input_pixels: *u8, input_w: s32, input_h: s32, input_stride_in_bytes: s32, output_pixels: *u8, output_w: s32, output_h: s32, output_stride_in_bytes: s32, num_channels: s32, alpha_channel: s32, flags: Resize_Flags) -> s32  #c_call;

stbir_edge :: enum u32 {
    CLAMP   :: 1;
    REFLECT :: 2;
    WRAP    :: 3;
    ZERO    :: 4;

    STBIR_EDGE_CLAMP   :: CLAMP;
    STBIR_EDGE_REFLECT :: REFLECT;
    STBIR_EDGE_WRAP    :: WRAP;
    STBIR_EDGE_ZERO    :: ZERO;
}

// This function adds the ability to specify how requests to sample off the edge of the image are handled.
stbir_resize_uint8_srgb_edgemode: #type (input_pixels: *u8, input_w: s32, input_h: s32, input_stride_in_bytes: s32, output_pixels: *u8, output_w: s32, output_h: s32, output_stride_in_bytes: s32, num_channels: s32, alpha_channel: s32, flags: Resize_Flags, edge_wrap_mode: stbir_edge) -> s32  #c_call;

//////////////////////////////////////////////////////////////////////////////
//
// Medium-complexity API
//
// This extends the easy-to-use API as follows:
//
//     * Alpha-channel can be processed separately
//       * If alpha_channel is not STBIR_ALPHA_CHANNEL_NONE
//         * Alpha channel will not be gamma corrected (unless flags&STBIR_FLAG_GAMMA_CORRECT)
//         * Filters will be weighted by alpha channel (unless flags&STBIR_FLAG_ALPHA_PREMULTIPLIED)
//     * Filter can be selected explicitly
//     * uint16 image type
//     * sRGB colorspace available for all types
//     * context parameter for passing to STBIR_MALLOC
stbir_filter :: enum u32 {
    DEFAULT      :: 0;
    BOX          :: 1;
    TRIANGLE     :: 2;
    CUBICBSPLINE :: 3;
    CATMULLROM   :: 4;
    MITCHELL     :: 5;

    STBIR_FILTER_DEFAULT      :: DEFAULT;
    STBIR_FILTER_BOX          :: BOX;
    STBIR_FILTER_TRIANGLE     :: TRIANGLE;
    STBIR_FILTER_CUBICBSPLINE :: CUBICBSPLINE;
    STBIR_FILTER_CATMULLROM   :: CATMULLROM;
    STBIR_FILTER_MITCHELL     :: MITCHELL;
}

stbir_colorspace :: enum u32 {
    COLORSPACE_LINEAR :: 0;
    COLORSPACE_SRGB   :: 1;

    MAX_COLORSPACES   :: 2;

    STBIR_COLORSPACE_LINEAR :: COLORSPACE_LINEAR;
    STBIR_COLORSPACE_SRGB   :: COLORSPACE_SRGB;

    STBIR_MAX_COLORSPACES   :: MAX_COLORSPACES;
}

// The following functions are all identical except for the type of the image data
stbir_resize_uint8_generic: #type (input_pixels: *u8, input_w: s32, input_h: s32, input_stride_in_bytes: s32, output_pixels: *u8, output_w: s32, output_h: s32, output_stride_in_bytes: s32, num_channels: s32, alpha_channel: s32, flags: Resize_Flags, edge_wrap_mode: stbir_edge, filter: stbir_filter, space: stbir_colorspace, alloc_context: *void) -> s32  #c_call;

stbir_resize_uint16_generic: #type (input_pixels: *u16, input_w: s32, input_h: s32, input_stride_in_bytes: s32, output_pixels: *u16, output_w: s32, output_h: s32, output_stride_in_bytes: s32, num_channels: s32, alpha_channel: s32, flags: Resize_Flags, edge_wrap_mode: stbir_edge, filter: stbir_filter, space: stbir_colorspace, alloc_context: *void) -> s32  #c_call;

stbir_resize_float_generic: #type (input_pixels: *float, input_w: s32, input_h: s32, input_stride_in_bytes: s32, output_pixels: *float, output_w: s32, output_h: s32, output_stride_in_bytes: s32, num_channels: s32, alpha_channel: s32, flags: Resize_Flags, edge_wrap_mode: stbir_edge, filter: stbir_filter, space: stbir_colorspace, alloc_context: *void) -> s32  #c_call;

//////////////////////////////////////////////////////////////////////////////
//
// Full-complexity API
//
// This extends the medium API as follows:
//
//       * uint32 image type
//     * not typesafe
//     * separate filter types for each axis
//     * separate edge modes for each axis
//     * can specify scale explicitly for subpixel correctness
//     * can specify image source tile using texture coordinates
stbir_datatype :: enum u32 {
    TYPE_UINT8  :: 0;
    TYPE_UINT16 :: 1;
    TYPE_UINT32 :: 2;
    TYPE_FLOAT  :: 3;

    MAX_TYPES   :: 4;

    STBIR_TYPE_UINT8  :: TYPE_UINT8;
    STBIR_TYPE_UINT16 :: TYPE_UINT16;
    STBIR_TYPE_UINT32 :: TYPE_UINT32;
    STBIR_TYPE_FLOAT  :: TYPE_FLOAT;

    STBIR_MAX_TYPES   :: MAX_TYPES;
}

stbir_resize: #type (input_pixels: *void, input_w: s32, input_h: s32, input_stride_in_bytes: s32, output_pixels: *void, output_w: s32, output_h: s32, output_stride_in_bytes: s32, datatype: stbir_datatype, num_channels: s32, alpha_channel: s32, flags: Resize_Flags, edge_mode_horizontal: stbir_edge, edge_mode_vertical: stbir_edge, filter_horizontal: stbir_filter, filter_vertical: stbir_filter, space: stbir_colorspace, alloc_context: *void) -> s32  #c_call;

stbir_resize_subpixel: #type (input_pixels: *void, input_w: s32, input_h: s32, input_stride_in_bytes: s32, output_pixels: *void, output_w: s32, output_h: s32, output_stride_in_bytes: s32, datatype: stbir_datatype, num_channels: s32, alpha_channel: s32, flags: Resize_Flags, edge_mode_horizontal: stbir_edge, edge_mode_vertical: stbir_edge, filter_horizontal: stbir_filter, filter_vertical: stbir_filter, space: stbir_colorspace, alloc_context: *void, x_scale: float, y_scale: float, x_offset: float, y_offset: float) -> s32  #c_call;

stbir_resize_region: #type (input_pixels: *void, input_w: s32, input_h: s32, input_stride_in_bytes: s32, output_pixels: *void, output_w: s32, output_h: s32, output_stride_in_bytes: s32, datatype: stbir_datatype, num_channels: s32, alpha_channel: s32, flags: Resize_Flags, edge_mode_horizontal: stbir_edge, edge_mode_vertical: stbir_edge, filter_horizontal: stbir_filter, filter_vertical: stbir_filter, space: stbir_colorspace, alloc_context: *void, s0: float, t0: float, s1: float, t1: float) -> s32  #c_call;

// All function pointers above are resolved at runtime by init_stb_image_resize()
// in loader.jai (dlopen of linux/stb_image_resize.so).

