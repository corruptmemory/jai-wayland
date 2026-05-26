
//
// Newly revamped Sound_Player!
//
//
// To see how to use this, see examples/audio.jai ...
//
//
// Basically:
//
// (1) Call sound_player_init() to do anything.
//
// (2) To play a sound, you need a Sound_Data; if you play the same effect many times,
//     you want to load a Sound_Data once and use the pointer to it many times.
//     You can load a Sound_Data using either load_audio_file() or load_audio_data().
//     Note that this returns a Sound_Data by value; but this Sound_Data needs to remain
//     live for as long as you wish to play the sound. So you can put it into a global,
//     copy it into a hash table and use that pointer, etc.
//
// (3) Once you have a Sound_Data, you can call make_stream() to create a *Sound_Stream,
//     which represents one instance of a playing sound. The sound will not yet actually
//     be playing, because we want to give you a chance to tweak stuff on the Sound_Stream,
//     like its rate or repeat properties [example: call set_repeating(stream)].
//
// (4) Once you are done tweaking your Sound_Stream, call start_playing(stream).
//
// (5) If you want to look for streams and tweak their properties while they are playing,
//     you can do that, but you must first lock sound_mutex.
//
// (N) Call sound_player_shutdown before exiting your program.


//
// This code is a descendent of the audio systems used in Braid and The Witness, thus
// it handles some things that are heavier-duty than many people need. But we have done
// our best here to keep the API simple. The demos only play simple 2D sounds, but this
// code will use Vector Base Amplitude Panning to pan sounds of an arbitrary number
// of channels onto output devices with up to Dolby 8.1 output support.
// (See the VBAP information at http://legacy.spa.aalto.fi/research/cat/vbap/ for some
// information about how this works).
//

// We do probably need to make a nicer API to all the 3D sound features so people
// can figure out how to do them, but in the meantime we figured we'd release this
// version so that people can get the boost in quality-of-life.

//             -jblow, 14 January 2024


// To Do:
// Detect Output Sampling Rate across OSs.
// :NeedCrossPlatformHighResolutionWait




// You probably don't need to think about MAX_SOUND_CATEGORIES; it's only in case
// you want to have *so* many different categories of volume ducking that it's
// more than 64!!
// VERBOSE is just for debugging Alsa issues that some people have seen. It will probably be removed soon.
#module_parameters (MAX_SOUND_CATEGORIES := DEFAULT_MAX_SOUND_CATEGORIES, VERBOSE := false) {
    DEFAULT_MAX_SOUND_CATEGORIES :: 64;
}

#load "load.jai";
#load "async.jai";
#load "cached_decoder.jai";

Audio_Channel :: enum u16 {
    FRONT_LEFT  :: 0;
    FRONT_RIGHT :: 1;
    CENTER      :: 2;
    SUBWOOFER   :: 3;
    REAR_LEFT   :: 4;
    REAR_RIGHT  :: 5;
    EXTEND_LEFT :: 6;
    EXTEND_RIGHT:: 7;
}

ACHANNEL_MAX           :: #run enum_highest_value(Audio_Channel) + 1;
OUTPUT_CHANNELS_MAX    :: ACHANNEL_MAX;
MAX_CHANNELS_PER_SOUND :: 8;


// You can define more Sound_Categories if you want.
Sound_Category :: enum u32 {
    GENERAL_SFX :: 0;
    AMBIENCES   :: 1;
    FOOTSTEPS   :: 2;
    UI          :: 3;
    MUSIC       :: 4;
}

Source_Direction :: enum u16 {
    MONO                      :: 0;
    LEFT                      :: 1;
    RIGHT                     :: 2;
    FRONT_LEFT                :: 3;
    FRONT_RIGHT               :: 4;
    REAR_LEFT                 :: 5;
    REAR_RIGHT                :: 6;
    CENTER_FORWARD            :: 7;
    SUBWOOFER_CENTER_FORWARD  :: 8;
    EXTEND_LEFT               :: 9;
    EXTEND_RIGHT              :: 10;
}

NUM_SOURCE_DIRECTIONS :: #run enum_highest_value(Source_Direction) + 1;

SOUND_INNER_RADIUS_DEFAULT ::  10.0;  // Multiplied by volume log scale
SOUND_OUTER_RADIUS_DEFAULT ::  150.0;  // Multiplied by volume log scale


CACHED_OGG_DECODE_THREADED :: true;



Scale_Mapping :: struct {
    //
    // According to VBAP we only need 2 speakers at once; the problem is,
    // we need to smoothly interpolate (potentially per-sample), so
    // hey, we get to think about all channels per sample.
    //

    source_scale_for_this_output_index:              [OUTPUT_CHANNELS_MAX] float;
    interpolated_source_scale_for_this_output_index: [OUTPUT_CHANNELS_MAX] float;
    dvolume_dsample:                                 [OUTPUT_CHANNELS_MAX] float;
}

Sound_Stream :: struct {
    // You can set these user_data fields to whatever you want,
    // to help identify this sound in your own system.
    user_data_u64:      u64;
    user_data_pointer: *void;

    // These manager_id and entity_id are arbitrary IDs you can use to refer to this sound,
    // and associate it with a particular entity in a particular universe in your game.
    // When you search for sounds, stop sounds, etc, we search by these two fields.
    manager_id: s64;
    entity_id:  s64;

    sound_name: string;

    user_flags: enum u32 {
        REPEATING              :: 0x1;
        SPATIALIZED            :: 0x2;
        MUSIC                  :: 0x10;  // We don't do anything with this any more; just for user's benefit.
        VOICEOVER              :: 0x20;
        IS_FOOTSTEP            :: 0x40;
        DO_NOT_KILL            :: 0x80;
        PAUSED_DUE_TO_MENU     :: 0x100;
        WAS_PAUSED_DUE_TO_MENU :: 0x200;
        AMBIENT                :: 0x400;
    }

    // internal_flags are wholly managed by Sound_Player,
    // but you could draw them, etc if you want to see
    // what is going on.
    internal_flags: enum u32 {
        FIRST_VOLUME_UPDATE               :: 0x2;
        WAITING_FOR_INITIAL_DECODER_PAGES :: 0x4;
        FADING_OUT                        :: 0x8;
    }

    num_channels : s32 = 2;  // Set when played, based on the sound_data.
    sound_data:  *Sound_Data;
    decoder:     *Cached_Decoder;

    category: Sound_Category;

    repeat_start_position: s64;
    repeat_end_position:   s64 = -1;

    universe_volume_scale := 1.0;  // Directly settable by the user, a separate factor meant to be used for an entire entity manager fading up or down.
    user_volume_scale := 1.0;      // Directly settable by the user, for this one effect, i.e. for randomization.

    play_cursor: float64 = 0;
    silent_samples_at_start_of_play: s64 = 0; // Not included in any repeats...  @Cleanup: Not currently used.

    marked              := false;
    inaudible           := false;  // An extra flag you can set to make this stream output no sound whatsoever (without changing the volume).

    // Position, orientation and radii are used only if flags & .SPATIALIZED:
    position:    Vector3;
    orientation: Quaternion;
    inner_radius := 0.5;
    outer_radius := 10.0;

    rate_scale   := 1.0;

    // Some accounting:
    samples_streamed_since_entity_update: s64;

    //
    // Internal variables you probably don't need to care about:
    //

    max_gain: float;  // For debugging.
    last_plane_dir: Vector2;
    debug_display_volume: float = 0;

    silent_this_frame  := false;  // Set this to true if all input_scale_mappings are 0.
    debug_watch        := false;

    current_rate: float = 1;
    desired_rate: float = 1;

    input_scale_mappings: [MAX_CHANNELS_PER_SOUND] Scale_Mapping;  // One target per channel.  Each target has an array of output loudnesses.

    initial_samples_fetched: s64;
    samples_needed_to_start_playing: s64;
};


Backend_Properties :: struct {
    initted := false;

    num_channels: s32;
    channel_names: [] string;

    output_sampling_rate: s32;
}


//
// After playing around with decibels / etc for a while I decided that they are not an
// appropriate scale for thinking about sound volumes for games.  Most audio references
// just unthinkingly start telling you about decibels and what they do and why they are good,
// but I find most of these things aren't true.  They are just a wacky unintuitive unit
// that got widely adopted.
//
// Instead, here we are using a perceptual unit where scaling by 2.0 means "it sounds twice as loud",
// etc.  This ends up being an exponentiation just like we do for HDR rendering (but with a different
// exponent).
//
// So, for example, 0.5 means "half as loud", which is -10dB, which is a linear scale factor of 0.316.
//
// To derive this math, you start with Loudness = 20 log(p / p0), the standard decibel equation.
// Then we presume that +10dB really means "twice as loud".  Let's call R the perceptual scale factor.
// Then R = pow(2, Loudness/10).  And you solve for that.  What we are using here is the reciprocal
// because for volume tweaks we are going in the other direction (perceptual to wave pressure, whereas
// R defines wave pressure to perceptual).
//
//              -jblow, 9 November 2011
//
perceptual_to_linear :: (x: float) -> float {
    LOG10_OF_2 :: 0.30103;
    EXPONENT :float= (1 / (2 * LOG10_OF_2));

    return pow(x, EXPONENT);
}

retired_decoders: [..] *Cached_Decoder;

// Taking these numbers down a bit, we'll see how it goes...
SECONDS_TO_FETCH_OGG  :: 0.4;
SECONDS_TO_FETCH_ADPCM:: 0.4;  // In theory we don't need this to be too long, but actually, if we make it shorter we will skip when frame rates are low, which is not great. But if you get down to 0.4s per frame, you probably should not expect anything to be good.

VERY_CLOSE :: 4.0;

vbap_speaker_directions: [ACHANNEL_MAX] Vector2;
vbap_source_directions:  [NUM_SOURCE_DIRECTIONS] Vector2;

ROOT_2_OVER_2 : float : 0.7071067;

Vbap_Arc :: struct {
    speaker1: Audio_Channel;
    speaker2: Audio_Channel;

    l_inverse: Matrix2;
}

arcs_6ch := Vbap_Arc.[
    .{ .CENTER,      .FRONT_LEFT,  .{} },
    .{ .FRONT_LEFT,  .REAR_LEFT,   .{} },
    .{ .REAR_LEFT,   .REAR_RIGHT,  .{} },
    .{ .REAR_RIGHT,  .FRONT_RIGHT, .{} },
    .{ .FRONT_RIGHT, .CENTER,      .{} }
];

arcs_8ch := Vbap_Arc.[
    .{ .CENTER,       .FRONT_LEFT,   .{} },
    .{ .FRONT_LEFT,   .REAR_LEFT,    .{} },
    .{ .REAR_LEFT,    .EXTEND_LEFT,  .{} },
    .{ .EXTEND_LEFT,  .EXTEND_RIGHT, .{} },
    .{ .EXTEND_RIGHT, .REAR_RIGHT,   .{} },
    .{ .REAR_RIGHT,   .FRONT_RIGHT,  .{} },
    .{ .FRONT_RIGHT,  .CENTER,       .{} }
];


arcs: [] Vbap_Arc;


// @Incomplete: Do we want a mutex around retired_decoders?
count_retired_decoders :: () -> s64 {
    return retired_decoders.count;
}

invert :: (using m: *Matrix2, result: *Matrix2) {
    det : float = _11 * _22 - _21 * _12;
    assert(det != 0);

    result._11 =  _22 / det;
    result._22 =  _11 / det;
    result._12 = -_12 / det;
    result._21 = -_21 / det;
}


clear_scale_accumulation :: (stream: *Sound_Stream, index: s64) {
    assert(index < MAX_CHANNELS_PER_SOUND);

    target := *stream.input_scale_mappings[index];

    for 0..OUTPUT_CHANNELS_MAX-1
        target.source_scale_for_this_output_index[it] = 0;
}


get_target_2_closeness :: (stream: *Sound_Stream) -> float {
    //
    // :StereoDot
    //
    // I did not understand the math happening in target_n, so I wrote a thing for target_2 that just
    // interpolates each dot to 1. We take the len after player, which should work to normalize
    // the volume correctly.  -jblow, 29 April 2015.
    //

    very_close: float = VERY_CLOSE;
    very_close = min(very_close, stream.inner_radius * 0.75);

    a := stream.position;
    b := listener_position;

    // Eliminate Z on both since we presume our speakers are in a plane.
    a.z = 0;
    b.z = 0;

    dist := distance(a, b);
    closeness: float = 0;
    if dist < very_close {
        closeness = 1.0 - (dist / very_close);
        Clamp(*closeness, 0, 1);
    }

    return closeness;
}

adjust_stereo_dots_by_closeness :: (dot_left: *float, dot_right: *float, closeness: float) {
    // See :StereoDot.

    if (!closeness) return;

    dot_left.*  = lerp(dot_left.*,  1, closeness);
    dot_right.* = lerp(dot_right.*, 1, closeness);
}

/*

  Mixing to stereo is not really VBAP.  It is just kind of a hack.  But,
  I left VBAP in the name to keep things uniform.

  The reason it's not VBAP is because when you don't have a speaker path
  that completely encircles the listener, it doesn't seem to have a way to
  represent objects in parts of space -- you would get negative gain values.

*/

accum_scale_target_2_source_mono :: (stream: *Sound_Stream, plane_dir: Vector2, gain_scale: float, target: *Scale_Mapping) {
    using Audio_Channel;

    closeness: float = get_target_2_closeness(stream);

    dot_left:  float = dot_product(plane_dir, vbap_speaker_directions[FRONT_LEFT]);
    dot_right: float = dot_product(plane_dir, vbap_speaker_directions[FRONT_RIGHT]);

    Clamp(*dot_left, 0, 1);
    Clamp(*dot_right, 0, 1);

    dot_left  += stereo_base;
    dot_right += stereo_base;

    adjust_stereo_dots_by_closeness(*dot_left, *dot_right, closeness);

    sum := dot_left * dot_left + dot_right * dot_right;
    len := sqrt(sum);
    assert(len > 0);

    target.source_scale_for_this_output_index[FRONT_LEFT] += (dot_left / len) * gain_scale;
    target.source_scale_for_this_output_index[FRONT_RIGHT] += (dot_right / len) * gain_scale;
}

accum_scale_target_2_source_n :: (stream: *Sound_Stream, plane_dir: Vector2, n: s64, gain_scale: float) {
    // @Speed: Lift these constants out; but for now we can't initialize
    // stuff like Vector2 at global scope!

    faux_vbap_stereo_right_front := Vector2.{ROOT_2_OVER_2,  -ROOT_2_OVER_2};
    faux_vbap_stereo_right_rear  := Vector2.{-ROOT_2_OVER_2, -ROOT_2_OVER_2};
    faux_vbap_stereo_left_front  := Vector2.{ROOT_2_OVER_2,   ROOT_2_OVER_2};
    faux_vbap_stereo_left_rear   := Vector2.{-ROOT_2_OVER_2,  ROOT_2_OVER_2};


    closeness := get_target_2_closeness(stream);

    for i: 0..n-1 {
        assert(i < MAX_CHANNELS_PER_SOUND);
        target := *stream.input_scale_mappings[i];

        source_dir_index := stream.sound_data.source_directions[i];
        source_dir       := vbap_source_directions[source_dir_index];

        rotate(*source_dir, -listener_theta);

        dot_left_front := dot_product(source_dir, faux_vbap_stereo_left_front);
        dot_left_rear  := dot_product(source_dir, faux_vbap_stereo_left_rear);

        dot_right_front := dot_product(source_dir, faux_vbap_stereo_right_front);
        dot_right_rear  := dot_product(source_dir, faux_vbap_stereo_right_rear);

        Clamp(*dot_left_front,  0, 1);
        Clamp(*dot_left_rear,   0, 1);
        Clamp(*dot_right_front, 0, 1);
        Clamp(*dot_right_rear,  0, 1);

        dot_left  := ROOT_2_OVER_2 * (dot_left_front + dot_left_rear);
        dot_right := ROOT_2_OVER_2 * (dot_right_front + dot_right_rear);

        Clamp(*dot_left,  0, 1);
        Clamp(*dot_right, 0, 1);

        adjust_stereo_dots_by_closeness(*dot_left, *dot_right, closeness);

/*
        if (stream.debug_watch) {
            log("accum %d, source_dir is %d (%.3f, %.3f), dot_left: [%.2f, %.2f], %.2f; dot_right: [%.2f, %.2f], %.2f\n", i, source_dir_index, source_dir.x, source_dir.y,
                       dot_left_front, dot_left_rear, dot_left, dot_right_front, dot_right_rear, dot_right);
        }
*/

        dot_left  += stereo_base;
        dot_right += stereo_base;

        len := sqrt(dot_left * dot_left + dot_right * dot_right);
        assert(len > 0);

        target.source_scale_for_this_output_index[Audio_Channel.FRONT_LEFT]  += (dot_left  / len) * gain_scale;
        target.source_scale_for_this_output_index[Audio_Channel.FRONT_RIGHT] += (dot_right / len) * gain_scale;

/*
        if (stream.debug_watch) {
            log("channel %d: Left %.3f, Right %.3f", i, target.gain[FRONT_LEFT], target.gain[FRONT_RIGHT]);
        }
*/
    }
}

add_vbap_gain_for_direction :: (target: *Scale_Mapping, plane_dir: Vector2, gain_scale: float) {
    highest_low    := -FLOAT32_INFINITY;
    best_arc_index : s64 = -1;

    local_arcs := arcs;
    for * arc: arcs {
        gain := multiply(arc.l_inverse, plane_dir);
        low  := min(gain.x, gain.y);

        if low > highest_low {
            highest_low = low;
            best_arc_index = it_index;
        }
    }

    if best_arc_index == -1 return;  // Assert here?  This really should not happen.

    arc := *arcs[best_arc_index];
    gain := multiply(multiply(arc.l_inverse, plane_dir), gain_scale);

    target.source_scale_for_this_output_index[arc.speaker1] += max(gain.x, 0);
    target.source_scale_for_this_output_index[arc.speaker2] += max(gain.y, 0);
}

skip_this_output_channel :: (index: Audio_Channel, stream: *Sound_Stream) -> bool {
    if stream.user_flags & .IS_FOOTSTEP {
        if index == .REAR_LEFT return true;
        if index == .REAR_RIGHT return true;
    }

    return false;
}

accum_scale_target_all_source_mono :: (stream: *Sound_Stream, plane_dir: Vector2, gain_scale: float, target: *Scale_Mapping) {
    tmp_target: Scale_Mapping;

    // Don't put gain_scale in until later, as otherwise this would affect computation of orig_len2 below.
    add_vbap_gain_for_direction(*tmp_target, plane_dir, 1.0);

    //
    // If the source is close to the listener, fill all speakers (so that we don't get discontinuities as the sound passes close by).
    //

    very_close := VERY_CLOSE;
    very_close = min(very_close, stream.inner_radius * 0.75);

    dist := distance(stream.position, listener_position);
    if dist < very_close {
        t := 1.0 - (dist / very_close);
        Clamp(*t, 0, 1);

        orig_len2 : float;
        for i: 0..OUTPUT_CHANNELS_MAX-1 {
            if i == xx Audio_Channel.SUBWOOFER continue;
            if skip_this_output_channel(xx i, stream) continue;

            s := tmp_target.source_scale_for_this_output_index[i];
            orig_len2 += s * s;

            tmp_target.source_scale_for_this_output_index[i] = lerp(s, 1, t);
        }

        len := sqrt(orig_len2);
        if !len return;

        for i : 0..OUTPUT_CHANNELS_MAX-1 {
            if i == xx Audio_Channel.SUBWOOFER continue;
            if skip_this_output_channel(xx i, stream) continue;

            tmp_target.source_scale_for_this_output_index[i] /= len;
        }
    }

    for i : 0..OUTPUT_CHANNELS_MAX-1 {
        target.source_scale_for_this_output_index[i] += tmp_target.source_scale_for_this_output_index[i] * gain_scale;
    }
}

accum_scale_target_all_source_n :: (stream: *Sound_Stream, plane_dir: Vector2, n: s64, gain_scale: float) {
    //
    // In this case we actually ignore plane_dir and use listener_theta to rotate the channels around...
    //

    using Source_Direction;

    for i: 0..n-1 {
        source_dir_index := stream.sound_data.source_directions[i];

        if source_dir_index == Source_Direction.SUBWOOFER_CENTER_FORWARD {
            assert(i < MAX_CHANNELS_PER_SOUND);
            stream.input_scale_mappings[i].source_scale_for_this_output_index[Audio_Channel.SUBWOOFER] = 1;
            continue;
        }

        target_dir, success := source_dir_to_target_dir(xx i);
        if success && skip_this_output_channel(target_dir, stream) continue;

        revised_dir := vbap_source_directions[source_dir_index];

        //
        // Override direction for stereo sources so that they come from straight-left and straight-right...
        //

        rotate(*revised_dir, -listener_theta);

        assert(i < MAX_CHANNELS_PER_SOUND);

        target := *stream.input_scale_mappings[i];
        add_vbap_gain_for_direction(target, revised_dir, gain_scale);
    }
}

get_plane_dir :: (stream: *Sound_Stream, position: Vector3) -> Vector2 {
    if (!have_listener) || !(stream.user_flags & .SPATIALIZED) {
        return .{1, 0};
    }

    pos := position - listener_position;
    up  := listener_up;

    // Put the sound into a 2D plane.

    pos = pos - up * dot_product(pos, up);
    normalize(*pos);

    plane_dir := Vector2.{dot_product(pos, listener_forward),
                          dot_product(pos, listener_left)};

    return plane_dir;
}


source_dir_to_target_dir :: (source_dir_index: Source_Direction) -> Audio_Channel, success := true {
    assert(backend.num_channels >= 6);  // For now we only handle 5.1 through 8.1 in this routine.

    using Audio_Channel;

    if #complete source_dir_index == {
      case .MONO;        return CENTER;
      case .LEFT;        return FRONT_LEFT;
      case .RIGHT;       return FRONT_RIGHT;
      case .FRONT_LEFT;  return FRONT_LEFT;
      case .FRONT_RIGHT; return FRONT_RIGHT;
      case .REAR_LEFT;   return REAR_LEFT;
      case .REAR_RIGHT;  return REAR_RIGHT;
      case .CENTER_FORWARD;           return CENTER;
      case .SUBWOOFER_CENTER_FORWARD; return SUBWOOFER;
      case .EXTEND_LEFT;
        if backend.num_channels >= 8  return EXTEND_LEFT;
        else                          return REAR_LEFT;
      case .EXTEND_RIGHT;
        if backend.num_channels >= 8  return EXTEND_RIGHT;
        else                          return REAR_RIGHT;
      case;
        assert(false);
        return CENTER, false;
    }
}

update_panning_helper_for_many_channel_music :: (stream: *Sound_Stream, gain_scale: float) {
    if backend.initted {
        assert(stream.num_channels <= 2);
        assert((backend.num_channels == 6) || (backend.num_channels == 8));
    }

    using Audio_Channel;

    if stream.num_channels == 1 {
        // :VolumeConfig
        // Make these configurable at some point?
        front  := 0.8;
        center := 1.0;
        subwoofer := center;
        rear   := 0.5;

        scales := *stream.input_scale_mappings[0].source_scale_for_this_output_index;
        scales.data[FRONT_LEFT]  = front  * gain_scale;
        scales.data[FRONT_RIGHT] = front  * gain_scale;
        scales.data[REAR_LEFT]   = rear   * gain_scale;
        scales.data[REAR_RIGHT]  = rear   * gain_scale;
        scales.data[CENTER]      = center * gain_scale;
        scales.data[SUBWOOFER]   = subwoofer * gain_scale;

        return;
    }

    // If we get here, the input is two channels.
    // @Cleanup: These are different from the Source_Direction indices; why?
    // Well, I know why, but it's confusing. Probably we should fix it.
    left  := *stream.input_scale_mappings[0];
    right := *stream.input_scale_mappings[1];

    // :VolumeConfig
    // Make these configurable at some point?

    // Unlike mono, we presume the two channels are coming from a bit off
    // to their respective sides, so the center channels are quieter than
    // the front, etc.
    front  := 1.0;
    center := .7;
    subwoofer := center;
    rear   := 0.5;

    left.source_scale_for_this_output_index[FRONT_LEFT]  = front * gain_scale;
    left.source_scale_for_this_output_index[REAR_LEFT]   = rear * gain_scale;
    left.source_scale_for_this_output_index[CENTER]      = center * gain_scale;
    left.source_scale_for_this_output_index[SUBWOOFER]   = subwoofer * gain_scale;

    right.source_scale_for_this_output_index[FRONT_RIGHT] = front * gain_scale;
    right.source_scale_for_this_output_index[REAR_RIGHT]  = rear * gain_scale;
    right.source_scale_for_this_output_index[CENTER]      = center * gain_scale;
    right.source_scale_for_this_output_index[SUBWOOFER]   = subwoofer * gain_scale;
}

update_panning_helper_for_locked_output :: (stream: *Sound_Stream, gain_scale: float) {
    //
    // This used to work by generally passing these sounds through the same pipeline as spatialized sounds.
    // It was less code, but very complicated and confusing and I kept making mistakes. So, now it is
    // more code but busted out into its own thing, and we'll see how it goes.
    //
    //    -jblow, 10 October 2015.
    //

    // @Robustness: Are we doing the right thing here if !have_listener? Maybe not.
    if backend.num_channels == 2 {
       if stream.num_channels == 1 {
           // This case probably does not happen; a mono locked sound?! But ... we'll do something.
           mapping := *stream.input_scale_mappings[0];
           mapping.source_scale_for_this_output_index[0] = gain_scale*.5;
           mapping.source_scale_for_this_output_index[1] = gain_scale*.5;
       } else if stream.num_channels == 2 {
           left_mapping  := *stream.input_scale_mappings[0];
           right_mapping := *stream.input_scale_mappings[1];

           left_mapping.source_scale_for_this_output_index[0]  = gain_scale;
           right_mapping.source_scale_for_this_output_index[1] = gain_scale;
       } else {
           for i : 0..stream.num_channels-1 {
               mapping := *stream.input_scale_mappings[i];

               source_dir_index := stream.sound_data.source_directions[i];
               source_dir := vbap_source_directions[source_dir_index];

               // We assume these are quad ambiences so they will all have y != 0.
               if source_dir.y > 0 {
                   mapping.source_scale_for_this_output_index[0] = gain_scale;
               } else {
                   mapping.source_scale_for_this_output_index[1] = gain_scale;
               }
           }
       }
    } else {
        if backend.initted assert(backend.num_channels >= 6);

        if ((stream.category == .MUSIC) && (stream.num_channels <= 2)) || !(stream.user_flags & .SPATIALIZED) || !have_listener {
            update_panning_helper_for_many_channel_music(stream, gain_scale);
            return;
        }

        for i : 0..stream.num_channels-1 {
            mapping := *stream.input_scale_mappings[i];

            //
            // @Incomplete: For this option, source directions are not currently
            // initialized so everything will come out the center! FixMe.
            //
            source_dir_index := stream.sound_data.source_directions[i];
            target_dir_index, success := source_dir_to_target_dir(source_dir_index);

            if success {
                mapping.source_scale_for_this_output_index[target_dir_index] = gain_scale;
            }
        }
    }
}

update_panning_helper :: (stream: *Sound_Stream, gain_scale: float) {
    locked_output := (stream.user_flags & .AMBIENT) || (stream.category == .UI) || (stream.category == .MUSIC) || !have_listener;
    if (stream.num_channels <= 2) && !(stream.user_flags & .SPATIALIZED) {
        locked_output = true;  // Treat it just like music if not spatialized.
    }

    if locked_output {
        update_panning_helper_for_locked_output(stream, gain_scale);
        return;
    }

    //
    // plane_dir is the direction in the 2D plane that the sound is coming from.
    // (We assume we are outputting for horizontal-plane speaker configurations).
    // (1, 0) is forward.  (0, 1) is to the left.
    //


    //
    // The gain_scale is for static stuff (or smoothly changing stuff!) like speaker volume.
    // Dynamic volume changes are interpolated per sample and so are not computed here.
    //
    // @Cleanup: Except that now that we do this gain stuff, maybe they ought to be --
    // the gain factors should probably get interpolated per sample, but currently
    // they do not (and doing that may be slow!)  If we do interpolate them per
    // sample, then this volume scale stuff can definitely go in there.
    // If we don't, we are probably producing clicks, right?  (For the same reason
    // that we interpolate volume_scale per sample instead of per frame!)
    //

    plane_dir, plane_dir_left, plane_dir_right: Vector2;
    gain_scale_right: float;
    plane_dir_left_is_set := false;

/*
    STEREO_SOURCES not currently implemented. We are doing a big refactor, so ...
    If we want this functionality in a new engine, we'll see how it fits into
    the new scheme.

    if (stream.num_channels == 2) && (sound.flags & ISSUED_SOUND_STEREO_SOURCES) {
        //
        // Use stereo sources to compute plane_dir, plane_dir_right.
        //

        pos_left  := object_to_world_space(sound.entity, sound.stereo_source_left);
        pos_right := object_to_world_space(sound.entity, sound.stereo_source_right);

        plane_dir = get_plane_dir(stream, pos_left);
        plane_dir_left = plane_dir;
        plane_dir_right = get_plane_dir(stream, pos_right);
        plane_dir_left_is_set = true;

        // @Refactor: Override the gain_scale that was passed in.
        gain_scale = perceptual_to_linear(get_desired_volume_perceptual(sound, stream, pos_left));
        gain_scale_right = perceptual_to_linear(get_desired_volume_perceptual(sound, stream, pos_right));
    } else {
*/
    //
    // Use point position to compute plane_dir.
    //

    plane_dir = get_plane_dir(stream, stream.position);

    if stream.user_flags & .AMBIENT {
        plane_dir = .{1, 0};  // No rotation with viewporotation: s64, but we do want e.g. stereo channels to stay stereo, 5.1 to stay mapped appropriately, etc.
        plane_dir_right = plane_dir;
		plane_dir_left_is_set = true;
    }

    stream.last_plane_dir = plane_dir;

    if backend.num_channels == 0 return;  // Did not initialize properly!

    if backend.num_channels == 2 {
        // VBAP targets for other channels will have been cleared already by the Sound_Stream constructor.
        if stream.num_channels == 1 {
            accum_scale_target_2_source_mono(stream, plane_dir, gain_scale, *stream.input_scale_mappings[0]);
        } else if stream.num_channels == 2 {
            //
            // Stereo is different from source_n, since we treat stereo posources: s64
            // as actually two differently positioned posources: s64 in space.
            //

            left_target  := *stream.input_scale_mappings[0];
            right_target := *stream.input_scale_mappings[1];

            accum_scale_target_2_source_mono(stream, plane_dir, gain_scale, left_target);
            accum_scale_target_2_source_mono(stream, plane_dir_right, gain_scale_right, right_target);
        } else {
            n := min(stream.num_channels, MAX_CHANNELS_PER_SOUND);
            accum_scale_target_2_source_n(stream, plane_dir, n, gain_scale);
        }
    } else {
        if backend.initted assert(backend.num_channels == 6 || backend.num_channels == 8);
        if stream.num_channels == 1 {
            accum_scale_target_all_source_mono(stream, plane_dir, gain_scale, *stream.input_scale_mappings[0]);
        } else if stream.num_channels == 2 {
            //
            // Stereo is different from source_n, since we treat stereo posources: s64
            // as actually two differently positioned posources: s64 in space.
            //

            left_target  := *stream.input_scale_mappings[0];
            right_target := *stream.input_scale_mappings[1];

            accum_scale_target_all_source_mono(stream, plane_dir, gain_scale, left_target);
            accum_scale_target_all_source_mono(stream, plane_dir_right, gain_scale_right, right_target);
        } else {
            n := min(stream.num_channels, MAX_CHANNELS_PER_SOUND);
            accum_scale_target_all_source_n(stream, plane_dir, n, gain_scale);
        }
    }
}

update_panning :: (stream: *Sound_Stream) {

    for i: 0..stream.num_channels-1  clear_scale_accumulation(stream, i);

    perceptual: float = get_desired_volume_perceptual(stream, stream.position);

    volume_scale_linear: float = perceptual_to_linear(perceptual);
    stream.debug_display_volume = perceptual;
    update_panning_helper(stream, volume_scale_linear);


    //
    // Unset silent_this_frame if any VBAP target is nonzero.
    // Also, set the stream's max gain value (this is for debugging).
    //
    silent_this_frame := true;
    stream.max_gain = 0;

    num_output_channels := backend.num_channels;

    for i: 0..MAX_CHANNELS_PER_SOUND-1 {
        target := *stream.input_scale_mappings[i];
        for j: 0..num_output_channels-1 {
            if target.source_scale_for_this_output_index[j] {
                silent_this_frame = false;
                if target.source_scale_for_this_output_index[j] > stream.max_gain
                    stream.max_gain = target.source_scale_for_this_output_index[j];
            }
        }
    }

    // Set stream.silent_this_frame once here becuase if we
    // set this to true at the beginning of the loop, then set
    // this to false during the loop, we invite a race condition
    // between the main thread and the async audio thread, causing
    // confusion in accumulate_stream and leading to a crash from dereferencing
    // a null-pointer in sample_n_channels, where 'samples' is null.
    // I believe the main thread won't come through here,
    // and the silent_this_frame state of any particular stream changing,
    // often enough for this crash to happen in practice, post-fix, but this is
    // likely not a permananent resolution for the issue. -josh 1 May 2019
    stream.silent_this_frame = silent_this_frame;
}

Sound_Player_Config :: struct {
    update_from_a_thread := true;
    audible_when_window_is_not_in_focus := false;  // May not be supported on most operating systems.
    keep_sounds_alive_by_default := true;  // If false, streams will go away if not marked every frame, which might be better for your use case.

    seconds_to_fill_ahead := 2.4 / 60.0; // How far ahead we mix the audio, to avoid skips. Here we say 2.4 frames at a 60Hz frame rate, (40 milliseconds), but if you know you are more responsive you can decrease this.

    set_async_thread_priority: () -> ();  // If set, we will call this when the mixer thread starts up, and you can use it to set thread priority or do other things.

    release_asset: (stream: *Sound_Stream, data: *Sound_Data); // If set, when we are done playing a sound, we call this. Note that we call this for every stream playing a sound; there may be other streams using the same sound still, so calling this is not a guarantee that the asset is done being played. (But you could use it to decrement a reference count.)
}


Output_Device :: struct {
    name: string;
    hints: [] string;
    device_index: s64;
}

// Call get_devices() to get an array of output devices.
get_devices :: () -> [] Output_Device {
    return backend_get_devices();  // Just glue for now.
}

sound_player_init :: (given_config: Sound_Player_Config) -> bool {
    config = given_config;

    result := true;

    axis_forward = .{1, 0, 0};
    axis_left    = .{0, 1, 0};
    axis_up      = .{0, 0, 1};

    listener_forward = axis_forward;
    listener_left    = axis_left;
    listener_up      = axis_up;

    audio_samples_per_history_sample = DEFAULT_AUDIO_SAMPLES_PER_HISTORY_SAMPLE;


    init(*sound_mutex);

    lock(*sound_mutex);
    defer unlock(*sound_mutex);

    init_sound_player_decode_queue();

    backend = backend_init(given_config);
    if !backend.initted {
        log_error("Sound_Player backend could not be initialized.\n");
        result = false;
    }

    using Audio_Channel;

    //
    // Big VBAP init section here...
    //
    {
        dir : [] Vector2 = vbap_speaker_directions;

        //
        // The X axis is straight forward!  Y is to the left.
        //
        if backend.num_channels == 2 {
            // @Incomplete: Change directions depending on whether
            dir[FRONT_LEFT]   = .{0, +1};
            dir[FRONT_RIGHT]  = .{0, -1};
            dir[REAR_LEFT]    = .{};
            dir[REAR_RIGHT]   = .{};
            dir[CENTER]       = .{};
            dir[SUBWOOFER]    = .{};
            dir[EXTEND_LEFT]  = .{};
            dir[EXTEND_RIGHT] = .{};
        } else if backend.num_channels == 6 {
            dir[FRONT_LEFT]   = .{+1, +1};
            dir[FRONT_RIGHT]  = .{+1, -1};
            dir[REAR_LEFT]    = .{-1, +1};
            dir[REAR_RIGHT]   = .{-1, -1};
            dir[CENTER]       = .{+1, 0};
            dir[SUBWOOFER]    = .{+1, 0};
            dir[EXTEND_LEFT]  = .{};
            dir[EXTEND_RIGHT] = .{};
        } else if backend.num_channels == 8 {
            dir[FRONT_LEFT]   = .{+1, +1};
            dir[FRONT_RIGHT]  = .{+1, -1};
            dir[REAR_LEFT]    = .{-1, +1};
            dir[REAR_RIGHT]   = .{-1, -1};
            dir[CENTER]       = .{1, 0};
            dir[SUBWOOFER]    = .{1, 0};
            dir[EXTEND_LEFT]  = .{-1, +0.5};    // Arbitrary direction value...
            dir[EXTEND_RIGHT] = .{-1, -0.5};    // Arbitrary direction value...
        }

        for * dir normalize(it);
    }

    {
        using Source_Direction;

        dir : [] Vector2 = vbap_source_directions;
        dir[MONO]                     = .{1, 0};
        dir[LEFT]                     = .{0, 1};
        dir[RIGHT]                    = .{0, -1};
        dir[FRONT_LEFT]               = .{+1, +1};
        dir[FRONT_RIGHT]              = .{+1, -1};
        dir[REAR_LEFT]                = .{-1, +1};
        dir[REAR_RIGHT]               = .{-1, -1};
        dir[CENTER_FORWARD]           = .{1, 0};
        dir[SUBWOOFER_CENTER_FORWARD] = .{1, 0};
        dir[EXTEND_LEFT]              = .{-1, +0.5};
        dir[EXTEND_RIGHT]             = .{-1, -0.5};

        for * dir normalize(it);
    }

    if backend.num_channels > 2 {
        // We will use VBAP...
        // Set up the arcs.

        if backend.num_channels == 6 {
            arcs     = arcs_6ch;
        } else {
            assert(backend.num_channels == 8);
            arcs     = arcs_8ch;
        }

        for * arc: arcs {
            l1 := vbap_speaker_directions[arc.speaker1];
            l2 := vbap_speaker_directions[arc.speaker2];

            // p = L * g

            // so, g = L^-1 * p

            l: Matrix2 = ---;
            l._11 = l1.x;
            l._21 = l1.y;
            l._12 = l2.x;
            l._22 = l2.y;
            invert(*l, *arc.l_inverse);
        }
    }

    if given_config.update_from_a_thread {
        thread_init(*async_thread, async_audio_update);
        thread_start(*async_thread);
    }

    for * mix_levels it.* = 1.0;

    #if OS == .WINDOWS {
        // :NeedCrossPlatformHighResolutionWait

        // In order to have a hope of waiting a reasonable amount of time,
        // we need to do this stupid thing. Probably we should use CreateWaitableTimer
        // and SetWaitableTimer, but we need that for every platform.
        Windows :: #import "Windows";
        Windows.timeBeginPeriod(1);
    }

    backend_play();

    return result;
}

sound_player_shutdown :: () {
    if async_thread.index {
        compare_and_swap(*async_thread_should_exit, false, true);

        thread_stopped := false;
        for i : 1..100 {
            log("Async thread shutdown, try %.\n", i);
            if thread_is_done(*async_thread, 10) {
                thread_stopped = true;
                break;
            }
        }

        if thread_stopped {
            log("Async thread stopped.\n");
        } else {
            log_error("Async thread did not stop. Killing it forcibly.\n");
        }

        thread_deinit(*async_thread);
    }

    lock(*sound_mutex);
    backend_shutdown();
    unlock(*sound_mutex);

    free_streams(live_streams);  // This may add to retired_decoders, so put the freeing of retired_decoders after this!
    array_reset(*live_streams);

    for decoder : retired_decoders {
        deinit(decoder);
        free(decoder);
    }

    array_reset(*retired_decoders);
}


samples_to_bytes :: (stream: *Sound_Stream, num_samples: s64) -> s64{
    return num_samples * 2 * stream.sound_data.nchannels;
}

set_master_volume :: (value: float) {
    master_volume = value;
}

find :: (entity_id: s64, manager_id: s64) -> *Sound_Stream {
    for live_streams {
        if it.manager_id != manager_id continue;
        if it.entity_id == entity_id return it;
    }

    return null;
}

update_desired_rate :: (stream: *Sound_Stream) {
    stream.desired_rate = stream.sound_data.sampling_rate / cast(float) backend.output_sampling_rate;
    stream.desired_rate *= stream.rate_scale;
}

make_stream :: (data: *Sound_Data, category := Sound_Category.GENERAL_SFX) -> *Sound_Stream {
    stream := New(Sound_Stream);
    stream.sound_data = data;
    stream.category = category;


    if data.type == .OGG_COMPRESSED {
        PAGE_SIZE :: 8000;
        decoder := create_ogg_decoder(data, PAGE_SIZE);

        stream.decoder = decoder;
        decoder.stream = stream;

        decoder.add_decode_queue_item = add_decode_queue_item;

        #if CACHED_OGG_DECODE_THREADED {
            decoder.do_not_queue = false;
        } else {
            decoder.do_not_queue = true;
        }

        // Don't copy num_channels from data, since data doesn't
        // know the right value; create_ogg_decoder does.

        stream.repeat_end_position = xx decoder.uncompressed_length_in_samples;
    } else {
        stream.num_channels = data.nchannels;
        stream.repeat_end_position = data.nsamples_times_nchannels / data.nchannels;
    }

    if data.type == .ADPCM_COMPRESSED {
        decoder := create_adpcm_decoder(data);
        stream.decoder = *decoder.base;
        decoder.stream = stream;

        decoder.add_decode_queue_item = add_decode_queue_item;
    }

    if stream.decoder {
        if !stream.decoder.do_not_queue  stream.internal_flags |= .WAITING_FOR_INITIAL_DECODER_PAGES;
    }

    return stream;
}

start_playing :: (stream: *Sound_Stream) {
    lock(*sound_mutex);
    defer unlock(*sound_mutex);

    array_add(*live_streams, stream);
}

stop_stream_abruptly :: (id: s64) {
    to_free: [..] *Sound_Stream;
    to_free.allocator = temp;

    lock(*sound_mutex);
    defer { unlock(*sound_mutex); free_streams(to_free); };

    for stream : live_streams {
        if stream.entity_id != id continue;

        // first remove stream from valid streams and then release sound (release() might call stop_stream_abruptly())
        remove stream;

        // :StreamFree
        // DO NOT RELEASE RESOURCES WHILE HOLDING THE SOUND_MUTEX, you will block the mixer thread!
        array_add(*to_free, stream);
    }
}

stop_stream_abruptly :: (data: *Sound_Data) {
    to_free: [..] *Sound_Stream;
    to_free.allocator = temp;

    lock(*sound_mutex);
    defer { unlock(*sound_mutex); free_streams(to_free); }

    for stream : live_streams {
        if stream.sound_data != data continue;
        // first remove stream from valid streams and then release sound (release() might call stop_stream_abruptly())
        remove stream;

        // :StreamFree
        // DO NOT RELEASE RESOURCES WHILE HOLDING THE SOUND_MUTEX, you will block the mixer thread!

        array_add(*to_free, stream);
    }
}

stop_all_sounds_abruptly :: (manager_id: s64) {
    to_free: [..] *Sound_Stream;
    to_free.allocator = temp;

    lock(*sound_mutex);
    defer { unlock(*sound_mutex); free_streams(to_free); }

    for stream : live_streams {
        if stream.manager_id != manager_id continue;

        // first remove stream from valid streams and then release sound (release_a() might call stop_stream_abruptly())
        remove stream;

        // :StreamFree
        // DO NOT RELEASE RESOURCES WHILE HOLDING THE SOUND_MUTEX, you will block the mixer thread!
        array_add(*to_free, stream);
    }
}

get_desired_volume_perceptual :: (stream: *Sound_Stream, position: Vector3) -> float {
    if stream.internal_flags & .FADING_OUT return 0;

    volume := stream.sound_data.volume_scale * stream.user_volume_scale * stream.universe_volume_scale;

    // Scale volume by category.

    scale := master_volume;
    scale *= mix_levels[stream.category];

    volume *= scale;

    if !have_listener return volume;

    if stream.user_flags & .SPATIALIZED {
        dist: float = distance(listener_position, position);
        t: float = (dist - stream.outer_radius) / (stream.inner_radius - stream.outer_radius);
        Clamp(*t, 0, 1);
        //t *= t;

        volume *= t;
    }

    return volume;
}


update_listener :: (camera_position: Vector3, camera_orientation: Quaternion) {
    listener_position = camera_position;
    have_listener = true;

    ori := camera_orientation;
    listener_orientation = ori;

    listener_forward = rotate(axis_forward, ori);
    listener_left    = rotate(axis_left,    ori);
    listener_up      = rotate(axis_up,      ori);

    listener_theta = xx atan2(listener_left.y, listener_left.x);
}


get_audio_sampling_rate :: () -> s64 {
    return backend.output_sampling_rate;
}


/*

    Decode Queue management ... handles the asynchronous decompression of
    compressed pages of audio.

*/


decode_queue_initted := false;

#if CACHED_OGG_DECODE_THREADED {
    decode_queue: [..] *Cached_Decoder_Page;
    decode_queue_semaphore: Semaphore;
    decode_queue_lock: Mutex;
    decode_queue_thread: Thread;
}

completed_queue: [..] *Cached_Decoder_Page;
completed_queue_lock: Mutex;



init_sound_player_decode_queue :: () {
    if decode_queue_initted return;

    #if CACHED_OGG_DECODE_THREADED {
        init(*decode_queue_lock);
        init(*decode_queue_semaphore);
    }
    init(*completed_queue_lock);

	decode_queue_initted = true;

    #if CACHED_OGG_DECODE_THREADED {
        thread_init(*decode_queue_thread, thread_proc);
        thread_start(*decode_queue_thread);
    }
}



process_one_page :: (page: *Cached_Decoder_Page) {
    if page.type == .OGG {
        owner := cast (*Cached_Ogg_Decoder) page.owner;
        owner.recompute_page(page.owner, page);
    } else {
        assert(page.type == .ADPCM);
        assert(false);  // We are not handling ADPCM yet.
    }

    lock(*completed_queue_lock);
    array_add(*completed_queue, page);
    unlock(*completed_queue_lock);
}


add_decode_queue_item :: (page: *Cached_Decoder_Page) {
    assert(decode_queue_initted);

    #if CACHED_OGG_DECODE_THREADED {
        lock(*decode_queue_lock);
        array_add(*decode_queue, page);
        unlock(*decode_queue_lock);
        signal(*decode_queue_semaphore);
    } else {
        process_one_page(page);  // This will add it to the completed queue.
    }
}

get_next_completed_decode_queue_item :: () -> *Cached_Decoder_Page {
    assert(decode_queue_initted);

    result: *Cached_Decoder_Page;

    lock(*completed_queue_lock);

    if completed_queue.count {
        result = completed_queue[0];
        array_ordered_remove_by_index(*completed_queue, 0);
    }

    unlock(*completed_queue_lock);

	return result;
}


#scope_file

update_stream :: (stream: *Sound_Stream) {
    update_desired_rate(stream);
    update_panning(stream);

    if stream.decoder {
        // Prefetch any data we may need to play. (The decompression will happen on another core, maybe!)

        decoder := stream.decoder;
        data    := stream.sound_data;

        seconds_to_fetch := SECONDS_TO_FETCH_OGG;
        if decoder.type == .ADPCM  seconds_to_fetch = SECONDS_TO_FETCH_ADPCM;

        samples_to_fetch := cast(s64) (stream.current_rate * data.sampling_rate * seconds_to_fetch);
        if samples_to_fetch > stream.repeat_end_position  {
            assert(stream.repeat_end_position >= 0); // This must have been set!
            samples_to_fetch = stream.repeat_end_position;
        }

        at_least := stream.decoder.page_size_in_samples * 3;  // We want to make sure we are reading some pages ahead, otherwise we can miss deadlines. Some videos, for example, with mono audio, end up being late a lot.

        if samples_to_fetch < at_least  samples_to_fetch = at_least;

        forward_sample := cast(s64) stream.play_cursor + samples_to_fetch;

        // Casting to float just to do math with int is a pain in the ass.
        // I am pretty sure I am going to change the coercion rules so that
        // you can just do this without casting.
        TOO_MANY_PAGES_PENDING := cast(s64) (data.sampling_rate / decoder.page_size_in_samples * seconds_to_fetch * 4.0);

        if stream.internal_flags & .WAITING_FOR_INITIAL_DECODER_PAGES {
            stream.samples_needed_to_start_playing = min((samples_to_fetch * 4) / 5, stream.repeat_end_position);
        }


        unmark_all_pages(decoder);

        if (decoder.issued_start_addresses.count > TOO_MANY_PAGES_PENDING) {
            //
            // We are falling behind and unable to process audio as quickly as we need to.
            // Just let this drain out, don't ask for new pages.
            //
        } else {
            mark_relevant_pages(decoder, cast(s64) stream.play_cursor, forward_sample);

            if stream.user_flags & .REPEATING {
                if forward_sample > stream.repeat_end_position {
                    forward_sample -= stream.repeat_end_position;
                    mark_relevant_pages(decoder, stream.repeat_start_position, forward_sample);
                }
            }
        }

        free_unmarked_pages(decoder);
    }


    stream.samples_streamed_since_entity_update = 0;
}

#scope_export

pre_entity_update :: () {
    lock(*sound_mutex);
    defer unlock(*sound_mutex);

    keep := config.keep_sounds_alive_by_default;
    for live_streams {
        it.marked = keep;

        if xx it.play_cursor >= it.repeat_end_position {
            it.internal_flags |= .FADING_OUT; // This will auto destroy and free the stream.
        }
    }
}

post_entity_update :: (dt: float) {
    lock(*sound_mutex);
    defer unlock(*sound_mutex);

    if dt == FLOAT32_INFINITY {
        // The user did not compute dt, so we do it.
        now := seconds_since_init();

        dt = ifx last_update_time then cast(float)(now - last_update_time);

        last_update_time = now;
    }

    to_free: [..] *Sound_Stream;
    to_free.allocator = temp;

    for stream : live_streams {
        update_stream(stream);

        if stream.internal_flags & .FADING_OUT {
            if stream.silent_this_frame {
                stream.marked = false;
            }
        }

        if !stream.marked {
            if stream.user_flags & .DO_NOT_KILL {
                // Do nothing.
            } else {
                remove stream;
                array_add(*to_free, stream);
                continue;
            }
        }
    }

    if to_free  free_streams(to_free);

    //
    // Look for any pages that are done decompressing; pull them in if so.
    //

    while true {
        page := get_next_completed_decode_queue_item();
        if !page break;

        assert(page.owner != null);

        found := array_unordered_remove_by_value(*page.owner.issued_start_addresses, page.start_address);
        assert(found >= 0);

        array_add(*page.owner.pages, page);

        if page.owner.stream && (page.owner.stream.internal_flags & .WAITING_FOR_INITIAL_DECODER_PAGES) {
            page.owner.stream.initial_samples_fetched += page.num_samples_contained;
        }
	}

    //
    // Wake up any streams that are ready.
    // We used to do this only when pages come in, which is the most efficient
    // thing, but there were some complexities regarding sounds that have
    // silence at the beginning, etc.   -jblow, 22 May 2015
    //

    for stream : live_streams {
        if !(stream.internal_flags & .WAITING_FOR_INITIAL_DECODER_PAGES) continue;

        fetched: s64 = stream.initial_samples_fetched;

        if stream.play_cursor < 0 { // We have this much silence to count!
            fetched += cast(s64) (-(stream.play_cursor + 0.5));
        }

        //
        // Note: This is maybe not really right since it doesn't ensure that all these pages
        // are sequential from the beginning, and it's unclear whether there are some cases
        // in which that might not happen.   -jblow, 22 May 2015
        //

        // print("Stream % fetched % needed %\n", stream.sound_data.name, fetched, stream.samples_needed_to_start_playing);

        if fetched >= stream.samples_needed_to_start_playing {
            stream.internal_flags &= ~.WAITING_FOR_INITIAL_DECODER_PAGES;
        }
    }


    //
    // Check the retired_decoders array to see if anyone is done.
    //

    for decoder : retired_decoders {
        if decoder.issued_start_addresses.count continue; // This guy still has work out, can't delete him.
        remove decoder;
        deinit(decoder);
        free(decoder);
    }

    if !backend.initted {
        // Just advance the streams as though they were playing.
        for stream : live_streams {
            stream.current_rate = stream.desired_rate;
            stream.play_cursor += dt * cast(float)(stream.sound_data.sampling_rate) * stream.current_rate;
            maybe_wrap_play_cursor(stream);
        }
    } else {
        if backend_needs_async_update_from_main_thread() {
            update_from_async_thread(false);
        }
    }
}

update :: (dt := FLOAT32_INFINITY) {
    // A general-purpose update() routine for people who don't want to think about
    // anything fancy.

    pre_entity_update();
    post_entity_update(dt);
}

set_repeating :: (stream: *Sound_Stream, repeating: bool) {
    lock(*sound_mutex);
    defer unlock(*sound_mutex);

    if repeating {
        stream.user_flags |= .REPEATING;
        data := stream.sound_data;
        stream.repeat_end_position = data.nsamples_times_nchannels / data.nchannels;
    } else {
        stream.user_flags &= ~.REPEATING;
    }
}

#scope_file

thread_proc :: (thread: *Thread) -> s64 {
    // @Incomplete: Provide hooks for us to set thread priority.

    // os_set_thread_priority(THREAD_PRIO_NORMAL);
    // os_set_thread_affinity(THREAD_AFFINITY_LOW_PRIORITY_THREAD);

    while true {
        #if CACHED_OGG_DECODE_THREADED {
            wait_for(*decode_queue_semaphore);
        }

        lock(*decode_queue_lock);
        assert(decode_queue.count >= 0);

        page: *Cached_Decoder_Page;
        if decode_queue.count {
            page = decode_queue[0];
            array_ordered_remove_by_index(*decode_queue, 0);  // Just make this a linked list?
        }

        unlock(*decode_queue_lock);

        if page  process_one_page(page);
    }

    // @Incomplete: We never break from the above loop to get down here.

    return 0;
}

free_streams :: (streams: [] *Sound_Stream) {
    lock(*sound_mutex);
    defer unlock(*sound_mutex);

    for streams free_stream(it);
}

free_stream :: (stream: *Sound_Stream) {
    if config.release_asset config.release_asset(stream, stream.sound_data);

    if stream.decoder {
        stream.decoder.stream = null;
        array_add(*retired_decoders, stream.decoder);
    }

    if stream.sound_name free(stream.sound_name.data);

    free(stream);
}

last_update_time: float64;

#scope_module
#import "Math";
#import "Thread";

BYTES_PER_SAMPLE :: size_of(s16);

// All sounds are multiplied by master_volume:
master_volume: float = 1;

//
// These mix levels can be used to tweak volume per type of sound.
// These are indexed by Sound_Category (which you can extend).
//

mix_levels: [MAX_SOUND_CATEGORIES] float;




//
// Listener variables that you can set directly for now;
// we should probably provide an API for this.
//
listener_position    : Vector3;
listener_orientation : Quaternion;

axis_forward : Vector3;
axis_left    : Vector3;
axis_up      : Vector3;

listener_forward : Vector3;
listener_left    : Vector3;
listener_up      : Vector3;

listener_theta: float;  // In the 2D speaker plane

have_listener := false;


update_history := false;  // Tells us whether to update the below sample history, or not.

//
// Internal stuff you don't need to mess with:
//

Sample_Output_History :: struct {
    low:  [OUTPUT_CHANNELS_MAX] float;
    high: [OUTPUT_CHANNELS_MAX] float;
}

HISTORY_LENGTH :: 1000;  // This is the length in samples.
DEFAULT_AUDIO_SAMPLES_PER_HISTORY_SAMPLE :: 128;

history: [HISTORY_LENGTH] Sample_Output_History;
history_cursor:    s64;
history_subcursor: s64;
audio_samples_per_history_sample: s64;
history_paused := false;

stereo_base : float = 1;



//
// More internal stuff:
//

live_streams: [..] *Sound_Stream;


// System variables you shouldn't screw with,
// unless you want to hold the sound_mutex to manipulate stuff:

async_thread: Thread;
sound_mutex:  Mutex;
async_thread_should_exit := false;

config:  Sound_Player_Config;
backend: Backend_Properties;


#if OS == {
    case .WINDOWS; #load "os/win32.jai";
    case .LINUX;   #load "os/alsa.jai";
    case .MACOS;   #load "os/core_audio.jai";
    case .PS5;     #load "os/ps5.jai";
    case .NN_SWITCH2;   #load "os/nintendo.jai";
    case .ANDROID; #load "os/aaudio.jai";
}

