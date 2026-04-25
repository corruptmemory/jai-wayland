// linux-dmabuf-v1 discovery helper — parallel to output.jai / input.jai.
//
// Binds zwp_linux_dmabuf_v1 from the registry and collects the
// (format, modifier) pairs the compositor advertises via .modifier events
// (protocol version 3+) or .format events (legacy v1). For protocol v4+,
// exposes explicit helpers for zwp_linux_dmabuf_feedback_v1 snapshots.

#import "Basic";
#import "POSIX";

Format_Modifier :: struct {
    format: u32;     // DRM fourcc
    modifier: u64;   // DRM modifier (MOD_LINEAR, MOD_INVALID, or driver-specific)
}

Dmabuf_Feedback_Tranche :: struct {
    target_device: [..] u8;          // opaque dev_t byte array from the compositor
    formats:       [..] Format_Modifier;
    flags:         u32;
}

Dmabuf_Feedback_Info :: struct {
    feedback:     Zwp_Linux_Dmabuf_Feedback_V1;
    main_device:  [..] u8;           // opaque dev_t byte array from the compositor
    format_table: [..] Format_Modifier;
    tranches:     [..] Dmabuf_Feedback_Tranche;
    complete:     bool;
}

Dmabuf_Info :: struct {
    dmabuf: Zwp_Linux_Dmabuf_V1;
    supported: [..] Format_Modifier;
    feedback_supported: bool;
}

// DRM modifier sentinels (from drm_fourcc.h).
DRM_FORMAT_MOD_LINEAR  : u64 : 0;
DRM_FORMAT_MOD_INVALID : u64 : 0x00ffffffffffffff;

// Discover zwp_linux_dmabuf_v1 and enumerate its advertised (format, modifier)
// pairs. Returns (info, true) if the compositor supports the protocol; (zero, false)
// if the global isn't advertised. Uses the context session (must be initialized).
//
// Wire sequence: bind the global, send a sync, then consume events up to the
// sync — the compositor sends all format/modifier events synchronously right
// after binding.
get_dmabuf_info :: () -> Dmabuf_Info, bool {
    info: Dmabuf_Info;

    global, found := get_global("zwp_linux_dmabuf_v1");
    if !found  return info, false;

    info.dmabuf = Zwp_Linux_Dmabuf_V1.{ id = allocate_id() };

    display := Wl_Display.{ id = 1 };
    batch: MessageBuilder;
    wl_registry_bind(*batch, registry(), *info.dmabuf);
    sync_id := allocate_id();
    wl_display_sync(*batch, *display, sync_id);
    wayland_send(*batch);

    for session() {
        if it.object_id == sync_id  break;
        if it.object_id == info.dmabuf.id {
            event: Zwp_Linux_Dmabuf_V1_Event;
            unmarshal_event(*event, it.opcode, it.payload, recv);
            if event.kind == {
              case .MODIFIER;
                // v3+: explicit modifier info. modifier_hi/lo are the two
                // halves of the 64-bit DRM modifier, transmitted big-endian
                // in spirit (hi first, then lo) but stored little-endian
                // per wl wire byte ordering.
                fm := array_add(*info.supported);
                fm.format = event.modifier.format;
                fm.modifier = (cast(u64) event.modifier.modifier_hi << 32)
                            | (cast(u64) event.modifier.modifier_lo);
              case .FORMAT;
                // Legacy v1 signal — format only, modifier implicit.
                // Record as INVALID so pick_format() can distinguish it
                // from an explicit-LINEAR advertisement.
                fm := array_add(*info.supported);
                fm.format = event.format.format;
                fm.modifier = DRM_FORMAT_MOD_INVALID;
            }
        }
    }

    info.feedback_supported = global.version >= 4;

    return info, true;
}

get_default_dmabuf_feedback :: (dmabuf: *Zwp_Linux_Dmabuf_V1) -> Dmabuf_Feedback_Info, bool {
    global, found := get_global("zwp_linux_dmabuf_v1");
    if !found || global.version < 4  return .{}, false;

    feedback := Zwp_Linux_Dmabuf_Feedback_V1.{ id = allocate_id() };

    display := Wl_Display.{ id = 1 };
    batch: MessageBuilder;
    zwp_linux_dmabuf_v1_get_default_feedback(*batch, dmabuf, feedback.id);
    sync_id := allocate_id();
    wl_display_sync(*batch, *display, sync_id);
    wayland_send(*batch);

    info, ok := collect_dmabuf_feedback(feedback, sync_id);

    destroy_batch: MessageBuilder;
    zwp_linux_dmabuf_feedback_v1_destroy(*destroy_batch, *feedback);
    wayland_send(*destroy_batch);

    return info, ok;
}

get_surface_dmabuf_feedback :: (dmabuf: *Zwp_Linux_Dmabuf_V1, surface: *Wl_Surface) -> Dmabuf_Feedback_Info, bool {
    global, found := get_global("zwp_linux_dmabuf_v1");
    if !found || global.version < 4  return .{}, false;

    feedback := Zwp_Linux_Dmabuf_Feedback_V1.{ id = allocate_id() };

    display := Wl_Display.{ id = 1 };
    batch: MessageBuilder;
    zwp_linux_dmabuf_v1_get_surface_feedback(*batch, dmabuf, feedback.id, surface);
    sync_id := allocate_id();
    wl_display_sync(*batch, *display, sync_id);
    wayland_send(*batch);

    info, ok := collect_dmabuf_feedback(feedback, sync_id);

    destroy_batch: MessageBuilder;
    zwp_linux_dmabuf_feedback_v1_destroy(*destroy_batch, *feedback);
    wayland_send(*destroy_batch);

    return info, ok;
}

collect_dmabuf_feedback :: (feedback: Zwp_Linux_Dmabuf_Feedback_V1, sync_id: u32) -> Dmabuf_Feedback_Info, bool {
    info: Dmabuf_Feedback_Info;
    info.feedback = feedback;

    current: Dmabuf_Feedback_Tranche;

    for session() {
        if it.object_id == sync_id  break;

        if it.object_id == feedback.id {
            event: Zwp_Linux_Dmabuf_Feedback_V1_Event;
            unmarshal_event(*event, it.opcode, it.payload, recv);

            if event.kind == {
              case .FORMAT_TABLE;
                append_feedback_format_table(*info.format_table, event.format_table.fd, event.format_table.size);

              case .MAIN_DEVICE;
                copy_bytes(*info.main_device, event.main_device.device);

              case .TRANCHE_TARGET_DEVICE;
                current = .{};
                copy_bytes(*current.target_device, event.tranche_target_device.device);

              case .TRANCHE_FORMATS;
                append_feedback_indices(*current.formats, info.format_table, event.tranche_formats.indices);

              case .TRANCHE_FLAGS;
                current.flags = event.tranche_flags.flags;

              case .TRANCHE_DONE;
                array_add(*info.tranches, current);
                current = .{};

              case .DONE;
                info.complete = true;
            }
        }
    }

    return info, info.complete;
}

append_feedback_format_table :: (out: *[..] Format_Modifier, fd: Fd, size: u32) {
    if size == 0 {
        close(cast(s32) fd);
        return;
    }

    data := mmap(null, cast(u64) size, PROT_READ, MAP_PRIVATE, cast(s32) fd, 0);
    close(cast(s32) fd);
    if data == cast(*void) -1  return;
    defer munmap(data, cast(u64) size);

    bytes := cast(*u8) data;
    entry_count := size / 16;
    if entry_count == 0  return;

    for 0..entry_count - 1 {
        entry := bytes + it * 16;
        format := read_u32(entry);
        modifier_lo := read_u32(entry + 8);
        modifier_hi := read_u32(entry + 12);
        array_add(out, .{
            format = format,
            modifier = (cast(u64) modifier_hi << 32) | cast(u64) modifier_lo,
        });
    }
}

append_feedback_indices :: (out: *[..] Format_Modifier, table: [] Format_Modifier, indices: [] u8) {
    if indices.count < 2  return;

    count := indices.count / 2;
    for 0..count - 1 {
        base := it * 2;
        index := cast(u32) indices[base] | ((cast(u32) indices[base + 1]) << 8);
        if index < table.count  array_add(out, table[index]);
    }
}

copy_bytes :: (dst: *[..] u8, src: [] u8) {
    dst.count = 0;
    for src  array_add(dst, it);
}

// Pick a (format, modifier) pair from the compositor's advertised set that
// matches the requested fourcc. Preference order:
//   1. LINEAR modifier for the preferred format (CPU-mappable, simplest)
//   2. INVALID modifier for the preferred format (driver-default tiling)
//   3. any modifier for the preferred format
//
// Returns (format, modifier, true) on success; (0, 0, false) if the
// compositor doesn't advertise the requested format at all.
pick_format :: (info: Dmabuf_Info, preferred_fourcc: u32) -> format: u32, modifier: u64, found: bool {
    // Pass 1: LINEAR
    for info.supported {
        if it.format == preferred_fourcc && it.modifier == DRM_FORMAT_MOD_LINEAR
            return it.format, it.modifier, true;
    }
    // Pass 2: INVALID (driver-implicit)
    for info.supported {
        if it.format == preferred_fourcc && it.modifier == DRM_FORMAT_MOD_INVALID
            return it.format, it.modifier, true;
    }
    // Pass 3: anything matching the format
    for info.supported {
        if it.format == preferred_fourcc
            return it.format, it.modifier, true;
    }
    return 0, 0, false;
}
