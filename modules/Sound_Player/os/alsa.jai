// About MMAP mode:
// MMAP mode seems to be a more direct way to interact with the hardware's ring
// buffer; however, we cannot rely on MMAP being supported on a particular device.
// The default/PulseAudio device doesn't support MMAP so we can only rely on the
// "safe" API in most circumstances. Though, using MMAP when it's available may
// enable a small latency win, if necessary.

/*
How this implementation works:
We make just a few assumptions: the device supports 2+ channel, signed 16-bit audio
and our buffer size can hold a few 60 Hz frames worth of audio at least. Even though
our buffer can be 20+ seconds, we limit ourselves to treating the buffer as if it
was only large enough to hold a few frames, so our latency is (hopefully) only a frame or
two.
*/

#scope_file

#import "POSIX"; // for poll, dlopen, dlsym

// libasound.so.2 is loaded at runtime by init_alsa() instead of being
// linked at build time. backend_init() calls init_alsa() before using
// any snd_pcm_* function pointer. See the load_alsa_functions() block
// at the end of this file for the full dlsym table.

alsa_lib: *void;

init_alsa :: () -> bool {
    if snd_pcm_open != null  return true;

    alsa_lib = dlopen("libasound.so.2", RTLD_LAZY);
    if !alsa_lib  alsa_lib = dlopen("libasound.so", RTLD_LAZY);
    if !alsa_lib  return false;

    return load_alsa_functions();
}

// @TODO this should be changed to file parameters when that becomes implemented
LITTLE_ENDIAN :: 0;
BIG_ENDIAN :: 1;
CPU_BYTE_ORDER :: LITTLE_ENDIAN;

// opaque structs
snd_pcm_t :: struct { }
snd_pcm_info_t :: struct { }
snd_pcm_hw_params_t :: struct { }
snd_pcm_sw_params_t :: struct { }

snd_pcm_stream_t :: u32;
snd_pcm_access_t :: u32;
snd_pcm_format_t :: u32;

/*
SND_PCM_ACCESS_MMAP_INTERLEAVED    :: 0;
SND_PCM_ACCESS_MMAP_NONINTERLEAVED :: 1;
SND_PCM_ACCESS_MMAP_COMPLEX        :: 2;
SND_PCM_ACCESS_RW_NONINTERLEAVED   :: 4;
*/

SND_PCM_ACCESS_RW_INTERLEAVED      :: 3;

SND_PCM_FORMAT_S16_LE  :: 2;
SND_PCM_FORMAT_S16_BE  :: 3;

#if CPU_BYTE_ORDER == LITTLE_ENDIAN {
    SND_PCM_FORMAT_S16_MY_ENDIAN :: SND_PCM_FORMAT_S16_LE;
} else {
    SND_PCM_FORMAT_S16_MY_ENDIAN :: SND_PCM_FORMAT_S16_BE;
}

/*
SND_PCM_FORMAT_UNKNOWN ::-1;
SND_PCM_FORMAT_S8      :: 0;
SND_PCM_FORMAT_U8      :: 1;
SND_PCM_FORMAT_U16_LE  :: 4;
SND_PCM_FORMAT_U16_BE  :: 5;
SND_PCM_FORMAT_S24_LE  :: 6;
SND_PCM_FORMAT_S24_BE  :: 7;
SND_PCM_FORMAT_U24_LE  :: 8;
SND_PCM_FORMAT_U24_BE  :: 9;
SND_PCM_FORMAT_S32_LE  :: 10;
SND_PCM_FORMAT_S32_BE  :: 11;
SND_PCM_FORMAT_U32_LE  :: 12;
SND_PCM_FORMAT_U32_BE  :: 13;
SND_PCM_FORMAT_FLOAT_LE :: 14;
SND_PCM_FORMAT_FLOAT_BE :: 15;
SND_PCM_FORMAT_FLOAT64_LE :: 16;
SND_PCM_FORMAT_FLOAT64_BE :: 17;
SND_PCM_FORMAT_IEC958_SUBFRAME_LE :: 18;
SND_PCM_FORMAT_IEC958_SUBFRAME_BE :: 19;
SND_PCM_FORMAT_MU_LAW :: 20;
SND_PCM_FORMAT_A_LAW :: 21;
SND_PCM_FORMAT_IMA_ADPCM :: 22;
SND_PCM_FORMAT_MPEG :: 23;
SND_PCM_FORMAT_GSM :: 24;
SND_PCM_FORMAT_SPECIAL :: 31;
SND_PCM_FORMAT_S24_3LE :: 32;
SND_PCM_FORMAT_S24_3BE :: 33;
SND_PCM_FORMAT_U24_3LE :: 34;
SND_PCM_FORMAT_U24_3BE :: 35;
SND_PCM_FORMAT_S20_3LE :: 36;
SND_PCM_FORMAT_S20_3BE :: 37;
SND_PCM_FORMAT_U20_3LE :: 38;
SND_PCM_FORMAT_U20_3BE :: 39;
SND_PCM_FORMAT_S18_3LE :: 40;
SND_PCM_FORMAT_S18_3BE :: 41;
SND_PCM_FORMAT_U18_3LE :: 42;
SND_PCM_FORMAT_U18_3BE :: 43;
SND_PCM_FORMAT_G723_24 :: 44;
SND_PCM_FORMAT_G723_24_1B :: 45;
SND_PCM_FORMAT_G723_40    :: 46;
SND_PCM_FORMAT_G723_40_1B :: 47;
SND_PCM_FORMAT_DSD_U8     :: 48;
SND_PCM_FORMAT_DSD_U16_LE :: 49;
SND_PCM_FORMAT_DSD_U32_LE :: 50;
SND_PCM_FORMAT_DSD_U16_BE :: 51;
SND_PCM_FORMAT_DSD_U32_BE :: 52;
*/

snd_pcm_uframes_t :: u64;
snd_pcm_sframes_t :: s64;

snd_pcm_open: #type (pcm: **snd_pcm_t, name: *u8, stream: snd_pcm_stream_t, mode: s32) -> s32  #c_call;
snd_pcm_close: #type (pcm: *snd_pcm_t) -> s32  #c_call;
snd_pcm_delay: #type (pcm: *snd_pcm_t, delayp: *snd_pcm_sframes_t) -> s32  #c_call;
snd_pcm_prepare: #type (pcm: *snd_pcm_t) -> s32  #c_call;
snd_pcm_writei: #type (pcm: *snd_pcm_t, buf: *void, size: snd_pcm_uframes_t) -> snd_pcm_sframes_t  #c_call;
snd_pcm_avail: #type (pcm: *snd_pcm_t) -> snd_pcm_sframes_t  #c_call;
snd_pcm_avail_update: #type (pcm: *snd_pcm_t) -> snd_pcm_sframes_t  #c_call;
snd_pcm_start: #type (pcm: *snd_pcm_t) -> s32  #c_call;
snd_pcm_recover: #type (pcm: *snd_pcm_t, err: s32, silent: s32) -> s32  #c_call;
snd_pcm_drop: #type (pcm: *snd_pcm_t) -> s32  #c_call;

snd_pcm_state_t :: enum u32 {
    SND_PCM_STATE_OPEN :: 0;
    SND_PCM_STATE_SETUP;
    SND_PCM_STATE_PREPARED;
    SND_PCM_STATE_RUNNING;
    SND_PCM_STATE_XRUN;
    SND_PCM_STATE_DRAINING;
    SND_PCM_STATE_PAUSED;
    SND_PCM_STATE_SUSPENDED;
    SND_PCM_STATE_DISCONNECTED;
}
snd_pcm_state: #type (pcm: *snd_pcm_t) -> snd_pcm_state_t  #c_call;

/*
snd_pcm_nonblock: #type (pcm: *snd_pcm_t, nonblock: s32) -> s32  #c_call;
snd_pcm_reset: #type (pcm: *snd_pcm_t) -> s32  #c_call;
snd_pcm_drain: #type (pcm: *snd_pcm_t) -> s32  #c_call;
snd_pcm_wait: #type (pcm: *snd_pcm_t, timeout: s32) -> s32  #c_call;
*/


snd_pcm_set_params: #type (pcm: *snd_pcm_t, format: snd_pcm_format_t, access: snd_pcm_access_t, channels: u32, rate: u32, soft_resample: s32, latency: u32) -> s32  #c_call;

snd_pcm_hw_params: #type (pcm: *snd_pcm_t, params: *snd_pcm_hw_params_t) -> s32  #c_call;
snd_pcm_hw_params_any: #type (pcm: *snd_pcm_t, params: *snd_pcm_hw_params_t) -> s32  #c_call;
snd_pcm_hw_params_get_channels_max: #type (params: *snd_pcm_hw_params_t, val: *u32) -> s32  #c_call;
snd_pcm_hw_params_set_format: #type (pcm: *snd_pcm_t, params: *snd_pcm_hw_params_t, val: snd_pcm_format_t) -> s32  #c_call;
snd_pcm_hw_params_set_access: #type (pcm: *snd_pcm_t, params: *snd_pcm_hw_params_t, access: snd_pcm_access_t) -> s32  #c_call;

/*
snd_pcm_hw_params_set_channels_minmax: #type (pcm: *snd_pcm_t, params: *snd_pcm_hw_params_t, min: *u32, max: *u32) -> s32  #c_call;
snd_pcm_hw_params_get_channels_min: #type (params: *snd_pcm_hw_params_t, val: *u32) -> s32  #c_call;
snd_pcm_hw_params_get_buffer_size_min: #type (params: *snd_pcm_hw_params_t, val: *snd_pcm_uframes_t) -> s32  #c_call;
snd_pcm_hw_params_get_buffer_time: #type (params: *snd_pcm_hw_params_t, val: *u32, dir: *s32) -> s32  #c_call;
snd_pcm_hw_params_get_period_size_min: #type (params: *snd_pcm_hw_params_t, frames: *snd_pcm_uframes_t, dir: *s32) -> s32  #c_call;
snd_pcm_hw_params_get_period_time: #type (params: *snd_pcm_hw_params_t, val: *u32, dir: *s32) -> s32  #c_call;
snd_pcm_hw_params_test_channels: #type (pcm: *snd_pcm_t, params: *snd_pcm_hw_params_t, val: u32) -> s32  #c_call;
snd_pcm_hw_params_set_periods: #type (pcm: *snd_pcm_t, params: *snd_pcm_hw_params_t, val: u32, dir: s32) -> s32  #c_call;
snd_pcm_hw_params_set_buffer_size: #type (pcm: *snd_pcm_t, params: *snd_pcm_hw_params_t, val: snd_pcm_uframes_t) -> s32  #c_call;
*/

snd_pcm_hw_params_set_period_size: #type (pcm: *snd_pcm_t, params: *snd_pcm_hw_params_t, val: snd_pcm_uframes_t, dir: s32) -> s32  #c_call;
snd_pcm_hw_params_set_rate_near: #type (pcm: *snd_pcm_t, params: *snd_pcm_hw_params_t, val: *u32, dir: *s32) -> s32  #c_call;
snd_pcm_hw_params_set_channels: #type (pcm: *snd_pcm_t, params: *snd_pcm_hw_params_t, val: u32) -> s32  #c_call;
snd_pcm_hw_params_get_rate: #type (params: *snd_pcm_hw_params_t, val: *u32, dir: *s32) -> s32  #c_call;
snd_pcm_hw_params_get_channels: #type (params: *snd_pcm_hw_params_t, val: *u32) -> s32  #c_call;
snd_pcm_hw_params_get_buffer_size: #type (params: *snd_pcm_hw_params_t, val: *snd_pcm_uframes_t) -> s32  #c_call;
snd_pcm_hw_params_get_periods: #type (params: *snd_pcm_hw_params_t, val: *u32, dir: *s32) -> s32  #c_call;
snd_pcm_hw_params_get_period_size: #type (params: *snd_pcm_hw_params_t, frames: *snd_pcm_uframes_t, dir: *s32) -> s32  #c_call;

snd_pcm_hw_params_malloc: #type (ptr: **snd_pcm_hw_params_t) -> s32  #c_call;
snd_pcm_hw_params_free: #type (obj: *snd_pcm_hw_params_t) -> void  #c_call;

snd_pcm_sw_params: #type (pcm: *snd_pcm_t, params: *snd_pcm_sw_params_t) -> s32  #c_call;
snd_pcm_sw_params_malloc: #type (ptr: **snd_pcm_sw_params_t) -> s32  #c_call;
snd_pcm_sw_params_free: #type (obj: *snd_pcm_sw_params_t) -> void  #c_call;


snd_pcm_sw_params_current: #type (pcm: *snd_pcm_t, params: *snd_pcm_sw_params_t) -> s32  #c_call;
snd_pcm_sw_params_get_start_threshold: #type (params: *snd_pcm_sw_params_t, val: *snd_pcm_uframes_t) -> s32  #c_call;
snd_pcm_sw_params_set_start_threshold: #type (pcm: *snd_pcm_t, params: *snd_pcm_sw_params_t, val: snd_pcm_uframes_t) -> s32  #c_call;
snd_pcm_sw_params_set_avail_min: #type (pcm: *snd_pcm_t, params: *snd_pcm_sw_params_t, val: snd_pcm_uframes_t) -> s32  #c_call;

/*
snd_pcm_poll_descriptors_revents: #type (pcm: *snd_pcm_t, pfds: *pollfd, nfds: u32, revents: *u16) -> s32  #c_call;
snd_pcm_poll_descriptors_count: #type (pcm: *snd_pcm_t) -> s32  #c_call;
snd_pcm_poll_descriptors: #type (pcm: *snd_pcm_t, pfds: *pollfd, space: u32) -> s32  #c_call;
*/


sound_error_name :: (errnum: s32) -> string {
    return to_string(snd_strerror(errnum));
}

snd_strerror: #type (errnum: s32) -> *u8  #c_call;

check_for_alsa_error :: (name: string, errnum: s32) {
    if !errnum return;
    log_error("Sound_Player ALSA backend error: functionality %: result code %, %. Current state is %", name, errnum, sound_error_name(errnum), ifx pcm_device then snd_pcm_state(pcm_device) else cast(snd_pcm_state_t) U32_MAX);
}

// direct (mmap) API

snd_pcm_channel_area_t :: struct {
    addr: *void; // starting address of channel sample buffer
    first: u32; // bits
    step: u32;  // bits
}

snd_pcm_mmap_begin: #type (pcm: *snd_pcm_t, areas: **snd_pcm_channel_area_t, offset: *snd_pcm_uframes_t, frames: *snd_pcm_uframes_t) -> s32  #c_call;
snd_pcm_mmap_commit: #type (pcm: *snd_pcm_t, offset: snd_pcm_uframes_t, frames: snd_pcm_uframes_t) -> snd_pcm_sframes_t  #c_call;
snd_pcm_mmap_writei: #type (pcm: *snd_pcm_t, buffer: *void, size: snd_pcm_uframes_t) -> snd_pcm_sframes_t  #c_call;
snd_pcm_mmap_readi: #type (pcm: *snd_pcm_t, buffer: *void, size: snd_pcm_uframes_t) -> snd_pcm_sframes_t  #c_call;
snd_pcm_mmap_writen: #type (pcm: *snd_pcm_t, buffer: **void, size: snd_pcm_uframes_t) -> snd_pcm_sframes_t  #c_call;
snd_pcm_mmap_readn: #type (pcm: *snd_pcm_t, buffer: **void, size: snd_pcm_uframes_t) -> snd_pcm_sframes_t  #c_call;

snd_device_name_hint: #type (card: s32, iface: *u8, hints: ***void) -> s32  #c_call;
snd_device_name_free_hint: #type (hints: **void) -> s32  #c_call;
snd_device_name_get_hint: #type (hint: *void, id: *u8) -> *u8  #c_call;

#scope_export

MY_SAMPLING_RATE :: 48000;  // @Incomplete: This should be configurable.

snd_card_next: #type (card: *s32) -> s32  #c_call;
snd_card_get_name: #type (card: s32, name: **u8) -> s32  #c_call;

backend_get_devices :: () -> [] Output_Device {
    output_devices: [..] Output_Device;

    if !init_alsa()  return output_devices;

    current: s32 = -1;
    hr := snd_card_next(*current);

    while current != -1 {
        c_name: *u8;
        hr = snd_card_get_name(current, *c_name);
        if hr == 0 {
            // @Leak: They don't give us a specific API call to free the names.
            // Maybe we need to c_free them but this seems dicey.
            name := copy_string(to_string(c_name));
            device := array_add(*output_devices);
            device.name = name;
            device.device_index = current;

            hint_strings: [..] string;
            {
                hints: **u8;
                hr = snd_device_name_hint(current, "pcm", xx *hints);
                if hr == 0 {
                    defer snd_device_name_free_hint(xx hints);
                    hint_cursor := hints;
                    while hint_cursor.* {
                        hint := hint_cursor.*;
                        c_name := snd_device_name_get_hint(hint, "NAME");
                        if c_name {
                            name := copy_string(to_string(c_name));
                            array_add(*hint_strings, name);
                        }

                        hint_cursor += 1;
                    }
                }
            }

            device.hints = hint_strings;
        }

        hr = snd_card_next(*current);
        if hr != 0  break;
    }

    enumerated_output_devices = output_devices;  // So we can refer back to this later.
    return output_devices;
}

backend_init :: (config: Sound_Player_Config) -> Backend_Properties {
    // @TODO it seems surround71 and surround51 dont always map to the system's default audio
    // device so we cant always rely on that. Maybe implement a way for the user-code to
    // override the device without a clunky configuration system

    SND_PCM_STREAM_PLAYBACK :: 0;
    SND_PCM_NONBLOCK :: 1;

    if !init_alsa() {
        log_error("Sound_Player: failed to dlopen libasound.so.2 — audio will be disabled.");
        return .{};
    }

    check_for_alsa_error("open", snd_pcm_open(*pcm_device, "default", SND_PCM_STREAM_PLAYBACK, SND_PCM_NONBLOCK));

    hwparams: *snd_pcm_hw_params_t;
    snd_pcm_hw_params_malloc(*hwparams);
    defer snd_pcm_hw_params_free(hwparams);

    snd_pcm_hw_params_any(pcm_device, hwparams);

    max_channels: u32;
    check_for_alsa_error("get_max_channels", snd_pcm_hw_params_get_channels_max(hwparams, *max_channels));

    // @Incomplete we need to query the actual chmap positions otherwise we could have our base
    // going through our center speaker instead of the subwoofer...

    // @Hack remove when Mixer supports 6 & 8 channel audio
    max_channels = 2;

    if max_channels == 8 { // 7.1 wide, note surround71 devices may have only 6 channels
        array_add(*channel_names, "Front Left");
        array_add(*channel_names, "Front Right");
        array_add(*channel_names, "Center");
        array_add(*channel_names, "Subwoofer");
        array_add(*channel_names, "Rear Left");
        array_add(*channel_names, "Rear Right");
        array_add(*channel_names, "Extend Left");
        array_add(*channel_names, "Extend Right");
    } else if max_channels == 6 {
        array_add(*channel_names, "Front Left");
        array_add(*channel_names, "Front Right");
        array_add(*channel_names, "Center");
        array_add(*channel_names, "Subwoofer");
        array_add(*channel_names, "Rear Left");
        array_add(*channel_names, "Rear Right");
    } else {
        array_add(*channel_names, "Left");
        array_add(*channel_names, "Right");
    }

    if max_channels > 8 {
        // max_channels can sometimes be set to an insane number since ALSA supports virtually endless amounts of channels in software, so if our hardware doesnt give us a sane amount, we fall back on using a 2 channel config
        max_channels = 2;
    }

    num_channels = cast(s32) max_channels;
    check_for_alsa_error("set_max_channels", snd_pcm_hw_params_set_channels(pcm_device, hwparams, max_channels));

    check_for_alsa_error("set_format", snd_pcm_hw_params_set_format(pcm_device, hwparams, SND_PCM_FORMAT_S16_MY_ENDIAN));

    check_for_alsa_error("set_access", snd_pcm_hw_params_set_access(pcm_device, hwparams, SND_PCM_ACCESS_RW_INTERLEAVED));

    actual_rate: u32 = MY_SAMPLING_RATE;
    check_for_alsa_error("set_rate_near", snd_pcm_hw_params_set_rate_near(pcm_device, hwparams, *actual_rate, null));

    check_for_alsa_error("set_period_size", snd_pcm_hw_params_set_period_size(pcm_device, hwparams, 256, 0));

    check_for_alsa_error("set_hw_params", snd_pcm_hw_params(pcm_device, hwparams));

    subunit_direction: s32;
    check_for_alsa_error("get_rate", snd_pcm_hw_params_get_rate(hwparams, *actual_rate, *subunit_direction));

    _period_size_in_frames: snd_pcm_uframes_t;
    check_for_alsa_error("get_period_size", snd_pcm_hw_params_get_period_size(hwparams, *_period_size_in_frames, *subunit_direction));
    period_size_in_frames = cast(s64)_period_size_in_frames;

    {
        sw_params: *snd_pcm_sw_params_t;
        snd_pcm_sw_params_malloc(*sw_params);
        defer snd_pcm_sw_params_free(sw_params);
        check_for_alsa_error("get_sw_params", snd_pcm_sw_params_current(pcm_device, sw_params));
        auto_start_frames: snd_pcm_uframes_t;
        #if VERBOSE {
            check_for_alsa_error("get_start_threshold", snd_pcm_sw_params_get_start_threshold(sw_params, *auto_start_frames));
            log("Auto-start frames were set to %", auto_start_frames);
        }
        auto_start_frames = 1; // Start as soon as we fill the first buffer. This should be the default, but it’s not documented and I don’t trust Alsa further than I can throw it. -rluba, 2024-03-14
        check_for_alsa_error("set_start_threshold", snd_pcm_sw_params_set_start_threshold(pcm_device, sw_params, auto_start_frames));
        check_for_alsa_error("set_sw_params", snd_pcm_sw_params(pcm_device, sw_params));
    }

    #if VERBOSE log("State before prepare: %", snd_pcm_state(pcm_device));
    check_for_alsa_error("prepare", snd_pcm_prepare(pcm_device));
    #if VERBOSE log("State after prepare: %", snd_pcm_state(pcm_device));

    // snd_pcm_delay always fails here on my machine. Calling snd_pcm_avail() first makes no difference.
    // But it succeeds in backend_count_buffered_bytes, with no additional snd_* call happening between now and then,
    // which suggests a timing issue in Alsa. So for now we’re just trying it here without logging errors.
    // -rluba, 2024-03-14
    _base_delay: snd_pcm_sframes_t;
    // check_for_alsa_error("get_delay (init)", snd_pcm_delay(pcm_device, *_base_delay));
    // #if VERBOSE log("Base delay: % (%)", _base_delay, snd_pcm_state(pcm_device));
    delay_result := snd_pcm_delay(pcm_device, *_base_delay);
    #if VERBOSE log("Base delay: % (%, result was %)", _base_delay, snd_pcm_state(pcm_device), delay_result);
    base_delay_in_frames = _base_delay;

    temporary_buffer_size_in_frames = actual_rate;  // 1 second worth of frames.
    temporary_buffer.count = cast(s64)(temporary_buffer_size_in_frames * num_channels*BYTES_PER_SAMPLE); // @Incomplete this is sort of arbitrary and we should maybe use period time instead
    temporary_buffer.data = alloc(temporary_buffer.count);

    result: Backend_Properties;
    result.num_channels  = num_channels;
    result.channel_names = channel_names;
    result.output_sampling_rate = MY_SAMPLING_RATE;
    result.initted       = true;

    return result;
}

backend_lock_fill_regions :: (bytes_to_lock: s64) -> Fill_Region_Result, bool {
    if !pcm_device return .{}, false;

    avail_frames := snd_pcm_avail(pcm_device);
    if avail_frames < 0 {
        log("Sound_Player Linux port is recovering... %\n", sound_error_name(xx avail_frames));
        check_for_alsa_error("recover", snd_pcm_recover(pcm_device, xx avail_frames, 0));
        avail_frames = snd_pcm_avail(pcm_device);
        if avail_frames < 0 {
            log_error("Sound_Player ALSA backend avail_update 2 failed: samples %", avail_frames);
        }
    }

    Clamp(*avail_frames, 0, temporary_buffer_size_in_frames);
    if avail_frames == 0 return .{}, false;

    avail_bytes := avail_frames*num_channels*BYTES_PER_SAMPLE;

    bytes_to_lock = min(bytes_to_lock, avail_bytes);
    bytes_to_lock = min(bytes_to_lock, temporary_buffer.count);

    result: Fill_Region_Result;
    result.buffer0 = .{bytes_to_lock, temporary_buffer.data};
    result.buffer1 = .{};

    return result, true;
}

backend_release_fill_regions :: (result: Fill_Region_Result) {
    s0 := result.buffer0;
    if !s0 return;

    buffer := cast(*u8) s0.data;
    frames := s0.count / (num_channels*BYTES_PER_SAMPLE);

    recovered := false;
    while frames > 0 {
        written := cast(s64) snd_pcm_writei(pcm_device, buffer, xx frames);
        if written < 0 {
            if recovered break;  // Don't try more than once.
            log_error("Sound_Player ALSA backend write code failure: result %; error name '%'\n", written, sound_error_name(xx -written));
            check_for_alsa_error("recover", snd_pcm_recover(pcm_device, xx written, 0));
            recovered = true;
            continue;
        }

        frames -= written;
        buffer += written * BYTES_PER_SAMPLE * num_channels;
    }
}

backend_count_buffered_bytes :: () -> (buffered_bytes: s64, minimum_prebuffered_bytes: s64) {
    if !pcm_device return 0, 0;
    avail_frames := snd_pcm_avail(pcm_device);

    if avail_frames < 0 {
        log_error("Sound_Player avail_update: %\n", sound_error_name(xx avail_frames));
        check_for_alsa_error("recover", snd_pcm_recover(pcm_device, xx avail_frames, 0));
        snd_pcm_recover(pcm_device, xx avail_frames, 0);
        avail_frames = snd_pcm_avail(pcm_device);
        if avail_frames < 0 {
            log_error("Sound_Player avail_update2: %\n", sound_error_name(xx avail_frames));
            return 0, 0;
        }
    }

    bytes_per_frame := BYTES_PER_SAMPLE * num_channels;
    avail_bytes := avail_frames * bytes_per_frame;

    _delay: snd_pcm_sframes_t;
    check_for_alsa_error("get_delay (count)", snd_pcm_delay(pcm_device, *_delay));
    #if VERBOSE log("Delay (count): % (%)", _delay, snd_pcm_state(pcm_device));
    delay: s64 = _delay - base_delay_in_frames;

    already_buffered_bytes := max(delay, 0) * bytes_per_frame;

    minimum_prebuffered_bytes := period_size_in_frames * 3 * bytes_per_frame;
    minimum_prebuffered_bytes = min(minimum_prebuffered_bytes, avail_bytes);

    return already_buffered_bytes, minimum_prebuffered_bytes;
}

backend_shutdown :: () {
    snd_pcm_drop(pcm_device);
    snd_pcm_close(pcm_device);
    pcm_device = null;
    free(temporary_buffer.data);
    temporary_buffer.data = null;
}

backend_needs_async_update_from_main_thread :: () -> bool {
    return false;
}

backend_play :: () {
    // Nothing to do here. Alsa auto-starts once the buffer gets filled.
    // And we need to prepare the device before that, so that happens in backend_init().
    // -rluba 2024-03-14
}

#scope_file;

num_channels: s32;
channel_names: [..] string;

pcm_device: *snd_pcm_t;

temporary_buffer_size_in_frames: s64;
buffer_consumed: snd_pcm_uframes_t;
period_size_in_frames: s64;
periods: u32 = 3;
base_delay_in_frames: s64;

temporary_buffer: string; // this is just scratch area for the Mixer to write into, this then gets written out to the device

enumerated_output_devices: [..] Output_Device;

// Runtime dlsym for every libasound entry point the rest of this file references.
// init_alsa() above dlopen's the library and calls this; backend_init() invokes init_alsa()
// before any snd_pcm_* use.
load_alsa_functions :: () -> bool {
    ok := true;
    snd_pcm_open                            = xx dlsym(alsa_lib, "snd_pcm_open");                            if snd_pcm_open == null                            ok = false;
    snd_pcm_close                           = xx dlsym(alsa_lib, "snd_pcm_close");                           if snd_pcm_close == null                           ok = false;
    snd_pcm_delay                           = xx dlsym(alsa_lib, "snd_pcm_delay");                           if snd_pcm_delay == null                           ok = false;
    snd_pcm_prepare                         = xx dlsym(alsa_lib, "snd_pcm_prepare");                         if snd_pcm_prepare == null                         ok = false;
    snd_pcm_writei                          = xx dlsym(alsa_lib, "snd_pcm_writei");                          if snd_pcm_writei == null                          ok = false;
    snd_pcm_avail                           = xx dlsym(alsa_lib, "snd_pcm_avail");                           if snd_pcm_avail == null                           ok = false;
    snd_pcm_avail_update                    = xx dlsym(alsa_lib, "snd_pcm_avail_update");                    if snd_pcm_avail_update == null                    ok = false;
    snd_pcm_start                           = xx dlsym(alsa_lib, "snd_pcm_start");                           if snd_pcm_start == null                           ok = false;
    snd_pcm_recover                         = xx dlsym(alsa_lib, "snd_pcm_recover");                         if snd_pcm_recover == null                         ok = false;
    snd_pcm_drop                            = xx dlsym(alsa_lib, "snd_pcm_drop");                            if snd_pcm_drop == null                            ok = false;
    snd_pcm_state                           = xx dlsym(alsa_lib, "snd_pcm_state");                           if snd_pcm_state == null                           ok = false;
    snd_pcm_set_params                      = xx dlsym(alsa_lib, "snd_pcm_set_params");                      if snd_pcm_set_params == null                      ok = false;
    snd_pcm_hw_params                       = xx dlsym(alsa_lib, "snd_pcm_hw_params");                       if snd_pcm_hw_params == null                       ok = false;
    snd_pcm_hw_params_any                   = xx dlsym(alsa_lib, "snd_pcm_hw_params_any");                   if snd_pcm_hw_params_any == null                   ok = false;
    snd_pcm_hw_params_get_channels_max      = xx dlsym(alsa_lib, "snd_pcm_hw_params_get_channels_max");      if snd_pcm_hw_params_get_channels_max == null      ok = false;
    snd_pcm_hw_params_set_format            = xx dlsym(alsa_lib, "snd_pcm_hw_params_set_format");            if snd_pcm_hw_params_set_format == null            ok = false;
    snd_pcm_hw_params_set_access            = xx dlsym(alsa_lib, "snd_pcm_hw_params_set_access");            if snd_pcm_hw_params_set_access == null            ok = false;
    snd_pcm_hw_params_set_period_size       = xx dlsym(alsa_lib, "snd_pcm_hw_params_set_period_size");       if snd_pcm_hw_params_set_period_size == null       ok = false;
    snd_pcm_hw_params_set_rate_near         = xx dlsym(alsa_lib, "snd_pcm_hw_params_set_rate_near");         if snd_pcm_hw_params_set_rate_near == null         ok = false;
    snd_pcm_hw_params_set_channels          = xx dlsym(alsa_lib, "snd_pcm_hw_params_set_channels");          if snd_pcm_hw_params_set_channels == null          ok = false;
    snd_pcm_hw_params_get_rate              = xx dlsym(alsa_lib, "snd_pcm_hw_params_get_rate");              if snd_pcm_hw_params_get_rate == null              ok = false;
    snd_pcm_hw_params_get_channels          = xx dlsym(alsa_lib, "snd_pcm_hw_params_get_channels");          if snd_pcm_hw_params_get_channels == null          ok = false;
    snd_pcm_hw_params_get_buffer_size       = xx dlsym(alsa_lib, "snd_pcm_hw_params_get_buffer_size");       if snd_pcm_hw_params_get_buffer_size == null       ok = false;
    snd_pcm_hw_params_get_periods           = xx dlsym(alsa_lib, "snd_pcm_hw_params_get_periods");           if snd_pcm_hw_params_get_periods == null           ok = false;
    snd_pcm_hw_params_get_period_size       = xx dlsym(alsa_lib, "snd_pcm_hw_params_get_period_size");       if snd_pcm_hw_params_get_period_size == null       ok = false;
    snd_pcm_hw_params_malloc                = xx dlsym(alsa_lib, "snd_pcm_hw_params_malloc");                if snd_pcm_hw_params_malloc == null                ok = false;
    snd_pcm_hw_params_free                  = xx dlsym(alsa_lib, "snd_pcm_hw_params_free");                  if snd_pcm_hw_params_free == null                  ok = false;
    snd_pcm_sw_params                       = xx dlsym(alsa_lib, "snd_pcm_sw_params");                       if snd_pcm_sw_params == null                       ok = false;
    snd_pcm_sw_params_malloc                = xx dlsym(alsa_lib, "snd_pcm_sw_params_malloc");                if snd_pcm_sw_params_malloc == null                ok = false;
    snd_pcm_sw_params_free                  = xx dlsym(alsa_lib, "snd_pcm_sw_params_free");                  if snd_pcm_sw_params_free == null                  ok = false;
    snd_pcm_sw_params_current               = xx dlsym(alsa_lib, "snd_pcm_sw_params_current");               if snd_pcm_sw_params_current == null               ok = false;
    snd_pcm_sw_params_get_start_threshold   = xx dlsym(alsa_lib, "snd_pcm_sw_params_get_start_threshold");   if snd_pcm_sw_params_get_start_threshold == null   ok = false;
    snd_pcm_sw_params_set_start_threshold   = xx dlsym(alsa_lib, "snd_pcm_sw_params_set_start_threshold");   if snd_pcm_sw_params_set_start_threshold == null   ok = false;
    snd_pcm_sw_params_set_avail_min         = xx dlsym(alsa_lib, "snd_pcm_sw_params_set_avail_min");         if snd_pcm_sw_params_set_avail_min == null         ok = false;
    snd_strerror                            = xx dlsym(alsa_lib, "snd_strerror");                            if snd_strerror == null                            ok = false;
    snd_pcm_mmap_begin                      = xx dlsym(alsa_lib, "snd_pcm_mmap_begin");                      if snd_pcm_mmap_begin == null                      ok = false;
    snd_pcm_mmap_commit                     = xx dlsym(alsa_lib, "snd_pcm_mmap_commit");                     if snd_pcm_mmap_commit == null                     ok = false;
    snd_pcm_mmap_writei                     = xx dlsym(alsa_lib, "snd_pcm_mmap_writei");                     if snd_pcm_mmap_writei == null                     ok = false;
    snd_pcm_mmap_readi                      = xx dlsym(alsa_lib, "snd_pcm_mmap_readi");                      if snd_pcm_mmap_readi == null                      ok = false;
    snd_pcm_mmap_writen                     = xx dlsym(alsa_lib, "snd_pcm_mmap_writen");                     if snd_pcm_mmap_writen == null                     ok = false;
    snd_pcm_mmap_readn                      = xx dlsym(alsa_lib, "snd_pcm_mmap_readn");                      if snd_pcm_mmap_readn == null                      ok = false;
    snd_device_name_hint                    = xx dlsym(alsa_lib, "snd_device_name_hint");                    if snd_device_name_hint == null                    ok = false;
    snd_device_name_free_hint               = xx dlsym(alsa_lib, "snd_device_name_free_hint");               if snd_device_name_free_hint == null               ok = false;
    snd_device_name_get_hint                = xx dlsym(alsa_lib, "snd_device_name_get_hint");                if snd_device_name_get_hint == null                ok = false;
    snd_card_next                           = xx dlsym(alsa_lib, "snd_card_next");                           if snd_card_next == null                           ok = false;
    snd_card_get_name                       = xx dlsym(alsa_lib, "snd_card_get_name");                       if snd_card_get_name == null                       ok = false;
    return ok;
}

