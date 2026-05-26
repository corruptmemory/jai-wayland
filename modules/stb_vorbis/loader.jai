// Runtime loader: dlopen the bundled stb_vorbis.so and resolve function pointers.

#import "POSIX";
#import "Basic";

stb_vorbis_lib: *void;

init_stb_vorbis :: () -> bool {
    if stb_vorbis_open_memory != null  return true;

    // stb_vorbis.so has no DT_NEEDED for libm but does call log/cos/etc. at
    // runtime. With nothing else linking libm into our binary, dlopen'ing
    // libm with RTLD_GLOBAL first makes its symbols visible to subsequent
    // dlopen targets via the global symbol scope.
    ensure_libm_loaded();

    stb_vorbis_lib = try_dlopen("modules/stb_vorbis/linux/stb_vorbis.so");
    if !stb_vorbis_lib  stb_vorbis_lib = try_dlopen(tprint("%linux/stb_vorbis.so", #filepath));
    if !stb_vorbis_lib  stb_vorbis_lib = dlopen("stb_vorbis.so", RTLD_LAZY);
    if !stb_vorbis_lib  return false;

    return load_stb_vorbis_functions();
}

#scope_file

libm_handle: *void;

ensure_libm_loaded :: () {
    if libm_handle  return;
    libm_handle = dlopen("libm.so.6", RTLD_LAZY | RTLD_GLOBAL);
    if !libm_handle  libm_handle = dlopen("libm.so", RTLD_LAZY | RTLD_GLOBAL);
}

try_dlopen :: (path: string) -> *void {
    cs := to_c_string(path,, temp);
    return dlopen(cs, RTLD_LAZY);
}

load_stb_vorbis_functions :: () -> bool {
    ok := true;
    stb_vorbis_get_info                       = xx dlsym(stb_vorbis_lib, "stb_vorbis_get_info");                       if stb_vorbis_get_info == null                       ok = false;
    stb_vorbis_get_comment                    = xx dlsym(stb_vorbis_lib, "stb_vorbis_get_comment");                    if stb_vorbis_get_comment == null                    ok = false;
    stb_vorbis_get_error                      = xx dlsym(stb_vorbis_lib, "stb_vorbis_get_error");                      if stb_vorbis_get_error == null                      ok = false;
    stb_vorbis_close                          = xx dlsym(stb_vorbis_lib, "stb_vorbis_close");                          if stb_vorbis_close == null                          ok = false;
    stb_vorbis_get_sample_offset              = xx dlsym(stb_vorbis_lib, "stb_vorbis_get_sample_offset");              if stb_vorbis_get_sample_offset == null              ok = false;
    stb_vorbis_get_file_offset                = xx dlsym(stb_vorbis_lib, "stb_vorbis_get_file_offset");                if stb_vorbis_get_file_offset == null                ok = false;
    stb_vorbis_open_pushdata                  = xx dlsym(stb_vorbis_lib, "stb_vorbis_open_pushdata");                  if stb_vorbis_open_pushdata == null                  ok = false;
    stb_vorbis_decode_frame_pushdata          = xx dlsym(stb_vorbis_lib, "stb_vorbis_decode_frame_pushdata");          if stb_vorbis_decode_frame_pushdata == null          ok = false;
    stb_vorbis_flush_pushdata                 = xx dlsym(stb_vorbis_lib, "stb_vorbis_flush_pushdata");                 if stb_vorbis_flush_pushdata == null                 ok = false;
    stb_vorbis_decode_filename                = xx dlsym(stb_vorbis_lib, "stb_vorbis_decode_filename");                if stb_vorbis_decode_filename == null                ok = false;
    stb_vorbis_decode_memory                  = xx dlsym(stb_vorbis_lib, "stb_vorbis_decode_memory");                  if stb_vorbis_decode_memory == null                  ok = false;
    stb_vorbis_open_memory                    = xx dlsym(stb_vorbis_lib, "stb_vorbis_open_memory");                    if stb_vorbis_open_memory == null                    ok = false;
    stb_vorbis_open_filename                  = xx dlsym(stb_vorbis_lib, "stb_vorbis_open_filename");                  if stb_vorbis_open_filename == null                  ok = false;
    stb_vorbis_open_file                      = xx dlsym(stb_vorbis_lib, "stb_vorbis_open_file");                      if stb_vorbis_open_file == null                      ok = false;
    stb_vorbis_open_file_section              = xx dlsym(stb_vorbis_lib, "stb_vorbis_open_file_section");              if stb_vorbis_open_file_section == null              ok = false;
    stb_vorbis_seek_frame                     = xx dlsym(stb_vorbis_lib, "stb_vorbis_seek_frame");                     if stb_vorbis_seek_frame == null                     ok = false;
    stb_vorbis_seek                           = xx dlsym(stb_vorbis_lib, "stb_vorbis_seek");                           if stb_vorbis_seek == null                           ok = false;
    stb_vorbis_seek_start                     = xx dlsym(stb_vorbis_lib, "stb_vorbis_seek_start");                     if stb_vorbis_seek_start == null                     ok = false;
    stb_vorbis_stream_length_in_samples       = xx dlsym(stb_vorbis_lib, "stb_vorbis_stream_length_in_samples");       if stb_vorbis_stream_length_in_samples == null       ok = false;
    stb_vorbis_stream_length_in_seconds       = xx dlsym(stb_vorbis_lib, "stb_vorbis_stream_length_in_seconds");       if stb_vorbis_stream_length_in_seconds == null       ok = false;
    stb_vorbis_get_frame_float                = xx dlsym(stb_vorbis_lib, "stb_vorbis_get_frame_float");                if stb_vorbis_get_frame_float == null                ok = false;
    stb_vorbis_get_frame_short_interleaved    = xx dlsym(stb_vorbis_lib, "stb_vorbis_get_frame_short_interleaved");    if stb_vorbis_get_frame_short_interleaved == null    ok = false;
    stb_vorbis_get_frame_short                = xx dlsym(stb_vorbis_lib, "stb_vorbis_get_frame_short");                if stb_vorbis_get_frame_short == null                ok = false;
    stb_vorbis_get_samples_float_interleaved  = xx dlsym(stb_vorbis_lib, "stb_vorbis_get_samples_float_interleaved");  if stb_vorbis_get_samples_float_interleaved == null  ok = false;
    stb_vorbis_get_samples_float              = xx dlsym(stb_vorbis_lib, "stb_vorbis_get_samples_float");              if stb_vorbis_get_samples_float == null              ok = false;
    stb_vorbis_get_samples_short_interleaved  = xx dlsym(stb_vorbis_lib, "stb_vorbis_get_samples_short_interleaved");  if stb_vorbis_get_samples_short_interleaved == null  ok = false;
    stb_vorbis_get_samples_short              = xx dlsym(stb_vorbis_lib, "stb_vorbis_get_samples_short");              if stb_vorbis_get_samples_short == null              ok = false;
    return ok;
}
