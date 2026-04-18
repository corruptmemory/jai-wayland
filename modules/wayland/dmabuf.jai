// linux-dmabuf-v1 discovery helper — parallel to output.jai / input.jai.
//
// Binds zwp_linux_dmabuf_v1 from the registry and collects the
// (format, modifier) pairs the compositor advertises via .modifier events
// (protocol version 3+) or .format events (legacy v1). Feedback API
// (zwp_linux_dmabuf_feedback_v1) is not used here; it's a newer
// per-surface negotiation API that we can add later if needed.

#import "Basic";

Format_Modifier :: struct {
    format: u32;     // DRM fourcc
    modifier: u64;   // DRM modifier (MOD_LINEAR, MOD_INVALID, or driver-specific)
}

Dmabuf_Info :: struct {
    dmabuf: Zwp_Linux_Dmabuf_V1;
    supported: [..] Format_Modifier;
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

    _, found := get_global("zwp_linux_dmabuf_v1");
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

    return info, true;
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
