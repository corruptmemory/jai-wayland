// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jim Powers

// A small xkb_keymap text shared by the keymap tests. xkb_test parses it
// directly; input_test sends it through a memfd on a wl_keyboard.keymap event.
// Covers the compact named form (AD01: q, Q), hex keysyms (AE01: 0x31, 0x21),
// and the xkbcommon symbols[N] group form (FK04: F4).

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
