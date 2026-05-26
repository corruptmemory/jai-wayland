#scope_file

#import "Basic";  // For assert.

#scope_export

#import "Adpcm";
#import "stb_vorbis";

/*

  Base "Class":


 */

Decoder_Type :: enum {
    OGG   :: 0;
    ADPCM :: 1;
}

Cached_Decoder_Page :: struct {
    type:  Decoder_Type;
    owner: *Cached_Decoder;
    
    // Because we reuse the page, the length in bytes is the same
    // among all pages, so to figure out how many samples to read,
    // use the end_address!

    start_address: s64 = -1;
    end_address:   s64 = -1;   // end_address is 1 higher than the last valid sample... so a 1-sample page would be start_address 0, end_address 1.
    page_index:    s64 = -1; 
    
    data: *void;

    buffer_length_in_bytes: s64;

    num_samples_contained:  s64;

    marked := false;
}


// @Incomplete: do_not_queue should be false if decoding oggs asynchronously

Cached_Decoder :: struct {
    type: Decoder_Type;

    pages: [..] *Cached_Decoder_Page;
    issued_start_addresses: [..] s64;    // These tell us which pages we are waiting to get back from the queue.

    page_size_in_samples:           s64 = -1;  // Will get initialized when we start the compressed file.
    uncompressed_length_in_samples: s64 = 0;

    num_channels  : s64;
    sampling_rate : s64;

    sound_data: *Sound_Data;
    stream:     *Sound_Stream;  // So that, if this is attached to a currently-playing sound, we can back-reference it. Only used externally to Adpcm_Decoder.

    do_not_queue := true;   // For example, for ADPCM, let's not queue, just crank through any page now, to reduce latency and possible stuttering.

    deinit_proc: (decoder: *Cached_Decoder) -> ();

    add_decode_queue_item: (page: *Cached_Decoder_Page) -> ();  // Called from the mixer only, hopefully.  -jblow, 26 September 2015

    recompute_page : (decoder: *Cached_Decoder, page: *Cached_Decoder_Page) -> ();
    make_page:       (decoder: *Cached_Decoder) -> *Cached_Decoder_Page;
}


//
// Derived "Classes":
//

Cached_Ogg_Decoder :: struct {
    using base: Cached_Decoder;

    vorbis_file: *stb_vorbis;

    seek_base     : s64;
    opus_pre_skip : s64;

    bytes_per_mono_sample : s64;
    uncompressed_length_in_bytes : s64;

    bitrate_low     : s64;
    bitrate_nominal : s64;
    bitrate_high    : s64;
};




//
// Ugh: We can't have more than one thread yet, because we need to ensure that
// accesses to any particular Vorbis file are serialized. The way I set this up,
// it doesn't think about things that way.  -jblow, 8 October 2013
//

CACHED_OGG_DECODE_NUM_THREADS :: 1;



/*


Code for base class Cached_Decoder:


 */




get_base_address :: (decoder: *Cached_Decoder, play_cursor: s64) -> s64 {
    return play_cursor - (play_cursor % decoder.page_size_in_samples);
}


unmark_all_pages :: (using decoder: *Cached_Decoder) {
    for pages  it.marked = false;
}

mark_relevant_pages :: (using decoder: *Cached_Decoder, start: s64, end: s64) {
    assert(end >= start);

    // We might get negative inputs if the stream is counting down silence.
    if end < 0  return;
    if start < 0  start = 0;

    cursor := get_base_address(decoder, start);

    while (cursor < end) && (cursor < uncompressed_length_in_samples) {  // Because the caller might have requested a window beyond the end of the file.
        page := find_page_by_base_address(decoder, cursor);

        if page {
            page.marked = true;
        } else {
            found := array_find(issued_start_addresses, cursor);
            if found {
                // Do nothing; this page is in progress.
            } else {
                assert(cursor >= 0);
                
                page = make_page(decoder);
                page.start_address = cursor;
                page.end_address   = min(uncompressed_length_in_samples, page.start_address + page_size_in_samples);
                page.marked = true;
                page.page_index = cursor / page_size_in_samples;

                if do_not_queue {
                    recompute_page(decoder, page);
                    page.marked = true;
                    array_add(*pages, page);
                } else {
                    array_add(*issued_start_addresses, page.start_address);

                    // Can't use 'using' here because we collect an overload!
                    assert(decoder.add_decode_queue_item != null);
                    decoder.add_decode_queue_item(page);
                }
            }
        }
        
        cursor += page_size_in_samples;
    }
    
}

free_unmarked_pages :: (using decoder: *Cached_Decoder) {
    for page : pages {
        if page.marked continue;

        free(page.data);
        free(page);
        
        remove page;
    }
}



find_page_by_base_address :: (using decoder: *Cached_Decoder, start_address: s64) -> *Cached_Decoder_Page {
    for pages  if it.start_address == start_address  return it;

    return null;
}

find_page_containing_cursor :: (using decoder: *Cached_Decoder, play_cursor: s64) -> (found: bool, start_address: s64, end_address: s64, data: *void) {
    cursor := get_base_address(decoder, play_cursor);

    page:= find_page_by_base_address(decoder, cursor);
    if !page  return false, 0, 0, null;

    assert(uncompressed_length_in_samples >= page.start_address);
    assert(page.end_address <= uncompressed_length_in_samples);

    end_address := min(page.end_address, uncompressed_length_in_samples);

    assert(play_cursor < end_address);  // Buffer bounds are exclusive, not inclusive!

    return true, page.start_address, end_address, page.data;
}

deinit :: (using decoder: *Cached_Decoder) {
    if decoder.deinit_proc  decoder.deinit_proc(decoder);
    
    for pages { free(it.data); free(it); }
    array_reset(*pages);
    array_reset(*issued_start_addresses);
}





/*


 Code for derived class Cached_Ogg_Decoder:



 */


create_ogg_decoder :: (data: *Sound_Data, _page_size_in_samples: s64) -> *Cached_Decoder { 
    d := New(Cached_Ogg_Decoder);

    assert(data != null);

    d.type = .OGG;
    d.sound_data = data;
    d.page_size_in_samples = _page_size_in_samples;

    success := start_vorbis_file(d);

    info := stb_vorbis_get_info(d.vorbis_file);
    d.sampling_rate = info.sample_rate;
    d.num_channels  = info.channels;
    data.nchannels  = xx info.channels;

    assert(d.vorbis_file != null);
    samples := stb_vorbis_stream_length_in_samples(d.vorbis_file);

    d.uncompressed_length_in_samples = samples;
    data.nsamples_times_nchannels = samples * data.nchannels;

    d.recompute_page = recompute_page_ogg;
    d.make_page      = make_page_ogg;
    d.deinit_proc    = deinit_proc_ogg;
    
    return *d.base;
}

deinit_proc_ogg :: (decoder: *Cached_Decoder) {
    me := cast(*Cached_Ogg_Decoder) decoder;
    if me.vorbis_file  stb_vorbis_close(me.vorbis_file);
}


make_page_ogg :: (using decoder: *Cached_Decoder) -> *Cached_Decoder_Page {
    page := New(Cached_Decoder_Page);

    length_in_bytes := page_size_in_samples * 2 * sound_data.nchannels;

    page.type = .OGG;
    page.data = alloc(length_in_bytes);
    page.buffer_length_in_bytes = length_in_bytes;
    page.owner = decoder;
    page.marked = false;
    
    return page;
}

/* 

static float get_s(float time, float period) {
    float spins = time / period;
    spins = fmod_cycling(spins, 1.0f);
    float t = sin(spins * 2 * M_PI);

    Clamp(t, -1, 1);
    return t;
}

 For debugging; keep me!

static void fill_buffer_with_sine_wave(Cached_Ogg_Decoder *decoder, void *data_start, int _address) {

    float last_value = 0;
    float first_value = 0;

    for (int i = 0; i < decoder.page_size_in_samples + EXTRA_TRAILING_SAMPLES; i++) {
        int address = _address + i;
        float t = address / (float)decoder.sampling_rate;

        float s = get_s(t, 1.0 / 250.0f);

        int ival = s * 32767.0 * .5;

        if (i == 0) first_value = s;
        if (i == decoder.page_size_in_samples - 1) last_value = s;

        short *base = (short *)data_start;
        short *sample_start = base + i * decoder.num_channels;
        for (int j = 0; j < decoder.num_channels; j++) {
            sample_start[j] = ival;
        }
    }

    Log::print("sine_wave address %d values (%.4f..%.4f)\n", _address, first_value, last_value);
}

*/

recompute_page_ogg :: (using decoder: *Cached_Decoder, _page: *Cached_Decoder_Page) {
    page    := _page;
    address := page.start_address;
    assert(address >= 0);

    d := cast(*Cached_Ogg_Decoder) decoder;

    if d.vorbis_file {
        seek_result := stb_vorbis_seek(d.vorbis_file, cast(u32) page.start_address);
        if seek_result <= 0 {
            log_error("Cached_Ogg_Decoder error in stb_vorbis_seek, start_address %, result %\n", page.start_address, seek_result);
            return;
        }
    } else {
        log_error("Cached_Ogg_Decoder content is not Vorbis.\n");
        return;
    }

    bigendian := false;

    bytes_per_sample := 2 * sound_data.nchannels;

    num_samples := page.end_address - page.start_address;
    nbytes      := num_samples * bytes_per_sample;

    num_shorts := num_samples * num_channels;

    result := stb_vorbis_get_samples_short_interleaved(d.vorbis_file, cast(s32) num_channels, page.data, cast(s32) num_shorts);
    
    if result <= 0 {
        print("Negative result from stb_vorbis_get_samples_short_interleaved: %\n", result);
        assert(false);
        return;
    }

    assert(num_samples == result);
    page.num_samples_contained = result;
}

start_vorbis_file :: (using decoder: *Cached_Ogg_Decoder) -> bool {
    seek_base = 0;

    data := decoder.sound_data;
    error_return: s32;
    vorbis_file = stb_vorbis_open_memory(data.buffer.data, cast(s32) data.buffer.count,
                                         *error_return, null);

    if vorbis_file return true;
    return false;
}


get_compressed_rate_channels_and_size :: (s: string) -> (num_samples: s64, num_channels: s64, sampling_rate: s64) {
    tmp_data: Sound_Data;
    tmp_data.buffer = s;
    tmp_data.samples = cast(*s16) s.data;

    decoder := create_ogg_decoder(*tmp_data, 100);
    if !decoder {
        // If we fail we already logged an error.
        return 0, 0, 0;
    }

    return decoder.uncompressed_length_in_samples, decoder.num_channels, decoder.sampling_rate;

    // tmp_data.samples = NULL;  // So the destructor does not delete them.
}




/*


  ADPCM decoder:


  This ADPCM stuff was originally copied from SDL. It is being heavily modified.
  As per the license, here is their copyright notice, etc.

*/


/*
  Simple DirectMedia Layer
  Copyright (C) 1997-2014 Sam Lantinga <slouken@libsdl.org>

  This software is provided 'as-is', without any express or implied
  warranty.  In no event will the authors be held liable for any damages
  arising from the use of this software.

  Permission is granted to anyone to use this software for any purpose,
  including commercial applications, and to alter it and redistribute it
  freely, subject to the following restrictions:

  1. The origin of this software must not be misrepresented; you must not
     claim that you wrote the original software. If you use this software
     in a product, an acknowledgment in the product documentation would be
     appreciated but is not required.
  2. Altered source versions must be plainly marked as such, and must not be
     misrepresented as being the original software.
  3. This notice may not be removed or altered from any source distribution.
*/



/*

  @Cleanup:

  Right now I am doing all this Adpcm stuff as just a straight copy-and-paste-and-modify
  from the Ogg code. *However*, it seems likely that there will be a fair bit of commonality,
  so we might want to factor out a subclass. But I want to do this straight-up first to see
  how simple I can really make it.   -jblow, 20 May 2015.

*/

// As usually exported, ADPCM seems to be in 1kB blocks always, so the 
// blocks per page represents a different amount of time depending whether
// the sound is mono or stereo, but I am not going to sweat that yet...??
ADPCM_BLOCKS_PER_PAGE :: 3;

Adpcm_Decoder :: struct {
    using base: Cached_Decoder;
}


create_adpcm_decoder :: (data: *Sound_Data) -> *Adpcm_Decoder {
    d := New(Adpcm_Decoder);

    d.type = .ADPCM;
    d.sound_data = data;

    d.do_not_queue = true;

    assert(data.wSamplesPerBlock > 0);
    d.page_size_in_samples = data.wSamplesPerBlock * ADPCM_BLOCKS_PER_PAGE;

    d.num_channels = data.nchannels;
    d.uncompressed_length_in_samples = data.nsamples_times_nchannels / data.nchannels;

    d.recompute_page = recompute_page_adpcm;
    d.make_page      = make_page_adpcm;
    
    return d;
}

make_page_adpcm :: (using decoder: *Cached_Decoder) -> *Cached_Decoder_Page {
    page := New(Cached_Decoder_Page);

    page.type = .ADPCM;

    length_in_bytes := page_size_in_samples * 2 * sound_data.nchannels;

    page.data = alloc(length_in_bytes);
    page.buffer_length_in_bytes = length_in_bytes;
    page.owner = decoder;
    page.marked = false;
    
    return page;
}

/*
get_s :: (time: float, period: float) -> float {
    spins := time / period;
    spins = fmod_cycling(spins, 1.0f);

    t = sin(spins * 2 * M_PI);

    Clamp(*t, -1, 1);
    return t;
}


// For debugging; keep me!

static void fill_buffer_with_sine_wave(Adpcm_Decoder *decoder, void *data_start, int _address) {

    float last_value = 0;
    float first_value = 0;

    for (int i = 0; i < decoder.page_size_in_samples + EXTRA_TRAILING_SAMPLES; i++) {
        int address = _address + i;
        float t = address / (float)decoder.sound_data.sampling_rate;

        float s = get_s(t, 1.0 / 250.0f);

        int ival = s * 32767.0 * .5;

        if (i == 0) first_value = s;
        if (i == decoder.page_size_in_samples - 1) last_value = s;

        short *base = (short *)data_start;
        short *sample_start = base + i * decoder.num_channels;
        for (int j = 0; j < decoder.num_channels; j++) {
            sample_start[j] = ival;
        }
    }

    Log::print("sine_wave address %d values (%.4f..%.4f)\n", _address, first_value, last_value);
}
*/

recompute_page_adpcm :: (using decoder: *Cached_Decoder, page: *Cached_Decoder_Page) {
    address := page.start_address;
    assert(address >= 0);
	if address < 0 return;  // Corrupted data... Hmm.

    bytes_per_sample := 2 * sound_data.nchannels;
/*
    int nbytes = page.buffer_length_in_bytes;

    // @Temporary  RANDOM NOISE!!
    for (int i = 0; i < nbytes; i++) {
        unsigned char *dest = (unsigned char *)page.data;
        dest[i] = globals.random_generator.get();
    }

*/

//    fill_buffer_with_sine_wave(this, page.data, address);  // For debugging.

    page_seek_pos: = sound_data.nBlockAlign * ADPCM_BLOCKS_PER_PAGE * page.page_index;

    num_samples := page.end_address - page.start_address;
    dest_bytes_needed := (num_samples) * bytes_per_sample;

    limit := sound_data.buffer.count;
	source_bytes_to_read : s64 = sound_data.nBlockAlign * ADPCM_BLOCKS_PER_PAGE;

    if page_seek_pos + source_bytes_to_read > limit {
        source_bytes_to_read = limit - page_seek_pos;
        assert(source_bytes_to_read >= 0);
    }

    // @Cleanup: Reinstate this assert when we also ahndle hitting the end of the file.
    // assert((source_bytes_to_read % sound_data.nBlockAlign) == 0);

    info: Adpcm_Info;
    info.nChannels        = sound_data.nchannels;
    info.nBlockAlign      = sound_data.nBlockAlign;
    info.wSamplesPerBlock = sound_data.wSamplesPerBlock;

    // @Feature: Would be nice to be able to use {} initializers for this.
    page_array: [] u8 = ---;
    page_array.data  = page.data;
    page_array.count = page.buffer_length_in_bytes;

    // @Feature: Would be nice to be able to use {} initializers for this.
    input_block: [] u8 = ---;
    input_block.data  = (cast (*u8) sound_data.samples) + page_seek_pos;
    input_block.count = source_bytes_to_read;

    decoded_bytes := IMA_ADPCM_decode(info, input_block, page_array);

    samples := decoded_bytes / bytes_per_sample;
    assert(samples <= page_size_in_samples);

    page.num_samples_contained = samples;

/*
    // @Debug @Temporary: Add a very prominent click.
    {
        short *samples = (short *)page.data;
        for (int i = 0; i < sound_data.nchannels; i++) {
            samples[page.num_samples_contained - 1 - i] = 0xffff;
        }
    }
*/
}

