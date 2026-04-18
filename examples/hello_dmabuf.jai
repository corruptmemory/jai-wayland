// Diagnostic — print the (format, modifier) pairs the compositor advertises
// via zwp_linux_dmabuf_v1. Useful for validating Task 5's discovery helper
// and for sanity-checking what formats are actually available before
// wiring up the full rendering path.

#import "Basic";
Wayland :: #import,dir "../modules/wayland";

main :: () {
    if !Wayland.init_wayland_session() return;
    defer Wayland.end_wayland_session();

    info, ok := Wayland.get_dmabuf_info();
    if !ok {
        print("Compositor does not advertise zwp_linux_dmabuf_v1.\n");
        return;
    }

    print("zwp_linux_dmabuf_v1 supports % (format, modifier) pair(s):\n\n",
        info.supported.count);

    // Group by format for readability — compositors often advertise many
    // modifiers per format, and flat-printing each one is hard to scan.
    printed: [..] u32;
    printed.allocator = temp;

    for fmt: info.supported {
        already := false;
        for p: printed  if p == fmt.format { already = true; break; }
        if already  continue;

        fourcc_bytes: [4] u8;
        fourcc_bytes[0] = cast(u8)(fmt.format & 0xFF);
        fourcc_bytes[1] = cast(u8)((fmt.format >> 8) & 0xFF);
        fourcc_bytes[2] = cast(u8)((fmt.format >> 16) & 0xFF);
        fourcc_bytes[3] = cast(u8)((fmt.format >> 24) & 0xFF);
        name: string = .{ count = 4, data = fourcc_bytes.data };

        print("  % (0x%):\n", name, formatInt(fmt.format, base=16));
        for m: info.supported {
            if m.format != fmt.format  continue;
            mod_note := "";
            if m.modifier == Wayland.DRM_FORMAT_MOD_LINEAR   mod_note = " [LINEAR]";
            if m.modifier == Wayland.DRM_FORMAT_MOD_INVALID  mod_note = " [INVALID / driver default]";
            print("    modifier=0x%%\n", formatInt(m.modifier, base=16, minimum_digits=16), mod_note);
        }
        array_add(*printed, fmt.format);
    }
}
