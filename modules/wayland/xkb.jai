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

    text := string.{ data = cast(*u8) data, count = cast(s64) size };
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
        name := string.{ data = text.data + name_start, count = i - name_start };
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
        if it.name == name  return it.xkb_code, true;
    }
    return 0, false;
}

// Parse the symbols section. Handles both compact entries:
//   key <AD01> { [ 0x71, 0x51 ] };
// and xkbcommon-style entries:
//   key <FK04> { type=..., symbols[1]= [ F4, F4, ... ] };
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
        name := string.{ data = text.data + name_start, count = i - name_start };
        i += 1;  // skip '>'

        // Look up evdev keycode
        xkb_code, found := find_xkb_code(names, name);
        if !found { i += 1; continue; }
        evdev := xkb_code - 8;
        if evdev < 0 || evdev >= MAX_EVDEV_KEYCODE { i += 1; continue; }

        // Limit parsing to this key's block. This matters for forms such as
        // `symbols[1] = [ ... ]`, where the first '[' belongs to the group index,
        // not to the keysym list.
        while i < end && text.data[i] != #char "{"  i += 1;
        if i >= end  break;
        block_start := i + 1;
        block_end   := find_section_end(text, block_start);
        if block_end > end  block_end = end;
        i = block_end + 1;

        list_start := find_keysym_list_start(text, block_start, block_end);
        if list_start < 0  continue;

        // Parse keysyms until ']'.
        entry := *keymap.entries[evdev];
        entry.count = 0;
        j := list_start;
        while j < block_end && text.data[j] != #char "]" {
            // Skip whitespace and commas
            while j < block_end && (text.data[j] == #char " " || text.data[j] == #char "\t" ||
                                    text.data[j] == #char "," || text.data[j] == #char "\n")
                j += 1;

            if j >= block_end || text.data[j] == #char "]"  break;

            token_start := j;
            while j < block_end && text.data[j] != #char "," && text.data[j] != #char "]" &&
                  text.data[j] != #char " " && text.data[j] != #char "\t" && text.data[j] != #char "\n"
                j += 1;

            token := string.{ data = text.data + token_start, count = j - token_start };

            val, parsed := parse_keysym_token(token);
            if !parsed  val = 0;  // Preserve level positions for unknown names.

            if entry.count < MAX_KEYSYMS_PER_KEY {
                entry.keysyms[entry.count] = val;
                entry.count += 1;
            }
        }
    }
}

find_keysym_list_start :: (text: string, start: s64, end: s64) -> s64 {
    p := start;
    while p < end {
        if match_keyword(text, p, end, "symbols") {
            q := p + 7;
            while q < end && text.data[q] != #char "="  q += 1;
            if q < end {
                while q < end && text.data[q] != #char "["  q += 1;
                if q < end  return q + 1;
            }
        }
        p += 1;
    }

    p = start;
    while p < end && text.data[p] != #char "["  p += 1;
    if p < end  return p + 1;
    return -1;
}

parse_keysym_token :: (token: string) -> u32, bool {
    if token.count == 0  return 0, false;

    if token.count == 1 {
        c := token.data[0];
        if (c >= #char "a" && c <= #char "z") ||
           (c >= #char "A" && c <= #char "Z") ||
           (c >= #char "0" && c <= #char "9")
            return cast(u32) c, true;
    }

    if token.count >= 2 && token.data[0] == #char "0" && token.data[1] == #char "x" {
        val, ok, remainder := string_to_int(advance(token, 2), 16, u32);
        if ok && !remainder  return val, true;
        return 0, false;
    }

    if token.data[0] == #char "F" && token.count >= 2 {
        n, ok := parse_decimal_suffix(token, 1);
        if ok && n >= 1 && n <= 35  return 0xffbe + cast(u32)(n - 1), true;
    }

    if match_token(token, "NoSymbol") return 0, true;

    if match_token(token, "space")      return 0x0020, true;
    if match_token(token, "exclam")     return 0x0021, true;
    if match_token(token, "quotedbl")   return 0x0022, true;
    if match_token(token, "numbersign") return 0x0023, true;
    if match_token(token, "dollar")     return 0x0024, true;
    if match_token(token, "percent")    return 0x0025, true;
    if match_token(token, "ampersand")  return 0x0026, true;
    if match_token(token, "apostrophe") || match_token(token, "quoteright") return 0x0027, true;
    if match_token(token, "parenleft")  return 0x0028, true;
    if match_token(token, "parenright") return 0x0029, true;
    if match_token(token, "asterisk")   return 0x002a, true;
    if match_token(token, "plus")       return 0x002b, true;
    if match_token(token, "comma")      return 0x002c, true;
    if match_token(token, "minus")      return 0x002d, true;
    if match_token(token, "period")     return 0x002e, true;
    if match_token(token, "slash")      return 0x002f, true;
    if match_token(token, "colon")      return 0x003a, true;
    if match_token(token, "semicolon")  return 0x003b, true;
    if match_token(token, "less")       return 0x003c, true;
    if match_token(token, "equal")      return 0x003d, true;
    if match_token(token, "greater")    return 0x003e, true;
    if match_token(token, "question")   return 0x003f, true;
    if match_token(token, "at")         return 0x0040, true;
    if match_token(token, "bracketleft")  return 0x005b, true;
    if match_token(token, "backslash")    return 0x005c, true;
    if match_token(token, "bracketright") return 0x005d, true;
    if match_token(token, "asciicircum")  return 0x005e, true;
    if match_token(token, "underscore")   return 0x005f, true;
    if match_token(token, "grave") || match_token(token, "quoteleft") return 0x0060, true;
    if match_token(token, "braceleft")  return 0x007b, true;
    if match_token(token, "bar")        return 0x007c, true;
    if match_token(token, "braceright") return 0x007d, true;
    if match_token(token, "asciitilde") return 0x007e, true;

    if match_token(token, "ISO_Left_Tab") return 0xfe20, true;
    if match_token(token, "BackSpace")    return 0xff08, true;
    if match_token(token, "Tab")          return 0xff09, true;
    if match_token(token, "Linefeed")     return 0xff0a, true;
    if match_token(token, "Return")       return 0xff0d, true;
    if match_token(token, "Pause")        return 0xff13, true;
    if match_token(token, "Scroll_Lock")  return 0xff14, true;
    if match_token(token, "Escape")       return 0xff1b, true;
    if match_token(token, "Delete")       return 0xffff, true;

    if match_token(token, "Home")      return 0xff50, true;
    if match_token(token, "Left")      return 0xff51, true;
    if match_token(token, "Up")        return 0xff52, true;
    if match_token(token, "Right")     return 0xff53, true;
    if match_token(token, "Down")      return 0xff54, true;
    if match_token(token, "Prior") || match_token(token, "Page_Up")     return 0xff55, true;
    if match_token(token, "Next")  || match_token(token, "Page_Down")   return 0xff56, true;
    if match_token(token, "End")       return 0xff57, true;
    if match_token(token, "Print")     return 0xff61, true;
    if match_token(token, "Insert")    return 0xff63, true;
    if match_token(token, "Menu")      return 0xff67, true;

    if match_token(token, "ISO_Level3_Shift") return 0xfe03, true;
    if match_token(token, "Shift_L")   return 0xffe1, true;
    if match_token(token, "Shift_R")   return 0xffe2, true;
    if match_token(token, "Control_L") return 0xffe3, true;
    if match_token(token, "Control_R") return 0xffe4, true;
    if match_token(token, "Meta_L")    return 0xffe7, true;
    if match_token(token, "Meta_R")    return 0xffe8, true;
    if match_token(token, "Alt_L")     return 0xffe9, true;
    if match_token(token, "Alt_R")     return 0xffea, true;
    if match_token(token, "Super_L")   return 0xffeb, true;
    if match_token(token, "Super_R")   return 0xffec, true;
    if match_token(token, "Hyper_L")   return 0xffed, true;
    if match_token(token, "Hyper_R")   return 0xffee, true;

    if match_token(token, "KP_Space")     return 0xff80, true;
    if match_token(token, "KP_Tab")       return 0xff89, true;
    if match_token(token, "KP_Enter")     return 0xff8d, true;
    if match_token(token, "KP_Delete")    return 0xff9f, true;
    if match_token(token, "KP_Up")        return 0xff97, true;
    if match_token(token, "KP_Down")      return 0xff99, true;
    if match_token(token, "KP_Left")      return 0xff96, true;
    if match_token(token, "KP_Right")     return 0xff98, true;
    if match_token(token, "KP_Page_Up")   return 0xff9a, true;
    if match_token(token, "KP_Page_Down") return 0xff9b, true;
    if match_token(token, "KP_Home")      return 0xff95, true;
    if match_token(token, "KP_End")       return 0xff9c, true;
    if match_token(token, "KP_Insert")    return 0xff9e, true;

    return 0, false;
}

parse_decimal_suffix :: (token: string, start: s64) -> s32, bool {
    if start >= token.count  return 0, false;
    n, success, remainder := string_to_int(advance(token, start), 10, s32);
    return n, success && !remainder;
}

match_token :: (token: string, literal: string) -> bool {
    return token == literal;
}

match_keyword :: (text: string, pos: s64, end: s64, keyword: string) -> bool {
    if pos + keyword.count > end  return false;
    for j: 0..keyword.count-1 {
        if text.data[pos + j] != keyword.data[j]  return false;
    }
    return true;
}
