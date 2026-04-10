// XKB keymap parser — extracts evdev keycode → keysym mappings from
// the xkb_keymap text format sent by the compositor via wl_keyboard.keymap.

#import "Basic";
#import "POSIX";

MAX_EVDEV_KEYCODE :: 768;
MAX_KEYSYMS_PER_KEY :: 4;

Keymap_Entry :: struct {
    keysyms: [MAX_KEYSYMS_PER_KEY] u32;
    count: u8;
}

Keymap :: struct {
    entries: [MAX_EVDEV_KEYCODE] Keymap_Entry;
}

Keycode_Name :: struct {
    name: string;    // e.g. "AD01" (slice into text, valid while text is alive)
    xkb_code: s32;
}

// Parse an xkb keymap string (from mmap'd wl_keyboard.keymap fd)
// into a lookup table indexed by evdev keycode.
parse_xkb_keymap :: (text: string) -> Keymap {
    keymap: Keymap;

    // Phase 1: parse xkb_keycodes section → name → xkb_number
    names: [..] Keycode_Name;
    names.allocator = temp;

    keycodes_start := find_section(text, "xkb_keycodes");
    keycodes_end := find_section_end(text, keycodes_start);
    parse_keycodes_section(text, keycodes_start, keycodes_end, *names);

    // Phase 2: parse xkb_symbols section → for each key, look up evdev keycode
    symbols_start := find_section(text, "xkb_symbols");
    symbols_end := find_section_end(text, symbols_start);
    parse_symbols_section(text, symbols_start, symbols_end, names, *keymap);

    return keymap;
}

// Look up a keysym for a given evdev keycode and level (0=normal, 1=shift).
keymap_get_keysym :: inline (keymap: *Keymap, evdev_keycode: u32, level: u32 = 0) -> u32 {
    if evdev_keycode >= MAX_EVDEV_KEYCODE  return 0;
    entry := *keymap.entries[evdev_keycode];
    if level >= cast(u32) entry.count  return 0;
    return entry.keysyms[level];
}

// Returns true if the keysym is a printable ASCII character.
keysym_is_ascii :: inline (keysym: u32) -> bool {
    return keysym >= 0x20 && keysym <= 0x7e;
}

// mmap a keymap fd and parse it. Caller should close the fd when done.
parse_keymap_fd :: (fd: Fd, size: u32) -> Keymap, bool {
    if size == 0  return .{}, false;
    data := mmap(null, cast(u64) size, PROT_READ, MAP_PRIVATE, cast(s32) fd, 0);
    if data == cast(*void) -1  return .{}, false;
    defer munmap(data, cast(u64) size);

    text: string;
    text.data = cast(*u8) data;
    text.count = cast(s64) size;
    // Strip null terminator if present
    if text.count > 0 && text.data[text.count - 1] == 0  text.count -= 1;

    return parse_xkb_keymap(text), true;
}

#scope_file

// Find the opening brace of a section like "xkb_keycodes" or "xkb_symbols"
find_section :: (text: string, section_name: string) -> s64 {
    pos: s64 = 0;
    while pos < text.count - section_name.count {
        found := true;
        for i: 0..section_name.count-1 {
            if text.data[pos + i] != section_name.data[i] { found = false; break; }
        }
        if found {
            // Find opening brace after section name
            i := pos + section_name.count;
            while i < text.count {
                if text.data[i] == #char "{"  return i + 1;
                i += 1;
            }
        }
        pos += 1;
    }
    return text.count;
}

// Find matching closing brace (handles nesting)
find_section_end :: (text: string, start: s64) -> s64 {
    depth: s32 = 1;
    i := start;
    while i < text.count && depth > 0 {
        if text.data[i] == #char "{"       depth += 1;
        else if text.data[i] == #char "}"  depth -= 1;
        i += 1;
    }
    return i - 1;
}

// Parse the keycodes section: lines like "<AD01> = 24;"
parse_keycodes_section :: (text: string, start: s64, end: s64, names: *[..] Keycode_Name) {
    i := start;
    while i < end {
        // Skip to next '<'
        while i < end && text.data[i] != #char "<"  i += 1;
        if i >= end  break;
        i += 1;  // skip '<'

        // Read name until '>'
        name_start := i;
        while i < end && text.data[i] != #char ">"  i += 1;
        if i >= end  break;
        name: string;
        name.data = text.data + name_start;
        name.count = i - name_start;
        i += 1;  // skip '>'

        // Skip to '='
        while i < end && text.data[i] != #char "="  i += 1;
        if i >= end  break;
        i += 1;  // skip '='

        // Skip whitespace
        while i < end && (text.data[i] == #char " " || text.data[i] == #char "\t")  i += 1;

        // Parse number
        num: s32 = 0;
        while i < end && text.data[i] >= #char "0" && text.data[i] <= #char "9" {
            num = num * 10 + cast(s32)(text.data[i] - #char "0");
            i += 1;
        }

        array_add(names, .{ name = name, xkb_code = num });
    }
}

// Look up an xkb keycode number by name
find_xkb_code :: (names: [] Keycode_Name, name: string) -> s32, bool {
    for names {
        if it.name.count == name.count {
            match := true;
            for j: 0..name.count-1 {
                if it.name.data[j] != name.data[j] { match = false; break; }
            }
            if match  return it.xkb_code, true;
        }
    }
    return 0, false;
}

// Parse the symbols section: entries like "key <AD01> { [ 0x71, 0x51 ] };"
parse_symbols_section :: (text: string, start: s64, end: s64,
                          names: [] Keycode_Name, keymap: *Keymap) {
    i := start;
    while i < end {
        // Find "key "
        if !match_keyword(text, i, end, "key ") {
            i += 1;
            continue;
        }
        i += 4;  // skip "key "

        // Skip whitespace
        while i < end && (text.data[i] == #char " " || text.data[i] == #char "\t")  i += 1;

        // Expect '<'
        if i >= end || text.data[i] != #char "<" { i += 1; continue; }
        i += 1;

        // Read keycode name
        name_start := i;
        while i < end && text.data[i] != #char ">"  i += 1;
        if i >= end  break;
        name: string;
        name.data = text.data + name_start;
        name.count = i - name_start;
        i += 1;  // skip '>'

        // Look up evdev keycode
        xkb_code, found := find_xkb_code(names, name);
        if !found { i += 1; continue; }
        evdev := xkb_code - 8;
        if evdev < 0 || evdev >= MAX_EVDEV_KEYCODE { i += 1; continue; }

        // Find the first '[' (keysym list)
        while i < end && text.data[i] != #char "["  i += 1;
        if i >= end  break;
        i += 1;  // skip '['

        // Parse hex keysyms until ']'
        entry := *keymap.entries[evdev];
        entry.count = 0;
        while i < end && text.data[i] != #char "]" {
            // Skip whitespace and commas
            while i < end && (text.data[i] == #char " " || text.data[i] == #char "\t" ||
                              text.data[i] == #char "," || text.data[i] == #char "\n")
                i += 1;

            if i >= end || text.data[i] == #char "]"  break;

            // Parse hex value (0x...)
            val: u32 = 0;
            if i + 1 < end && text.data[i] == #char "0" && text.data[i+1] == #char "x" {
                i += 2;
                while i < end {
                    c := text.data[i];
                    if c >= #char "0" && c <= #char "9" {
                        val = (val << 4) | cast(u32)(c - #char "0");
                    } else if c >= #char "a" && c <= #char "f" {
                        val = (val << 4) | cast(u32)(c - #char "a" + 10);
                    } else if c >= #char "A" && c <= #char "F" {
                        val = (val << 4) | cast(u32)(c - #char "A" + 10);
                    } else break;
                    i += 1;
                }
            } else {
                // Skip non-hex token (shouldn't happen in well-formed keymap)
                while i < end && text.data[i] != #char "," && text.data[i] != #char "]"
                    i += 1;
                continue;
            }

            if entry.count < MAX_KEYSYMS_PER_KEY {
                entry.keysyms[entry.count] = val;
                entry.count += 1;
            }
        }
    }
}

match_keyword :: (text: string, pos: s64, end: s64, keyword: string) -> bool {
    if pos + keyword.count > end  return false;
    for j: 0..keyword.count-1 {
        if text.data[pos + j] != keyword.data[j]  return false;
    }
    return true;
}
