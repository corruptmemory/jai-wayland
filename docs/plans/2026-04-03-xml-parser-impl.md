# XML Parser Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Parse Wayland protocol XML files into structured Jai data that a future code generator will consume.

**Architecture:** Two-layer design. Layer 1 (`xml.jai`) is a zero-copy pull parser that yields events as slices into the source string. Layer 2 (`protocol.jai`) drives the pull parser to build protocol structs. A `main.jai` test harness validates by parsing the vendored `wayland.xml` and printing a summary.

**Tech Stack:** Jai (beta 0.2.026), `#import "Basic"`, `#import "File"`, `#import "String"`. No external dependencies.

**Reference:** `vendor/reference/zig-wayland/src/xml.zig` (pull parser architecture), `vendor/reference/wayland-rs/wayland-scanner/src/protocol.rs` (data model).

---

### Task 1: Project skeleton and build verification

**Files:**
- Create: `src/main.jai`
- Create: `build.sh`

**Step 1: Create build.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
~/jai/jai/bin/jai-linux src/main.jai
```

**Step 2: Create minimal main.jai**

```jai
#import "Basic";

main :: () {
    print("jai-wayland build OK\n");
}
```

**Step 3: Run build and verify**

Run: `chmod +x build.sh && ./build.sh && ./main`
Expected: `jai-wayland build OK`

**Step 4: Commit**

```
feat: project skeleton with build.sh
```

---

### Task 2: XML pull parser — core types and tag parsing

**Files:**
- Create: `src/xml.jai`

**Step 1: Define core types**

The parser struct holds the remaining document as a `string` (pointer+length slice that advances). The `Xml_Event` is a tagged union. The parser operates in modes: `NORMAL` (between tags), `ATTRS` (inside an open tag, yielding attributes), `CHARS` (reading character data).

```jai
Xml_Parser :: struct {
    doc: string;                    // remaining unparsed document (advances as we consume)
    current_tag: string;            // name of the current open tag (for self-closing emit)
    mode: enum u8 {
        NORMAL;
        ATTRS;
        CHARS;
    };
}

Xml_Event :: struct {
    kind: Kind;
    name: string;                   // tag name (for OPEN_TAG, CLOSE_TAG), attr name (for ATTRIBUTE)
    value: string;                  // attr value (for ATTRIBUTE), text (for CHARACTER_DATA)

    Kind :: enum u8 {
        OPEN_TAG;
        CLOSE_TAG;
        ATTRIBUTE;
        CHARACTER_DATA;
        COMMENT;
        PROCESSING_INSTRUCTION;
    }
}

xml_parser_init :: (doc: string) -> Xml_Parser { ... }
xml_next :: (p: *Xml_Parser) -> (event: Xml_Event, ok: bool) { ... }
```

**Step 2: Implement NORMAL mode**

Handles:
- `<?...?>` → PROCESSING_INSTRUCTION
- `<!--...-->` → COMMENT
- `</tag>` → CLOSE_TAG
- `<tag` → OPEN_TAG, switch to ATTRS mode
- Other → switch to CHARS mode

All returned strings are slices into the original document (zero-copy).

Key helper: `advance :: (p: *Xml_Parser, n: s64)` — moves `doc.data` forward by n, shrinks `doc.count` by n.

**Step 3: Implement ATTRS mode**

After an OPEN_TAG, subsequent calls yield ATTRIBUTEs until we hit `>` (switch to NORMAL) or `/>` (emit CLOSE_TAG for self-closing, switch to NORMAL).

Attribute parsing: scan for `name="value"` or `name='value'`. Values are raw (entity decoding happens in consumer if needed).

**Step 4: Implement CHARS mode**

Scan forward until `<` is found. Everything before it is CHARACTER_DATA. Switch back to NORMAL.

**Step 5: Add skip_whitespace helper**

Used in NORMAL and ATTRS modes to skip spaces/tabs/newlines.

**Step 6: Wire into main.jai for smoke test**

```jai
#import "Basic";
#import "File";
#load "xml.jai";

main :: () {
    contents, ok := read_entire_file("vendor/wayland-protocols/core/wayland.xml");
    if !ok { print("Failed to read file\n"); return; }

    parser := xml_parser_init(contents);
    tag_count := 0;
    attr_count := 0;
    while true {
        event, has_event := xml_next(*parser);
        if !has_event break;
        if event.kind == .OPEN_TAG   tag_count += 1;
        if event.kind == .ATTRIBUTE  attr_count += 1;
    }
    print("Tags: %, Attributes: %\n", tag_count, attr_count);
}
```

Run: `./build.sh && ./main`
Expected: Prints tag and attribute counts (non-zero, no crash).

**Step 7: Commit**

```
feat: xml pull parser with tag, attribute, and character data parsing
```

---

### Task 3: XML pull parser — entity decoding

**Files:**
- Modify: `src/xml.jai`

**Step 1: Add xml_decode_entities utility**

This is NOT part of the pull parser's event stream — it's a utility the consumer calls on attribute values or character data when needed. The protocol XML descriptions contain `&amp;`, `&lt;`, `&gt;`, `&quot;`, `&apos;`.

```jai
// Returns a new string with entities replaced. Allocates only if entities are present.
xml_decode_entities :: (raw: string) -> string { ... }
```

Scan for `&`. If none found, return the original string (no allocation). If found, build result using `String_Builder`, replacing the 5 standard entities.

**Step 2: Verify with main.jai**

Add a quick test: decode `"a &amp; b &lt; c"` and print the result.

**Step 3: Commit**

```
feat: xml entity decoding for &amp; &lt; &gt; &quot; &apos;
```

---

### Task 4: Protocol data model

**Files:**
- Create: `src/protocol.jai`

**Step 1: Define all protocol structs**

```jai
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
    enums: [..] Enum;
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
    interface: string;     // empty if not applicable
    enum_name: string;     // empty if not applicable, can be "name" or "interface.name"
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

Enum :: struct {
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
```

**Step 2: Add parse_arg_type helper**

```jai
parse_arg_type :: (s: string) -> Arg_Type {
    if s == "int"    return .INT;
    if s == "uint"   return .UINT;
    // ... etc
}
```

**Step 3: Add parse_u32 helper**

Handles both decimal and `0x` hex values (needed for enum entry values like `0x20203843`).

**Step 4: Commit**

```
feat: protocol data model structs
```

---

### Task 5: Protocol parser — drive XML pull parser to build data model

**Files:**
- Modify: `src/protocol.jai`
- Modify: `src/main.jai`

**Step 1: Implement parse_protocol**

```jai
parse_protocol :: (xml_source: string) -> Protocol {
    parser := xml_parser_init(xml_source);
    protocol: Protocol;

    while true {
        event, ok := xml_next(*parser);
        if !ok break;

        if event.kind == .OPEN_TAG {
            if event.name == "protocol"  { parse_protocol_attrs(*parser, *protocol); }
            if event.name == "copyright" { protocol.copyright = parse_text_content(*parser, "copyright"); }
            if event.name == "interface" { array_add(*protocol.interfaces, parse_interface(*parser)); }
        }
    }
    return protocol;
}
```

**Step 2: Implement parse_interface**

Consumes attributes (name, version), then loops for child elements: description, request, event, enum. Returns when it sees `</interface>`.

**Step 3: Implement parse_message (shared by request and event)**

Consumes attributes (name, type="destructor", since), then child arg and description elements.

**Step 4: Implement parse_enum and parse_entry**

parse_enum: attributes name, since, bitfield. Children: description, entry.
parse_entry: attributes name, value (decimal or hex), since, summary.

**Step 5: Implement parse_arg**

Attributes: name, type, interface, enum, allow-null, summary.

**Step 6: Implement parse_description and parse_text_content helpers**

`parse_description`: collects summary attr + body text until `</description>`.
`parse_text_content`: collects all CHARACTER_DATA until the matching close tag.

**Step 7: Implement consume_attrs helper**

A small helper that reads all ATTRIBUTE events from the current position (until the next non-ATTRIBUTE event). Returns a fixed-size array or processes via callback. This avoids duplicating the attribute-reading loop in every parse_* function.

**Step 8: Update main.jai to parse and print summary**

```jai
main :: () {
    contents, ok := read_entire_file("vendor/wayland-protocols/core/wayland.xml");
    if !ok { print("Failed to read file\n"); return; }

    protocol := parse_protocol(contents);
    print("Protocol: %\n", protocol.name);
    print("Interfaces: %\n", protocol.interfaces.count);
    for protocol.interfaces {
        print("  % v% — % requests, % events, % enums\n",
              it.name, it.version, it.requests.count, it.events.count, it.enums.count);
    }
}
```

Run: `./build.sh && ./main`
Expected output (approximate):
```
Protocol: wayland
Interfaces: 22
  wl_display v1 — 2 requests, 2 events, 1 enums
  wl_registry v1 — 1 requests, 2 events, 0 enums
  wl_callback v1 — 0 requests, 1 events, 0 enums
  ...
```

**Step 9: Commit**

```
feat: protocol parser — parse wayland.xml into structured data model
```

---

### Task 6: Validate against all vendored protocol files

**Files:**
- Modify: `src/main.jai`

**Step 1: Parse all 59 vendored XML files**

Update main to walk the vendor/wayland-protocols directory tree (or just hard-code the paths for now), parse each file, and print a one-line summary per protocol. This validates the parser handles all edge cases across the full protocol corpus.

```jai
files :: string.[
    "vendor/wayland-protocols/core/wayland.xml",
    "vendor/wayland-protocols/stable/xdg-shell/xdg-shell.xml",
    // ... key files at minimum
];

for files {
    contents, ok := read_entire_file(it);
    if !ok { print("FAIL: %\n", it); continue; }
    protocol := parse_protocol(contents);
    print("OK: % — % interfaces\n", protocol.name, protocol.interfaces.count);
}
```

**Step 2: Fix any parse failures**

Common edge cases to watch for:
- Hex values in entry (`0x20203843`)
- Cross-interface enum refs (`enum="wl_shm.format"`)
- Self-closing tags (`<arg ... />`)
- `allow-null="true"` attribute
- `bitfield="true"` on enums
- `since` attribute on various elements

**Step 3: Commit**

```
feat: validate parser against all 59 vendored protocol XML files
```

---

### Task 7: Print detailed parse output for spot-checking

**Files:**
- Modify: `src/main.jai`

**Step 1: Add verbose output for wl_display interface**

Print all requests, events, enums with their args to verify correctness against the XML source. This serves as a human-readable validation.

**Step 2: Commit**

```
feat: verbose parse output for validation
```
