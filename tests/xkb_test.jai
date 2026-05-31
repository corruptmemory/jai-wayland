#import "Basic";
Wayland :: #import,dir "../modules/wayland";

SAMPLE_KEYMAP :: #string END
xkb_keycodes "evdev_aliases(qwerty)" {
    <ESC>  = 9;
    <AE01> = 10;
    <AD01> = 24;
    <LALT> = 64;
    <FK04> = 70;
};

xkb_symbols "pc_us_inet(evdev)" {
    key <ESC>  { [ Escape ] };
    key <AE01> { [ 0x31, 0x21 ] };
    key <AD01> { [ q, Q ] };
    key <LALT> { [ Alt_L ] };
    key <FK04> {
        type= "CTRL+ALT";
        symbols[1]= [ F4, F4, F4, F4, XF86Switch_VT_4 ]
    };
};
END

test_compact_named_keysyms :: () {
    keymap := Wayland.parse_xkb_keymap(SAMPLE_KEYMAP);

    assert(Wayland.keymap_get_keysym(*keymap, 1) == 0xff1b, "ESC should decode to XK_Escape");
    assert(Wayland.keymap_get_keysym(*keymap, 16, 0) == #char "q", "AD01 level 0 should decode to q");
    assert(Wayland.keymap_get_keysym(*keymap, 16, 1) == #char "Q", "AD01 level 1 should decode to Q");
    assert(Wayland.keymap_get_keysym(*keymap, 56) == 0xffe9, "LALT should decode to XK_Alt_L");

    print("  PASS: test_compact_named_keysyms\n");
}

test_hex_keysyms :: () {
    keymap := Wayland.parse_xkb_keymap(SAMPLE_KEYMAP);

    assert(Wayland.keymap_get_keysym(*keymap, 2, 0) == #char "1", "AE01 level 0 should decode from hex");
    assert(Wayland.keymap_get_keysym(*keymap, 2, 1) == #char "!", "AE01 level 1 should decode from hex");

    print("  PASS: test_hex_keysyms\n");
}

test_symbols_group_form :: () {
    keymap := Wayland.parse_xkb_keymap(SAMPLE_KEYMAP);

    assert(Wayland.keymap_get_keysym(*keymap, 62, 0) == 0xffc1, "FK04 level 0 should decode to XK_F4");
    assert(Wayland.keymap_get_keysym(*keymap, 62, 1) == 0xffc1, "FK04 level 1 should decode to XK_F4");

    print("  PASS: test_symbols_group_form\n");
}

main :: () {
    print("=== XKB Parser Tests ===\n\n");

    test_compact_named_keysyms();
    test_hex_keysyms();
    test_symbols_group_form();

    print("\n=== All XKB tests passed ===\n");
}
