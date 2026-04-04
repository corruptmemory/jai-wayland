#import "String";

Xml_Parser :: struct {
    doc: string;
    current_tag: string;
    mode: enum u8 {
        NORMAL;
        ATTRS;
        CHARS;
    };
}

Xml_Event :: struct {
    kind: Kind;
    name: string;
    value: string;

    Kind :: enum u8 {
        OPEN_TAG;
        CLOSE_TAG;
        ATTRIBUTE;
        CHARACTER_DATA;
        COMMENT;
        PROCESSING_INSTRUCTION;
    }
}

xml_parser_init :: (doc: string) -> Xml_Parser {
    p: Xml_Parser;
    p.doc = doc;
    return p;
}

xml_next :: (p: *Xml_Parser) -> (event: Xml_Event, ok: bool) {
    ev: Xml_Event;
    has: bool;
    if p.mode == {
        case .NORMAL; ev, has = xml_next_normal(p);
        case .ATTRS;  ev, has = xml_next_attrs(p);
        case .CHARS;  ev, has = xml_next_chars(p);
    }
    return ev, has;
}

// ── helpers ──

advance :: (p: *Xml_Parser, n: s64) {
    p.doc.data += n;
    p.doc.count -= n;
}

skip_whitespace :: (p: *Xml_Parser) {
    while p.doc.count > 0 {
        c := p.doc[0];
        if c != #char " " && c != #char "\t" && c != #char "\n" && c != #char "\r"  break;
        advance(p, 1);
    }
}

peek :: (p: *Xml_Parser, offset: s64) -> (char: u8, ok: bool) {
    if offset >= p.doc.count  return 0, false;
    return p.doc[offset], true;
}

is_name_char :: (c: u8) -> bool {
    if c >= #char "A" && c <= #char "Z"  return true;
    if c >= #char "a" && c <= #char "z"  return true;
    if c >= #char "0" && c <= #char "9"  return true;
    if c == #char ":" || c == #char "_" || c == #char "-" || c == #char "."  return true;
    return false;
}

// ── mode implementations ──

xml_next_normal :: (p: *Xml_Parser) -> (event: Xml_Event, ok: bool) {
    ev: Xml_Event;

    skip_whitespace(p);
    c0, ok0 := peek(p, 0);
    if !ok0  return ev, false;

    if c0 == #char "<" {
        c1, ok1 := peek(p, 1);
        if !ok1  return ev, false;

        // Processing instruction: <?...?>
        if c1 == #char "?" {
            end := find_index_from_left(p.doc, "?>", 2);
            if end < 0  return ev, false;
            ev.kind = .PROCESSING_INSTRUCTION;
            ev.value.data = p.doc.data + 2;
            ev.value.count = end - 2;
            advance(p, end + 2);
            return ev, true;
        }

        // Close tag or comment
        if c1 == #char "/" {
            c2, ok2 := peek(p, 2);
            if !ok2  return ev, false;
            if is_name_char(c2) {
                end := find_index_from_left(p.doc, #char ">", 3);
                if end < 0  return ev, false;
                ev.kind = .CLOSE_TAG;
                ev.name.data = p.doc.data + 2;
                ev.name.count = end - 2;
                advance(p, end + 1);
                return ev, true;
            }
            return ev, false;
        }

        if c1 == #char "!" {
            c2, ok2 := peek(p, 2);
            if !ok2  return ev, false;
            if c2 == #char "-" {
                c3, ok3 := peek(p, 3);
                if !ok3  return ev, false;
                if c3 == #char "-" {
                    end := find_index_from_left(p.doc, "-->", 4);
                    if end < 0  return ev, false;
                    ev.kind = .COMMENT;
                    ev.value.data = p.doc.data + 4;
                    ev.value.count = end - 4;
                    advance(p, end + 3);
                    return ev, true;
                }
            }
            // CDATA
            if c2 == #char "[" && begins_with(slice(p.doc, 3, p.doc.count - 3), "CDATA[") {
                end := find_index_from_left(p.doc, "]]>", 9);
                if end < 0  return ev, false;
                ev.kind = .CHARACTER_DATA;
                ev.value.data = p.doc.data + 9;
                ev.value.count = end - 9;
                advance(p, end + 3);
                return ev, true;
            }
            return ev, false;
        }

        // Open tag: <tagname
        if is_name_char(c1) {
            // Find end of tag name: scan from index 1 until non-name char
            name_end : s64 = 1;
            while name_end < p.doc.count {
                if !is_name_char(p.doc[name_end])  break;
                name_end += 1;
            }
            ev.kind = .OPEN_TAG;
            ev.name.data = p.doc.data + 1;
            ev.name.count = name_end - 1;
            p.current_tag = ev.name;
            advance(p, name_end);
            p.mode = .ATTRS;
            return ev, true;
        }

        return ev, false;
    }

    // Not a '<' — switch to character data mode
    p.mode = .CHARS;
    chars_ev, chars_ok := xml_next_chars(p);
    return chars_ev, chars_ok;
}

xml_next_attrs :: (p: *Xml_Parser) -> (event: Xml_Event, ok: bool) {
    ev: Xml_Event;

    skip_whitespace(p);
    c0, ok0 := peek(p, 0);
    if !ok0  return ev, false;

    // End of tag: >
    if c0 == #char ">" {
        advance(p, 1);
        p.mode = .NORMAL;
        next_ev, next_ok := xml_next_normal(p);
        return next_ev, next_ok;
    }

    // Self-closing: />
    if c0 == #char "/" {
        c1, ok1 := peek(p, 1);
        if !ok1  return ev, false;
        if c1 != #char ">"  return ev, false;
        ev.kind = .CLOSE_TAG;
        ev.name = p.current_tag;
        advance(p, 2);
        p.mode = .NORMAL;
        return ev, true;
    }

    // Parse attribute name
    name_end : s64 = 0;
    while name_end < p.doc.count {
        if !is_name_char(p.doc[name_end])  break;
        name_end += 1;
    }
    if name_end == 0  return ev, false;

    attr_name: string;
    attr_name.data = p.doc.data;
    attr_name.count = name_end;
    advance(p, name_end);

    skip_whitespace(p);

    // Expect '='
    eq, eq_ok := peek(p, 0);
    if !eq_ok || eq != #char "="  return ev, false;
    advance(p, 1);

    skip_whitespace(p);

    // Expect quote
    quote, q_ok := peek(p, 0);
    if !q_ok  return ev, false;
    if quote != #char "\"" && quote != #char "'"  return ev, false;

    // Find closing quote
    end := find_index_from_left(p.doc, quote, 1);
    if end < 0  return ev, false;

    ev.kind = .ATTRIBUTE;
    ev.name = attr_name;
    ev.value.data = p.doc.data + 1;
    ev.value.count = end - 1;
    advance(p, end + 1);
    return ev, true;
}

xml_next_chars :: (p: *Xml_Parser) -> (event: Xml_Event, ok: bool) {
    ev: Xml_Event;

    i : s64 = 0;
    while i < p.doc.count {
        if p.doc[i] == #char "<" {
            ev.kind = .CHARACTER_DATA;
            ev.value.data = p.doc.data;
            ev.value.count = i;
            advance(p, i);
            p.mode = .NORMAL;
            return ev, true;
        }
        i += 1;
    }

    // Remaining text with no more tags
    if p.doc.count > 0 {
        ev.kind = .CHARACTER_DATA;
        ev.value = p.doc;
        advance(p, p.doc.count);
        p.mode = .NORMAL;
        return ev, true;
    }

    return ev, false;
}
