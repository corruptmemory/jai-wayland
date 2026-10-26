// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jim Powers

#import "Basic";
#import "POSIX";
Wayland :: #import,dir "../modules/wayland";

main :: () {
    print("=== Dmabuf Tests ===\n\n");

    test_make_drm_modifier_keeps_high_word();
    test_format_table_parse_keeps_high_word();

    print("\n=== All dmabuf tests passed ===\n");
}

test_make_drm_modifier_keeps_high_word :: () {
    nvidia := Wayland.make_drm_modifier(0x03000000, 0x00e08014);
    assert(nvidia == 0x0300000000e08014, "make_drm_modifier(0x03000000, 0x00e08014) = 0x%", formatInt(nvidia, base = 16));

    invalid := Wayland.make_drm_modifier(0x00ffffff, 0xffffffff);
    assert(invalid == Wayland.DRM_FORMAT_MOD_INVALID, "make_drm_modifier(0x00ffffff, 0xffffffff) = 0x%", formatInt(invalid, base = 16));

    print("  PASS: make_drm_modifier_keeps_high_word\n");
}

// One 16-byte zwp_linux_dmabuf_feedback_v1 format-table entry:
// format u32 at 0, padding at 4, modifier_lo u32 at 8, modifier_hi u32 at 12.
test_format_table_parse_keeps_high_word :: () {
    entry: [16] u8;
    Wayland.write_u32(entry.data,      0xAABBCCDD);
    Wayland.write_u32(entry.data + 8,  0x55667788);
    Wayland.write_u32(entry.data + 12, 0x11223344);

    fd := Wayland.memfd_create("dmabuf_test".data, 0);
    assert(fd >= 0, "memfd_create failed");
    written := write(fd, entry.data, cast(u64) entry.count);
    assert(written == entry.count, "write to memfd returned %", written);

    // append_feedback_format_table takes ownership of the fd and closes it.
    out: [..] Wayland.Format_Modifier;
    Wayland.append_feedback_format_table(*out, cast(Wayland.Fd) fd, 16);

    assert(out.count == 1, "expected 1 format-table entry, got %", out.count);
    assert(out[0].format == 0xAABBCCDD, "format = 0x%", formatInt(out[0].format, base = 16));
    assert(out[0].modifier == 0x1122334455667788, "modifier = 0x%", formatInt(out[0].modifier, base = 16));

    print("  PASS: format_table_parse_keeps_high_word\n");
}
