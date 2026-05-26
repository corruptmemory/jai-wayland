//
// This file was auto-generated using the following command:
//
// jai modules/stb_vorbis/generate.jai
//



// normally stb_vorbis uses malloc() to allocate memory at startup,
// and alloca() to allocate temporary memory during a frame on the
// stack. (Memory consumption will depend on the amount of setup
// data in the file and how you set the compile flags for speed
// vs. size. In my test files the maximal-size usage is ~150KB.)
//
// You can modify the wrapper functions in the source (setup_malloc,
// setup_temp_malloc, temp_malloc) to change this behavior, or you
// can use a simpler allocation model: you pass in a buffer from
// which stb_vorbis will allocate _all_ its memory (including the
// temp memory). "open" may fail with a VORBIS_outofmem if you
// do not pass in enough data; there is no way to determine how
// much you do need except to succeed (at which point you can
// query get_info to find the exact amount required. yes I know
// this is lame).
//
// If you pass in a non-NULL buffer of the type below, allocation
// will occur from it as described above. Otherwise just pass NULL
// to use malloc()/alloca()
stb_vorbis_alloc :: struct {
    alloc_buffer:                 *u8;
    alloc_buffer_length_in_bytes: s32;
}

stb_vorbis :: struct {}

stb_vorbis_info :: struct {
    sample_rate:                u32;
    channels:                   s32;

    setup_memory_required:      u32;
    setup_temp_memory_required: u32;
    temp_memory_required:       u32;

    max_frame_size:             s32;
}

stb_vorbis_comment :: struct {
    vendor:              *u8;

    comment_list_length: s32;
    comment_list:        **u8;
}

// get general information about the file
stb_vorbis_get_info: #type (f: *stb_vorbis) -> stb_vorbis_info  #c_call;

// get ogg comments
stb_vorbis_get_comment: #type (f: *stb_vorbis) -> stb_vorbis_comment  #c_call;

// get the last error detected (clears it, too)
stb_vorbis_get_error: #type (f: *stb_vorbis) -> s32  #c_call;

// close an ogg vorbis file and free all memory in use
stb_vorbis_close: #type (f: *stb_vorbis) -> void  #c_call;

// this function returns the offset (in samples) from the beginning of the
// file that will be returned by the next decode, if it is known, or -1
// otherwise. after a flush_pushdata() call, this may take a while before
// it becomes valid again.
// NOT WORKING YET after a seek with PULLDATA API
stb_vorbis_get_sample_offset: #type (f: *stb_vorbis) -> s32  #c_call;

// returns the current seek point within the file, or offset from the beginning
// of the memory buffer. In pushdata mode it returns 0.
stb_vorbis_get_file_offset: #type (f: *stb_vorbis) -> u32  #c_call;

// this API allows you to get blocks of data from any source and hand
// them to stb_vorbis. you have to buffer them; stb_vorbis will tell
// you how much it used, and you have to give it the rest next time;
// and stb_vorbis may not have enough data to work with and you will
// need to give it the same data again PLUS more. Note that the Vorbis
// specification does not bound the size of an individual frame.
stb_vorbis_open_pushdata: #type (datablock: *u8, datablock_length_in_bytes: s32, datablock_memory_consumed_in_bytes: *s32, error: *s32, alloc_buffer: *stb_vorbis_alloc) -> *stb_vorbis  #c_call;

// create a vorbis decoder by passing in the initial data block containing
//    the ogg&vorbis headers (you don't need to do parse them, just provide
//    the first N bytes of the file--you're told if it's not enough, see below)
// on success, returns an stb_vorbis *, does not set error, returns the amount of
//    data parsed/consumed on this call in *datablock_memory_consumed_in_bytes;
// on failure, returns NULL on error and sets *error, does not change *datablock_memory_consumed
// if returns NULL and *error is VORBIS_need_more_data, then the input block was
//       incomplete and you need to pass in a larger block from the start of the file
stb_vorbis_decode_frame_pushdata: #type (f: *stb_vorbis, datablock: *u8, datablock_length_in_bytes: s32, channels: *s32, output: ***float, samples: *s32) -> s32  #c_call;

// decode a frame of audio sample data if possible from the passed-in data block
//
// return value: number of bytes we used from datablock
//
// possible cases:
//     0 bytes used, 0 samples output (need more data)
//     N bytes used, 0 samples output (resynching the stream, keep going)
//     N bytes used, M samples output (one frame of data)
// note that after opening a file, you will ALWAYS get one N-bytes,0-sample
// frame, because Vorbis always "discards" the first frame.
//
// Note that on resynch, stb_vorbis will rarely consume all of the buffer,
// instead only datablock_length_in_bytes-3 or less. This is because it wants
// to avoid missing parts of a page header if they cross a datablock boundary,
// without writing state-machiney code to record a partial detection.
//
// The number of channels returned are stored in *channels (which can be
// NULL--it is always the same as the number of channels reported by
// get_info). *output will contain an array of float* buffers, one per
// channel. In other words, (*output)[0][0] contains the first sample from
// the first channel, and (*output)[1][0] contains the first sample from
// the second channel.
//
// *output points into stb_vorbis's internal output buffer storage; these
// buffers are owned by stb_vorbis and application code should not free
// them or modify their contents. They are transient and will be overwritten
// once you ask for more data to get decoded, so be sure to grab any data
// you need before then.
stb_vorbis_flush_pushdata: #type (f: *stb_vorbis) -> void  #c_call;

stb_vorbis_decode_filename: #type (filename: *u8, channels: *s32, sample_rate: *s32, output: **s16) -> s32  #c_call;

stb_vorbis_decode_memory: #type (mem: *u8, len: s32, channels: *s32, sample_rate: *s32, output: **s16) -> s32  #c_call;

// decode an entire file and output the data interleaved into a malloc()ed
// buffer stored in *output. The return value is the number of samples
// decoded, or -1 if the file could not be opened or was not an ogg vorbis file.
// When you're done with it, just free() the pointer returned in *output.
stb_vorbis_open_memory: #type (data: *u8, len: s32, error: *s32, alloc_buffer: *stb_vorbis_alloc) -> *stb_vorbis  #c_call;

stb_vorbis_open_filename: #type (filename: *u8, error: *s32, alloc_buffer: *stb_vorbis_alloc) -> *stb_vorbis  #c_call;

// create an ogg vorbis decoder from a filename via fopen(). on failure,
// returns NULL and sets *error (possibly to VORBIS_file_open_failure).
stb_vorbis_open_file: #type (f: *FILE, close_handle_on_close: s32, error: *s32, alloc_buffer: *stb_vorbis_alloc) -> *stb_vorbis  #c_call;

// create an ogg vorbis decoder from an open FILE *, looking for a stream at
// the _current_ seek point (ftell). on failure, returns NULL and sets *error.
// note that stb_vorbis must "own" this stream; if you seek it in between
// calls to stb_vorbis, it will become confused. Moreover, if you attempt to
// perform stb_vorbis_seek_*() operations on this file, it will assume it
// owns the _entire_ rest of the file after the start point. Use the next
// function, stb_vorbis_open_file_section(), to limit it.
stb_vorbis_open_file_section: #type (f: *FILE, close_handle_on_close: s32, error: *s32, alloc_buffer: *stb_vorbis_alloc, len: u32) -> *stb_vorbis  #c_call;

stb_vorbis_seek_frame: #type (f: *stb_vorbis, sample_number: u32) -> s32  #c_call;
stb_vorbis_seek: #type (f: *stb_vorbis, sample_number: u32) -> s32  #c_call;

// these functions seek in the Vorbis file to (approximately) 'sample_number'.
// after calling seek_frame(), the next call to get_frame_*() will include
// the specified sample. after calling stb_vorbis_seek(), the next call to
// stb_vorbis_get_samples_* will start with the specified sample. If you
// do not need to seek to EXACTLY the target sample when using get_samples_*,
// you can also use seek_frame().
stb_vorbis_seek_start: #type (f: *stb_vorbis) -> s32  #c_call;

// this function is equivalent to stb_vorbis_seek(f,0)
stb_vorbis_stream_length_in_samples: #type (f: *stb_vorbis) -> u32  #c_call;
stb_vorbis_stream_length_in_seconds: #type (f: *stb_vorbis) -> float  #c_call;

// these functions return the total length of the vorbis stream
stb_vorbis_get_frame_float: #type (f: *stb_vorbis, channels: *s32, output: ***float) -> s32  #c_call;

stb_vorbis_get_frame_short_interleaved: #type (f: *stb_vorbis, num_c: s32, buffer: *s16, num_shorts: s32) -> s32  #c_call;
stb_vorbis_get_frame_short: #type (f: *stb_vorbis, num_c: s32, buffer: **s16, num_samples: s32) -> s32  #c_call;

// Channel coercion rules:
//    Let M be the number of channels requested, and N the number of channels present,
//    and Cn be the nth channel; let stereo L be the sum of all L and center channels,
//    and stereo R be the sum of all R and center channels (channel assignment from the
//    vorbis spec).
//        M    N       output
//        1    k      sum(Ck) for all k
//        2    *      stereo L, stereo R
//        k    l      k > l, the first l channels, then 0s
//        k    l      k <= l, the first k channels
//    Note that this is not _good_ surround etc. mixing at all! It's just so
//    you get something useful.
stb_vorbis_get_samples_float_interleaved: #type (f: *stb_vorbis, channels: s32, buffer: *float, num_floats: s32) -> s32  #c_call;
stb_vorbis_get_samples_float: #type (f: *stb_vorbis, channels: s32, buffer: **float, num_samples: s32) -> s32  #c_call;

stb_vorbis_get_samples_short_interleaved: #type (f: *stb_vorbis, channels: s32, buffer: *s16, num_shorts: s32) -> s32  #c_call;
stb_vorbis_get_samples_short: #type (f: *stb_vorbis, channels: s32, buffer: **s16, num_samples: s32) -> s32  #c_call;

////////   ERROR CODES
STBVorbisError :: enum u32 {
    no_error                         :: 0;

    need_more_data                   :: 1;

    invalid_api_mixing               :: 2;
    outofmem                         :: 3;
    feature_not_supported            :: 4;
    too_many_channels                :: 5;
    file_open_failure                :: 6;
    seek_without_length              :: 7;

    unexpected_eof                   :: 10;
    seek_invalid                     :: 11;

    invalid_setup                    :: 20;
    invalid_stream                   :: 21;

    missing_capture_pattern          :: 30;
    invalid_stream_structure_version :: 31;
    continued_packet_flag_invalid    :: 32;
    incorrect_stream_serial_number   :: 33;
    invalid_first_page               :: 34;
    bad_packet_type                  :: 35;
    cant_find_last_page              :: 36;
    seek_failed                      :: 37;
    ogg_skeleton_not_supported       :: 38;

    VORBIS__no_error                        :: no_error;

    VORBIS_need_more_data                   :: need_more_data;

    VORBIS_invalid_api_mixing               :: invalid_api_mixing;
    VORBIS_outofmem                         :: outofmem;
    VORBIS_feature_not_supported            :: feature_not_supported;
    VORBIS_too_many_channels                :: too_many_channels;
    VORBIS_file_open_failure                :: file_open_failure;
    VORBIS_seek_without_length              :: seek_without_length;

    VORBIS_unexpected_eof                   :: unexpected_eof;
    VORBIS_seek_invalid                     :: seek_invalid;

    VORBIS_invalid_setup                    :: invalid_setup;
    VORBIS_invalid_stream                   :: invalid_stream;

    VORBIS_missing_capture_pattern          :: missing_capture_pattern;
    VORBIS_invalid_stream_structure_version :: invalid_stream_structure_version;
    VORBIS_continued_packet_flag_invalid    :: continued_packet_flag_invalid;
    VORBIS_incorrect_stream_serial_number   :: incorrect_stream_serial_number;
    VORBIS_invalid_first_page               :: invalid_first_page;
    VORBIS_bad_packet_type                  :: bad_packet_type;
    VORBIS_cant_find_last_page              :: cant_find_last_page;
    VORBIS_seek_failed                      :: seek_failed;
    VORBIS_ogg_skeleton_not_supported       :: ogg_skeleton_not_supported;
}

// All function pointers above are resolved at runtime by init_stb_vorbis()
// in loader.jai (dlopen of linux/stb_vorbis.so).

