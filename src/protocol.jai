// ── Protocol data model ──

Protocol :: struct {
    name: string;
    copyright: string;
    interfaces: [..] Interface;
}

Interface :: struct {
    name: string;
    version: u32;
    description: Description;
    requests: [..] Message;
    events: [..] Message;
    enums: [..] Enum_Def;
}

Message :: struct {
    name: string;
    since: u32;
    is_destructor: bool;
    description: Description;
    args: [..] Arg;
}

Arg :: struct {
    name: string;
    arg_type: Arg_Type;
    interface_name: string;
    enum_name: string;
    allow_null: bool;
    summary: string;
}

Arg_Type :: enum u8 {
    INT;
    UINT;
    FIXED;
    STRING;
    OBJECT;
    NEW_ID;
    ARRAY;
    FD;
}

Enum_Def :: struct {
    name: string;
    since: u32;
    bitfield: bool;
    description: Description;
    entries: [..] Entry;
}

Entry :: struct {
    name: string;
    value: u32;
    since: u32;
    summary: string;
}

Description :: struct {
    summary: string;
    body: string;
}

// ── Protocol parser ──

parse_protocol :: (xml_source: string) -> Protocol {
    p := xml_parser_init(xml_source);
    proto: Protocol;

    while true {
        event, ok := xml_next(*p);
        if !ok break;
        if event.kind == {
            case .ATTRIBUTE;
                if event.name == "name" proto.name = event.value;
            case .OPEN_TAG;
                if event.name == "copyright"  proto.copyright = parse_copyright(*p);
                if event.name == "interface"  array_add(*proto.interfaces, parse_interface(*p));
                if event.name == "description" parse_description(*p);  // top-level description, discard
            case .CLOSE_TAG;
                if event.name == "protocol" break;
        }
    }
    return proto;
}

parse_interface :: (p: *Xml_Parser) -> Interface {
    iface: Interface;
    iface.version = 1;

    while true {
        event, ok := xml_next(p);
        if !ok break;
        if event.kind == {
            case .ATTRIBUTE;
                if event.name == "name"    iface.name = event.value;
                if event.name == "version" iface.version = parse_u32(event.value);
            case .OPEN_TAG;
                if event.name == "description" iface.description = parse_description(p);
                if event.name == "request"     array_add(*iface.requests, parse_message(p));
                if event.name == "event"       array_add(*iface.events, parse_message(p));
                if event.name == "enum"        array_add(*iface.enums, parse_enum(p));
            case .CLOSE_TAG;
                if event.name == "interface" break;
        }
    }
    return iface;
}

parse_message :: (p: *Xml_Parser) -> Message {
    msg: Message;
    msg.since = 1;

    while true {
        event, ok := xml_next(p);
        if !ok break;
        if event.kind == {
            case .ATTRIBUTE;
                if event.name == "name"  msg.name = event.value;
                if event.name == "since" msg.since = parse_u32(event.value);
                if event.name == "type"  { if event.value == "destructor" msg.is_destructor = true; }
            case .OPEN_TAG;
                if event.name == "description" msg.description = parse_description(p);
                if event.name == "arg"         array_add(*msg.args, parse_arg(p));
            case .CLOSE_TAG;
                if event.name == "request" || event.name == "event" break;
        }
    }
    return msg;
}

parse_arg :: (p: *Xml_Parser) -> Arg {
    arg: Arg;

    while true {
        event, ok := xml_next(p);
        if !ok break;
        if event.kind == {
            case .ATTRIBUTE;
                if event.name == "name"       arg.name = event.value;
                if event.name == "type"       arg.arg_type = string_to_arg_type(event.value);
                if event.name == "interface"  arg.interface_name = event.value;
                if event.name == "enum"       arg.enum_name = event.value;
                if event.name == "allow-null" arg.allow_null = (event.value == "true");
                if event.name == "summary"    arg.summary = event.value;
            case .OPEN_TAG;
                if event.name == "description" parse_description(p);  // consume and discard
            case .CLOSE_TAG;
                if event.name == "arg" break;
        }
    }
    return arg;
}

parse_enum :: (p: *Xml_Parser) -> Enum_Def {
    e: Enum_Def;
    e.since = 1;

    while true {
        event, ok := xml_next(p);
        if !ok break;
        if event.kind == {
            case .ATTRIBUTE;
                if event.name == "name"     e.name = event.value;
                if event.name == "since"    e.since = parse_u32(event.value);
                if event.name == "bitfield" e.bitfield = (event.value == "true");
            case .OPEN_TAG;
                if event.name == "description" e.description = parse_description(p);
                if event.name == "entry"       array_add(*e.entries, parse_entry(p));
            case .CLOSE_TAG;
                if event.name == "enum" break;
        }
    }
    return e;
}

parse_entry :: (p: *Xml_Parser) -> Entry {
    entry: Entry;
    entry.since = 1;

    while true {
        event, ok := xml_next(p);
        if !ok break;
        if event.kind == {
            case .ATTRIBUTE;
                if event.name == "name"    entry.name = event.value;
                if event.name == "value"   entry.value = parse_u32(event.value);
                if event.name == "since"   entry.since = parse_u32(event.value);
                if event.name == "summary" entry.summary = event.value;
            case .OPEN_TAG;
                if event.name == "description" parse_description(p);  // consume and discard
            case .CLOSE_TAG;
                if event.name == "entry" break;
        }
    }
    return entry;
}

parse_description :: (p: *Xml_Parser) -> Description {
    desc: Description;

    while true {
        event, ok := xml_next(p);
        if !ok break;
        if event.kind == {
            case .ATTRIBUTE;
                if event.name == "summary" desc.summary = event.value;
            case .CHARACTER_DATA;
                desc.body = xml_decode_entities(event.value);
            case .CLOSE_TAG;
                if event.name == "description" break;
        }
    }
    return desc;
}

parse_copyright :: (p: *Xml_Parser) -> string {
    text: string;
    while true {
        event, ok := xml_next(p);
        if !ok break;
        if event.kind == {
            case .CHARACTER_DATA;
                text = event.value;
            case .CLOSE_TAG;
                if event.name == "copyright" break;
        }
    }
    return text;
}

// ── Helpers ──

parse_u32 :: (s: string) -> u32 {
    if s.count == 0 return 0;

    // Handle hex prefix
    if s.count > 2 && s[0] == #char "0" && (s[1] == #char "x" || s[1] == #char "X") {
        result: u64 = 0;
        for 2..s.count-1 {
            c := s[it];
            result *= 16;
            if c >= #char "0" && c <= #char "9"      result += cast(u64)(c - #char "0");
            else if c >= #char "a" && c <= #char "f"  result += cast(u64)(c - #char "a" + 10);
            else if c >= #char "A" && c <= #char "F"  result += cast(u64)(c - #char "A" + 10);
        }
        return cast(u32) result;
    }

    // Handle negative numbers (treat as signed then cast)
    start := 0;
    negative := false;
    if s[0] == #char "-" { negative = true; start = 1; }

    result: u64 = 0;
    for start..s.count-1 {
        c := s[it];
        if c >= #char "0" && c <= #char "9" {
            result = result * 10 + cast(u64)(c - #char "0");
        }
    }

    if negative {
        signed_val := -cast(s32) result;
        return cast(u32) signed_val;
    }
    return cast(u32) result;
}

string_to_arg_type :: (s: string) -> Arg_Type {
    if s == "int"    return .INT;
    if s == "uint"   return .UINT;
    if s == "fixed"  return .FIXED;
    if s == "string" return .STRING;
    if s == "object" return .OBJECT;
    if s == "new_id" return .NEW_ID;
    if s == "array"  return .ARRAY;
    if s == "fd"     return .FD;
    return .INT;  // fallback
}
