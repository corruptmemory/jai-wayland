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

    if info.feedback_supported {
        default_feedback, default_ok := Wayland.get_default_dmabuf_feedback(*info.dmabuf);
        if default_ok {
            print_feedback_summary("Default zwp_linux_dmabuf_feedback_v1 snapshot", default_feedback);
        } else {
            print("\nDefault zwp_linux_dmabuf_feedback_v1 snapshot incomplete.\n");
        }

        surface := Wayland.Wl_Surface.{ id = Wayland.allocate_id() };
        batch: Wayland.MessageBuilder;
        Wayland.wl_compositor_create_surface(*batch, Wayland.compositor(), surface.id);
        Wayland.wayland_send(*batch);

        surface_feedback, surface_ok := Wayland.get_surface_dmabuf_feedback(*info.dmabuf, *surface);
        if surface_ok {
            print_feedback_summary("Surface zwp_linux_dmabuf_feedback_v1 snapshot", surface_feedback);
        } else {
            print("\nSurface zwp_linux_dmabuf_feedback_v1 snapshot incomplete.\n");
        }

        destroy_batch: Wayland.MessageBuilder;
        Wayland.wl_surface_destroy(*destroy_batch, *surface);
        Wayland.wayland_send(*destroy_batch);
    } else {
        print("\nzwp_linux_dmabuf_feedback_v1 unavailable; compositor advertised linux-dmabuf v<4.\n");
    }
}

print_feedback_summary :: (label: string, feedback: Wayland.Dmabuf_Feedback_Info) {
    print("\n%:\n", label);
    print("  complete: %\n", feedback.complete);
    print("  main device: ");
    print_device_bytes(feedback.main_device);
    print("\n");
    print("  format table entries: %\n", feedback.format_table.count);
    print("  tranches: %\n", feedback.tranches.count);

    for tranche, i: feedback.tranches {
        print("    tranche %: flags=0x% target_device=",
            i,
            formatInt(tranche.flags, base=16));
        print_device_bytes(tranche.target_device);
        print(" formats=%\n", tranche.formats.count);

        max_print :: 8;
        printed_count := 0;
        for fmt: tranche.formats {
            if printed_count >= max_print {
                print("      ... % more\n", tranche.formats.count - printed_count);
                break;
            }
            print("      ");
            print_fourcc(fmt.format);
            print(" modifier=0x%\n", formatInt(fmt.modifier, base=16, minimum_digits=16));
            printed_count += 1;
        }
    }
}

print_fourcc :: (format: u32) {
    fourcc_bytes: [4] u8;
    fourcc_bytes[0] = cast(u8)(format & 0xFF);
    fourcc_bytes[1] = cast(u8)((format >> 8) & 0xFF);
    fourcc_bytes[2] = cast(u8)((format >> 16) & 0xFF);
    fourcc_bytes[3] = cast(u8)((format >> 24) & 0xFF);
    name: string = .{ count = 4, data = fourcc_bytes.data };
    print("%", name);
}

print_device_bytes :: (bytes: [] u8) {
    if bytes.count == 0 {
        print("<empty>");
        return;
    }

    print("0x");
    for bytes  print("%", formatInt(it, base=16, minimum_digits=2));
}
