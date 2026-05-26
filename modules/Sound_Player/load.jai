//
// If optional == true, we don't log an error when the file fails to load.
//
load_audio_file :: (filename: string, optional := false) -> Sound_Data {
    #import "File";

    file_data, success := read_entire_file(filename);
    if !success {
        if !optional {
            log_error("load_audio_file was unable to read the file: %\n", filename);
        }

        return .{};
    }

    return load_audio_data(filename, file_data);
}

load_audio_data :: (name_for_error_reporting: string, data: string) -> Sound_Data {
    #import "Wav_File";

    result: Sound_Data;

    name := name_for_error_reporting;

    if data.count < 12 {
        log_error("Unable to parse '%' as wav or ogg.\n", name);
        return .{};
    }

    magic0 := get_magic4(data, 0);
    if magic0 == 0x46464952 {
        result.name = copy_string(name);
        result.buffer = data;

        format, samples, success2, extra := get_wav_header(result.buffer);
        if !success2 {
            log_error("Unable to parse '%' as wav.\n", name);
            return result;
        }

        if format.wFormatTag == WAVE_FORMAT_PCM {
            result.type                     = .LINEAR_SAMPLE_ARRAY;
            result.nchannels                = cast(u16) format.nChannels;
            result.nsamples_times_nchannels = samples.count/BYTES_PER_SAMPLE;

            // For now, we only do 16-bit wav files, for code simplicity.
            // It would not be too hard to expand this support, but we should
            // decide whether it's worth the tradeoff.
            if format.wBitsPerSample != BYTES_PER_SAMPLE * 8 {
                log_error("Sound_Player currently doesn't support .wav with % bits per sample (currently, the only supported size is 16 bits).", format.wBitsPerSample);
                return result;
            }
        } else if format.wFormatTag == WAVE_FORMAT_DVI_ADPCM {
            result.type             = .ADPCM_COMPRESSED;
            result.wSamplesPerBlock = extra.wSamplesPerBlock;
            result.nBlockAlign      = format.nBlockAlign;

            result.nchannels = cast(u16) format.nChannels;
            // The value in the FACT chunk is number of samples by time.
            result.nsamples_times_nchannels = extra.wSamplesAccordingToFactChunk * result.nchannels;
        } else {
            log_error("Sound_Player currently doesn't support WAV format %.", format.wFormatTag);
            return result;
        }

        result.samples       = cast(*s16) samples.data;
        result.sampling_rate = cast(u32) format.nSamplesPerSec;

        result.loaded = true;
    } else if magic0 == 0x5367674f {
        result.name   = copy_string(name);
        result.buffer = data;
        result.type   = .OGG_COMPRESSED;

        result.loaded = true;
    } else {
        // Unsupported format.
        log_error("Unknown or unsupported format in %\n", name);
    }

    return result;
}

get_magic4 :: (data: string, base: s64) -> u32 {
    u0 := cast(u32) data[base + 0];
    u1 := cast(u32) data[base + 1];
    u2 := cast(u32) data[base + 2];
    u3 := cast(u32) data[base + 3];

    u := (u3 << 24) | (u2 << 16) | (u1 << 8) | u0;

    return u;
}
