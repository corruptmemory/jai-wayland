#scope_export

/*

  All code in this file must be threadsafe.

  Be careful reading local variables!

  Do not call procedures outside this file unless they are vetted!

 */

TEST_K :: 1.0;
DELTA_RATE_MAX :: 18.0 * (1.0 / 40000.0) * TEST_K;
DELTA_RATE_MIN :: -DELTA_RATE_MAX;

the_accumulator: [48000] Audio_Dest_Sample;  // @Incomplete: Make this constant better.
accumulator_element_size :: size_of(Audio_Dest_Sample);


Audio_Sample_Base :: struct {
    channels: [MAX_CHANNELS_PER_SOUND] float;
}

Fill_Region_Result :: struct {
    buffer0: string;
    buffer1: string;
}

//
// We define Audio_Source_Sample and Audio_Dest_Sample just so
// we can have typechecking... but we want all the same operators,
// etc.
//
// But note that the indexing is different between these!  The indexing
// for Dest_Sample is ACHANNEL_*; the indexing for Source_Sample
// is SOUND_SOURCE_*.
//
//     -jblow, 3 December 2011
//

Audio_Source_Sample :: struct {
    using base: Audio_Sample_Base;
}

Audio_Dest_Sample :: struct {
    using base: Audio_Sample_Base;
}

Sound_Data :: struct {
    using resource: struct {
        name: string;       // Resource identifier.
        full_path: string;  // Full path to resource, in case not loaded.
        loaded := false;    //
        skip_load := false; // Flag to skip hotloading events.
    };

    Kind :: enum {
        UNINITIALIZED;
        LINEAR_SAMPLE_ARRAY;
        OGG_COMPRESSED;
        ADPCM_COMPRESSED;
    }

    type := Kind.UNINITIALIZED;

    nsamples_times_nchannels : s64;   // How many samples long is this effect?   (a stereo sample actually counts as 2 here, against the convention the sound player uses... confusing!  @Cleanup)

    nchannels: u16 = 1;       // How many channels are in this effect? For OGG_COMPRESSED sounds, this is ignored, and stays 1, because we don't want to be in the business of parsing the ogg file just to represent the data. Instead that's in the Cached_Ogg_Decoder. Yes maybe this is confusing and can be cleaned up.
    sampling_rate: u32 = 44100;

    // Note that each sample counted in 'nsamples' is a mono sample.
    // So a 1-second long, stereo sound effect will have a value of
    // 'nsamples' that is twice that of a 1-second long, mono sound effect.

    buffer: string;      // buffer where the sound data is stored (this class owns this buffer)
    samples: *s16;       // points where sound sample data is inside buffer_ptr (treat this as *void if the data is compressed in some way.)


    volume_scale : float = 1;  // This is in perceptual units; 2.0 means "sounds twice as loud".
    silence_before_repeat : float = 0;

	//
	// If streaming:
	//

	filename_to_stream_from : string;
    source_directions: [MAX_CHANNELS_PER_SOUND] Source_Direction;

    nBlockAlign : s32 = 0;       // Copied from the wave format.
    wSamplesPerBlock : s32 = 0;  // Copied from the wave format.
}

Buffer_Bounds :: struct {
    start, end: s64;
    memory: *void;
}

get_buffer_bounds :: (stream: *Sound_Stream, data: *Sound_Data, index: s64, result: *Buffer_Bounds) -> success: bool , no_overflow: bool {  // @Cleanup: Eliminate 'no_overflow'.
    if stream.decoder {
        // print("decoder on % index %\n", data.name, index);

        extra_samples: int;
        success, start, end, memory := find_page_containing_cursor(stream.decoder, index);
        if !success return false, false;

        if end > stream.repeat_end_position  end = stream.repeat_end_position;

        result.start  = start;
        result.end    = end;
        result.memory = memory;

        return success, true;
    } else {
        end := data.nsamples_times_nchannels / data.nchannels;
        if stream.repeat_end_position >= 0 {
            if end > stream.repeat_end_position  end = stream.repeat_end_position;
        }

        result.start = 0;
        result.end = end;
        result.memory = cast(*void)data.samples;

        return true, true;
    }
}


add :: (v0: *Audio_Sample_Base, v1: *Audio_Sample_Base, nchannels: s64) -> Audio_Sample_Base {
    result: Audio_Sample_Base = ---;

    for 0..nchannels-1
        result.channels[it] = v0.channels[it] + v1.channels[it];

    return result;
}

plus_equals :: (v0: *Audio_Sample_Base, v1: *Audio_Sample_Base, nchannels: s64) {
    for 0..nchannels-1
        v0.channels[it] += v1.channels[it];
}

multiply :: (v0: *Audio_Sample_Base, v1: *Audio_Sample_Base) -> Audio_Sample_Base {
    result: Audio_Sample_Base;

    for v0.channels
        result.channels[it_index] = it * v1.channels[it_index];

    return result;
}

multiply :: (v0: *Audio_Sample_Base, k: float) -> Audio_Sample_Base {
    result: Audio_Sample_Base;

    for v0.channels
        result.channels[it_index] = it * k;

    return result;
}

multiply :: (k: float, v0: *Audio_Sample_Base) -> Audio_Sample_Base {
    return multiply(v0, k);
}

times_equals :: (v0: *Audio_Sample_Base, k: float) {
    for v0.channels
        v0.channels[it_index] *= k;
}


/*
sine_offset :s64= 0;

do_sine_wave :: (dest: *s16, num_samples: int, player: *Sound_Player) {
    amplitude := 8000.0;
    omega := 100.0;

    b := backend.fill_buffer_size_in_bytes / (BYTES_PER_SAMPLE * 2);
    for i: 0..num_samples-1 {
        t := cast(float)sine_offset / cast(float)b;

        fresult := amplitude * cos(omega * t * 2 * 3.1415926);
        result := cast(s16) fresult;

        dest[i*2 + 0] = result;
        dest[i*2 + 1] = result;

        sine_offset += 1;
    }

    if sine_offset > b sine_offset -= b;  // It's a precision thing, so the sine wave doesn't degrade.
}
*/


get_icursor_and_remainder :: (source_cursor: float64) -> icursor: s64, remainder: float64 {
    icursor   := cast(s64) floor(source_cursor);
    remainder := source_cursor - icursor;

//    assert(remainder >= 0);

    return icursor, remainder;
}

sample_n_channels :: (stream: *Sound_Stream, samples: *s16, page_start: s64, page_end: s64, source_cursor: float64, samples_return: [] float, no_overflow: bool) #no_abc {
    nchannels := stream.num_channels;

    icursor, remainder := get_icursor_and_remainder(source_cursor);

    //assert(icursor >= page_start);
    //assert(icursor < page_end);

    icursor -= page_start;
    page_size := page_end - page_start;


    i_0 := icursor;
    i_1 := icursor+1;

    if (i_1 >= page_size) && no_overflow  i_1 = i_0;

    for k : 0..nchannels-1 {
        s0 := cast(float) samples[i_0 * nchannels + k];
        s1 := cast(float) samples[i_1 * nchannels + k];

        s := lerp(s0, s1, cast(float) remainder);

        samples_return[k] = s;
    }
}

mix_sample_into_output_streams :: (stream: *Sound_Stream, source: *Audio_Source_Sample, dest: *Audio_Dest_Sample) #no_abc {
    for i : 0..stream.num_channels-1 {

        source_value := source.channels[i];
        target := *stream.input_scale_mappings[i];

        for j : 0..backend.num_channels-1 {
            factor := source_value * target.interpolated_source_scale_for_this_output_index[j];

            if i == 0 {
                dest.channels[j] = factor;
            } else {
                dest.channels[j] += factor;
            }

            target.interpolated_source_scale_for_this_output_index[j] += target.dvolume_dsample[j];
        }
    }
}

maybe_wrap_play_cursor :: (stream: *Sound_Stream) {
    if !(stream.user_flags & .REPEATING) return;

    data := stream.sound_data;
    t := stream.play_cursor;

    if (t > 0) && stream.repeat_end_position && ((cast(s64) t) >= stream.repeat_end_position) {
        t = fmod_cycling(t, cast(float64) stream.repeat_end_position);
        t += cast(float64) stream.repeat_start_position;
        stream.play_cursor = t;
    }
}

catch_up_volumes :: (stream: *Sound_Stream) {
    for i : 0..stream.num_channels-1 {
        target := *stream.input_scale_mappings[i];

        for j : 0..backend.num_channels-1 {
            goal := target.source_scale_for_this_output_index[j];
            target.interpolated_source_scale_for_this_output_index[j] = goal;
        }
    }
}

accumulate_buffer_f :: (accumulator: *Audio_Dest_Sample, num_samples: s64, source_cursor: float64,
                        page: *void, page_start: s64, page_end: s64,
                        stream: *Sound_Stream, no_overflow: bool) -> (cursor: float64, samples_written: s64) {

    if num_samples == 0 return source_cursor, 0;
    // assert(num_samples > 0);

    if stream.silent_this_frame {
        stream.current_rate = stream.desired_rate;

        // play_cursor is handled upon return!   stream.play_cursor += num_samples * stream.current_rate;
        // maybe_wrap_play_cursor(stream);

        catch_up_volumes(stream);

        stream.samples_streamed_since_entity_update += num_samples;

        fnum_samples := cast(float) num_samples;
        if stream.current_rate < 0 {
            return source_cursor - fnum_samples * stream.current_rate, num_samples;  // @Robustness: Set various 'last_sample_output', etc stuff?
        } else {
            return source_cursor + fnum_samples * stream.current_rate, num_samples;  // @Robustness: Set various 'last_sample_output', etc stuff?
        }
    }

    samples := cast(*s16) page;
    rate := stream.current_rate;
    delta_rate := stream.desired_rate - stream.current_rate;

    if stream.user_flags & .PAUSED_DUE_TO_MENU {
        // Insta-stop without rate cooldown...

        stream.current_rate = 0;
        delta_rate = 0;
        rate = 0;

        stream.user_flags |= .WAS_PAUSED_DUE_TO_MENU;
        catch_up_volumes(stream);
    } else {
        if stream.user_flags & .WAS_PAUSED_DUE_TO_MENU {
            // Insta-start without warmup.
            stream.current_rate = stream.desired_rate;
            rate = stream.current_rate;
            delta_rate = 0;

            stream.user_flags &= ~.WAS_PAUSED_DUE_TO_MENU;
        }
    }

    drate_dsample := delta_rate / num_samples;
    Clamp(*drate_dsample, DELTA_RATE_MIN, DELTA_RATE_MAX);

    dcursor_dsample := rate;
    ddcursor_dsample := drate_dsample;

    samples_written := num_samples;  // May get overwritten if we break from the loop early.

    tmp: Audio_Source_Sample = ---;

    {

        if num_samples > 0 {
            for i : 0..stream.num_channels-1 {
                target := *stream.input_scale_mappings[i];
                for j : 0..backend.num_channels-1 {
                    goal := target.source_scale_for_this_output_index[j];
                    current := target.interpolated_source_scale_for_this_output_index[j];

                    rate = (goal - current) / num_samples;

                    limit := 30.0 / backend.output_sampling_rate;  // Can go from volume 0-1 in max 1/30th sec.
                    Clamp(*rate, -limit, limit);

                    target.dvolume_dsample[j] = rate;
                }
            }
        }

        num_output_channels := backend.num_channels;
        mix: Audio_Dest_Sample = ---;
        for i : 0..num_samples-1 {
            sample_n_channels(stream, samples, page_start, page_end, source_cursor, tmp.channels, no_overflow);
            mix_sample_into_output_streams(stream, *tmp, *mix);

            plus_equals(*accumulator[i].base, *mix.base, num_output_channels);

            source_cursor += dcursor_dsample;
            dcursor_dsample += ddcursor_dsample;

            icursor := cast(s64) source_cursor;
            if (icursor >= page_end) || (icursor < page_start) {
                samples_written = i + 1;
                break;
            }
        }
    }

    //
    // Update the current_rate and current_scale, potentially topping them off.
    //
    // assert(samples_written > 0);

    stream.samples_streamed_since_entity_update += samples_written;

    stream.current_rate += drate_dsample * samples_written;

    if abs(stream.desired_rate - stream.current_rate) < 0.001 {
        stream.current_rate = stream.desired_rate;
    }

/* @Experiment
    stream.last_volume_linear += dscale_dsample * samples_written;
    if (fabs(desired_scale - stream.last_volume_linear) < 0.001f) {
        stream.last_volume_linear = desired_scale;
    }
*/

   /*
    stream.x0 = x0;
    stream.x1 = x1;

    stream.y0 = y0;
    stream.y1 = y1;
*/

    return source_cursor, samples_written;
}


accumulate_stream :: (stream: *Sound_Stream, accumulator: [] Audio_Dest_Sample, num_samples: s64) -> bool {
    data := stream.sound_data;
    if !data return false;

/* Temporary test hack:
	if (stream.flags & .WAITING_FOR_INITIAL_DECODER_PAGES) {
		if (stream.decoder && (stream.decoder.pages.items > 1)) stream.flags &= ~.WAITING_FOR_INITIAL_DECODER_PAGES;
	}
*/

    // Don't go forward with this stream if we haven't started getting decoder pages yet.
	if stream.internal_flags & .WAITING_FOR_INITIAL_DECODER_PAGES {
		return false;
	}

    if stream.internal_flags & .FIRST_VOLUME_UPDATE {
        catch_up_volumes(stream);
        stream.internal_flags &= ~.FIRST_VOLUME_UPDATE;
    }

    num_source_samples := data.nsamples_times_nchannels / data.nchannels;

    if stream.repeat_end_position >= 0 {
        num_source_samples = min(num_source_samples, stream.repeat_end_position);
    }


    direction : s64 = 1;
    if stream.current_rate < 0 direction = -1;

    dest_cursor : s64 = 0;

    while num_samples {
        // assert(num_samples >= 0);
        range := stream.repeat_end_position - stream.repeat_start_position;
        if range <= 0 {
            // Nothing to play!
            break;
        }

        maybe_wrap_play_cursor(stream); // Do this BEFORE copying stream.play_cursor into source_cursor!
        source_cursor := stream.play_cursor;
        orig_source_cursor := source_cursor;

        si, remainder := get_icursor_and_remainder(source_cursor);

        //
        // If we should play silence samples, do so here...
        //
        silence_samples : s64 = 0;
        if si < 0 {
            if direction < 0  silence_samples = num_samples;
            else silence_samples = (0 - si + direction - 1) / direction;
        } else if si >= num_source_samples {
            if direction < 0  silence_samples = (si - num_source_samples + 1 + (-direction) + 1) / (-direction);
            else silence_samples = num_samples;
        }

        // assert(silence_samples >= 0);
        if silence_samples < 0 silence_samples = 0;

        if silence_samples {
            to_subtract := silence_samples;
            Clamp(*to_subtract, 0, num_samples);

            num_samples -= to_subtract;
            dest_cursor += to_subtract;
			assert(dest_cursor >= 0);
            source_cursor += cast(float64) (to_subtract * direction);
            stream.play_cursor += cast(float64) (to_subtract * direction);

            // assert(num_samples >= 0);

            stream.samples_streamed_since_entity_update += to_subtract;

            stream.current_rate = stream.desired_rate;
            catch_up_volumes(stream);

            continue;
        }


        //
        // Do actual data samples.
        //

        no_overflow: bool;
        bounds: Buffer_Bounds;

        if !stream.silent_this_frame {
            success: bool;
            success, no_overflow = get_buffer_bounds(stream, data, cast(s64) source_cursor, *bounds);

			if !success {
				stream.silent_this_frame = true;  // Failed to decompress audio in time?
			}
        }

        if stream.silent_this_frame {
            // If it is silent_this_frame, pointer for 'bounds' will be unused.
            bounds.start = cast(s64) source_cursor;
            bounds.end = bounds.start + num_samples;
            bounds.memory = null;
        }



        to_copy: s64 = ---;
        if direction > 0 {
            to_copy = bounds.end - cast(s64) source_cursor;
        } else {
            // assert(direction < 0);
            to_copy = cast(s64) source_cursor - bounds.start + 1;
        }

        if to_copy > num_samples  to_copy = num_samples;
        if to_copy == 0 {
            to_copy = 1;  // @Incomplete, decide what to do here.
        }

        accum2 := *accumulator[dest_cursor];
        samples_written: s64;
        source_cursor, samples_written =
            accumulate_buffer_f(accum2, to_copy, source_cursor,
                                bounds.memory, bounds.start, bounds.end,
                                stream, no_overflow);

        stream.play_cursor += (source_cursor - orig_source_cursor);
		maybe_wrap_play_cursor(stream);

		assert(samples_written >= 0);

        num_samples -= samples_written;

        dest_cursor += samples_written;

        // assert(num_samples >= 0);
    }

    return false;
}

advance_history_cursor :: () {
    history_cursor += 1;
    if history_cursor == HISTORY_LENGTH  history_cursor = 0;

    history_subcursor = 0;

    for j : 0..OUTPUT_CHANNELS_MAX-1 {
        history[history_cursor].low[j] = 0;
        history[history_cursor].high[j] = 0;
    }
}

fill_sample_buffer :: (buffer: string) {
    if !buffer return;

    num_channels := backend.num_channels;
    if !num_channels return;
    assert (num_channels == 2 || num_channels == 6 || num_channels == 8);

    num_samples := buffer.count / (BYTES_PER_SAMPLE * num_channels);
    assert(num_samples <= the_accumulator.count);
    assert(buffer.count / BYTES_PER_SAMPLE % num_channels == 0);

    //
    // Ugh! It was very easy to make this perf mistake...
    // Issue a warning on stuff like this?
    //
    //                -jblow, 6 December 2016
    //
    // accumulator := the_accumulator;
    //

    accumulator: [] Audio_Dest_Sample = the_accumulator;

    memset(accumulator.data, 0, num_samples * accumulator_element_size);  // @Feature: Should be able to do size_of(accumulator[0]) in some way.

    for live_streams {
        if it.inaudible continue;
        // ta := seconds_since_init();
        // print("Accum %: %\n", it_index, it.sound_name);
        accumulate_stream(it, accumulator, num_samples);
        // tb := seconds_since_init();
        // print("Accumulate took % seconds for % samples (% bytes/sec).\n", tb - ta, num_samples, cast(float)num_samples / cast(float)(tb-ta));
    }

    // Copy the accumulator into the buffer...

    dest := cast(*s16) buffer.data;

    if num_channels == 2 {
/*
        for (int i = 0; i < num_samples; i++) {
            for (int j = 0; j < AUDIO_SAMPLE_NUM_CHANNELS; j++) {
                int value = accumulator[i].channels[j];

                Clamp(value, -32767, 32767);
                dest[i*num_channels + j] = value;
            }
        }
*/

        for i : 0..num_samples-1 {
            value0 := accumulator[i].channels[Audio_Channel.FRONT_LEFT];
            value1 := accumulator[i].channels[Audio_Channel.FRONT_RIGHT];

            Clamp(*value0, -32767, 32767);
            Clamp(*value1, -32767, 32767);

            dest[i*2 + 0] = cast(s16) value0;
            dest[i*2 + 1] = cast(s16) value1;
        }
        bytes := num_samples*BYTES_PER_SAMPLE*num_channels;
        // print("filled % bytes at %\n", num_samples*BYTES_PER_SAMPLE*num_channels, buffer.data);
    } else {

        for i : 0..num_samples-1 {
            for j : 0..num_channels-1 {
                value := accumulator[i].channels[j];

                Clamp(*value, -32767, 32767);

                dest[i*num_channels + j] = cast(s16) value;
            }
        }
    }

    // Danger!

    if update_history { //  @Cleanup: Module parameter for developer mode?  Core.developer {
        scale := 1.0 / 32767.0;

        if !history_paused {
            h := *history[history_cursor];

            for i : 0..num_samples-1 {
                for c : 0..num_channels-1 {
                    value := dest[i * num_channels + c];

                    f := value * scale;
                    if f > h.high[c]  h.high[c] = f;
                    if f < h.low[c]   h.low[c]  = f;
                }

                history_subcursor += 1;
                if history_subcursor >= audio_samples_per_history_sample {
                    advance_history_cursor();
                    h = *history[history_cursor];
                }
            }
        }
    }

    // do_sine_wave(dest, num_samples, player);
}


/*
   // Generate static for testing:

   static :: (s: string) {
    samples := s.count/BYTES_PER_SAMPLE;
    dest := cast(*s16) s.data;

    for 0..samples-1 {
        // s[it] = cast(u8)random_get();

        t := cast(float)it / 2000.0;
        omega :: 100.0;
        y := cos(omega * t);
        dest[it] = cast(s16) (y * 32767.0);
    }
}
*/

/*
sanity :: (s: string, name: string) {
    samples := s.count/BYTES_PER_SAMPLE;
    dest := cast(*s16) s.data;

    prev_bad := false;
    for 0..samples-1 {
        bad := false;
        if dest[it] == 0x0dcd bad = true;
        if bad print("Bad\n");
        if bad && prev_bad {
            print("Fail in % sample %\n", name, it);
        }

        prev_bad = bad;
    }
}
*/

update_from_async_thread :: (actually_async: bool) {
    #if OS == .WINDOWS {
        // Ideally, we should lock only where we access shared resources. However, the win32 implementation of
        // release_fill_regions() doesn't like it (DirectSoundBuffer.Unlock() complains).
        // We should figure out if we can stop doing this!

        lock(*sound_mutex);
    }

    buffered_bytes, minimum_prebuffered_bytes := backend_count_buffered_bytes();

    needed_samples := cast(s64) (backend.output_sampling_rate * config.seconds_to_fill_ahead);
    needed_bytes   := needed_samples * BYTES_PER_SAMPLE * backend.num_channels;

    if needed_bytes < minimum_prebuffered_bytes  needed_bytes = minimum_prebuffered_bytes;

    bytes_to_buffer := needed_bytes - buffered_bytes;

    minimum_to_buffer := 8 * BYTES_PER_SAMPLE * backend.num_channels;  // Don't spam us if it is a super small amount of data.

    if bytes_to_buffer >= minimum_to_buffer {
        regions, success := backend_lock_fill_regions(bytes_to_buffer);
        #if VERBOSE log("Buffered: %, minimum: %, regions: %/%", buffered_bytes, minimum_prebuffered_bytes, regions.buffer0.count, regions.buffer1.count);

        fill_sample_buffer(regions.buffer0);
        fill_sample_buffer(regions.buffer1);

        // It's important that we are not locking the sound_mutex while we are releasing the fill regions. In some
        // platforms (ie.PS4), this call might need to send data to the output hardware which can take a significant amount of time.
        #if OS == .WINDOWS unlock(*sound_mutex);

        backend_release_fill_regions(regions);
    } else {
        #if OS == .WINDOWS unlock(*sound_mutex);
    }
}


async_audio_update :: (thread: *Thread) -> s64 {
    if config.set_async_thread_priority  config.set_async_thread_priority();

    while true {
        update_from_async_thread(true);
        should_exit := compare_and_swap(*async_thread_should_exit, true, false);
        if should_exit {
            return 0;
        }

        // :NeedCrossPlatformHighResolutionWait
        sleep_milliseconds(1);
    }

    return 0;
}


